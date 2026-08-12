import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' show CircularProgressIndicator;
import 'package:flutter/services.dart' show HardwareKeyboard;
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/file_types.dart';
import '../models/relic.dart';
import '../theme/relic_theme.dart';
import '../theme/tokens.dart';
import 'controls.dart';
import 'file_icons.dart';
import 'glyphs.dart';
import 'relic_mark.dart';

/// The result row (design §06/§07). Tapping the body selects the row, revealing
/// the action cluster (delete · vault · open · download · ⋯ · copy); Edit,
/// Share, and Copy-as live in the ⋯ menu. The copy button copies and closes;
/// double-tap opens the unified edit screen.
class ResultRow extends StatefulWidget {
  final Relic relic;
  final bool selected;
  final int nowSecs;
  final VoidCallback onSelect;
  final VoidCallback onCopy;
  final VoidCallback onPromoteToggle;
  final VoidCallback onEdit; // double-tap opens the unified edit screen
  final VoidCallback onDelete;

  /// The on-device pass (tags, OCR, generated title) is queued or running for
  /// this item, so the meta line shows a spinner instead of tags that aren't
  /// there yet.
  final bool analyzing;

  /// Open this relic's link in the browser. Only shown for items that contain
  /// a URL (see [Relic.hasLink]); null hides the action.
  final VoidCallback? onOpenLink;

  /// Open this relic's file/image in the OS default app. Only shown for
  /// blob-backed file/photo relics (see [Relic.hasFile]); null hides it.
  final VoidCallback? onOpenFile;

  /// Open the anchored row overflow menu (⋯ button: View / Edit / Share /
  /// Copy as); receives the trigger's global rect so the host can position
  /// the dropdown. Null hides the action.
  final void Function(Rect anchor)? onMore;

  /// One-click download for blob relics (images/files): save to the Save
  /// folder, copy the path to the clipboard, reveal in the file manager.
  /// Null hides the action (hosts pass it for blob items on desktop only).
  final VoidCallback? onDownload;
  final void Function(String tag)? onTagTap;
  final RelicSync sync;

  /// Blob upload progress (0..1) while this row's attachment is uploading, or
  /// null. When set it takes over the syncing badge with a determinate
  /// "Uploading NN%" ring so a large image/file copy reads as active.
  final double? uploadFraction;
  final String? imagePath;

  /// Right-click (desktop): select the row and open the row menu at the
  /// cursor. Null leaves secondary clicks unhandled.
  final void Function(Offset globalPos)? onContextMenu;

  /// Tap on the sync status badge ("Not synced" warn triangle, or the
  /// syncing spinner when the host wants to explain a stall) — receives the
  /// badge's global rect so the host can anchor an explanation popover.
  final void Function(Rect anchor)? onSyncBadgeTap;

  /// Part of a multi-select set (Ctrl/Shift+click). Highlight + check badge
  /// only — the action cluster stays tied to [selected].
  final bool bulkSelected;

  /// Devices of exact-duplicate rows collapsed behind this one (display-time
  /// grouping — see collapseDuplicates). Shown as a meta-line hint:
  /// "Desktop + MULTIVAC-III" when the twin came from another machine, or
  /// "Desktop ×2" for a same-device double capture.
  final List<String> dupDevices;

  /// Machine tags that exist but have not yet earned a chip: open-vocabulary
  /// tags seen only once (see relic-sift/src/tag_vocab.rs). They stay on the
  /// relic so search finds them; showing them would fill the row's two chip
  /// slots with one-off words nobody will ever filter on.
  final Set<String> provisionalTags;

  const ResultRow({
    super.key,
    required this.relic,
    required this.selected,
    required this.nowSecs,
    required this.onSelect,
    required this.onCopy,
    required this.onPromoteToggle,
    required this.onEdit,
    required this.onDelete,
    this.analyzing = false,
    this.onOpenLink,
    this.onOpenFile,
    this.onMore,
    this.onDownload,
    this.onTagTap,
    this.sync = RelicSync.synced,
    this.uploadFraction,
    this.imagePath,
    this.bulkSelected = false,
    this.dupDevices = const [],
    this.onContextMenu,
    this.onSyncBadgeTap,
    this.provisionalTags = const {},
  });

  /// Rows are a fixed height so selecting an item (which reveals the action
  /// cluster) or switching between items never changes their vertical size.
  /// Sized to comfortably fit two lines of title + the meta line; roomier on
  /// touch. Public because keyboard navigation has to compute a scroll offset
  /// for a row the lazy ListView may not have built yet (popup.dart
  /// `_scrollListToSelected`).
  static double heightFor(bool isMobile) => isMobile ? 96 : 76;

  /// Whether the open-in-browser affordance should appear for this row.
  bool get _showOpen => onOpenLink != null && relic.hasLink;

  /// An image whose bytes the engine can decode and preview inline.
  bool get _isImage =>
      relic.kind == Kind.photo ||
      (relic.kind == Kind.file && isDisplayableImageFile(relic.filename, relic.mime));
  bool get _showViewImage => _isImage;

