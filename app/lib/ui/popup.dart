import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' show RefreshIndicator;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/local_save.dart';
import '../data/repo.dart';
import '../data/save_prefs.dart';
import '../data/result_grouping.dart';
import '../data/temporal_parser.dart';
import '../data/text_transforms.dart';
import '../models/relic.dart';
import '../platform/store_safe.dart';
import 'coach_marks.dart';
import '../theme/relic_theme.dart';
import '../theme/tokens.dart';
import '../util/blob_open.dart';
import '../widgets/chrome.dart';
import '../widgets/controls.dart';
import '../widgets/date_range_calendar.dart';
import '../widgets/relic_drag.dart';
import '../widgets/relic_mark.dart';
import '../widgets/result_row.dart';
import '../platform/sound.dart';
import 'dialogs.dart';
import 'share_dialog.dart';
import 'toast.dart';

/// "2 days, 3 hours from now" — the two largest non-zero units of the gap
/// between now and [remindAtMs], up to months. Used in the reminder-set toast.
String _relativeFromNow(int remindAtMs) {
  var mins = (remindAtMs - DateTime.now().millisecondsSinceEpoch) ~/ 60000;
  if (mins < 1) return 'less than a minute from now';
  final months = mins ~/ (60 * 24 * 30);
  mins -= months * 60 * 24 * 30;
  final days = mins ~/ (60 * 24);
  mins -= days * 60 * 24;
  final hours = mins ~/ 60;
  mins -= hours * 60;
  final parts = <String>[];
  void add(int v, String unit) {
    if (v > 0) parts.add('$v $unit${v == 1 ? '' : 's'}');
  }

  add(months, 'month');
  add(days, 'day');
  add(hours, 'hour');
  add(mins, 'minute');
  return '${parts.take(2).join(', ')} from now';
}

/// A one-shot "open this relic in the editor" request, created fresh per
/// save & annotate hotkey press. Identity-compared (the SAME relic can be
/// annotated twice in a row), so it must be a NEW object each time.
class EditRequest {
  final Relic relic;

  /// False when the vault cap refused the promotion — the editor still opens
  /// (the item is saved to history), with a warning toast.
  final bool promoted;
  const EditRequest(this.relic, {this.promoted = true});
}

/// The history popup — the hero surface (design §07).
class PopupView extends StatefulWidget {
  final RelicRepo repo;
  final VoidCallback onClose;
  final VoidCallback onSettings;

  /// When set (and changed since the last build), the popup opens straight
  /// into the edit dialog for this relic — the save & annotate hotkey flow.
  final EditRequest? annotate;

  /// Fires when a modal dialog opens/closes over the list, so the host can
  /// suspend blur-to-close while the user is mid-edit (alt-tabbing to check
  /// something must not destroy a half-typed note).
  final void Function(bool open)? onModalChanged;

  /// Called after a relic is placed on the clipboard via an explicit pick
  /// (copy / Enter / double-click). Lets the host hide the window and, if the
  /// "paste on select" preference is on, paste into the frontmost app. Falls
  /// back to [onClose] when not provided.
  final VoidCallback? onPick;

  /// When set, the results list becomes pull-to-refresh (mobile): a downward
  /// drag invokes this (e.g. a re-sync). Desktop leaves it null.
  final Future<void> Function()? onRefresh;

  /// True while a background sync is in flight — drives the header spinner.
  final bool syncing;

  /// Desktop only: trigger the connect/sign-in flow. When set and the vault
  /// isn't synced, a slim "sign in to save & sync" banner is shown.
  final VoidCallback? onConnect;

  /// Desktop only: pin state + toggle. Pinning keeps the window open across
  /// focus loss (the host owns the blur handling); Esc still closes.
  final bool pinned;
  final VoidCallback? onPinToggle;

  /// Desktop only: fired by the host when the popup was EXPLICITLY closed
  /// (Esc / X / tray click). Clears every search constraint — text, tags,
  /// date, sort, scope — so the next summon starts fresh on All. Click-away
  /// hides don't fire it: an alt-tab detour keeps your place.
  final Listenable? resetSignal;

  /// Desktop only: fired by the host every time the window is summoned, so
  /// the search box regains focus and type-to-search works from the very
  /// first keystroke regardless of where focus ended up last time.
  final Listenable? summonSignal;

  /// Desktop only: whether the CURRENT summon is the mini picker. Set by the
  /// host per-summon (which hotkey fired, or the default), so the same PopupView
  /// renders compact or full without a persistent mode flag.
  final ValueListenable<bool>? miniSignal;

  /// Global hotkey lines for the "?" cheatsheet, e.g.
  /// ("Ctrl+Shift+Q", "Open history"). The host supplies live values so a
  /// rebound shortcut shows what the user actually set.
  final List<(String keys, String label)> globalShortcuts;

  /// Desktop only: true while clipboard capture is paused (tray toggle) —
  /// shows the "Capture paused" pill so a forgotten pause is never silent.
  /// [pausedUntil] supplies the auto-resume moment (null = until resumed);
  /// [onResumeCapture] resumes immediately.
  final ValueListenable<bool>? capturePaused;
  final DateTime? Function()? pausedUntil;
  final VoidCallback? onResumeCapture;

  const PopupView({
    super.key,
    required this.repo,
    required this.onClose,
    required this.onSettings,
    this.onPick,
    this.onRefresh,
    this.syncing = false,
    this.onConnect,
    this.annotate,
    this.onModalChanged,
    this.pinned = false,
    this.onPinToggle,
    this.resetSignal,
    this.summonSignal,
    this.miniSignal,
    this.globalShortcuts = const [],
    this.capturePaused,
    this.pausedUntil,
    this.onResumeCapture,
  });

  @override
  State<PopupView> createState() => _PopupViewState();
}

class _PopupViewState extends State<PopupView> {
  final _searchCtl = TextEditingController();
  final _searchFocus = FocusNode();
  final _scroll = ScrollController();
  // First-run coach marks (desktop): anchors + one-shot visibility.
  final _kSearch = GlobalKey();
  final _kCompose = GlobalKey();
  final _kSettings = GlobalKey();
  final _kList = GlobalKey();
  bool _showCoach = false;
  Scope _scope = Scope.all;
  SortMode _sort = SortMode.relevance;
  int _selected = 0;
  final bool _dragOver = false;
  Timer? _debounce;

  /// Date filter. [_manualRange] is set by the preset/calendar picker and wins
  /// over a range parsed live from the search box ([_parsed]); [_manualLabel] is
  /// a friendly preset name (null → derive from the dates).
  DateRange? _manualRange;
  String? _manualLabel;
  TemporalParse? _parsed;

  /// Active tag filters, kept separate from the free-text search box so a tag
  /// stays selected (and removable) while you type, and you can filter by tag
  /// alone. Combined into the repo query as `tag:` clauses.
  final List<String> _activeTags = [];

  final _toasts = ToastQueue();
  Widget? _dialog;

  /// Anchored row overflow menu (opened from a row's ⋯ button, or via
  /// right-click — [atCursor] switches the anchoring convention): the
  /// trigger's global rect plus the relic it acts on. Houses View / Edit /
  /// Share with Copy-as as a drill-in sub-list; the cursor-invoked variant
  /// adds Copy and Delete (Windows context-menu muscle memory). Rendered as
  /// its own lightweight overlay layer — no dim barrier, dismissed by
  /// Esc/outside tap.
  ({Rect anchor, Relic relic, bool atCursor})? _rowMenuFor;

  /// Anchored "why isn't this synced" popover, opened from a row's sync
  /// badge: reason + age + Retry.
  ({Rect anchor, Relic relic})? _syncInfoFor;

  /// Identifies the root Stack the ⋯ menu is positioned within. Used to convert
  /// the trigger's global anchor into the Stack's local space at build time
  /// (reading the last frame's settled transform), rather than calling
  /// globalToLocal inside the menu's LayoutBuilder during layout — where the
  /// ancestor transform isn't yet authoritative on the frame the menu appears,
  /// which made the panel drop low then snap up.
  final GlobalKey _rootStackKey = GlobalKey();

  /// True while the ⋯ menu shows the Copy-as sub-list instead of the actions.
  bool _rowMenuSub = false;

  /// The live "Deleted" undo toast and its restore action, set on delete and
  /// cleared when the toast leaves the queue. Drives Ctrl/Cmd+Z — undo works
  /// only while the toast is up.
  ToastMsg? _undoToast;
  Future<void> Function()? _undoRestore;

  /// Multi-select (Ctrl/Shift+click): uid → the Relic snapshot taken at
  /// selection time. A Map, not a Set, so bulk actions still work after the
  /// item scrolls out of the loaded window or the list re-sorts. Cleared on
  /// every query/scope/filter change (see _applyQuery) and after bulk actions.
  final Map<String, Relic> _multiSel = {};

  /// Separator for "Combine & paste" (feature_multi_combine). Cycles through
  /// newline / space / comma-space via the chip in the bulk bar.
  String _combineSep = '\n';

  /// Present collection facets (tag → count), recomputed when the corpus or
  /// scope changes. Shown as one-tap browse chips when not searching.
  Map<String, int> _collections = const {};

  /// Curated collection catalog: (label, tag, icon). Only those present show.
  static const _kCollections = <(String, String, IconData)>[
    ('Links', 'url', LucideIcons.link),
    ('Code', 'code', LucideIcons.code),
    ('Secrets', 'secret', LucideIcons.keyRound),
    ('Emails', 'email', LucideIcons.mail),
    ('JSON', 'json', LucideIcons.braces),
    ('Markdown', 'markdown', LucideIcons.hash),
    ('Colors', 'color', LucideIcons.palette),
    ('Paths', 'path', LucideIcons.folderTree),
    // Backed by the 'Document' extension chip (tag matching is
    // case-insensitive) — sift's generic 'file' tag is actively stripped in
    // favor of ext chips, so it was a dead facet.
    ('Documents', 'document', LucideIcons.fileText),
    ('Screenshots', 'screenshot', LucideIcons.monitor),
    ('Receipts', 'receipt', LucideIcons.receipt),
    ('Chats', 'chat', LucideIcons.messageSquare),
    ('To-dos', 'todo', LucideIcons.listChecks),
    ('Notes', 'note', LucideIcons.notebook),
    // Only shown when snippets exist (present-facet counting in
    // _presentCollections). Backed by the reserved 'snippet' user tag.
    ('Snippets', 'snippet', LucideIcons.scrollText),
    ('Photos', 'photo', LucideIcons.image),
    ('QR codes', 'qrcode', LucideIcons.qrCode),
    ('Charts', 'chart', LucideIcons.chartColumn),
    ('Diagrams', 'diagram', LucideIcons.workflow),
    ('Addresses', 'address', LucideIcons.mapPin),
    ('OTP codes', 'otp', LucideIcons.shieldCheck),
    ('Tracking', 'tracking', LucideIcons.truck),
    // Value-type facets from the semantic detectors (heuristic_tags.dart). Each
    // only shows in the strip when at least one relic carries it.
    ('Numbers', 'number', LucideIcons.binary),
    ('Prices', 'currency', LucideIcons.banknote),
    ('Times', 'time', LucideIcons.clock),
    ('Durations', 'duration', LucideIcons.timer),
    ('Mentions', 'handle', LucideIcons.atSign),
    ('Hashtags', 'hashtag', LucideIcons.hash),
    // Entity facets from the new deterministic detectors. `paper`/`bank` are the
    // unifying tags (doi/arxiv → paper; iban/swift/routing → bank).
    ('Papers', 'paper', LucideIcons.newspaper),
    ('Books', 'book', LucideIcons.book),
    ('Coordinates', 'geo', LucideIcons.map),
    ('Tables', 'table', LucideIcons.table),
    ('Tickets', 'ticket', LucideIcons.ticket),
    ('Bank', 'bank', LucideIcons.landmark),
    ('Coupons', 'coupon', LucideIcons.tag),
    ('Config', 'env', LucideIcons.settings),
  ];

  /// Prune the "open in default app" temp cache once per process.
  static bool _prunedViewCache = false;