  /// Whether the open-in-default-app affordance should appear for this row.
  /// The `!_isImage` term hands images to the eye button, and `!_showOpen`
  /// structurally guarantees a row never shows two externalLink buttons — a
  /// photo whose OCR text contains a URL now shows the link button only.
  bool get _showOpenFile =>
      onOpenFile != null && relic.hasFile && !_isImage && !_showOpen;

  @override
  State<ResultRow> createState() => _ResultRowState();
}

class _ResultRowState extends State<ResultRow> {
  bool _hover = false;
  DateTime? _lastTapAt;

  /// Set from [RelicTheme.isMobileOf] each build; the helpers below read it to
  /// switch between the compact desktop metrics and roomier phone ones.
  bool _m = false;
  double _v(double desktop, double mobile) => _m ? mobile : desktop;

  /// How long after a tap a second one still counts as a double-click.
  ///
  /// Matches Windows' default (`HKCU\Control Panel\Mouse\DoubleClickSpeed`,
  /// 500 ms). The old 350 ms was tighter than the system setting, so an
  /// ordinary double-click landed as two selects and the edit screen never
  /// opened. Only ever compared against taps on the *same* row — `_lastTapAt`
  /// is per-row state — so a longer window can't merge taps on two rows.
  static const Duration _doubleTapWindow = Duration(milliseconds: 500);

  /// Single tap selects (instant — reveals the action cluster); a second tap
  /// within the double-click window opens the unified edit screen. Done by hand
  /// so the first tap stays instant (GestureDetector.onDoubleTap would delay
  /// onTap).
  void _onTap() {
    // Modifier click = multi-select toggle/range (handled by the host's
    // onSelect): bypass double-tap detection so rapid Ctrl+clicks never pop
    // the viewer.
    final hk = HardwareKeyboard.instance;
    if (hk.isControlPressed || hk.isMetaPressed || hk.isShiftPressed) {
      _lastTapAt = null;
      widget.onSelect();
      return;
    }
    final now = DateTime.now();
    final last = _lastTapAt;
    if (last != null && now.difference(last) < _doubleTapWindow) {
      _lastTapAt = null;
      widget.onEdit();
    } else {
      _lastTapAt = now;
      widget.onSelect();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    _m = RelicTheme.isMobileOf(context);
    final r = widget.relic;
    final sel = widget.selected;
    final bulk = widget.bulkSelected;

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _onTap, // tap selects → reveals the action cluster; double-tap views
        onSecondaryTapDown: widget.onContextMenu == null
            ? null
            : (d) {
                _lastTapAt = null; // a right-click must not arm double-tap
                widget.onContextMenu!(d.globalPosition);
              },
        child: SizedBox(
          height: ResultRow.heightFor(_m),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // ONE shared highlight shape — hover tint, bulk wash, and the
              // selected card all use identical insets and radius, so selecting
              // a hovered row keeps the exact same footprint and only upgrades
              // the treatment (fill → card with border + shadow). No divider:
              // rows separate by spacing alone; the fixed row height keeps the
              // layout stable in every state.
              Positioned.fill(
                top: _v(3, 4),
                bottom: _v(4, 5),
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: sel
                        ? BoxDecoration(
                            color: c.selectedCard,
                            borderRadius: BorderRadius.circular(10.5),
                            border: Border.all(
                              color: c.isDark
                                  ? c.accent.withValues(alpha: 0.35)
                                  : c.border,
                              width: 1,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: c.cardShadow,
                                blurRadius: 8,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          )
                        : BoxDecoration(
                            color: bulk
                                ? c.selected.withValues(alpha: 0.45)
                                : _hover
                                    ? c.surfaceHover
                                    : const Color(0x00000000),
                            borderRadius: BorderRadius.circular(10.5),
                          ),
                  ),
                ),
              ),
              // Content layer. The resting trailing cluster stays in flow and
              // reserves the right-edge space, so the body's width — and thus
              // its text wrapping — is identical whether or not the row is
              // selected. Nothing here reflows on selection.
              Padding(
                // 12 here + the list's 12 outer padding = the icon sits 24
                // from the window edge with the highlight edge exactly
                // halfway, on both platforms (popup.dart results ListView).
                padding: EdgeInsets.fromLTRB(12, _v(9, 12), 12, _v(9, 12)),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    _Tile(relic: r, selected: sel, imagePath: widget.imagePath),
                    SizedBox(width: _v(11, 13)),
                    Expanded(child: _body(c)),
                    SizedBox(width: _v(8, 10)),
                    _restingTrailing(c),
                  ],
                ),
              ),
              // Action cluster — overlays the content on selection, masked by
              // the floating card's fill (right-rounded so content fades under
              // it) and inset to sit inside the card, so the layout underneath
              // is never disturbed.
              if (sel)
                Positioned(
                  top: _v(3, 4) + 1,
                  bottom: _v(4, 5) + 1,
                  right: 1,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Fade-in strip: content under the mask edge dissolves
                      // instead of getting bisected (a tag chip cut mid-letter
                      // reads as a bug — caught in the store screenshots).
                      Container(
                        width: 22,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              c.selectedCard.withValues(alpha: 0),
                              c.selectedCard,
                            ],
                          ),
                        ),
                      ),
                      Container(
                        decoration: BoxDecoration(
                          color: c.selectedCard,
                          borderRadius: const BorderRadius.only(
                            topRight: Radius.circular(9.5),
                            bottomRight: Radius.circular(9.5),
                          ),
                        ),
                        alignment: Alignment.center,
                        padding: const EdgeInsets.only(left: 4, right: 8),
                        child: _actionCluster(c),
                      ),
                    ],
                  ),
                ),
              if (bulk)
                Positioned(
                  left: sel ? 13 : 3,
                  top: sel ? 7 : 5,
                  child: Container(
                    width: 15,
                    height: 15,
                    decoration:
                        BoxDecoration(color: c.accent, shape: BoxShape.circle),
                    alignment: Alignment.center,
                    child: Icon(LucideIcons.check, size: 10, color: c.onAccent),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(RelicColors c) {
    final r = widget.relic;
    final sel = widget.selected;
    final titleColor = c.text;
    final metaColor = sel ? c.accentMuted : c.textFaint;

    if (r.isSecret) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            '•••• •••• •••• ••••',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: RelicTheme.mono(
              size: _v(13, 15),
              color: c.secretBright,
              letterSpacing: 1.4,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            _secretLabel(r),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: RelicTheme.mono(size: _v(10.5, 12.5), color: metaColor),
          ),
        ],
      );
    }

    // Sans-first: a real title always reads as sans. Otherwise file/other rows
    // (paths, filenames) stay mono, and an untitled text snippet is mono only
    // when it's machine-recognized structured content (url/code/json/path);
    // plain prose gets the friendlier sans weight.
    final hasTitle = r.title != null && r.title!.trim().isNotEmpty;
    const monoTags = {'url', 'code', 'json', 'path'};
    final mono = hasTitle
        ? false
        : (r.kind == Kind.file || r.kind == Kind.other)
            ? true
            : r.tags.any(monoTags.contains);
    final title = r.displayTitle;
    final titleStyle = mono
        ? RelicTheme.mono(size: _v(12.5, 14.5), color: titleColor, height: 1.4)
        : RelicTheme.sans(
            size: _v(13, 15.5),
            weight: FontWeight.w500,
            color: titleColor,
            height: 1.4,
          );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: titleStyle,
        ),
        const SizedBox(height: 4),
        _meta(c, metaColor),
      ],
    );
  }

  /// Wrap a sync badge so tapping it reports its global rect to the host
  /// (anchors the "why isn't this synced" popover). Swallows the tap so the
  /// row doesn't also toggle selection.
  Widget _syncBadgeTappable(Widget child) {
    if (widget.onSyncBadgeTap == null) return child;
    return Builder(
      builder: (ctx) => MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            final box = ctx.findRenderObject() as RenderBox?;
            if (box == null || !box.hasSize) return;
            widget.onSyncBadgeTap!(box.localToGlobal(Offset.zero) & box.size);
          },
          child: child,
        ),
      ),
    );
  }

  Widget _meta(RelicColors c, Color metaColor) {
    final r = widget.relic;
    final up = widget.uploadFraction;
    if (up != null) {
      return _syncBadgeTappable(Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 10,
            height: 10,
            child: CircularProgressIndicator(
              value: up <= 0 ? null : up, // 0 → indeterminate (not a frozen 0%)
              strokeWidth: 1.5,
              color: c.accentMuted,
            ),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              up <= 0 ? 'Uploading…' : 'Uploading ${(up * 100).round()}%',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: RelicTheme.mono(size: 10.5, color: c.accentMuted),
            ),
          ),
        ],
      ));
    }
    if (widget.sync == RelicSync.syncing) {
      return _syncBadgeTappable(Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 10,
            height: 10,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: c.accentMuted,
            ),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              'Syncing…',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: RelicTheme.mono(size: 10.5, color: c.accentMuted),
            ),
          ),
        ],
      ));
    }
    if (widget.sync == RelicSync.blocked) {
      return _syncBadgeTappable(Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.triangleAlert, size: 11, color: c.warningDim),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              'Not synced',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: RelicTheme.mono(size: 10.5, color: c.warningDim),
            ),
          ),
        ],
      ));
    }
    // Local on-device analysis. Sits below the sync states on purpose: those
    // are about whether the item is safe elsewhere, which matters more than
    // whether its tags have landed yet.
    if (widget.analyzing) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 10,
            height: 10,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: c.accentMuted,
            ),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              'Analyzing…',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: RelicTheme.mono(size: 10.5, color: c.accentMuted),
            ),
          ),
        ],
      );
    }
    final age = relativeAge(r.createdAt, widget.nowSecs);
    var device = r.device ?? '';
    if (widget.dupDevices.isNotEmpty) {
      final all = <String>{
        if (device.isNotEmpty) device,
        ...widget.dupDevices.where((d) => d.isNotEmpty),
      };
      device = all.length > 1
          ? all.join(' + ')
          : (device.isEmpty
              ? device
              : '$device ×${widget.dupDevices.length + 1}');
    }
    final metaPrefix = [device, age].where((s) => s.isNotEmpty).join(' · ');
    final visible = widget.provisionalTags.isEmpty
        ? r.allTags
        : r.allTags
              .where(
                (t) =>
                    r.isUserTag(t) ||
                    !widget.provisionalTags.contains(t.toLowerCase()),
              )
              .toList();
    final tags = visible.take(2).toList();
    final beyondCap = visible.length - tags.length;

    final prefixStyle = RelicTheme.mono(size: _v(10.5, 12.5), color: metaColor);
    final autotagStyle = RelicTheme.mono(size: _v(10, 12), color: c.autotagText);
    final countStyle = RelicTheme.mono(size: 10, color: c.textFaintest);

    // A narrow iPad Split View pane leaves this line ~130px — less than the
    // prefix plus two chips, which is how it used to overflow by ~5px
    // (docs/apple-port-2026-08.md §7). Everything after the prefix is
    // indivisible: a chip squeezed down to "bus…" reads worse than no chip, so
    // the line is packed by measurement rather than handed to Flexible. The
    // prefix keeps a floor (and still ellipsizes into whatever is left over),
    // chips are spent left to right while they fit, and the ones that don't
    // fold into the same "+N" that already stands in for tags there was never
    // room for. From ~200px up nothing is ever dropped, so every window that
    // isn't a narrow pane keeps the layout it always had. The cost is a
    // handful of short shaping calls per row build — the same work the Texts
    // below do anyway.
    return LayoutBuilder(
      builder: (ctx, box) {
        // Same fallback Text itself uses, so measuring never needs a
        // MediaQuery the rendering could do without.
        final scaler = MediaQuery.maybeTextScalerOf(ctx) ?? TextScaler.noScaling;
        double textW(String s, TextStyle style) => (TextPainter(
              text: TextSpan(text: s, style: style),
              textDirection: TextDirection.ltr,
              textScaler: scaler,
            )..layout())
            .width;

        // Leading 6 is the gap each tag sits behind.
        double tagW(String t) =>
            6 +
            (r.isUserTag(t)
                ? _MetaChip.widthFor(t, textW)
                : textW('#$t', autotagStyle));
        // Paperclip cluster: its 7px gap, the icon, 2px, then the count.
        final attachN = '${r.attachments.length}';
        final attachW = r.hasAttachments
            ? 7 + _v(10.5, 12.5) + 2 + textW(attachN, prefixStyle)
            : 0.0;
        // Ten mono characters ("Desktop · …") is the least that still says
        // where and when the item came from; a shorter prefix reserves only
        // what it actually needs.
        final prefixFloor = math.min(
          textW(metaPrefix, prefixStyle),
          textW('0123456789', prefixStyle),
        );
        final room = box.maxWidth - prefixFloor - attachW;
        double packedW(int n) {
          var w = 0.0;
          for (var i = 0; i < n; i++) {
            w += tagW(tags[i]);
          }
          final folded = beyondCap + tags.length - n;
          return folded == 0 ? w : w + 6 + textW('+$folded', countStyle);
        }

        var shown = tags.length;
        while (shown > 0 && packedW(shown) > room) {
          shown--;
        }
        final overflow = beyondCap + tags.length - shown;

        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                metaPrefix,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: prefixStyle,
              ),
            ),
            if (r.hasAttachments) ...[
              const SizedBox(width: 7),
              Icon(LucideIcons.paperclip,
                  size: _v(10.5, 12.5), color: metaColor),
              const SizedBox(width: 2),
              Text(attachN, style: prefixStyle),
            ],
            for (final t in tags.take(shown)) ...[
              const SizedBox(width: 6),
              // User tags stay as chips; machine (auto) tags render as a quiet
              // "#tag" so they read as metadata, not a badge. Desktop filters on
              // tap (swallowing the row tap); phones render them display-only, as
              // a target that small mid-row mostly collects accidental taps.
              if (r.isUserTag(t))
                _MetaChip(
                    label: t, onTap: _m ? null : () => widget.onTagTap?.call(t))
              else if (_m)
                Text('#$t', style: autotagStyle)
              else
                SwallowTap(
                  onTap: () => widget.onTagTap?.call(t),
                  child: Text('#$t', style: autotagStyle),
                ),
            ],
            if (overflow > 0) ...[
              const SizedBox(width: 6),
              Text('+$overflow', style: countStyle),
            ],
          ],
        );
      },
    );
  }

  String _secretLabel(Relic r) {
    final label = r.title ?? 'Secret';
    return '$label · Reveal to view';
  }

  /// Resting trailing cluster — always in flow. Secret badge / promoted star /
  /// not-synced spinner, then copy. Defines the body's reserved right-edge
  /// width so wrapping stays constant; hidden behind the overlay when selected.
  Widget _restingTrailing(RelicColors c) {
    final r = widget.relic;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.uploadFraction != null) ...[
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              value: widget.uploadFraction! <= 0 ? null : widget.uploadFraction,
              strokeWidth: 1.5,
              color: c.textFaintest,
            ),
          ),
          const SizedBox(width: 6),
        ] else if (r.isSecret) ...[
          _SecretBadge(),
          const SizedBox(width: 6),
        ] else if (widget.sync == RelicSync.syncing) ...[
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: c.textFaintest,
            ),
          ),
          const SizedBox(width: 6),
        ] else if (widget.sync == RelicSync.blocked) ...[
          _syncBadgeTappable(
            Icon(LucideIcons.triangleAlert, size: 13, color: c.warningDim),
          ),
          const SizedBox(width: 6),
        ] else if (r.promoted) ...[
          RelicMark(
            size: 14,
            color: c.accent,
            facets: false,
          ), // filled gem = in vault
          const SizedBox(width: 6),
        ],
        // Link items get a one-tap "open in browser" next to copy, so it's
        // obvious the row is a link you can follow.
        if (widget._showOpen) ...[
          GhostButton(
              icon: LucideIcons.externalLink,
              size: 30,
              swallowTap: true,
              onTap: widget.onOpenLink!),
          const SizedBox(width: 6),
        ],
        if (widget._showViewImage) ...[
          GhostButton(
              icon: LucideIcons.eye,
              size: 30,
              swallowTap: true,
              onTap: widget.onEdit,
              tooltip: 'View'),
          const SizedBox(width: 6),
        ] else if (widget._showOpenFile) ...[
          GhostButton(
              icon: LucideIcons.externalLink,
              size: 30,
              swallowTap: true,
              onTap: widget.onOpenFile!),
          const SizedBox(width: 6),
        ],
        GhostButton(
            icon: LucideIcons.copy,
            size: 30,
            swallowTap: true,
            onTap: widget.onCopy),
      ],
    );
  }

  /// Selected action cluster — delete · star · view · edit · copy. Copy sits on
  /// the FAR RIGHT, exactly where the resting copy button is, so tapping a row
  /// never moves a destructive button under your finger. Delete is pushed to the
  /// far left, separated by a gap, so it can't be hit by muscle memory.
  Widget _actionCluster(RelicColors c) {
    final r = widget.relic;
    if (_m) return _mobileCluster(c, r);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        GhostButton(
          icon: LucideIcons.trash2,
          size: 28,
          style: GhostStyle.danger,
          swallowTap: true,
          onTap: widget.onDelete,
        ),
        const SizedBox(width: 5),
        GhostButton(
          // Relic gem — filled when in the vault, outline when not.
          iconBuilder: (sz, fg) => RelicMark(
            size: sz,
            color: r.promoted ? c.accent : fg,
            facets: false,
            filled: r.promoted,
          ),
          size: 28,
          swallowTap: true,
          onTap: widget.onPromoteToggle,
        ),
        if (widget._showOpen) ...[
          const SizedBox(width: 3),
          GhostButton(
              icon: LucideIcons.externalLink,
              size: 28,
              swallowTap: true,
              onTap: widget.onOpenLink!),
        ],
        if (widget._showViewImage) ...[
          const SizedBox(width: 3),
          GhostButton(
              icon: LucideIcons.eye,
              size: 28,
              swallowTap: true,
              onTap: widget.onEdit,
              tooltip: 'View'),
        ] else if (widget._showOpenFile) ...[
          const SizedBox(width: 3),
          GhostButton(
              icon: LucideIcons.externalLink,
              size: 28,
              swallowTap: true,
              onTap: widget.onOpenFile!),
        ],
        if (widget.onDownload != null) ...[
          const SizedBox(width: 3),
          GhostButton(
              icon: LucideIcons.download,
              size: 28,
              swallowTap: true,
              onTap: widget.onDownload!),
        ],
        // Everything else (View / Edit / Share / Copy as) lives behind ⋯ so
        // the cluster stays compact.
        if (widget.onMore != null) ...[
          const SizedBox(width: 3),
          Builder(
            builder: (ctx) => GhostButton(
              icon: LucideIcons.ellipsis,
              size: 28,
              swallowTap: true,
              onTap: () {
                final box = ctx.findRenderObject() as RenderBox?;
                if (box == null || !box.hasSize) return;
                widget.onMore!(box.localToGlobal(Offset.zero) & box.size);
              },
            ),
          ),
        ],
        const SizedBox(width: 3),
        GhostButton(
          icon: LucideIcons.copy,
          size: 28,
          style: GhostStyle.filled,
          swallowTap: true,
          onTap: widget.onCopy,
        ),
      ],
    );
  }

  /// Mobile action cluster — deliberately spare: Save-to-Vault, (open link on a
  /// link row), View, ⋯, Copy. Everything else (Share, Edit, Copy as, Save to
  /// device, Open, Delete) lives in the ⋯ menu so the row never crowds. Copy
  /// stays on the far right, over the resting copy button, so tapping a row
  /// doesn't shuffle a button under your finger.
  Widget _mobileCluster(RelicColors c, Relic r) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        GhostButton(
          iconBuilder: (sz, fg) => RelicMark(
            size: sz,
            color: r.promoted ? c.accent : fg,
            facets: false,
            filled: r.promoted,
          ),
          size: 28,
          swallowTap: true,
          onTap: widget.onPromoteToggle,
        ),
        if (widget._showOpen) ...[
          const SizedBox(width: 3),
          GhostButton(
              icon: LucideIcons.externalLink,
              size: 28,
              swallowTap: true,
              onTap: widget.onOpenLink!),
        ],
        const SizedBox(width: 3),
        GhostButton(
            icon: LucideIcons.eye,
            size: 28,
            swallowTap: true,
            onTap: widget.onEdit),
        if (widget.onMore != null) ...[
          const SizedBox(width: 3),
          Builder(
            builder: (ctx) => GhostButton(
              icon: LucideIcons.ellipsis,
              size: 28,
              swallowTap: true,
              onTap: () {
                final box = ctx.findRenderObject() as RenderBox?;
                if (box == null || !box.hasSize) return;
                widget.onMore!(box.localToGlobal(Offset.zero) & box.size);
              },
            ),
          ),
        ],
        const SizedBox(width: 3),
        GhostButton(
          icon: LucideIcons.copy,
          size: 28,
          style: GhostStyle.filled,
          swallowTap: true,
          onTap: widget.onCopy,
        ),
      ],
    );
  }
}