  /// The current page window from the repo (SQLite-backed, indexed search),
  /// with exact-duplicate text rows collapsed for display (see
  /// [collapseDuplicates]). Every list interaction — keyboard nav, shift
  /// ranges, enter-to-copy — works on this collapsed view, so indexes stay
  /// consistent; a hidden duplicate resurfaces if its representative is
  /// deleted.
  List<GroupedRelic> get _grouped => collapseDuplicates(widget.repo.visible);
  List<Relic> get _results => [for (final g in _grouped) g.relic];

  int get _now => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  @override
  void initState() {
    super.initState();
    // On desktop the popup is summoned to type-and-filter, so focus the search
    // box immediately. On mobile that would pop the keyboard up over the list
    // before layout (and trips an IME size assertion) — let the user tap in.
    if (!(Platform.isAndroid || Platform.isIOS)) _searchFocus.requestFocus();
    widget.resetSignal?.addListener(_resetSearchState);
    widget.summonSignal?.addListener(_focusSearchOnSummon);
    widget.miniSignal?.addListener(_onChange);
    _toasts.addListener(_onChange);
    _scroll.addListener(_onScroll);
    // One-time housekeeping: clear stale "open in default app" temp files.
    if (!_prunedViewCache) {
      _prunedViewCache = true;
      unawaited(pruneRelicViewCache());
    }
    // Global Ctrl/Cmd+Z for undo-delete — a raw handler so it wins over the
    // search field's own text undo, but only while an undo is actually pending.
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
    // Seed the first page once the tree is mounted (avoids notify-during-build).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _applyQuery();
      _recomputeCollections();
      _maybeShowCoach();
      // Cold-start save & annotate: the request arrived with the first build.
      if (widget.annotate != null) _openAnnotate(widget.annotate!);
    });
  }

  /// Warm-path save & annotate: the State survives across window summons, so
  /// a new request arrives via didUpdateWidget. Identity comparison — each
  /// hotkey press mints a fresh EditRequest, even for the same relic.
  @override
  void didUpdateWidget(covariant PopupView old) {
    super.didUpdateWidget(old);
    if (!identical(widget.resetSignal, old.resetSignal)) {
      old.resetSignal?.removeListener(_resetSearchState);
      widget.resetSignal?.addListener(_resetSearchState);
    }
    if (!identical(widget.summonSignal, old.summonSignal)) {
      old.summonSignal?.removeListener(_focusSearchOnSummon);
      widget.summonSignal?.addListener(_focusSearchOnSummon);
    }
    final req = widget.annotate;
    if (req != null && !identical(req, old.annotate)) {
      _openAnnotate(req);
    }
  }

  /// Back to the default browse state: no text, no tag/date filters, default
  /// sort, All scope, scrolled to the top. Runs while the window is hidden
  /// (fired on explicit close), so the next summon opens fresh.
  void _resetSearchState() {
    if (!mounted) return;
    _debounce?.cancel();
    final dirty = _searching ||
        _scope != Scope.all ||
        _sort != SortMode.relevance ||
        _searchCtl.text.isNotEmpty;
    if (!dirty) return;
    _searchCtl.clear();
    _activeTags.clear();
    _manualRange = null;
    _manualLabel = null;
    _parsed = null;
    _scope = Scope.all;
    _sort = SortMode.relevance;
    _selected = 0;
    _multiSel.clear();
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _applyQuery();
  }

  /// Give the search box focus on every summon so typing filters immediately —
  /// unless a modal editor is up, which owns the keyboard.
  void _focusSearchOnSummon() {
    if (!mounted || _dialog != null) return;
    if (Platform.isAndroid || Platform.isIOS) return;
    _searchFocus.requestFocus();
  }

  /// Route every dialog open/close through one place so the host reliably
  /// learns when a modal is up (it suspends blur-to-close while the user is
  /// mid-edit — alt-tabbing must not destroy a half-typed note).
  void _setDialog(Widget? d) {
    if (!mounted) return;
    setState(() => _dialog = d);
    widget.onModalChanged?.call(d != null);
  }

  /// Open the save & annotate editor for a just-captured relic.
  void _openAnnotate(EditRequest req) {
    if (!req.promoted) {
      _toasts.show(ToastMsg(
        'Saved to history. Vault is full',
        severity: ToastSeverity.warning,
        icon: LucideIcons.triangleAlert,
      ));
    }
    _edit(req.relic, autofocus: true, savedToast: 'Saved to Vault');
  }

  /// First-run coach marks: desktop only, once (persisted). A short delay lets
  /// the window + header/list settle so the anchors measure.
  void _maybeShowCoach() {
    if (Platform.isAndroid || Platform.isIOS) return;
    if (widget.repo.coachMarksSeen) return;
    Future.delayed(const Duration(milliseconds: 350), () {
      if (mounted && !widget.repo.coachMarksSeen) {
        setState(() => _showCoach = true);
      }
    });
  }

  void _dismissCoach() {
    setState(() => _showCoach = false);
    widget.repo.markCoachMarksSeen();
  }

  List<CoachStep> _coachSteps() => [
        CoachStep(
          targetKey: _kSearch,
          title: 'Find anything, instantly',
          body:
              'Search by keyword or by meaning. Relic reads text, screenshots and files on-device, so "that receipt" or "the api key" just finds it.',
        ),
        CoachStep(
          targetKey: _kCompose,
          title: 'Add things yourself',
          body:
              'Hit + for a quick note, or paste and drop in text, files and screenshots. Everything you copy is captured here automatically, too.',
        ),
        CoachStep(
          targetKey: _kList,
          title: 'Tag & describe for recall',
          body:
              'Open any item to edit its tags and description. Relic auto-tags, but a quick tweak makes it far easier to find later.',
        ),
        CoachStep(
          targetKey: _kSettings,
          title: 'Hotkeys & settings',
          body:
              'Set the global hotkey to summon Relic from anywhere, plus capture preferences and more, in Settings.',
        ),
      ];

  /// Slim persistent nudge shown while the vault isn't synced (demo / local-only).
  Widget _connectBanner(RelicColors c) => GestureDetector(
        onTap: widget.onConnect,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(14, 8, 12, 8),
            decoration: BoxDecoration(
              color: c.accent.withValues(alpha: 0.10),
              border: Border(bottom: BorderSide(color: c.border, width: 1)),
            ),
            child: Row(children: [
              Icon(LucideIcons.cloud, size: 14, color: c.accent),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  "You're browsing locally. Sign in to save & sync everywhere.",
                  style: RelicTheme.sans(size: 11.5, color: c.textSecondary),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 4),
                decoration: BoxDecoration(
                  color: c.accent,
                  borderRadius: BorderRadius.circular(Radii.chip),
                ),
                child: Text('Sign in',
                    style: RelicTheme.sans(
                        size: 11, weight: FontWeight.w600, color: c.onAccent)),
              ),
            ]),
          ),
        ),
      );

  /// Slim "capture is paused" pill: a forgotten pause used to silently eat
  /// copies for days — now it's visible on every summon, with one-tap Resume
  /// and the auto-resume time when a timed pause is running.
  Widget _pausedBanner(RelicColors c) {
    final until = widget.pausedUntil?.call();
    var label = 'Capture paused';
    if (until != null) {
      final mins = until.difference(DateTime.now()).inMinutes + 1;
      if (mins >= 55) {
        label = 'Capture paused for about an hour';
      } else if (mins > 0) {
        label = 'Capture paused for $mins min';
      }
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 7, 12, 7),
      decoration: BoxDecoration(
        color: c.warningDim.withValues(alpha: 0.10),
        border: Border(bottom: BorderSide(color: c.border, width: 1)),
      ),
      child: Row(children: [
        Icon(LucideIcons.pause, size: 13, color: c.warningDim),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            label,
            style: RelicTheme.sans(size: 11.5, color: c.textSecondary),
          ),
        ),
        const SizedBox(width: 8),
        if (widget.onResumeCapture != null)
          GhostButton(
            label: 'Resume',
            size: 26,
            fontSize: 11,
            onTap: widget.onResumeCapture,
          ),
      ]),
    );
  }

  /// A fake example tile shown behind the coach marks when the vault is empty,
  /// so the "tag & describe" step has a real target to spotlight.
  Widget _coachSampleTile(RelicColors c) => Padding(
        padding: const EdgeInsets.all(8),
        child: Container(
          key: _kList,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(Radii.tile),
            border: Border.all(color: c.border, width: 1),
          ),
          child: Row(children: [
            Icon(LucideIcons.image, size: 18, color: c.accent),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Design mockup, checkout screen',
                      style: RelicTheme.sans(
                          size: 13, weight: FontWeight.w500, color: c.text)),
                  const SizedBox(height: 3),
                  Text('Example item. Open it to edit its tags & description.',
                      style: RelicTheme.sans(size: 11.5, color: c.textMuted)),
                  const SizedBox(height: 7),
                  Row(children: [
                    _sampleChip(c, 'design'),
                    const SizedBox(width: 6),
                    _sampleChip(c, 'checkout'),
                    const SizedBox(width: 6),
                    _sampleChip(c, 'screenshot'),
                  ]),
                ],
              ),
            ),
          ]),
        ),
      );

  Widget _sampleChip(RelicColors c, String t) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: c.accent.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(Radii.chip),
        ),
        child: Text('#$t', style: RelicTheme.mono(size: 10, color: c.accentMuted)),
      );

  /// Recompute the present collection facets (cheap COUNT per candidate tag).
  /// Called on corpus/scope changes, not on every keystroke.
  void _recomputeCollections() {
    if (!mounted) return;
    final counts = widget.repo.tagCounts(
      _kCollections.map((e) => e.$2),
      vaultOnly: _scope == Scope.vault,
    );
    setState(() => _collections = counts);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    widget.resetSignal?.removeListener(_resetSearchState);
    widget.summonSignal?.removeListener(_focusSearchOnSummon);
    widget.miniSignal?.removeListener(_onChange);
    _toasts.removeListener(_onChange);
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    _scroll.dispose();
    _searchCtl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _onChange() {
    // When the undo toast expires or is dismissed, the undo window closes.
    if (_undoToast != null && !_toasts.items.contains(_undoToast)) {
      _undoToast = null;
      _undoRestore = null;
    }
    if (mounted) setState(() {});
  }

  /// Raw key handler for Ctrl/Cmd+Z. Returns true (swallowing the event, so the
  /// search box doesn't also text-undo) only when a delete is undoable.
  bool _onHardwareKey(KeyEvent e) {
    if (e is! KeyDownEvent || _undoRestore == null) return false;
    if (e.logicalKey != LogicalKeyboardKey.keyZ) return false;
    final mod = HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    if (!mod) return false;
    _performUndo();
    return true;
  }

  /// Run the pending undo (restore the relic) and clear the window.
  void _performUndo() {
    final restore = _undoRestore;
    final toast = _undoToast;
    _undoRestore = null;
    _undoToast = null;
    if (toast != null) _toasts.dismiss(toast);
    if (restore != null) restore();
  }

  /// Push the active search + scope to the repo and refresh the window. The
  /// query is the active tag filters (`tag:`) plus the free-text box. A date
  /// phrase typed in the box is parsed into a range and stripped from the FTS
  /// text; a manually-picked range (preset/calendar) overrides any parsed one.
  /// Sort directives typed into the box ("latest invoice"): the word is
  /// stripped from the FTS text and forces a date sort for THIS query (the
  /// sort chip is untouched). Conservative vocabulary — "last"/"first" are too
  /// ambiguous ("last name", "first aid"), and "last week" already belongs to
  /// the temporal parser.
  static final _newestDirective =
      RegExp(r'\b(latest|newest|most recent)\b', caseSensitive: false);
  static final _oldestDirective =
      RegExp(r'\b(oldest|earliest)\b', caseSensitive: false);

  void _applyQuery() {
    _multiSel.clear(); // a changed result set invalidates the selection
    final raw = _searchCtl.text.trim();
    final parsed = parseTemporal(raw);
    _parsed = parsed;
    final range = _effectiveRange;
    // When the range came from typing, search the residual (phrase removed) so
    // FTS doesn't also try to match "last week" as words. A manual range leaves
    // the box text alone.
    var text =
        _manualRange != null ? raw : (parsed.hasRange ? parsed.residual : raw);
    var sort = _sort;
    if (_newestDirective.hasMatch(text)) {
      text = text.replaceAll(_newestDirective, ' ').trim();
      sort = SortMode.newest;
    } else if (_oldestDirective.hasMatch(text)) {
      text = text.replaceAll(_oldestDirective, ' ').trim();
      sort = SortMode.oldest;
    }
    final query = [
      for (final t in _activeTags) 'tag:$t',
      if (text.isNotEmpty) text,
    ].join(' ');
    widget.repo.setQuery(
      query,
      _scope,
      sort: sort,
      createdAfter: range?.after,
      createdBefore: range?.before,
    );
    if (mounted) setState(() {});
  }

  /// The active date range: a manual pick wins, else one parsed from the box.
  DateRange? get _effectiveRange =>
      _manualRange ?? (_parsed?.hasRange == true ? _parsed!.range : null);

  /// True when anything is constraining the list (text, a tag, or a date range).
  bool get _searching =>
      _searchCtl.text.trim().isNotEmpty ||
      _activeTags.isNotEmpty ||
      _effectiveRange != null;

  /// Add/remove a tag from the active filter set.
  void _toggleTag(String tag) {
    setState(() {
      if (!_activeTags.remove(tag)) _activeTags.add(tag);
      _selected = 0;
    });
    _applyQuery();
  }

  void _cycleSort() {
    setState(() {
      _sort = SortMode.values[(_sort.index + 1) % SortMode.values.length];
      _selected = 0;
    });
    _applyQuery();
  }

  void _onSearchChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 140), () {
      _selected = 0;
      _applyQuery();
    });
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    if (pos.pixels >= pos.maxScrollExtent - 400 && widget.repo.hasMore) {
      widget.repo.loadMore();
      if (mounted) setState(() {});
    }
  }

  void _move(int delta) {
    final n = _results.length;
    if (n == 0) return;
    setState(() => _selected = (_selected + delta).clamp(0, n - 1));
    // Mini picker scrolls through everything: keep the selection visible and
    // page in more history as it nears the end.
    if (widget.miniSignal?.value ?? false) {
      _scrollMiniToSelected();
      if (_selected >= n - 3 && widget.repo.hasMore) {
        widget.repo.loadMore();
      }
    }
  }

  /// The mini picker's list: dense rows, scrollable through the whole result
  /// set (the window caps at [MiniResultRow.maxRows] tall and scrolls beyond),
  /// with the same near-bottom load-more as the full list via [_scroll].
  Widget _miniList(RelicColors c, List<Relic> results, bool searching) {
    if (results.isEmpty) {
      return Align(
        alignment: Alignment.topCenter,
        child: SizedBox(
          height: MiniResultRow.height,
          child: Center(
            child: Text(
              searching ? 'No matches' : 'Nothing here yet',
              style: RelicTheme.sans(size: 12, color: c.textFaintest),
            ),
          ),
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
      itemCount: results.length,
      itemBuilder: (_, i) {
        final r = results[i];
        return MiniResultRow(
          relic: r,
          selected: i == _selected,
          imagePath: widget.repo.localImagePath(r),
          syncing: widget.repo.relicSync(r) != RelicSync.synced ||
              widget.repo.uploadFraction(r) != null,
          onSelect: () => setState(() => _selected = i),
          onActivate: () => _copy(r),
        );
      },
    );
  }

  /// Keep the arrow-selected mini row in view (fixed 30px rows → offset math)
  /// and pull more history as the selection nears the end.
  void _scrollMiniToSelected() {
    if (!_scroll.hasClients) return;
    const pad = 4.0;
    final top = pad + _selected * MiniResultRow.height;
    final bottom = top + MiniResultRow.height;
    final pos = _scroll.position;
    final off = pos.pixels;
    double? target;
    if (top < off) {
      target = top - pad;
    } else if (bottom > off + pos.viewportDimension) {
      target = bottom - pos.viewportDimension + pad;
    }
    if (target != null) {
      _scroll.jumpTo(target.clamp(0.0, pos.maxScrollExtent));
    }
  }

  /// Wrap the results list in a pull-to-refresh affordance when the host
  /// provided [PopupView.onRefresh] (mobile); otherwise return it unchanged.
  Widget _maybeRefresh(RelicColors c, Widget list) {
    final onRefresh = widget.onRefresh;
    if (onRefresh == null) return list;
    return RefreshIndicator(
      onRefresh: onRefresh,
      color: c.accent,
      backgroundColor: c.panel,
      child: list,
    );
  }

  Future<void> _copy(Relic r) async {
    await widget.repo.putOnClipboard(r);
    _toasts.show(
      ToastMsg(
        r.kind == Kind.photo ? 'Image copied' : 'Copied to clipboard',
        severity: ToastSeverity.success,
        icon: LucideIcons.circleCheck,
      ),
    );
    (widget.onPick ?? widget.onClose)();
  }

  /// Open the reminder scheduler for [r] (feature_reminders). Re-renders after
  /// a clear so the scheduled list stays current without closing the dialog.
  void _openRemind(Relic r) {
    void show() {
      final pending = [
        for (final rem in widget.repo.remindersFor(r.uid))
          (rem.id, rem.remindAt),
      ];
      _setDialog(RemindDialog(
        preview: r.displayTitle,
        pending: pending,
        onCancel: () => _setDialog(null),
        onClear: (id) {
          widget.repo.clearReminder(id);
          show();
        },
        onPick: (ms) {
          widget.repo.addReminder(r.uid, ms);
          _setDialog(null);
          _toasts.show(ToastMsg(
            'Reminder set for ${_relativeFromNow(ms)}',
            severity: ToastSeverity.success,
            icon: LucideIcons.alarmClock,
          ));
        },
      ));
    }

    show();
  }

  /// Open a link relic in the system browser. Shown only for items that
  /// contain a URL; falls back to a toast if the link can't be launched.
  Future<void> _openLink(Relic r) async {
    final url = r.firstUrl;
    if (url == null) return;
    final uri = Uri.tryParse(url);
    var ok = false;
    if (uri != null) {
      try {
        ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {
        ok = false;
      }
    }
    if (ok) {
      // Step aside for the browser: our popup is always-on-top, so leaving it
      // up would sit over the page we just opened.
      widget.onClose();
      return;
    }
    if (mounted) {
      _toasts.show(ToastMsg(
        "Couldn't open link",
        severity: ToastSeverity.warning,
        icon: LucideIcons.triangleAlert,
      ));
    }
  }

  /// Open a file/image relic in the OS default app (decrypt → temp file → hand
  /// off). Shown only for blob-backed file/photo relics.
  Future<void> _openFile(Relic r) async {
    final ok = await openRelicExternally(widget.repo, r);
    if (ok) {
      // Step aside for the app that's about to open the file (same reason as
      // _openLink): our always-on-top window would otherwise cover it.
      widget.onClose();
      return;
    }
    if (mounted) {
      _toasts.show(ToastMsg(
        // Offline with a blob that was never downloaded is the common case
        // here, and it's the one the user can actually do something about.
        blobUnavailableMessage(widget.repo, r, 'open'),
        severity: ToastSeverity.warning,
        icon: LucideIcons.triangleAlert,
      ));
    }
  }

  /// Row download: save the blob to the Save folder (Downloads by default) and
  /// put the written PATH on the clipboard so it can be pasted anywhere. We do
  /// NOT pop the file manager open — a folder window stealing focus on every
  /// download is more nuisance than help; the copied path is the way to it.
  /// Desktop blob rows only.
  Future<void> _download(Relic r) async {
    try {
      final path = await saveBlobToDisk(widget.repo, r);
      await widget.repo.putTextOnClipboard(path);
      if (mounted) {
        _toasts.show(ToastMsg(
          'Saved · path copied',
          severity: ToastSeverity.success,
          icon: LucideIcons.download,
        ));
      }
    } catch (_) {
      if (mounted) {
        _toasts.show(ToastMsg(
          "Couldn't save file",
          severity: ToastSeverity.warning,
          icon: LucideIcons.triangleAlert,
        ));
      }
    }
  }

  /// Mobile "Save to device" (row menu). Shares one implementation with the
  /// viewer's save action so the two can't drift: both honour the Save location
  /// setting, both stream from the cached decrypted file, and both report where
  /// the file actually landed.
  ///
  /// This used to be its own copy calling FileSaver.saveFile, which on Android
  /// writes to app-private storage the user cannot browse — and which reports
  /// failure as a success string, so this toast said "Saved to your device"
  /// even when nothing had been written.
  Future<void> _saveToDevice(Relic r) async {
    try {
      final outcome = await saveBlobOnMobile(widget.repo, r);
      if (!mounted || outcome.canceled) return;
      _toasts.show(ToastMsg(
        outcome.location != null
            ? 'Saved to ${outcome.location}'
            : 'Saved to your device',
        severity: ToastSeverity.success,
        icon: LucideIcons.download,
      ));
    } catch (e) {
      if (mounted) {
        _toasts.show(ToastMsg(
          "Couldn't save: $e",
          severity: ToastSeverity.warning,
          icon: LucideIcons.triangleAlert,
        ));
      }
    }
  }

  Future<void> _promote(Relic r) async {
    final nowPromoted = !r.promoted;
    await widget.repo.promote(r, nowPromoted);
    _toasts.show(
      ToastMsg(
        nowPromoted ? 'Promoted to Vault' : 'Removed from Vault',
        severity: ToastSeverity.accent,
        icon: LucideIcons.gem,
        iconBuilder: (sz, col) =>
            RelicMark(size: sz, color: col, facets: false),
      ),
    );
    if (nowPromoted && widget.repo.promotionSound) {
      unawaited(playPromotionSound());
    }
    // No in-popup gem flourish — the native gem toast covers the closed-window
    // case (see desktop.dart). Just refresh to reflect the new vault state.
    setState(() {});
    _recomputeCollections();
  }

  /// Delete entry point. A vault item (promoted) is curated, so deleting one is
  /// gated behind a confirm dialog — the deliberate safety net. Stream-only
  /// items delete quietly with a short Undo window (toast button or Ctrl/Cmd+Z,
  /// while the toast is up) that genuinely restores the relic and its blob.
  Future<void> _delete(Relic r) async {
    if (r.promoted) {
      _setDialog(
        ConfirmDialog(
          title: 'Delete from Vault?',
          message:
              'This permanently removes “${r.displayTitle}” from your vault. This can’t be undone.',
          confirmLabel: 'Delete',
          onCancel: () => _setDialog(null),
          onConfirm: () async {
            _setDialog(null);
            await widget.repo.delete(r);
            _toasts.show(
              ToastMsg(
                'Removed from Vault',
                severity: ToastSeverity.neutral,
                icon: LucideIcons.trash2,
              ),
            );
            setState(() {});
            _recomputeCollections();
          },
        ),
      );
      return;
    }
    final canUndo = widget.repo.canUndoDelete;
    final blob = canUndo ? await widget.repo.snapshotBlob(r) : null;
    await widget.repo.delete(r);
    if (canUndo) {
      _undoRestore = () async {
        await widget.repo.restore(r, blob: blob);
        if (mounted) setState(() {});
        _recomputeCollections();
      };
    }
    final toast = ToastMsg(
      'Deleted',
      severity: ToastSeverity.neutral,
      icon: LucideIcons.trash2,
      action: canUndo ? 'Undo' : null,
      duration: const Duration(seconds: 5),
      onAction: canUndo ? _performUndo : null,
    );
    _undoToast = canUndo ? toast : null;
    _toasts.show(toast);
    setState(() {});
    _recomputeCollections();
  }

  /// Row tap router: plain click keeps the existing single-selection;
  /// Ctrl/Cmd+click toggles the row in the multi-select set (and moves the
  /// anchor); Shift+click selects the range from the anchor over the loaded
  /// results. ResultRow already bypasses double-tap detection for these.
  void _rowTapped(int i, Relic r) {
    final hk = HardwareKeyboard.instance;
    if (hk.isControlPressed || hk.isMetaPressed) {
      setState(() {
        if (_multiSel.remove(r.uid) == null) _multiSel[r.uid] = r;
        _selected = i; // anchor for a following shift-click
      });
    } else if (hk.isShiftPressed) {
      final res = _results;
      final lo = _selected < i ? _selected : i;
      final hi = _selected < i ? i : _selected;
      setState(() {
        for (var k = lo; k <= hi && k < res.length; k++) {
          _multiSel[res[k].uid] = res[k];
        }
      });
    } else {
      setState(() => _selected = i);
      // Two-pane: a plain tap shows the relic in the detail pane ("list on
      // the left, selected relic on the right"). Phone widths keep tap =
      // select (the action cluster) with double-tap opening the editor.
      if (_twoPane(context)) _edit(r);
    }
  }

  /// Bulk delete with ONE undo group: every selected relic (and its blob) is
  /// snapshotted, deleted, and restorable together via the toast or Ctrl+Z.
  /// Vault items keep the deliberate confirm gate, but stay in the undo group
  /// — a uniform group beats partially-restorable batches.
  Future<void> _bulkDelete() async {
    final items = _multiSel.values.toList();
    if (items.isEmpty) return;
    Future<void> doIt() async {
      final canUndo = widget.repo.canUndoDelete;
      final snaps = <(Relic, Uint8List?)>[];
      for (final r in items) {
        snaps.add((r, canUndo ? await widget.repo.snapshotBlob(r) : null));
        await widget.repo.delete(r);
      }
      if (canUndo) {
        _undoRestore = () async {
          for (final (r, b) in snaps) {
            await widget.repo.restore(r, blob: b);
          }
          if (mounted) setState(() {});
          _recomputeCollections();
        };
      }
      final toast = ToastMsg(
        '${items.length} deleted',
        severity: ToastSeverity.neutral,
        icon: LucideIcons.trash2,
        action: canUndo ? 'Undo' : null,
        duration: const Duration(seconds: 5),
        onAction: canUndo ? _performUndo : null,
      );
      _undoToast = canUndo ? toast : null;
      _toasts.show(toast);
      setState(_multiSel.clear);
      _recomputeCollections();
    }

    if (items.any((r) => r.promoted)) {
      _setDialog(
        ConfirmDialog(
          title: 'Delete ${items.length} items?',
          message:
              'This includes items saved to your Vault. You can undo for a few seconds afterwards.',
          confirmLabel: 'Delete',
          onCancel: () => _setDialog(null),
          onConfirm: () {
            _setDialog(null);
            doIt();
          },
        ),
      );
    } else {
      await doIt();
    }
  }

  /// Merge-copy: join the selected TEXT items into one clipboard write, in
  /// display order (selection order for anything that re-sorted out of the
  /// current results). Photos/files are skipped; the toast says so.
  /// Join the selected TEXT relics in display order using [sep]. Returns
  /// (joinedText, sensitive, mergedCount, skippedNonText) or null when nothing
  /// selected / no text to merge. Shared by "Copy" and "Combine & paste".
  Future<(String, bool, int, int)?> _joinSelectedText(String sep) async {
    final items = _multiSel.values.toList();
    if (items.isEmpty) return null;
    final order = <String, int>{};
    final res = _results;
    for (var i = 0; i < res.length; i++) {
      order[res[i].uid] = i;
    }
    var next = res.length;
    for (final r in items) {
      order.putIfAbsent(r.uid, () => next++);
    }
    items.sort((a, b) => order[a.uid]!.compareTo(order[b.uid]!));

    final parts = <String>[];
    var sensitive = false;
    for (final r in items) {
      if (r.kind != Kind.string) continue;
      final t = await widget.repo.textOf(r);
      if (t == null || t.isEmpty) continue;
      parts.add(t);
      sensitive = sensitive || r.isSecret;
    }
    if (parts.isEmpty) return null;
    return (parts.join(sep), sensitive, parts.length, items.length - parts.length);
  }

  Future<void> _bulkCopy() async {
    final j = await _joinSelectedText('\n');
    if (j == null) {
      if (_multiSel.isNotEmpty) {
        _toasts.show(ToastMsg(
          'Only text items can merge',
          severity: ToastSeverity.neutral,
          icon: LucideIcons.info,
        ));
      }
      return;
    }
    final (text, sensitive, merged, skipped) = j;
    await widget.repo.putTextOnClipboard(text, sensitive: sensitive);
    _toasts.show(ToastMsg(
      skipped == 0
          ? 'Copied $merged items as one'
          : 'Copied $merged text items as one ($skipped skipped)',
      severity: ToastSeverity.success,
      icon: LucideIcons.copy,
    ));
    setState(_multiSel.clear);
  }

  /// Combine the selected text (feature_multi_combine) with the chosen
  /// separator and paste it as one block into the frontmost app, reusing the
  /// normal pick → hide → sendPaste host path.
  Future<void> _combinePaste() async {
    final j = await _joinSelectedText(_combineSep);
    if (j == null) {
      if (_multiSel.isNotEmpty) {
        _toasts.show(ToastMsg(
          'Only text items can combine',
          severity: ToastSeverity.neutral,
          icon: LucideIcons.info,
        ));
      }
      return;
    }
    await widget.repo.putTextOnClipboard(j.$1, sensitive: j.$2);
    _multiSel.clear();
    (widget.onPick ?? widget.onClose)();
  }

  /// The display label for the current combine separator.
  String get _combineSepLabel => switch (_combineSep) {
        ' ' => 'space',
        ', ' => 'comma',
        _ => 'newline',
      };

  void _cycleCombineSep() => setState(() {
        _combineSep = switch (_combineSep) {
          '\n' => ' ',
          ' ' => ', ',
          _ => '\n',
        };
      });

  /// Copy [r]'s text through a transform (the row ⋯ "Copy as" menu).
  Future<void> _copyAs(Relic r, String label, String Function(String) fn) async {
    final t = await widget.repo.textOf(r);
    if (t == null) return;
    await widget.repo.putTextOnClipboard(fn(t), sensitive: r.isSecret);
    _toasts.show(ToastMsg(
      'Copied as $label',
      severity: ToastSeverity.success,
      icon: LucideIcons.circleCheck,
    ));
  }

  /// Bulk tag: one tag applied to every selected relic's user tags.
  void _bulkTag() {
    if (_multiSel.isEmpty) return;
    _setDialog(
      BulkTagDialog(
        count: _multiSel.length,
        onCancel: () => _setDialog(null),
        onApply: (tag) async {
          _setDialog(null);
          final items = _multiSel.values.toList();
          for (final r in items) {
            if (!r.userTags.contains(tag)) {
              await widget.repo
                  .updateMeta(r, userTags: [...r.userTags, tag]);
            }
          }
          await widget.repo.addCustomTag(tag);
          _toasts.show(ToastMsg(
            'Tagged ${items.length} items #$tag',
            severity: ToastSeverity.success,
            icon: LucideIcons.hash,
          ));
          setState(_multiSel.clear);
          _recomputeCollections();
        },
      ),
    );
  }

  /// Bulk promote: every selected item that isn't already in the Vault gets
  /// promoted, one toast (and at most one promotion sound) for the batch.
  Future<void> _bulkPromote() async {
    final items = _multiSel.values.where((r) => !r.promoted).toList();
    if (items.isEmpty) {
      _toasts.show(ToastMsg(
        'Already in your Vault',
        severity: ToastSeverity.neutral,
        icon: LucideIcons.info,
      ));
      setState(_multiSel.clear);
      return;
    }
    for (final r in items) {
      await widget.repo.promote(r, true);
    }
    if (widget.repo.promotionSound) unawaited(playPromotionSound());
    _toasts.show(ToastMsg(
      '${items.length} promoted to Vault',
      severity: ToastSeverity.success,
      icon: LucideIcons.gem,
    ));
    setState(_multiSel.clear);
    _recomputeCollections();
  }

  /// Slim action bar shown above the list while a multi-selection exists.
  Widget _bulkBar(RelicColors c) => Container(
        padding: const EdgeInsets.fromLTRB(14, 7, 14, 7),
        decoration: BoxDecoration(
          color: c.panel,
          border: Border(bottom: BorderSide(color: c.border, width: 1)),
        ),
        child: Row(
          children: [
            Icon(LucideIcons.copyCheck, size: 13, color: c.accentMuted),
            const SizedBox(width: 7),
            Text(
              '${_multiSel.length} selected',
              style: RelicTheme.mono(size: 11, color: c.textSecondary),
            ),
            const SizedBox(width: 10),
            // Overflow-safe: the action cluster scrolls horizontally (anchored
            // right) so it never overflows the narrow popup, even at Mini width
            // with the extra Combine controls on.
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                reverse: true,
                child: Row(
                  children: [
                    _bulkBtn(c, 'Copy', LucideIcons.copy, _bulkCopy),
                    const SizedBox(width: 8),
                    _bulkBtn(c, 'Keep', LucideIcons.gem, _bulkPromote),
                    const SizedBox(width: 8),
                    _bulkBtn(c, 'Tag', LucideIcons.hash, _bulkTag),
                    const SizedBox(width: 8),
                    _bulkBtn(c, 'Delete', LucideIcons.trash2, _bulkDelete,
                        danger: true),
                    const SizedBox(width: 8),
                    _bulkBtn(c, 'Clear', LucideIcons.x,
                        () => setState(_multiSel.clear)),
                    if (widget.repo.multiCombine) ...[
                      const SizedBox(width: 8),
                      _sepChip(c),
                      const SizedBox(width: 8),
                      _bulkBtn(c, 'Combine', LucideIcons.combine, _combinePaste),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      );

  /// Tappable chip showing the current combine separator; tap to cycle it
  /// (newline / space / comma).
  Widget _sepChip(RelicColors c) => GestureDetector(
        onTap: _cycleCombineSep,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: c.panel,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: c.border),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(LucideIcons.separatorHorizontal,
                  size: 11, color: c.textFaintest),
              const SizedBox(width: 5),
              Text(
                _combineSepLabel,
                style: RelicTheme.mono(size: 10, color: c.textSecondary),
              ),
            ]),
          ),
        ),
      );

  Widget _bulkBtn(RelicColors c, String label, IconData icon, VoidCallback onTap,
          {bool danger = false}) =>
      GhostButton(
        icon: icon,
        label: label,
        size: 26,
        iconSize: 12,
        fontSize: 11.5,
        style: danger ? GhostStyle.danger : GhostStyle.ghost,
        onTap: onTap,
      );

  /// Anchored dropdown for the row ⋯ button: copies the item's text through a
  /// transform. Sits under the trigger (flips above when there's no room),
  /// clamped to the popup bounds; a transparent full-size tap target behind it
  /// dismisses on any outside click.
  Widget _rowMenu(RelicColors c) {
    final sel = _rowMenuFor!;
    final r = sel.relic;
    final mob = RelicTheme.isMobileOf(context);
    final atCursor = sel.atCursor;
    final canCopyAs = r.kind == Kind.string && !r.isSecret;
    final w = mob ? 210.0 : 150.0;
    final rowH = mob ? 46.0 : 30.0;
    const headerH = 22.0;
    const pad = 6.0;
    void close() => setState(() => _rowMenuFor = null);
    // Convert the trigger's global anchor into the root Stack's local space here,
    // at build time, against the Stack's already-settled render object from the
    // last frame. Doing it here (not inside the menu's LayoutBuilder during the
    // layout phase) reads an authoritative transform, so the panel lands in the
    // right place on the very first frame instead of dropping low then snapping.
    final rootBox = _rootStackKey.currentContext?.findRenderObject() as RenderBox?;
    final anchor = (rootBox != null && rootBox.hasSize)
        ? sel.anchor.shift(-rootBox.localToGlobal(Offset.zero))
        : sel.anchor;
    // The main (non-sub) action list. On mobile, View / Save-to-Vault / Copy are
    // visible buttons, so the menu carries everything else — including Delete
    // (red), Open, and Save to device. Desktop keeps its lean View/Edit/Share list.
    final List<Widget> mainRows = mob
        ? [
            _MenuRow(
                label: 'Share',
                icon: LucideIcons.share2,
                height: rowH,
                onTap: () {
                  close();
                  _share(r);
                }),
            _MenuRow(
                label: 'Edit',
                icon: LucideIcons.squarePen,
                height: rowH,
                onTap: () {
                  close();
                  _edit(r);
                }),
            if (r.hasFile)
              _MenuRow(
                  label: 'Open',
                  icon: LucideIcons.externalLink,
                  height: rowH,
                  onTap: () {
                    close();
                    _openFile(r);
                  }),
            if (r.blobKey != null)
              _MenuRow(
                  label: 'Save to device',
                  icon: LucideIcons.download,
                  height: rowH,
                  onTap: () {
                    close();
                    _saveToDevice(r);
                  }),
            if (canCopyAs)
              _MenuRow(
                  label: 'Copy as',
                  icon: LucideIcons.clipboardCopy,
                  submenu: true,
                  height: rowH,
                  onTap: () => setState(() => _rowMenuSub = true)),
            _MenuRow(
                label: 'Delete',
                icon: LucideIcons.trash2,
                tint: c.dangerText,
                height: rowH,
                onTap: () {
                  close();
                  _delete(r);
                }),
          ]
        : [
            // The right-click variant leads with Copy and ends with Delete —
            // what a Windows context menu is expected to carry. The ⋯ variant
            // stays lean (the action cluster is already visible next to it).
            if (atCursor)
              _MenuRow(
                  label: 'Copy',
                  icon: LucideIcons.copy,
                  height: rowH,
                  onTap: () {
                    close();
                    _copy(r);
                  }),
            _MenuRow(
                label: 'Edit',
                icon: LucideIcons.squarePen,
                height: rowH,
                onTap: () {
                  close();
                  _edit(r);
                }),
            _MenuRow(
                label: 'Share',
                icon: LucideIcons.share2,
                height: rowH,
                onTap: () {
                  close();
                  _share(r);
                }),
            if (canCopyAs)
              _MenuRow(
                  label: 'Copy as',
                  icon: LucideIcons.clipboardCopy,
                  submenu: true,
                  height: rowH,
                  onTap: () => setState(() => _rowMenuSub = true)),
            if (widget.repo.reminders)
              _MenuRow(
                  label: 'Remind me…',
                  icon: LucideIcons.alarmClock,
                  height: rowH,
                  onTap: () {
                    close();
                    _openRemind(r);
                  }),
            if (widget.repo.relicSync(r) == RelicSync.blocked)
              _MenuRow(
                  label: 'Retry sync',
                  icon: LucideIcons.refreshCw,
                  height: rowH,
                  onTap: () {
                    close();
                    widget.repo.retrySync(r);
                    _toasts.show(ToastMsg(
                      'Retrying sync',
                      severity: ToastSeverity.neutral,
                      icon: LucideIcons.refreshCw,
                    ));
                  }),
            if (atCursor)
              _MenuRow(
                  label: 'Delete',
                  icon: LucideIcons.trash2,
                  tint: c.dangerText,
                  height: rowH,
                  onTap: () {
                    close();
                    _delete(r);
                  }),
          ];
    // Two modes share the panel: the action list, or the Copy-as sub-list
    // (header + back row + transforms). Height drives the flip-above check.
    final rows =
        _rowMenuSub ? 1 + copyAsTransforms.length : mainRows.length;
    final h = (_rowMenuSub ? headerH : 0) + rowH * rows + pad * 2;
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: close,
        onSecondaryTapDown: (_) => close(),
        child: LayoutBuilder(
          builder: (ctx, box) {
            // `anchor` is already in this Stack's local space (converted above at
            // build time); LayoutBuilder only supplies the box for clamping/flip.
            // Button anchor: right-aligned under the trigger. Cursor anchor:
            // top-left at the click point (Windows convention).
            final a = anchor;
            final left =
                (atCursor ? a.left : a.right - w).clamp(6.0, box.maxWidth - w - 6);
            var top = a.bottom + (atCursor ? 2 : 4);
            if (top + h > box.maxHeight - 6) top = a.top - h - (atCursor ? 2 : 4);
            return Stack(
              children: [
                Positioned(
                  left: left,
                  top: top,
                  width: w,
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: pad),
                    decoration: BoxDecoration(
                      color: c.panel,
                      borderRadius: BorderRadius.circular(Radii.input),
                      border: Border.all(color: c.borderStrong, width: 1),
                      boxShadow: [
                        BoxShadow(
                          color: c.shadowSoft,
                          blurRadius: 16,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: _rowMenuSub
                          ? [
                              Container(
                                height: headerH,
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 12),
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  'COPY AS',
                                  style: RelicTheme.mono(
                                    size: 9,
                                    color: c.textFaintest,
                                    letterSpacing: 1.2,
                                  ),
                                ),
                              ),
                              _MenuRow(
                                label: 'Back',
                                icon: LucideIcons.chevronLeft,
                                height: rowH,
                                onTap: () =>
                                    setState(() => _rowMenuSub = false),
                              ),
                              for (final (label, fn) in copyAsTransforms)
                                _MenuRow(
                                  label: label,
                                  height: rowH,
                                  onTap: () {
                                    close();
                                    _copyAs(r, label, fn);
                                  },
                                ),
                            ]
                          : mainRows,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// Anchored popover for a blocked row's sync badge: WHY it won't sync
  /// (mapped from the recorded HTTP status), when it was refused, and a
  /// Retry action. Same overlay mechanics as the ⋯ menu.
  Widget _syncInfo(RelicColors c) {
    final sel = _syncInfoFor!;
    final r = sel.relic;
    final rej = widget.repo.syncRejection(r);
    void close() => setState(() => _syncInfoFor = null);
    if (rej == null) {
      // Cleared while open (a pull merged a newer copy) — nothing to explain.
      WidgetsBinding.instance.addPostFrameCallback((_) => close());
      return const SizedBox.shrink();
    }
    final reason = syncRejectionReason(rej.status);
    final hint = syncRejectionHint(rej.status, storeSafe: storeSafeBuild);
    const w = 230.0;
    final rootBox =
        _rootStackKey.currentContext?.findRenderObject() as RenderBox?;
    final anchor = (rootBox != null && rootBox.hasSize)
        ? sel.anchor.shift(-rootBox.localToGlobal(Offset.zero))
        : sel.anchor;
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: close,
        onSecondaryTapDown: (_) => close(),
        child: LayoutBuilder(
          builder: (ctx, box) {
            final a = anchor;
            final left = a.left.clamp(6.0, box.maxWidth - w - 6);
            // Height varies with the hint line; measure loosely and flip
            // above when the badge sits near the bottom edge.
            final estH = hint == null ? 96.0 : 116.0;
            var top = a.bottom + 4;
            if (top + estH > box.maxHeight - 6) top = a.top - estH - 4;
            return Stack(children: [
              Positioned(
                left: left,
                top: top,
                width: w,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                  decoration: BoxDecoration(
                    color: c.panel,
                    borderRadius: BorderRadius.circular(Radii.input),
                    border: Border.all(color: c.borderStrong, width: 1),
                    boxShadow: [
                      BoxShadow(
                        color: c.shadowSoft,
                        blurRadius: 16,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(children: [
                        Icon(LucideIcons.triangleAlert,
                            size: 12, color: c.warningDim),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(reason,
                              style: RelicTheme.sans(
                                  size: 11.5,
                                  weight: FontWeight.w600,
                                  color: c.text)),
                        ),
                      ]),
                      if (hint != null) ...[
                        const SizedBox(height: 4),
                        Text(hint,
                            style: RelicTheme.sans(
                                size: 10.5, color: c.textSecondary)),
                      ],
                      const SizedBox(height: 4),
                      Text(
                        'refused ${relativeAge(rej.rejectedAt, _now)}'
                        '${rej.rejectedAt > _now - 3 * 86400 ? ' ago' : ''}',
                        style: RelicTheme.mono(size: 9.5, color: c.textFaintest),
                      ),
                      const SizedBox(height: 4),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: GhostButton(
                          icon: LucideIcons.refreshCw,
                          label: 'Retry',
                          size: 28,
                          iconSize: 13,
                          onTap: () {
                            close();
                            widget.repo.retrySync(r);
                            _toasts.show(ToastMsg(
                              'Retrying sync',
                              severity: ToastSeverity.neutral,
                              icon: LucideIcons.refreshCw,
                            ));
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ]);
          },
        ),
      ),
    );
  }

  /// Header chip tooltip: when the vault last completed a pull.
  String _lastSyncLabel() {
    final t = widget.repo.lastSyncedAt;
    if (t == null) return 'Not synced yet · click to sync';
    final secs = t.millisecondsSinceEpoch ~/ 1000;
    final a = relativeAge(secs, _now);
    final line = a == 'just now'
        ? 'Last synced just now'
        : (_now - secs >= 3 * 86400)
            ? 'Last synced $a'
            : 'Last synced $a ago';
    return '$line · click to sync';
  }

  /// The "N not synced" sheet: every blocked item, its reason, per-item and
  /// bulk Retry.
  void _openSyncIssues() {
    _setDialog(_SyncIssuesSheet(
      repo: widget.repo,
      nowSecs: _now,
      onClose: () => _setDialog(null),
      onRetryAll: (n) {
        widget.repo.retryAllBlocked();
        _setDialog(null);
        _toasts.show(ToastMsg(
          'Retrying $n items',
          severity: ToastSeverity.neutral,
          icon: LucideIcons.refreshCw,
        ));
      },
    ));
  }

  /// The "?" cheatsheet: search operators + keyboard shortcuts.
  void _openHelp() {
    _setDialog(_HelpSheet(
      globalShortcuts: widget.globalShortcuts,
      onClose: () => _setDialog(null),
    ));
  }

  /// Share dialog: offline QR + E2EE link (see share_dialog.dart). Routed
  /// through _setDialog so blur-to-close suspends while it's up.
  void _share(Relic r) {
    _setDialog(
      ShareDialog(
        relic: r,
        repo: widget.repo,
        onClose: () => _setDialog(null),
      ),
    );
  }

  /// Open the "+" composer to author a new relic by hand.
  void _compose() {
    _setDialog(
      ComposeDialog(
        repo: widget.repo,
        allowSnippet: true,
        onCancel: () => _setDialog(null),
        onCreate: (title, body, tags, files, promote) {
          final ok = widget.repo.createNote(
            title: title,
            body: body,
            userTags: tags,
            files: files,
            promote: promote,
          );
          _setDialog(null);
          if (ok) {
            _toasts.show(ToastMsg(
              promote ? 'Created in Vault' : 'Created',
              severity: ToastSeverity.success,
              icon: LucideIcons.check,
            ));
            _recomputeCollections();
          } else {
            _toasts.show(ToastMsg(
              'Couldn’t create. Too large or empty',
              severity: ToastSeverity.warning,
              icon: LucideIcons.triangleAlert,
            ));
          }
        },
      ),
    );
  }

  void _edit(Relic r, {bool autofocus = false, String savedToast = 'Saved'}) {
    _setDialog(
      EditDialog(
        relic: r,
        repo: widget.repo,
        autofocus: autofocus,
        onCancel: () => _setDialog(null),
        onCopy: () {
          _setDialog(null);
          _copy(r);
        },
        onShare: () => _share(r),
        onDelete: () {
          _setDialog(null);
          _delete(r);
        },
        onSave: (title, note, userTags, machineTags, content, addedFiles,
            removedAttachmentIds) async {
          // Belt-and-braces with the dialog's locked chip: editing metadata
          // must never unmask a secret by dropping its `secret` tag.
          if (r.isSecret && !machineTags.contains('secret')) {
            machineTags = [...machineTags, 'secret'];
          }
          // Meta first, attachments second: both re-read the current row and
          // pending_ops upserts on (uid,'push'), so one final push goes out.
          await widget.repo.updateMeta(
            r,
            title: title,
            note: note,
            userTags: userTags,
            tags: machineTags,
            content: content,
          );
          var attachMsg = '';
          if (addedFiles.isNotEmpty || removedAttachmentIds.isNotEmpty) {
            final res = await widget.repo.updateAttachments(
              r,
              added: addedFiles,
              removedIds: removedAttachmentIds,
            );
            attachMsg = switch (res) {
              AttachmentEditResult.ok => '',
              AttachmentEditResult.tooLarge =>
                'Attachments kept as they were: over the size limit.',
              AttachmentEditResult.bundleUnavailable =>
                'Attachments kept as they were: connect to the internet and try again.',
              AttachmentEditResult.unsupported =>
                'Attachments kept as they were.',
            };
          }
          _setDialog(null);
          _toasts.show(
            ToastMsg(
              attachMsg.isEmpty ? savedToast : attachMsg,
              severity: attachMsg.isEmpty
                  ? ToastSeverity.success
                  : ToastSeverity.neutral,
              icon: attachMsg.isEmpty
                  ? LucideIcons.circleCheck
                  : LucideIcons.info,
            ),
          );
        },
      ),
    );
  }

  void _openTags() {
    _setDialog(
      TagsSheet(
        repo: widget.repo,
        vaultOnly: _scope == Scope.vault,
        selected: _activeTags,
        // Picking a tag applies the filter and closes the sheet so the user
        // drops straight into the filtered results.
        onPick: (tag) {
          _toggleTag(tag);
          _setDialog(null);
        },
        onCreateTag: (tag) => widget.repo.addCustomTag(tag),
        onClose: () => _setDialog(null),
      ),
    );
  }

  /// The collection facets present in the current scope, in catalog order.
  List<(String, String, IconData)> get _presentCollections => [
        for (final e in _kCollections)
          if (_collections.containsKey(e.$2)) e,
      ];

  /// The horizontally-scrolling list of one-tap browse chips. Shared by the
  /// mobile strip and the desktop inline control row.
  Widget _collectionsList(
    List<(String, String, IconData)> present, {
    required EdgeInsets padding,
  }) =>
      _HScroll(
        builder: (controller) => ListView.separated(
          controller: controller,
          scrollDirection: Axis.horizontal,
          padding: padding,
          itemCount: present.length,
          separatorBuilder: (_, _) => const SizedBox(width: 6),
          itemBuilder: (_, i) {
            final (label, tag, icon) = present[i];
            return _CollectionChip(
              label: label,
              icon: icon,
              count: _collections[tag] ?? 0,
              onTap: () => _toggleTag(tag),
            );
          },
        ),
      );

  /// Mobile-only horizontal strip of one-tap browse facets. Tapping filters to
  /// that tag. (Desktop folds these into the single slim control row.)
  Widget _collectionsStrip(RelicColors c) {
    final present = _presentCollections;
    if (present.isEmpty) return const SizedBox.shrink();
    return Container(
      height: 32,
      margin: const EdgeInsets.only(bottom: 8),
      child: _collectionsList(present,
          padding: const EdgeInsets.symmetric(horizontal: 14)),
    );
  }

  /// The de-boxed slim control cluster below the search box.
  ///
  /// Mobile keeps the original two-row layout verbatim (scope row + a separate
  /// collections strip) so nothing regresses on phones. Desktop collapses to a
  /// single 32px row: a compact scope segmented control, the inline collections
  /// (edge-faded, scrollable) filling the middle, then icon-only date and sort
  /// ghost buttons.
  Widget _slimControls(RelicColors c, bool searching) {
    if (RelicTheme.isMobileOf(context)) {
      // Mobile keeps the exact original scope row; the collections strip is
      // emitted separately in build() (after the active-tags strip) so the
      // vertical order is unchanged.
      return Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
        child: Row(
          children: [
            Expanded(child: _scopeBar()),
            const SizedBox(width: 8),
            _dateButton(c),
            const SizedBox(width: 8),
            _sortButton(c),
          ],
        ),
      );
    }
    final present = _presentCollections;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
      child: SizedBox(
        height: 32,
        child: LayoutBuilder(
          builder: (context, box) {
            // The label appears on the sort button only when there's room; the
            // popup gets narrow (Mini ~380px) and the label would crowd out the
            // collections.
            final showSortLabel = box.maxWidth >= 470;
            return Row(
              children: [
                ScopeBar(scope: _scope, onChanged: _onScopeChanged, compact: true),
                const SizedBox(width: 10),
                Expanded(
                  child: (searching || present.isEmpty)
                      ? const SizedBox.shrink()
                      : ShaderMask(
                          shaderCallback: (rect) {
                            // ~12px opaque-in / transparent-out fade on each
                            // edge, expressed as fractions of the actual width.
                            final f =
                                (12.0 / rect.width).clamp(0.0, 0.5).toDouble();
                            return LinearGradient(
                              begin: Alignment.centerLeft,
                              end: Alignment.centerRight,
                              colors: const [
                                Color(0x00000000),
                                Color(0xFF000000),
                                Color(0xFF000000),
                                Color(0x00000000),
                              ],
                              stops: [0.0, f, 1.0 - f, 1.0],
                            ).createShader(rect);
                          },
                          blendMode: BlendMode.dstIn,
                          child: _collectionsList(
                            present,
                            padding:
                                const EdgeInsets.symmetric(horizontal: 12),
                          ),
                        ),
                ),
                const SizedBox(width: 8),
                _dateButton(c),
                const SizedBox(width: 2),
                _sortButton(c, showLabel: showSortLabel),
              ],
            );
          },
        ),
      ),
    );
  }

  void _onScopeChanged(Scope s) {
    setState(() {
      _scope = s;
      _selected = 0;
    });
    _applyQuery();
    _recomputeCollections();
  }

  /// The scope segmented control wired to state (full-width, non-compact).
  Widget _scopeBar() => ScopeBar(scope: _scope, onChanged: _onScopeChanged);

  /// Sort toggle — cycles relevance → newest → oldest. Lets you flip search
  /// results to strict date order instead of relevance ranking. [showLabel]
  /// drops to icon-only (with a tooltip of the current mode) on narrow popups.
  Widget _sortButton(RelicColors c, {bool showLabel = true}) {
    final (icon, label) = switch (_sort) {
      SortMode.relevance => (LucideIcons.arrowUpDown, 'Best'),
      SortMode.newest => (LucideIcons.arrowDown, 'Newest'),
      SortMode.oldest => (LucideIcons.arrowUp, 'Oldest'),
    };
    final active = _sort != SortMode.relevance;
    final style = active ? GhostStyle.active : GhostStyle.ghost;
    final m = RelicTheme.isMobileOf(context);
    return showLabel
        ? GhostButton(
            icon: icon,
            label: label,
            // A LABELED GhostButton is exempt from the 1.4x mobile finger-target
            // bump that icon-only ones get, so this pill sat at 28 next to a
            // date button rendering at 42. Passing the final height directly is
            // the only way to line them up.
            size: m ? 42 : 28,
            iconSize: 13,
            fontSize: 11,
            style: style,
            onTap: _cycleSort,
          )
        : GhostButton(
            icon: icon,
            size: 28,
            iconSize: 14,
            style: style,
            tooltip: 'Sort: $label',
            onTap: _cycleSort,
          );
  }

  /// Date-filter toggle — opens the presets + custom-calendar sheet. Shows as
  /// active (amber) whenever a range is set (picked or parsed from the box).
  Widget _dateButton(RelicColors c) {
    final active = _effectiveRange != null;
    final m = RelicTheme.isMobileOf(context);
    return GhostButton(
      icon: LucideIcons.calendar,
      // Mobile matches the copy button: 30 renders at 42 with a defaulted 21px
      // glyph. The old 28/14 gave a 40px box with a 14px icon, which read as a
      // noticeably smaller glyph than everything around it.
      size: m ? 30 : 28,
      iconSize: m ? null : 14,
      style: active ? GhostStyle.active : GhostStyle.ghost,
      tooltip: 'Filter by date',
      onTap: _openDateFilter,
    );
  }

  void _openDateFilter() {
    _setDialog(
      DateFilterSheet(
        current: _effectiveRange,
        onClose: () => _setDialog(null),
        onPick: (range, label) {
          setState(() {
            _manualRange = range;
            _manualLabel = label;
            // A manual pick (or an explicit clear) supersedes any parsed range.
            _selected = 0;
          });
          _setDialog(null);
          _applyQuery();
          _recomputeCollections();
        },
      ),
    );
  }

  /// Clear whichever date filter is active. A manual range is dropped directly; a
  /// range parsed from the box is removed by stripping the phrase from the text.
  void _clearDateFilter() {
    if (_manualRange != null) {
      setState(() {
        _manualRange = null;
        _manualLabel = null;
      });
    } else if (_parsed?.hasRange == true) {
      _searchCtl.text = _parsed!.residual;
    }
    _selected = 0;
    _applyQuery();
    _recomputeCollections();
  }

  /// The active date chip's label: the friendly preset name, the parsed phrase,
  /// or a date-derived label. Null when no range is active.
  String? get _dateChipLabel {
    if (_manualRange != null) {
      return _manualLabel ?? formatDateRangeLabel(_manualRange!);
    }
    if (_parsed?.hasRange == true) {
      final t = _parsed!.matchedText.trim();
      return t.isNotEmpty ? t : formatDateRangeLabel(_parsed!.range!);
    }
    return null;
  }

  /// Removable chips for the active tag filters — so a tag stays visible and can
  /// be unselected even after the tags sheet is closed.
  Widget _activeTagsStrip(RelicColors c) {
    return Container(
      width: double.infinity, // else the popup Column centers it
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Wrap(
        alignment: WrapAlignment.start,
        spacing: 6,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (_dateChipLabel != null)
            GestureDetector(
              onTap: _clearDateFilter,
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Container(
                  height: 32,
                  padding: const EdgeInsets.fromLTRB(9, 0, 7, 0),
                  decoration: BoxDecoration(
                    color: c.accent,
                    borderRadius: BorderRadius.circular(Radii.pill),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(LucideIcons.calendar, size: 12, color: c.onAccent),
                      const SizedBox(width: 5),
                      Text(
                        _dateChipLabel!,
                        style: RelicTheme.mono(size: 11.5, color: c.onAccent),
                      ),
                      const SizedBox(width: 5),
                      Icon(
                        LucideIcons.x,
                        size: 12,
                        color: c.onAccent.withValues(alpha: 0.8),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          for (final t in _activeTags)
            GestureDetector(
              onTap: () => _toggleTag(t),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Container(
                  height: 32,
                  padding: const EdgeInsets.fromLTRB(10, 0, 7, 0),
                  decoration: BoxDecoration(
                    color: c.accent,
                    borderRadius: BorderRadius.circular(Radii.pill),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '#$t',
                        style: RelicTheme.mono(size: 11.5, color: c.onAccent),
                      ),
                      const SizedBox(width: 5),
                      Icon(
                        LucideIcons.x,
                        size: 12,
                        color: c.onAccent.withValues(alpha: 0.8),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (_activeTags.length > 1)
            GestureDetector(
              onTap: () {
                setState(() {
                  _activeTags.clear();
                  _selected = 0;
                });
                _applyQuery();
              },
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Container(
                  height: 32,
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(
                    'Clear',
                    style: RelicTheme.mono(size: 10.5, color: c.textFaintest),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    if (_rowMenuFor != null && e.logicalKey == LogicalKeyboardKey.escape) {
      setState(() => _rowMenuFor = null);
      return KeyEventResult.handled;
    }
    if (_syncInfoFor != null && e.logicalKey == LogicalKeyboardKey.escape) {
      setState(() => _syncInfoFor = null);
      return KeyEventResult.handled;
    }
    // Ctrl/Cmd+A: select all loaded results into the multi-select set — but
    // only when the search field isn't focused (there it must stay native
    // text select-all).
    if (e.logicalKey == LogicalKeyboardKey.keyA &&
        (HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isMetaPressed) &&
        !_searchFocus.hasPrimaryFocus &&
        _dialog == null) {
      final res = _results;
      if (res.isNotEmpty) {
        setState(() {
          for (final r in res) {
            _multiSel[r.uid] = r;
          }
        });
      }
      return KeyEventResult.handled;
    }
    if (_dialog != null) {
      if (e.logicalKey == LogicalKeyboardKey.escape) {
        _setDialog(null);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    switch (e.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        _move(1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        _move(-1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
        final r = _results;
        if (_selected < r.length) _copy(r[_selected]);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.escape:
        // Layered: an open dialog was already handled above; a live
        // multi-selection clears before the popup closes.
        if (_multiSel.isNotEmpty) {
          setState(_multiSel.clear);
          return KeyEventResult.handled;
        }
        widget.onClose();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.backspace:
        // Companion to type-to-search below: erase from the query even when
        // focus drifted to the list (once the field is focused it handles
        // backspace natively).
        if (!_searchFocus.hasPrimaryFocus && _searchCtl.text.isNotEmpty) {
          final t = _searchCtl.text;
          final next = t.substring(0, t.length - 1);
          _searchCtl.value = TextEditingValue(
            text: next,
            selection: TextSelection.collapsed(offset: next.length),
          );
          _searchFocus.requestFocus();
          _onSearchChanged(next);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
    }
    // Type-to-search: a printable keystroke focuses the search box and begins
    // filtering (in the current scope). Only when nothing above claimed the
    // key, no command modifier is held, and the box doesn't already have focus
    // (else let the TextField type it itself).
    final ch = e.character;
    final hasCmdMod = HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isAltPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    final printable = ch != null &&
        ch.isNotEmpty &&
        ch.runes.every((r) => r >= 0x20 && r != 0x7f); // letters/digits/punct/space
    if (printable && !hasCmdMod && !_searchFocus.hasPrimaryFocus) {
      final text = _searchCtl.text;
      final sel = _searchCtl.selection;
      final start = sel.isValid ? sel.start : text.length;
      final end = sel.isValid ? sel.end : text.length;
      final next = text.replaceRange(start, end, ch);
      _searchCtl.value = TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: start + ch.length),
      );
      _searchFocus.requestFocus();
      _onSearchChanged(next); // existing 140ms debounce → _applyQuery
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Whether the touch UI is running two-pane (iPad / Android tablet width,
  /// docs/apple-port-2026-08.md §5). Desktop never: its popup is a compact
  /// summon window with modal dialogs by design.
  bool _twoPane(BuildContext context) =>
      RelicTheme.isMobileOf(context) &&
      RelicTheme.isWideOf(context) &&
      !(widget.miniSignal?.value ?? false);

  /// Two-pane composition: [list] (the whole existing single-column UI) on
  /// the left at a fixed comfortable width, and the detail pane on the right
  /// hosting the same widgets that overlay as modals at phone widths —
  /// [_setDialog] content renders here instead, so every edit/compose/remind
  /// flow works unchanged in both layouts.
  Widget _withDetailPane(RelicColors c, Widget list) {
    if (!_twoPane(context)) return list;
    return Row(children: [
      SizedBox(width: 380, child: list),
      Container(width: 1, color: c.border),
      Expanded(
        child: _dialog == null
            ? Center(
                child: Text('Select an item',
                    style: RelicTheme.sans(size: 13, color: c.textFaint)),
              )
            : Container(
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
                child: _dialog,
              ),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    final grouped = _grouped;
    final results = [for (final g in grouped) g.relic];
    if (_selected >= results.length && results.isNotEmpty) {
      _selected = results.length - 1;
    }
    final searching = _searching;
    // Mini picker: compact, chrome-stripped, cursor-anchored (desktop only).
    // The mode is per-summon (set by the host from which hotkey fired).
    final mini =
        (widget.miniSignal?.value ?? false) && !RelicTheme.isMobileOf(context);

    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: Container(
        decoration: BoxDecoration(
          color: c.base,
          borderRadius: BorderRadius.circular(Radii.popup),
          border: Border.all(color: c.border, width: 1),
          boxShadow: [
            BoxShadow(
              color: c.shadowStrong,
              blurRadius: 80,
              spreadRadius: -24,
              offset: const Offset(0, 40),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          key: _rootStackKey,
          children: [
            _withDetailPane(c, Column(
              children: [
                if (!mini)
                  PopupHeader(
                  sync: widget.repo.sync,
                  syncing: widget.syncing || widget.repo.syncBusy,
                  uploadFraction: widget.repo.uploadingFraction,
                  onSettings: widget.onSettings,
                  onTags: _openTags,
                  onCompose: _compose,
                  onClose: widget.onClose,
                  pinned: widget.pinned,
                  onPinToggle: widget.onPinToggle,
                  composeKey: _kCompose,
                  settingsKey: _kSettings,
                  // Click = Sync now when healthy, the issues sheet when
                  // items are blocked. Hover explains the last sync.
                  onSyncTap: !widget.repo.syncEnabled
                      ? null
                      : () {
                          if (widget.repo.sync.kind == SyncKind.quotaFull) {
                            _openSyncIssues();
                          } else {
                            widget.repo.syncNow();
                          }
                        },
                  syncTooltip:
                      widget.repo.syncEnabled ? _lastSyncLabel() : null,
                ),
                if (!mini &&
                    widget.onConnect != null &&
                    !widget.repo.syncEnabled)
                  _connectBanner(c),
                if (!mini && widget.capturePaused != null)
                  ValueListenableBuilder<bool>(
                    valueListenable: widget.capturePaused!,
                    builder: (_, paused, _) => paused
                        ? _pausedBanner(c)
                        : const SizedBox.shrink(),
                  ),
                SearchField(
                  key: _kSearch,
                  controller: _searchCtl,
                  focusNode: _searchFocus,
                  onChanged: _onSearchChanged,
                  onHelp: (mini || RelicTheme.isMobileOf(context))
                      ? null
                      : _openHelp,
                ),
                if (!mini) _slimControls(c, searching),
                if (!mini && (_activeTags.isNotEmpty || _dateChipLabel != null))
                  _activeTagsStrip(c),
                // Desktop folds the browse chips into the slim row above; mobile
                // keeps them as their own strip here.
                if (!mini && !searching && RelicTheme.isMobileOf(context))
                  _collectionsStrip(c),
                if (!mini && _multiSel.isNotEmpty) _bulkBar(c),
                Expanded(
                  child: mini
                      ? _miniList(c, results, searching)
                      : results.isEmpty
                      ? (searching
                            ? _NoMatches(
                                query: _searchCtl.text.trim().isNotEmpty
                                    ? _searchCtl.text
                                    : (_activeTags.isNotEmpty
                                          ? _activeTags
                                                .map((t) => '#$t')
                                                .join(' ')
                                          : (_dateChipLabel ?? '')),
                              )
                            : (_showCoach ? _coachSampleTile(c) : const _Empty()))
                      : _maybeRefresh(
                          c,
                          ListView.builder(
                            controller: _scroll,
                            physics: widget.onRefresh != null
                                ? const AlwaysScrollableScrollPhysics()
                                : null,
                            // 12 outside + 12 inside the row (result_row
                            // content inset) splits the icon's 24px total
                            // offset evenly, so the highlight card floats
                            // equidistant between the window edge and the
                            // icon. Change both together.
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            itemCount:
                                results.length + (widget.repo.hasMore ? 1 : 0),
                            itemBuilder: (_, i) {
                              if (i >= results.length) {
                                return _LoadMore(
                                  shown: results.length,
                                  total: widget.repo.matchCount,
                                  onTap: () {
                                    widget.repo.loadMore();
                                    if (mounted) setState(() {});
                                  },
                                );
                              }
                              final r = results[i];
                              final mob = RelicTheme.isMobileOf(context);
                              final rowSync = widget.repo.relicSync(r);
                              final row = ResultRow(
                                key: i == 0 ? _kList : null,
                                relic: r,
                                uploadFraction: widget.repo.uploadFraction(r),
                                dupDevices: grouped[i].dupDevices,
                                provisionalTags: widget.repo.provisionalTags,
                                analyzing: widget.repo.analyzingUids.contains(
                                  r.uid,
                                ),
                                selected: i == _selected,
                                bulkSelected: _multiSel.containsKey(r.uid),
                                nowSecs: _now,
                                onSelect: () => _rowTapped(i, r),
                                onCopy: () => _copy(r),
                                onPromoteToggle: () => _promote(r),
                                onEdit: () => _edit(r),
                                onDelete: () => _delete(r),
                                onOpenLink: () => _openLink(r),
                                onOpenFile: () => _openFile(r),
                                onMore: (rect) => setState(() {
                                  _rowMenuSub = false;
                                  _rowMenuFor =
                                      (anchor: rect, relic: r, atCursor: false);
                                }),
                                // Windows muscle memory: right-click selects the
                                // row (single-select, never multi-toggle — an
                                // in-progress Ctrl-selection survives) and opens
                                // the row menu at the cursor.
                                onContextMenu: mob
                                    ? null
                                    : (pos) => setState(() {
                                          _selected = i;
                                          _rowMenuSub = false;
                                          _rowMenuFor = (
                                            anchor:
                                                Rect.fromLTWH(pos.dx, pos.dy, 0, 0),
                                            relic: r,
                                            atCursor: true,
                                          );
                                        }),
                                onSyncBadgeTap: rowSync == RelicSync.blocked
                                    ? (rect) => setState(() =>
                                        _syncInfoFor = (anchor: rect, relic: r))
                                    : null,
                                onDownload: !mob &&
                                        r.blobKey != null &&
                                        r.attachments.isEmpty
                                    ? () => _download(r)
                                    : null,
                                onTagTap: _toggleTag,
                                sync: rowSync,
                                imagePath: widget.repo.localImagePath(r),
                              );
                              // Desktop rows are OS drag sources (text /
                              // image / file out to other apps); secrets stay
                              // put.
                              return RelicDragSource(
                                relic: r,
                                repo: widget.repo,
                                enabled: !mob && !r.isSecret,
                                child: row,
                              );
                            },
                          ),
                        ),
                ),
              ],
            )),
            if (_dragOver) _DragOverlay(),
            // Phone widths only: two-pane renders _dialog in the detail pane
            // (see _withDetailPane) instead of as a modal.
            if (_dialog != null && !_twoPane(context))
              Positioned.fill(
                child: GestureDetector(
                  onTap: () => _setDialog(null),
                  child: Container(
                    color: const Color(0x99000000),
                    alignment: Alignment.center,
                    padding: EdgeInsets.symmetric(
                      horizontal: RelicTheme.isMobileOf(context) ? 8 : 18,
                      vertical: RelicTheme.isMobileOf(context) ? 24 : 18,
                    ),
                    child: GestureDetector(onTap: () {}, child: _dialog),
                  ),
                ),
              ),
            if (_rowMenuFor != null) _rowMenu(c),
            if (_syncInfoFor != null) _syncInfo(c),
            Positioned(
              left: 0,
              right: 0,
              // On mobile, lift the toast clear of the floating + button so the
              // Undo action isn't hidden behind (and untappable under) the FAB.
              bottom: RelicTheme.isMobileOf(context) ? 96 : 12,
              child: ToastStack(queue: _toasts),
            ),
            if (_showCoach)
              Positioned.fill(
                child: CoachMarks(steps: _coachSteps(), onDone: _dismissCoach),
              ),
          ],
        ),
      ),
    );
  }
}

/// One hoverable row of the anchored ⋯ menu. [submenu] draws a trailing
/// chevron for drill-in entries (Copy as).
class _MenuRow extends StatefulWidget {
  final String label;
  final double height;
  final VoidCallback onTap;
  final IconData? icon;
  final bool submenu;
  final Color? tint; // colors icon + label (e.g. a red Delete)
  const _MenuRow({
    required this.label,
    required this.height,
    required this.onTap,
    this.icon,
    this.submenu = false,
    this.tint,
  });

  @override
  State<_MenuRow> createState() => _MenuRowState();
}

class _MenuRowState extends State<_MenuRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    return GestureDetector(
      onTap: widget.onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Container(
          height: widget.height,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          color: _hover ? c.surfaceHover : const Color(0x00000000),
          child: Row(
            children: [
              if (widget.icon != null) ...[
                Icon(widget.icon, size: 13, color: widget.tint ?? c.textSecondary),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  widget.label,
                  style: RelicTheme.sans(size: 12.5, color: widget.tint ?? c.text),
                ),
              ),
              if (widget.submenu)
                Icon(LucideIcons.chevronRight, size: 13, color: c.textFaint),
            ],
          ),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();
  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 66,
              height: 66,
              decoration: BoxDecoration(
                color: c.panel,
                borderRadius: BorderRadius.circular(Radii.card),
                border: Border.all(color: c.border, width: 1),
              ),
              alignment: Alignment.center,
              child: Icon(LucideIcons.inbox, size: 28, color: c.textFaintest),
            ),
            const SizedBox(height: 16),
            Text(
              'Nothing here yet',
              style: RelicTheme.sans(
                size: 15,
                weight: FontWeight.w500,
                color: c.text,
              ),
            ),
            const SizedBox(height: 6),
            SizedBox(
              width: 240,
              child: Text(
                'Copy anything (text, an image, a file) and it lands here automatically.',
                textAlign: TextAlign.center,
                style: RelicTheme.sans(
                  size: 12.5,
                  color: c.textMuted,
                  height: 1.5,
                ),
              ),
            ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(Radii.tile),
                border: Border.all(
                  color: c.accent.withValues(alpha: 0.4),
                  width: 1.5,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(LucideIcons.upload, size: 14, color: c.accent),
                  const SizedBox(width: 8),
                  Text(
                    'Or drop files to keep them',
                    style: RelicTheme.mono(size: 11, color: c.accentMuted),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Wraps a horizontally-scrolling list so it behaves on desktop: the vertical
/// mouse wheel scrolls it sideways (Flutter only maps the wheel to the scroll
/// axis, so a horizontal list ignores a normal wheel), and click-drag works
/// (mouse isn't a drag device by default). Builds its child with the supplied
/// controller.
class _HScroll extends StatefulWidget {
  final Widget Function(ScrollController controller) builder;
  const _HScroll({required this.builder});

  @override
  State<_HScroll> createState() => _HScrollState();
}

class _HScrollState extends State<_HScroll> {
  final _ctl = ScrollController();

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _onSignal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent || !_ctl.hasClients) return;
    // Use the vertical wheel delta (the common case); fall back to dx for
    // tilt/horizontal wheels.
    final raw = e.scrollDelta.dy != 0 ? e.scrollDelta.dy : e.scrollDelta.dx;
    if (raw == 0) return;
    final target = (_ctl.offset + raw).clamp(
      _ctl.position.minScrollExtent,
      _ctl.position.maxScrollExtent,
    );
    _ctl.jumpTo(target);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerSignal: _onSignal,
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(
          scrollbars: false,
          dragDevices: const {
            PointerDeviceKind.touch,
            PointerDeviceKind.mouse,
            PointerDeviceKind.trackpad,
            PointerDeviceKind.stylus,
          },
        ),
        child: widget.builder(_ctl),
      ),
    );
  }
}

class _CollectionChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final int count;
  final VoidCallback onTap;
  const _CollectionChip({
    required this.label,
    required this.icon,
    required this.count,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    return Hoverable(
      onTap: onTap,
      builder: (context, hovered) => AnimatedContainer(
        duration: Motion.selection,
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          // De-boxed: transparent at rest, a ghost-hover fill on hover.
          color: hovered ? c.ghostHover : const Color(0x00000000),
          borderRadius: BorderRadius.circular(Radii.pill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: c.accentMuted),
            const SizedBox(width: 6),
            Text(
              label,
              style: RelicTheme.sans(size: 12, color: c.textSecondary),
            ),
            const SizedBox(width: 6),
            Text(
              '$count',
              style: RelicTheme.mono(size: 10.5, color: c.textFaintest),
            ),
          ],
        ),
      ),
    );
  }
}

/// Modal sheet listing every blocked (rejected) item with its human reason
/// and Retry actions. Opened from the header's "N not synced" chip.
class _SyncIssuesSheet extends StatefulWidget {
  final RelicRepo repo;
  final int nowSecs;
  final VoidCallback onClose;
  final void Function(int count) onRetryAll;
  const _SyncIssuesSheet({
    required this.repo,
    required this.nowSecs,
    required this.onClose,
    required this.onRetryAll,
  });
  @override
  State<_SyncIssuesSheet> createState() => _SyncIssuesSheetState();
}

class _SyncIssuesSheetState extends State<_SyncIssuesSheet> {
  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    final items = widget.repo.blockedItems();
    return Container(
      width: 400,
      constraints: const BoxConstraints(maxHeight: 420),
      decoration: BoxDecoration(
        color: c.panel,
        borderRadius: BorderRadius.circular(Radii.card),
        border: Border.all(color: c.borderStrong, width: 1),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 10, 8),
            child: Row(
              children: [
                Icon(LucideIcons.triangleAlert, size: 15, color: c.warningDim),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Not synced',
                    style: RelicTheme.sans(
                        size: 14, weight: FontWeight.w600, color: c.text),
                  ),
                ),
                GhostIconButton(
                    icon: LucideIcons.x, size: 24, onTap: widget.onClose),
              ],
            ),
          ),
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 18),
              child: Text(
                'Everything synced. These items cleared up on their own.',
                style: RelicTheme.sans(size: 12, color: c.textMuted),
              ),
            )
          else ...[
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                itemCount: items.length,
                itemBuilder: (_, i) {
                  final it = items[i];
                  final r = it.relic;
                  final title = r.isSecret
                      ? (r.title ?? 'Secret')
                      : r.displayTitle;
                  return Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 7),
                    decoration: BoxDecoration(
                      border: i == 0
                          ? null
                          : Border(top: BorderSide(color: c.border, width: 1)),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: RelicTheme.sans(
                                    size: 12,
                                    weight: FontWeight.w500,
                                    color: c.text),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '${syncRejectionReason(it.status)} · '
                                '${relativeAge(it.rejectedAt, widget.nowSecs)}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: RelicTheme.mono(
                                    size: 10, color: c.warningDim),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        GhostButton(
                          label: 'Retry',
                          size: 26,
                          fontSize: 11,
                          onTap: () {
                            widget.repo.retrySync(r);
                            setState(() {});
                          },
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
              child: Align(
                alignment: Alignment.centerLeft,
                child: GhostButton(
                  icon: LucideIcons.refreshCw,
                  label: 'Retry all',
                  size: 30,
                  iconSize: 13,
                  style: GhostStyle.active,
                  onTap: () => widget.onRetryAll(items.length),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The "?" cheatsheet: search operators, date phrases, and every keyboard /
/// mouse trick the popup supports, with the host's live global hotkeys.
class _HelpSheet extends StatelessWidget {
  final List<(String keys, String label)> globalShortcuts;
  final VoidCallback onClose;
  const _HelpSheet({required this.globalShortcuts, required this.onClose});

  static const _search = <(String, String)>[
    ('tag:work', 'only items with a tag'),
    ('kind:image', 'by type (image, text, file)'),
    ('is:kept', 'only Vault items'),
    ('has:file', 'only items with a file'),
    ('"exact words"', 'literal phrase'),
    ('last week / June 20', 'date phrases work inline'),
    ('oldest / newest', 'sort words work inline'),
  ];

  static const _keys = <(String, String)>[
    ('Up / Down', 'move selection'),
    ('Enter', 'copy the selected item'),
    ('Ctrl+Click', 'multi-select'),
    ('Shift+Click', 'select a range'),
    ('Ctrl+A', 'select all results'),
    ('Ctrl+Z', 'undo a delete (while the toast shows)'),
    ('Right-click', 'row menu'),
    ('Double-click', 'open the viewer'),
    ('Backspace', 'edit the search from the list'),
    ('Esc', 'close'),
  ];

  static const _mouse = <(String, String)>[
    ('Drag a row out', 'drop text, images, or files into other apps'),
    ('Drop files in', 'save them to your Vault'),
  ];

  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    Widget section(String title, List<(String, String)> rows) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: RelicTheme.mono(
                    size: 9.5, color: c.textFaintest, letterSpacing: 1.2)),
            const SizedBox(height: 6),
            for (final (k, v) in rows)
              Padding(
                padding: const EdgeInsets.only(bottom: 5),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 128,
                      child: Text(k,
                          style:
                              RelicTheme.mono(size: 11, color: c.accentMuted)),
                    ),
                    Expanded(
                      child: Text(v,
                          style: RelicTheme.sans(
                              size: 11.5, color: c.textSecondary)),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 10),
          ],
        );
    return Container(
      width: 400,
      constraints: const BoxConstraints(maxHeight: 460),
      decoration: BoxDecoration(
        color: c.panel,
        borderRadius: BorderRadius.circular(Radii.card),
        border: Border.all(color: c.borderStrong, width: 1),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 10, 6),
            child: Row(
              children: [
                Icon(LucideIcons.circleHelp, size: 15, color: c.accentMuted),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Search & shortcuts',
                    style: RelicTheme.sans(
                        size: 14, weight: FontWeight.w600, color: c.text),
                  ),
                ),
                GhostIconButton(
                    icon: LucideIcons.x, size: 24, onTap: onClose),
              ],
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  section('SEARCH', _search),
                  section('KEYBOARD', _keys),
                  section('MOUSE', _mouse),
                  if (globalShortcuts.isNotEmpty)
                    section('ANYWHERE IN WINDOWS', globalShortcuts),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}


class _NoMatches extends StatelessWidget {
  final String query;
  const _NoMatches({required this.query});
  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 66,
              height: 66,
              decoration: BoxDecoration(
                color: c.panel,
                borderRadius: BorderRadius.circular(Radii.card),
                border: Border.all(color: c.border, width: 1),
              ),
              alignment: Alignment.center,
              child: Icon(LucideIcons.searchX, size: 28, color: c.textFaintest),
            ),
            const SizedBox(height: 14),
            Text(
              'No results for “$query”',
              textAlign: TextAlign.center,
              style: RelicTheme.sans(
                size: 15,
                weight: FontWeight.w500,
                color: c.text,
              ),
            ),
            const SizedBox(height: 6),
            SizedBox(
              width: 250,
              child: Text(
                'Try a different term, or switch scope to search the Vault too.',
                textAlign: TextAlign.center,
                style: RelicTheme.sans(
                  size: 12.5,
                  color: c.textMuted,
                  height: 1.5,
                ),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: 260,
              child: Text(
                "Tip: narrow with kind:image, is:kept, tag:work, or dates like 'last week'.",
                textAlign: TextAlign.center,
                style: RelicTheme.mono(
                  size: 10.5,
                  color: c.textFaintest,
                  height: 1.5,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Footer below the last result when more pages exist. Tapping loads the next
/// page; the list also auto-loads on scroll (`_onScroll`), so this doubles as a
/// "there's more, and here's how much" affordance rather than the only way in.
class _LoadMore extends StatelessWidget {
  final int shown;
  final int total;
  final VoidCallback onTap;
  const _LoadMore({
    required this.shown,
    required this.total,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    final m = RelicTheme.isMobileOf(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(8, 6, 8, m ? 22 : 12),
      child: GestureDetector(
        onTap: onTap,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Container(
            height: m ? 48 : 38,
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.circular(Radii.chip),
              border: Border.all(color: c.border, width: 1),
            ),
            alignment: Alignment.center,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  LucideIcons.chevronDown,
                  size: m ? 18 : 15,
                  color: c.textSecondary,
                ),
                const SizedBox(width: 8),
                Text(
                  'Load more',
                  style: RelicTheme.sans(
                    size: m ? 14.5 : 12.5,
                    weight: FontWeight.w500,
                    color: c.textSecondary,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '$shown of $total',
                  style: RelicTheme.mono(
                    size: m ? 12.5 : 10.5,
                    color: c.textFaintest,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DragOverlay extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    return Positioned.fill(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: DottedBorderBox(
          color: c.accent,
          child: Container(
            decoration: BoxDecoration(
              color: c.selected.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(11),
            ),
            alignment: Alignment.center,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 74,
                  height: 74,
                  decoration: BoxDecoration(
                    color: c.selected,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: c.accent.withValues(alpha: 0.4)),
                  ),
                  alignment: Alignment.center,
                  child: Icon(LucideIcons.upload, size: 32, color: c.accent),
                ),
                const SizedBox(height: 16),
                Text(
                  'Drop to add to your Vault',
                  style: RelicTheme.sans(
                    size: 16,
                    weight: FontWeight.w600,
                    color: c.textOnSelected,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A simple dashed-border box (Flutter has no built-in dashed border).
class DottedBorderBox extends StatelessWidget {
  final Color color;
  final Widget child;
  const DottedBorderBox({super.key, required this.color, required this.child});
  @override
  Widget build(BuildContext context) =>
      CustomPaint(painter: _DashPainter(color), child: child);
}

class _DashPainter extends CustomPainter {
  final Color color;
  _DashPainter(this.color);
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final r = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(11),
    );
    final path = Path()..addRRect(r);
    const dash = 7.0, gap = 5.0;
    for (final metric in path.computeMetrics()) {
      double d = 0;
      while (d < metric.length) {
        canvas.drawPath(metric.extractPath(d, d + dash), p);
        d += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashPainter old) => old.color != color;
}