/// Kind tile: text glyph (pencil/paragraph) / photo thumbnail / type-specific
/// file icon / secret key.
class _Tile extends StatelessWidget {
  final Relic relic;
  final bool selected;
  final String? imagePath;
  const _Tile({required this.relic, required this.selected, this.imagePath});

  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    final m = RelicTheme.isMobileOf(context);
    final r = relic;

    // Screenshots always show a thumbnail; image files and notes whose sole
    // attachment is an image show one too once their blob is local (imagePath is
    // non-null only for renderable images).
    if (r.kind == Kind.photo || imagePath != null) {
      return _PhotoThumb(c: c, imagePath: imagePath);
    }

    final Color tileBg;
    final Color tileBorder;
    Widget inner;
    if (r.isSecret) {
      tileBg = c.secretBg;
      tileBorder = c.secretBorder;
      inner = Icon(LucideIcons.keyRound, size: m ? 23 : 19, color: c.secret);
    } else if (selected) {
      tileBg = c.selectedTile;
      tileBorder = c.accent.withValues(alpha: 0.25);
      inner = _txOrIcon(c, c.accentBright, m);
    } else {
      tileBg = c.surface;
      tileBorder = c.border;
      inner = _txOrIcon(c, c.textSecondary, m);
    }

    return Container(
      width: m ? 54 : 44,
      height: m ? 54 : 44,
      decoration: BoxDecoration(
        color: tileBg,
        borderRadius: BorderRadius.circular(Radii.tile),
        border: Border.all(color: tileBorder, width: 1),
      ),
      alignment: Alignment.center,
      child: inner,
    );
  }

  Widget _txOrIcon(RelicColors c, Color color, bool m) {
    switch (relic.kind) {
      case Kind.file:
        // Type-specific glyph (3D box, video reel, archive…) by extension.
        return Icon(fileIconFor(relic.filename), size: m ? 23 : 19, color: color);
      case Kind.other:
        return Icon(LucideIcons.shapes, size: m ? 23 : 19, color: c.textFaintest);
      default:
        // A note with attachments takes on their identity: one file → its
        // category icon; many → a paperclip. (A sole image is handled above by
        // the thumbnail.)
        if (relic.hasAttachments) {
          return Icon(
            relic.attachments.length == 1
                ? fileIconFor(relic.attachments.first.name)
                : LucideIcons.paperclip,
            size: m ? 23 : 19,
            color: color,
          );
        }
        // If the text was recognized as a known type (path, url, code, json…),
        // the big tile shows that type's icon — picked by priority, not stored
        // order, so an incidental scan-anywhere entity ("localhost:8080" in a
        // note) can't relabel the whole clip.
        final ic = primaryTagIcon(relic.tags);
        if (ic != null) return Icon(ic, size: m ? 22 : 18, color: color);
        // Plain copied text: a short squiggle glyph for note-like snippets,
        // straight paragraph lines for longer passages (≥250 chars).
        final len = (relic.content ?? relic.preview ?? '').length;
        final sz = m ? 22.0 : 18.0;
        return len < 250
            ? ShortTextGlyph(size: sz, color: color)
            : Icon(LucideIcons.alignLeft, size: sz, color: color);
    }
  }
}

class _PhotoThumb extends StatelessWidget {
  final RelicColors c;
  final String? imagePath;

  /// Explicit square size; null falls back to the mobile/desktop row tile size.
  final double? dim;

  /// Corner radius; null uses the standard tile radius.
  final double? radius;
  const _PhotoThumb({required this.c, this.imagePath, this.dim, this.radius});
  @override
  Widget build(BuildContext context) {
    final size = dim ?? (RelicTheme.isMobileOf(context) ? 54.0 : 44.0);
    final rad = radius ?? Radii.tile;
    if (imagePath != null) {
      return Container(
        width: size,
        height: size,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(rad),
          border: Border.all(color: c.border, width: 1),
        ),
        child: Image.file(
          File(imagePath!),
          width: size,
          height: size,
          fit: BoxFit.cover,
          // Decode at ~3x the display size (aspect preserved — only cacheWidth
          // is set) so a list of thumbnails never full-decodes a screenshot.
          cacheWidth: (size * 3).round(),
          errorBuilder: (_, _, _) => _mock(c, size, rad),
        ),
      );
    }
    return _mock(c, size, rad);
  }

  Widget _mock(RelicColors c, double size, double rad) {
    // Tiny thumbnails (the mini picker) can't fit the bar-skeleton — show a
    // plain tile with a faint image glyph instead.
    if (size < 30) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: c.thumbBg,
          borderRadius: BorderRadius.circular(rad),
          border: Border.all(color: c.border, width: 1),
        ),
        alignment: Alignment.center,
        child: Icon(LucideIcons.image, size: size * 0.58, color: c.textFaintest),
      );
    }
    return Container(
      width: 50,
      height: 50,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: c.thumbBg,
        borderRadius: BorderRadius.circular(rad),
        border: Border.all(color: c.border, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(height: 13, color: c.thumbBar),
          Padding(
            padding: const EdgeInsets.all(6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _bar(0.8),
                const SizedBox(height: 3),
                _bar(0.58),
                const SizedBox(height: 3),
                _bar(0.42),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _bar(double w) => FractionallySizedBox(
    widthFactor: w,
    child: Container(
      height: 4,
      decoration: BoxDecoration(
        color: const Color(0xFF3A4F5E),
        borderRadius: BorderRadius.circular(2),
      ),
    ),
  );
}

/// A dense one-line row for the mini picker (the mini hotkey): a 20px media
/// chit + title, plus a faint "trigger" pill on snippets. No preview, no meta,
/// no action cluster.
///
/// A single tap fires [onActivate] — one click, item pasted, window gone.
/// Unlike [ResultRow] there is deliberately no select-then-confirm step: the
/// mini picker exists to be the fastest path from "I need that thing" to the
/// thing being in your document, and a picker you have to click twice is just
/// the full popup wearing a smaller window. [onSelect] is still called on
/// hover so the keyboard highlight follows the pointer.
///
/// [onEdit] paints a small pencil on the row you're pointing at (or have
/// selected with the arrows), for the one case a click can't serve: the item
/// is nearly right and needs a change first.
class MiniResultRow extends StatefulWidget {
  final Relic relic;
  final bool selected;
  final String? imagePath;
  final VoidCallback onSelect;
  final VoidCallback onActivate;

  /// Open this item in the editor. The mini window is far too small to host a
  /// modal, so the host expands to the full popup first.
  final VoidCallback? onEdit;

  /// Not yet synced (queued/uploading or blocked). Shows a tiny dot so the
  /// compact picker also reflects in-flight state.
  final bool syncing;
  const MiniResultRow({
    super.key,
    required this.relic,
    required this.selected,
    required this.imagePath,
    required this.onSelect,
    required this.onActivate,
    this.onEdit,
    this.syncing = false,
  });

  /// Row height (logical px) — the popup host uses this to size the window.
  static const double height = 30;

  /// Max rows visible at once: the desktop shell caps the mini window to this
  /// height, and the list scrolls (with load-more) through everything beyond it.
  static const int maxRows = 8;

  @override
  State<MiniResultRow> createState() => _MiniResultRowState();
}

class _MiniResultRowState extends State<MiniResultRow> {
  bool _hover = false;

  /// Pointing at a row also selects it, so the arrow-key highlight and the
  /// pointer never disagree about which item Enter would take.
  void _enter() {
    setState(() => _hover = true);
    if (!widget.selected) widget.onSelect();
  }

  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    final r = widget.relic;
    final sel = widget.selected;
    final isSnippet = r.userTags.contains('snippet');
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => _enter(),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onActivate,
        child: Container(
          height: MiniResultRow.height,
          padding: const EdgeInsets.symmetric(horizontal: 9),
          decoration: BoxDecoration(
            color: sel ? c.accent.withValues(alpha: 0.15) : null,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _leading(c),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  r.displayTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: RelicTheme.sans(
                    size: 12.5,
                    color: sel ? c.textOnSelected : c.text,
                  ),
                ),
              ),
              if (widget.syncing) ...[
                const SizedBox(width: 8),
                Container(
                  width: 6,
                  height: 6,
                  decoration:
                      BoxDecoration(color: c.accentMuted, shape: BoxShape.circle),
                ),
              ],
              if (isSnippet) ...[
                const SizedBox(width: 8),
                _snippetPill(c),
              ],
              // Vault gem (after the snippet pill, so they never overlap) when
              // the item is promoted.
              if (r.promoted) ...[
                const SizedBox(width: 8),
                RelicMark(size: 12, color: c.accent, facets: false),
              ],
              _editSlot(c, sel),
            ],
          ),
        ),
      ),
    );
  }

  /// The pencil, in a slot that is always reserved so the title never reflows
  /// as the pointer moves down the list. It paints on the row you're pointing
  /// at, and on the arrow-selected row so the affordance is discoverable
  /// without a mouse ever touching it.
  Widget _editSlot(RelicColors c, bool sel) {
    final onEdit = widget.onEdit;
    const w = 22.0;
    if (onEdit == null) return const SizedBox.shrink();
    if (!_hover && !sel) return const SizedBox(width: w);
    // No tooltip, deliberately: the mini window is ~340px wide and a few rows
    // tall, and a tooltip hanging off a row at that edge renders cramped or
    // clipped. A pencil does not need a label.
    return SizedBox(
      width: w,
      height: MiniResultRow.height,
      child: GestureDetector(
        // Opaque, and nested inside the row's detector, so the tap opens the
        // editor instead of pasting the item and closing the window.
        behavior: HitTestBehavior.opaque,
        onTap: onEdit,
        child: Icon(
          LucideIcons.squarePen,
          size: 13,
          color: sel ? c.textOnSelected : c.textSecondary,
        ),
      ),
    );
  }

  Widget _leading(RelicColors c) {
    final r = widget.relic;
    // Image → small rounded thumbnail (decoded tiny).
    if (r.kind == Kind.photo || widget.imagePath != null) {
      return _PhotoThumb(c: c, imagePath: widget.imagePath, dim: 20, radius: 5);
    }
    // Secret → key glyph in a tinted tile.
    if (r.isSecret) {
      return _chit(c, c.secretBg, c.secretBorder,
          Icon(LucideIcons.keyRound, size: 12, color: c.secret));
    }
    // Non-image file → its file-type glyph in a soft tile.
    if (r.kind == Kind.file) {
      return _chit(c, c.surface, c.border,
          Icon(fileIconFor(r.filename), size: 12, color: c.textSecondary));
    }
    // Note carrying attachments → the attachment's glyph (or a paperclip).
    if (r.hasAttachments) {
      return _chit(
        c,
        c.surface,
        c.border,
        Icon(
          r.attachments.length == 1
              ? fileIconFor(r.attachments.first.name)
              : LucideIcons.paperclip,
          size: 12,
          color: c.textSecondary,
        ),
      );
    }
    // Text/link/note/qrcode → a bare glyph (no tile) so plain rows read lighter.
    final ic = primaryTagIcon(r.tags);
    if (ic != null) {
      return SizedBox(
          width: 20, height: 20, child: Icon(ic, size: 15, color: c.textSecondary));
    }
    final len = (r.content ?? r.preview ?? '').length;
    return SizedBox(
      width: 20,
      height: 20,
      child: Center(
        child: len < 250
            ? ShortTextGlyph(size: 15, color: c.textSecondary)
            : Icon(LucideIcons.alignLeft, size: 15, color: c.textSecondary),
      ),
    );
  }

  Widget _chit(RelicColors c, Color bg, Color border, Widget inner) => Container(
        width: 20,
        height: 20,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: border, width: 1),
        ),
        alignment: Alignment.center,
        child: inner,
      );

  Widget _snippetPill(RelicColors c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: c.accent.withValues(alpha: 0.45)),
        ),
        child: Text('snippet',
            style: RelicTheme.mono(size: 8.5, color: c.accent, letterSpacing: 0.7)),
      );
}

class _SecretBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: c.secretBg,
        borderRadius: BorderRadius.circular(Radii.chip),
        border: Border.all(color: c.secretBorder, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.lock, size: 10, color: c.secret),
          const SizedBox(width: 4),
          Text('Secret', style: RelicTheme.mono(size: 9, color: c.secret)),
        ],
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  final String label;
  final VoidCallback? onTap; // null = display-only (phones)
  const _MetaChip({required this.label, this.onTap});

  /// Rendered width of the chip, for the meta line's packing pass. Mirrors
  /// [build] exactly: 7px padding + 1px border a side, plus the 10px tag icon
  /// and its 3px gap on the labels that have one. [measure] supplies the text
  /// width in the caller's text scale.
  static double widthFor(
    String label,
    double Function(String, TextStyle) measure,
  ) =>
      16 +
      (tagIconFor(label) != null ? 13 : 0) +
      measure(label, RelicTheme.mono(size: 10));

  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    final icon = tagIconFor(label);
    final onTap = this.onTap;
    final chip = Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: c.accent.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(Radii.chip),
          border: Border.all(color: c.accent.withValues(alpha: 0.30), width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 10, color: c.accent),
              const SizedBox(width: 3),
            ],
            Text(label, style: RelicTheme.mono(size: 10, color: c.accent)),
          ],
        ),
      );
    return onTap == null ? chip : SwallowTap(onTap: onTap, child: chip);
  }
}
