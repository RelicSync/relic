import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart'
    show
        SelectableText,
        CircularProgressIndicator,
        TextField,
        CalendarDatePicker,
        Material,
        MaterialType,
        ScaffoldMessenger,
        SnackBar,
        Theme;
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_filex/open_filex.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

import '../app_globals.dart';
import '../data/local_save.dart';
import '../data/repo.dart';
import '../data/save_prefs.dart';
import '../data/file_types.dart';
import '../util/blob_open.dart';
import '../models/relic.dart';
import '../theme/relic_theme.dart';
import '../theme/tokens.dart';
import '../widgets/controls.dart';
import '../widgets/fields.dart';
import '../widgets/file_icons.dart';
import '../widgets/glyphs.dart';

BoxDecoration _modalDecoration(RelicColors c) => BoxDecoration(
      color: c.panel,
      borderRadius: BorderRadius.circular(Radii.card),
      border: Border.all(color: c.border, width: 1),
      boxShadow: Shadows.window(c),
    );

Widget _dialogHeader(RelicColors c, Widget leading, String title, VoidCallback onClose) => Container(
      padding: const EdgeInsets.fromLTRB(Insets.xl, Insets.lg, Insets.md, Insets.lg),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.border, width: 1))),
      child: Row(children: [
        leading,
        const SizedBox(width: Insets.md),
        Expanded(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: RelicTheme.headline(size: 15, color: c.text))),
        GhostIconButton(icon: LucideIcons.x, size: 28, iconSize: 15, onTap: onClose),
      ]),
    );

Widget _primaryButton(RelicColors c, IconData? icon, String label, VoidCallback onTap) =>
    PrimaryButton(icon: icon, label: label, onTap: onTap);

/// The system's tag chip, exactly as the result row draws it: a warm gold-tint
/// ground with deep-gold mono on it, and no hairline. The outlined-gold chip
/// the dialogs used to draw is gone — gold is a fill here, never an outline.
class _TagChip extends StatelessWidget {
  final String label;

  /// Trailing affordance: the remove ×, or the inert lock on `secret`.
  final IconData? trailingIcon;

  /// Null leaves the trailing glyph inert (the secret lock).
  final VoidCallback? onTrailingTap;
  const _TagChip({required this.label, this.trailingIcon, this.onTrailingTap});

  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    final icon = trailingIcon;
    final onTrailing = onTrailingTap;
    return Container(
      padding: const EdgeInsets.fromLTRB(Insets.sm, 3, Insets.xs, 3),
      decoration: BoxDecoration(
        color: c.tagBg,
        borderRadius: BorderRadius.circular(Radii.tag),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text(label, style: RelicTheme.mono(size: 11, color: c.tagText)),
        if (icon != null) ...[
          const SizedBox(width: 5),
          if (onTrailing == null)
            Icon(icon, size: 11, color: c.tagText)
          else
            Hoverable(
              onTap: onTrailing,
              builder: (context, hovered) => Icon(icon,
                  size: 12, color: hovered ? c.text : c.tagText),
            ),
        ],
      ]),
    );
  }
}

/// A one-tap "add this tag" chip (the suggestion row). Same chip language,
/// with a leading + and a warmer hover.
class _AddTagChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _AddTagChip({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    return Hoverable(
      onTap: onTap,
      builder: (context, hovered) => Container(
        padding: const EdgeInsets.fromLTRB(6, 3, Insets.sm, 3),
        decoration: BoxDecoration(
          // Hover moves the warm ground a step away from the page in whichever
          // direction reads as "raised" for that palette: darker on parchment,
          // lighter on ink.
          color: hovered
              ? (c.isDark ? c.selectedTile : c.ghostHover)
              : c.tagBg,
          borderRadius: BorderRadius.circular(Radii.tag),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(LucideIcons.plus, size: 11, color: c.tagText),
          const SizedBox(width: 3),
          Text(label, style: RelicTheme.mono(size: 11, color: c.tagText)),
        ]),
      ),
    );
  }
}

/// The unified view + edit screen. Opened on double-click and from the row's
/// edit action; it both shows the relic (media, extracted/secret text, meta)
/// and edits its title / note / tags / body / attachments. Absorbs everything
/// the old read-only viewer did.
class EditDialog extends StatefulWidget {
  final Relic relic;
  final RelicRepo repo;
  final VoidCallback onCancel;

  /// Host closes this dialog, then copies the relic to the clipboard.
  final VoidCallback onCopy;

  /// Host closes this dialog, then runs its delete flow.
  final VoidCallback onDelete;

  /// Host swaps in the ShareDialog (replacing this one); null = share
  /// unavailable for this relic.
  final VoidCallback? onShare;

  /// [content] is null when the body is unchanged / not editable.
  /// [addedFiles]/[removedAttachmentIds] carry the attachment delta (desktop
  /// note relics only — empty everywhere else).
  final Future<void> Function(
      String title,
      String note,
      List<String> userTags,
      List<String> machineTags,
      String? content,
      List<(String name, String? mime, Uint8List bytes)> addedFiles,
      Set<String> removedAttachmentIds) onSave;

  /// Focus the title field on open (the save & annotate hotkey flow — the
  /// user's next keystrokes ARE the label).
  final bool autofocus;

  const EditDialog(
      {super.key,
      required this.relic,
      required this.repo,
      required this.onCancel,
      required this.onSave,
      required this.onCopy,
      required this.onDelete,
      this.onShare,
      this.autofocus = false});

  @override
  State<EditDialog> createState() => _EditDialogState();
}

/// Which section, if any, is blown up to fill the dialog (view/edit large text).
enum _Expanded { none, content, extracted }

class _EditDialogState extends State<EditDialog> {
  // Title auto-fills from the caption (photos) or the preview/first line (text)
  // — but never from a secret's masked preview (noise, not a title).
  late final TextEditingController _title = TextEditingController(
      text: widget.relic.title ??
          (widget.relic.isSecret ? '' : widget.relic.preview ?? ''));
  late final TextEditingController _note = TextEditingController(text: widget.relic.note ?? '');
  late final TextEditingController _tag = TextEditingController();
  // The BODY is editable for non-secret text relics only (a secret's
  // plaintext must stay masked; photos/files have no text body).
  bool get _bodyEditable =>
      widget.relic.kind == Kind.string &&
      !widget.relic.isSecret &&
      (widget.relic.content ?? '').isNotEmpty;
  late final TextEditingController _body =
      TextEditingController(text: widget.relic.content ?? '');
  // Two lists: auto-assigned (machine) tags and the user's own — both editable.
  late final List<String> _machine = [...widget.relic.tags];
  late final List<String> _tags = [...widget.relic.userTags];

  // Attachment delta (desktop note relics): existing ids marked for removal
  // (kept in the list, rendered struck-through, so a mis-click is a cheap
  // un-mark) + files picked to add. Applied by the host via
  // repo.updateAttachments AFTER updateMeta.
  final Set<String> _removedIds = {};
  final List<(String name, String? mime, Uint8List bytes)> _added = [];
  bool _attachPicking = false;
  String? _attachNote;
  bool get _attachmentsEditable =>
      widget.repo.canEditAttachments && widget.relic.kind == Kind.string;
  int get _keptExistingBytes => widget.relic.attachments
      .where((a) => !_removedIds.contains(a.id))
      .fold(0, (n, a) => n + a.size);
  int get _addedBytes => _added.fold(0, (n, f) => n + f.$3.length);

  // View-side state absorbed from the old read-only viewer.
  bool _revealed = false; // secret masking
  String? _content; // the relic's full text (extracted / OCR / body)
  bool _blobLoading = false; // image/file blob is being fetched for display
  bool _copiedText = false; // copy-extracted-text feedback
  bool _saving = false;
  bool _saved = false;
  String? _saveError;

  /// Where the last save landed ("Download/report.pdf"), surfaced in the
  /// tooltip so the file is actually findable afterwards.
  String? _savedTo;
  bool _opening = false;
  _Expanded _expanded = _Expanded.none;

  // A TextField over a very large body janks badly, so past this size the
  // content is shown as read-only selectable text in both collapsed + expanded
  // modes (still copyable, just not editable inline).
  static const int _hugeBody = 64 * 1024;

  /// True for a picture we can render inline: a photo, or a file whose bytes are
  /// a displayable raster image.
  bool get _isImage =>
      widget.relic.kind == Kind.photo ||
      (widget.relic.kind == Kind.file &&
          isDisplayableImageFile(widget.relic.filename, widget.relic.mime));

  /// The extracted / OCR'd text for this relic, if any — the searchable
  /// content, minus the cases where it's just the filename or the title
  /// echoed back (so there's nothing real to show).
  String? get _extractedText {
    final t = _content?.trim();
    if (t == null || t.isEmpty) return null;
    if (t == widget.relic.filename) return null;
    if (t == widget.relic.title?.trim()) return null;
    return t;
  }

  /// The save must not produce an empty relic (no text, no attachments) —
  /// that's a delete, not an edit.
  bool get _wouldBeEmpty {
    if (!_attachmentsEditable) return false;
    final text = _bodyEditable ? _body.text : (widget.relic.content ?? '');
    final keptCount =
        widget.relic.attachments.length - _removedIds.length + _added.length;
    return text.trim().isEmpty && keptCount <= 0;
  }
  // Existing/created user tags, offered as one-tap "add" chips.
  late final List<String> _allUserTags = (widget.repo.tagFrequencies().user.keys.toList())
    ..sort();
  final _titleF = FocusNode();
  final _noteF = FocusNode();
  final _tagF = FocusNode();
  final _bodyF = FocusNode();

  @override
  void initState() {
    super.initState();
    // Load the full text (extracted/OCR/body) for the meta line + extracted
    // section, then update the display.
    widget.repo.textOf(widget.relic).then((t) {
      if (mounted) setState(() => _content = t);
    });
    // Kick a blob fetch when a picture/file needs its bytes to display and they
    // aren't local yet.
    final r = widget.relic;
    final alreadyLocal = widget.repo.localImagePath(r) != null ||
        (r.hasAttachments &&
            widget.repo.attachmentPath(r, r.attachments.first.id) != null);
    if (r.blobKey != null &&
        !alreadyLocal &&
        (r.kind == Kind.photo || r.kind == Kind.file || r.hasAttachments)) {
      _blobLoading = true;
      widget.repo.ensureBlob(r).then((_) {
        if (mounted) setState(() => _blobLoading = false);
      });
    }
    if (widget.autofocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _titleF.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    _tag.dispose();
    _body.dispose();
    _titleF.dispose();
    _noteF.dispose();
    _tagF.dispose();
    _bodyF.dispose();
    super.dispose();
  }

  /// Header glyph for a text relic: secret key, else the detected type's icon
  /// (path/url/code…), else the short/long text glyph.
  Widget _textLeading(RelicColors c) {
    final r = widget.relic;
    if (r.isSecret) {
      return Icon(LucideIcons.keyRound, size: 15, color: c.secret);
    }
    // Priority-ranked, mirroring the row tile — stored order would let an
    // incidental entity tag pick the header glyph.
    final ic = primaryTagIcon(r.tags);
    if (ic != null) return Icon(ic, size: 15, color: c.textSecondary);
    return (r.content ?? r.preview ?? '').length < 250
        ? ShortTextGlyph(size: 15, color: c.textSecondary)
        : Icon(LucideIcons.alignLeft, size: 15, color: c.textSecondary);
  }

  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    final r = widget.relic;
    final leading = switch (r.kind) {
      Kind.photo => Icon(LucideIcons.image, size: 15, color: c.textSecondary),
      Kind.file =>
        Icon(fileIconFor(r.filename), size: 15, color: c.textSecondary),
      _ => _textLeading(c),
    };
    return Container(
      width: 440,
      decoration: _modalDecoration(c),
      clipBehavior: Clip.antiAlias,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        _dialogHeader(c, leading, r.displayTitle, widget.onCancel),
        Flexible(
          child: _expanded == _Expanded.none
              ? _collapsedBody(c)
              : _expandedBody(c),
        ),
        _footer(c),
      ]),
    );
  }

  // --- collapsed (default) body ---

  Widget _collapsedBody(RelicColors c) {
    final r = widget.relic;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(Insets.xl, Insets.xl, Insets.xl, Insets.xl),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Media zone (image / file card / secret well) — omitted for plain
        // non-secret text, which has no media.
        ..._mediaZone(c),
        // Extracted text (OCR / document text) for photos + files.
        if ((r.kind == Kind.photo || r.kind == Kind.file) &&
            _extractedText != null) ...[
          _extractedCollapsed(c),
          const SizedBox(height: Insets.xl),
        ],
        // Editable body for non-secret text relics.
        if (_bodyEditable) ...[
          Row(children: [
            _label(c, 'Content'),
            const Spacer(),
            GhostButton(
                icon: LucideIcons.maximize2,
                label: 'Show all',
                size: 26,
                iconSize: 13,
                onTap: () => setState(() => _expanded = _Expanded.content)),
          ]),
          _bodyField(c),
          const SizedBox(height: Insets.xl),
        ],
        _label(c, 'Title'),
        _field(c, _title, _titleF),
        const SizedBox(height: Insets.xl),
        _label(c, 'Note'),
        _field(c, _note, _noteF, minHeight: 60, maxLines: 4),
        const SizedBox(height: Insets.xl),
        _label(c, 'Tags'),
        _tagsField(c),
        _suggestions(c),
        if (_attachmentsEditable) ...[
          const SizedBox(height: Insets.xl),
          _label(c, 'Attachments'),
          _attachmentsSection(c),
        ] else if (r.hasAttachments) ...[
          const SizedBox(height: Insets.xl),
          _label(c, 'Attachments'),
          _readonlyAttachments(c),
        ],
        const SizedBox(height: Insets.xl),
        _snippetBox(c),
        const SizedBox(height: Insets.lg),
        _metaLine(c),
        const SizedBox(height: Insets.sm),
        Row(children: [
          Icon(LucideIcons.info, size: 12, color: c.textFaintest),
          const SizedBox(width: Insets.sm),
          Flexible(child: Text('Title, note and tags are all searchable. Type a tag and press Enter.', style: RelicTheme.sans(size: 11, color: c.textFaintest))),
        ]),
      ]),
    );
  }

  /// The body TextField for a text relic (collapsed mode). Read-only for huge
  /// bodies (a big editable field janks); edits persist across expand/collapse
  /// because it's the same [_body] controller.
  Widget _bodyField(RelicColors c) {
    if (_body.text.length > _hugeBody) {
      return Container(
        width: double.infinity,
        constraints: const BoxConstraints(maxHeight: 160),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: Insets.md),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(Radii.input),
          border: Border.all(color: c.borderStrong),
        ),
        child: SingleChildScrollView(
          child: SelectableText(_body.text,
              maxLines: 6,
              style: RelicTheme.mono(size: 12.5, color: c.text, height: 1.6)),
        ),
      );
    }
    return _field(c, _body, _bodyF, minHeight: 60, maxLines: 6, mono: true);
  }

  /// Media for the collapsed body: image well, file card, or the secret well
  /// (masked or revealed). Returns empty for plain non-secret text.
  List<Widget> _mediaZone(RelicColors c) {
    final r = widget.relic;
    if (r.isSecret) {
      return [
        _revealed ? _secretRevealed(c) : _secretMasked(c),
        const SizedBox(height: Insets.xl),
      ];
    }
    if (_isImage) return [_imageWell(c), const SizedBox(height: Insets.xl)];
    if (r.kind == Kind.file) {
      return [_fileCard(c), const SizedBox(height: Insets.xl)];
    }
    return const [];
  }

  Widget _imageWell(RelicColors c) {
    final path = widget.repo.localImagePath(widget.relic);
    return ClipRRect(
      borderRadius: BorderRadius.circular(Radii.card),
      child: Container(
        width: double.infinity,
        color: c.inset,
        padding: const EdgeInsets.all(Insets.md),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 180),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(Radii.tile),
            child: path != null
                ? Image.file(File(path),
                    fit: BoxFit.contain,
                    cacheWidth: 900,
                    errorBuilder: (_, _, _) => _imgPlaceholder(c))
                : (_blobLoading ? _imgLoading(c) : _imgPlaceholder(c)),
          ),
        ),
      ),
    );
  }

  Widget _imgLoading(RelicColors c) => Container(
        height: 180,
        decoration: BoxDecoration(color: c.thumbBg, border: Border.all(color: c.border)),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.4, color: c.accent),
          ),
        ),
      );

  Widget _imgPlaceholder(RelicColors c) => Container(
        height: 180,
        decoration: BoxDecoration(color: c.thumbBg, border: Border.all(color: c.border)),
        child: Center(child: Icon(LucideIcons.image, size: 40, color: c.thumbBar)),
      );

  Widget _fileCard(RelicColors c) {
    final r = widget.relic;
    return Container(
      padding: const EdgeInsets.all(Insets.lg),
      decoration: BoxDecoration(
          color: c.inset, borderRadius: BorderRadius.circular(Radii.card)),
      child: Row(children: [
        Container(
          width: 52, height: 52,
          decoration: BoxDecoration(color: c.panel, borderRadius: BorderRadius.circular(Radii.tile), border: Border.all(color: c.border)),
          alignment: Alignment.center,
          child: Icon(fileIconFor(r.filename), size: 26, color: c.textSecondary),
        ),
        const SizedBox(width: Insets.lg),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(r.filename ?? 'file', style: RelicTheme.sans(size: 13, weight: FontWeight.w500, color: c.text), maxLines: 2, overflow: TextOverflow.ellipsis),
            const SizedBox(height: Insets.xs),
            Text('${humanBytes(r.byteSize)}${r.device != null ? ' · ${r.device}' : ''}',
                style: RelicTheme.mono(size: 11.5, color: c.textFaint)),
          ]),
        ),
      ]),
    );
  }

  /// Compact one-row masked well for an unrevealed secret (not a hero panel):
  /// an eye-off icon, dotted placeholder, and a Reveal control.
  Widget _secretMasked(RelicColors c) => Container(
        padding: const EdgeInsets.fromLTRB(Insets.lg, Insets.md, Insets.sm, Insets.md),
        decoration: BoxDecoration(
          // Warm chip language, straight off the row: a gold-tint ground with
          // deep-gold mono on it, and no hairline — the fill does the work.
          color: c.secretBg,
          borderRadius: BorderRadius.circular(Radii.card),
        ),
        child: Row(children: [
          Icon(LucideIcons.eyeOff, size: 15, color: c.secret),
          const SizedBox(width: Insets.md),
          Expanded(
            child: Text('•••• •••• ••••',
                style: RelicTheme.mono(
                    size: 13, color: c.secretBright, letterSpacing: 1.4)),
          ),
          GhostButton(
              icon: LucideIcons.eye,
              label: 'Reveal',
              size: 28,
              iconSize: 13,
              onTap: () => setState(() => _revealed = true)),
        ]),
      );

  /// Revealed secret: read-only selectable plaintext (secrets stay
  /// non-editable) with a Hide control on the label row.
  Widget _secretRevealed(RelicColors c) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [
            _label(c, 'Secret'),
            const Spacer(),
            GhostButton(
                icon: LucideIcons.eyeOff,
                label: 'Hide',
                size: 26,
                iconSize: 13,
                onTap: () => setState(() => _revealed = false)),
          ]),
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxHeight: 140),
            padding: const EdgeInsets.all(Insets.lg),
            decoration: BoxDecoration(
              color: c.secretBg,
              borderRadius: BorderRadius.circular(Radii.card),
            ),
            // Revealed, the plaintext is the point: it goes to full-strength ink
            // on the warm ground, exactly as the row does when the eye is on.
            child: SingleChildScrollView(
              child: SelectableText(_content ?? '…',
                  style: RelicTheme.mono(size: 12.5, color: c.text, height: 1.7)),
            ),
          ),
        ],
      );

  /// Extracted-text section, collapsed: label + copy-text + expand controls,
  /// then a clamped plain (non-scrolling) preview.
  Widget _extractedCollapsed(RelicColors c) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [
            _label(c, 'Extracted text'),
            const Spacer(),
            GhostIconButton(
                icon: _copiedText ? LucideIcons.check : LucideIcons.clipboardCopy,
                size: 26,
                iconSize: 13,
                onTap: _copyExtractedText),
            const SizedBox(width: 4),
            GhostIconButton(
                icon: LucideIcons.maximize2,
                size: 26,
                iconSize: 13,
                onTap: () => setState(() => _expanded = _Expanded.extracted)),
          ]),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(Insets.lg),
            decoration: BoxDecoration(
              color: c.inset,
              borderRadius: BorderRadius.circular(Radii.card),
            ),
            child: Text(_extractedText!,
                maxLines: 6,
                overflow: TextOverflow.ellipsis,
                style: RelicTheme.mono(size: 12.5, color: c.textSecondary, height: 1.6)),
          ),
        ],
      );

  // --- expanded body (content or extracted text blown up) ---

  Widget _expandedBody(RelicColors c) {
    final isContent = _expanded == _Expanded.content;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Insets.xl, Insets.lg, Insets.xl, Insets.md),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          _label(c, isContent ? 'Content' : 'Extracted text'),
          const Spacer(),
          if (!isContent) ...[
            GhostIconButton(
                icon: _copiedText ? LucideIcons.check : LucideIcons.clipboardCopy,
                size: 26,
                iconSize: 13,
                onTap: _copyExtractedText),
            const SizedBox(width: 4),
          ],
          GhostButton(
              icon: LucideIcons.minimize2,
              label: 'Collapse',
              size: 26,
              iconSize: 13,
              onTap: () => setState(() => _expanded = _Expanded.none)),
        ]),
        const SizedBox(height: 8),
        Expanded(
          child: isContent ? _expandedContent(c) : _expandedExtracted(c),
        ),
      ]),
    );
  }

  Widget _expandedContent(RelicColors c) {
    // Huge bodies stay read-only (a full-height editable field janks); note the
    // threshold at [_hugeBody].
    final readOnly = _body.text.length > _hugeBody;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: Insets.md),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(Radii.input),
        border: Border.all(color: c.borderStrong),
      ),
      child: readOnly
          ? SingleChildScrollView(
              child: SelectableText(_body.text,
                  style: RelicTheme.mono(size: 12.5, color: c.text, height: 1.6)),
            )
          : TextField(
              controller: _body,
              focusNode: _bodyF,
              style: RelicTheme.sans(size: 13.5, color: c.text, height: 1.5),
              cursorColor: c.accent,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              decoration: kBareField,
            ),
    );
  }

  Widget _expandedExtracted(RelicColors c) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(Insets.lg),
        decoration: BoxDecoration(
          color: c.inset,
          borderRadius: BorderRadius.circular(Radii.card),
        ),
        child: SingleChildScrollView(
          child: SelectableText(_extractedText ?? '',
              style: RelicTheme.mono(size: 12.5, color: c.textSecondary, height: 1.7)),
        ),
      );

  // --- read-only attachment strip (mobile / non-string kinds) ---

  Widget _readonlyAttachments(RelicColors c) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final a in widget.relic.attachments) _attachmentTile(c, a),
        ],
      );

  Widget _attachmentTile(RelicColors c, Attachment a) {
    final path = widget.repo.attachmentPath(widget.relic, a.id);
    final isImg = path != null && isDisplayableImageFile(a.name, a.mime);
    final ready = path != null;
    return Container(
      margin: const EdgeInsets.only(bottom: Insets.sm),
      padding: const EdgeInsets.fromLTRB(Insets.md, Insets.sm, Insets.sm, Insets.sm),
      decoration: BoxDecoration(
        color: c.inset,
        borderRadius: BorderRadius.circular(Radii.row),
      ),
      child: Row(children: [
        SizedBox(
          width: 34,
          height: 34,
          child: isImg
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(Radii.tile),
                  child: Image.file(File(path), fit: BoxFit.cover,
                      errorBuilder: (_, e, s) =>
                          Icon(fileIconFor(a.name), size: 17, color: c.textSecondary)),
                )
              : Icon(fileIconFor(a.name), size: 18, color: c.textSecondary),
        ),
        const SizedBox(width: Insets.md),
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(a.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: RelicTheme.sans(size: 12.5, weight: FontWeight.w500, color: c.text)),
                const SizedBox(height: 2),
                Text(ready ? humanBytes(a.size) : 'Loading…',
                    style: RelicTheme.mono(size: 10.5, color: c.textFaint)),
              ]),
        ),
        if (ready) ...[
          _attachBtn(LucideIcons.externalLink, () => _openAttachment(a)),
          const SizedBox(width: Insets.xs),
          _attachBtn(LucideIcons.download, () => _saveAttachment(a)),
        ],
      ]),
    );
  }

  /// De-boxed: the old bordered 28px tile is now a plain ghost icon button, so
  /// the attachment row reads as one surface instead of three.
  Widget _attachBtn(IconData icon, VoidCallback onTap) => GhostIconButton(
        icon: icon,
        size: 28,
        iconSize: 14,
        onTap: onTap,
      );

  Future<void> _openAttachment(Attachment a) async {
    final p = widget.repo.attachmentPath(widget.relic, a.id);
    if (p != null) await OpenFilex.open(p);
  }

  Future<void> _saveAttachment(Attachment a) async {
    final p = widget.repo.attachmentPath(widget.relic, a.id);
    if (p == null) return;
    final mobile = RelicTheme.isMobileOf(context); // before any await
    final dot = a.name.lastIndexOf('.');
    final base = safeFileName(dot > 0 ? a.name.substring(0, dot) : a.name);
    final ext = dot > 0 ? a.name.substring(dot + 1) : 'bin';
    try {
      if (mobile) {
        // Was routed through desktopSaveDir, which on Android resolves to the
        // app-private .../files/Download — invisible to the user and wiped on
        // uninstall. Same destination rules as the main Save action now, and
        // straight from the unpacked attachment file (no byte buffering).
        final outcome = await saveFileOnMobile(
          sourcePath: p,
          base: base,
          ext: ext,
          isImage: a.mime?.startsWith('image/') ?? false,
          mime: a.mime,
        );
        if (!mounted || outcome.canceled) return;
        _toastSaved(outcome.location);
        return;
      }
      final bytes = await File(p).readAsBytes();
      final dir = await desktopSaveDir(widget.repo);
      final sep = Platform.pathSeparator;
      var path = '$dir$sep$base.$ext';
      for (var n = 1; File(path).existsSync(); n++) {
        path = '$dir$sep$base ($n).$ext';
      }
      File(path).writeAsBytesSync(bytes);
    } catch (e) {
      // Was swallowed entirely, so a failed attachment save looked like a
      // no-op button. Surface it.
      if (mounted) _toastSaved(null, error: '$e');
    }
  }

  /// Mobile confirmation snackbar. [message] overrides the save wording
  /// entirely, for callers reporting something other than a save.
  void _toastSaved(String? where, {String? error, String? message}) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.showSnackBar(SnackBar(
      content: Text(message ??
          (error != null
              ? 'Couldn’t save: $error'
              : (where != null ? 'Saved to $where' : 'Saved'))),
      duration: const Duration(seconds: 3),
    ));
  }

  // --- meta line ---

  Widget _metaLine(RelicColors c) {
    final r = widget.relic;
    final text = r.blobKey != null && r.kind != Kind.string
        ? '${r.mime ?? 'PNG'} · ${humanBytes(r.byteSize)}'
        : '${(_content ?? '').length} chars · ${r.device ?? ''}';
    return Text(text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: RelicTheme.mono(size: 10, color: c.textFaintest));
  }

  // --- internal actions (do NOT close the dialog) ---

  Future<void> _copyExtractedText() async {
    final t = _extractedText;
    if (t == null) return;
    await Clipboard.setData(ClipboardData(text: t));
    if (!mounted) return;
    setState(() => _copiedText = true);
    await Future.delayed(const Duration(milliseconds: 1400));
    if (mounted) setState(() => _copiedText = false);
  }

  /// Save the relic's blob to the device. Mobile: honours the user's Save
  /// location setting (Downloads / ask every time / gallery — see [SaveMode]).
  /// Desktop: one-click write to the configured Save location (Settings),
  /// defaulting to the OS Downloads folder. Decrypts (and downloads, if needed)
  /// the blob first.
  Future<void> _save() async {
    if (_saving || _saved) return;
    final mobile = RelicTheme.isMobileOf(context); // before any await
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      final r = widget.relic;
      String? where;
      if (mobile) {
        // Streams from the cached decrypted file; fetches it first if this is
        // the first time the blob has been needed on this device.
        final outcome = await saveBlobOnMobile(widget.repo, r);
        // Backing out of the system save sheet is not a failure and must not
        // latch the button into the saved state.
        if (outcome.canceled) {
          if (mounted) setState(() => _saving = false);
          return;
        }
        where = outcome.location;
      } else {
        // Desktop: one-click write to the configured Save location (Downloads
        // by default), never overwriting an existing file.
        await saveBlobToDisk(widget.repo, r);
      }
      if (mounted) {
        setState(() {
          _saving = false;
          _saved = true;
          _savedTo = where;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _saveError = '$e';
        });
      }
    }
  }

  /// Decrypt + download (if needed) the blob to a temp file with a real name +
  /// extension, then hand it to the OS's default app for this type.
  Future<void> _open() async {
    if (_opening) return;
    setState(() => _opening = true);
    var ok = false;
    try {
      ok = await openRelicExternally(widget.repo, widget.relic);
    } catch (_) {
    } finally {
      if (mounted) setState(() => _opening = false);
    }
    // A failed open used to be entirely silent. Offline with a blob that was
    // never downloaded is the usual reason, so say so.
    if (!ok && mounted) {
      _toastSaved(null,
          error: null,
          message: blobUnavailableMessage(widget.repo, widget.relic, 'open'));
    }
  }

  /// Open a text relic's link in the system browser (distinct from [_open],
  /// which hands a file blob to the OS viewer).
  Future<void> _openLink(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  // --- snippet box ---

  /// True when this item carries the reserved 'snippet' tag (kept in sync with
  /// the tags field, since both read/write [_tags]).
  bool get _isSnippet => _tags.contains('snippet');

  /// A one-tap box to make (or un-make) this item a reusable snippet. Adds or
  /// removes the 'snippet' tag; the change lands when the user hits Save.
  Widget _snippetBox(RelicColors c) {
    return GestureDetector(
      onTap: () => setState(() {
        if (_isSnippet) {
          _tags.remove('snippet');
        } else {
          _tags.add('snippet');
        }
      }),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: Insets.lg, vertical: Insets.md),
          decoration: BoxDecoration(
            // On: the selected-card language — warm tint + the system's gold
            // hairline. Gold stays a fill here; the label is always ink.
            color: _isSnippet ? c.tagBg : c.surface,
            borderRadius: BorderRadius.circular(Radii.row),
            border:
                Border.all(color: _isSnippet ? c.selectedBorder : c.border),
          ),
          child: Row(children: [
            Icon(_isSnippet ? LucideIcons.checkSquare : LucideIcons.square,
                size: 16, color: _isSnippet ? c.accent : c.textSecondary),
            const SizedBox(width: Insets.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Save as snippet',
                      style: RelicTheme.sans(
                          size: 13, weight: FontWeight.w500, color: c.text)),
                  const SizedBox(height: 2),
                  Text('Type its title in the picker and it jumps to the top.',
                      style:
                          RelicTheme.sans(size: 11, color: c.textSecondary)),
                ],
              ),
            ),
            Icon(LucideIcons.scrollText,
                size: 15,
                color: _isSnippet ? c.accent : c.textFaintest),
          ]),
        ),
      ),
    );
  }

  // --- footer ---

  Widget _footer(RelicColors c) {
    final r = widget.relic;
    // Phones: the touch clamp widens every icon button to 40px+, so the full
    // row can't fit at 360 logical — tighten gaps and drop the labeled Cancel
    // (the header X and system back already dismiss).
    final mobile = RelicTheme.isMobileOf(context);
    final gap = SizedBox(width: mobile ? 4 : Insets.sm);
    final ico = _footerIcon;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Insets.xl, vertical: Insets.md),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: c.border, width: 1))),
      child: Row(children: [
        GhostButton(
            icon: LucideIcons.trash2,
            size: ico,
            style: GhostStyle.danger,
            tooltip: 'Delete',
            onTap: widget.onDelete),
        SizedBox(width: mobile ? 6 : Insets.md),
        // When the edit would empty the relic, hide the action cluster and warn
        // instead — keeps the row from overflowing at the 380px Mini width.
        if (_wouldBeEmpty)
          Flexible(
            child: Text(
              'Keep some text or an attachment, or delete this relic instead.',
              maxLines: 2,
              style: RelicTheme.sans(size: 11, color: c.warning),
            ),
          )
        else ...[
          if (widget.onShare != null) ...[
            GhostIconButton(
                icon: LucideIcons.share2,
                size: ico,
                iconSize: 14,
                tooltip: 'Share',
                onTap: widget.onShare),
            gap,
          ],
          if (r.kind == Kind.string && r.firstUrl != null) ...[
            GhostIconButton(
                icon: LucideIcons.externalLink,
                size: ico,
                iconSize: 14,
                tooltip: 'Open link',
                onTap: () => _openLink(r.firstUrl!)),
            gap,
          ],
          if (r.hasFile) ...[
            _openIconAction(c),
            gap,
          ],
          if (r.blobKey != null) ...[
            _saveIconAction(c),
            gap,
          ],
          GhostIconButton(
              icon: LucideIcons.copy,
              size: ico,
              iconSize: 14,
              tooltip: 'Copy',
              onTap: widget.onCopy),
        ],
        const Spacer(),
        if (!mobile) ...[
          GhostButton(label: 'Cancel', size: 30, onTap: widget.onCancel),
          const SizedBox(width: Insets.sm),
        ],
        Opacity(
          opacity: _wouldBeEmpty ? 0.4 : 1,
          child: _primaryButton(c, null, 'Save', () {
            if (_wouldBeEmpty) return;
            widget.onSave(_title.text, _note.text, _tags, _machine,
                _bodyEditable ? _body.text : null, _added, _removedIds);
          }),
        ),
      ]),
    );
  }

  /// Footer icon buttons. `GhostButton` widens an icon-only button on phones to
  /// `(size * 1.4).clamp(40, 64)`, so 30 becomes 42 and an image relic's six
  /// actions overflow the 360dp footer by ~1px, slicing the Save pill. 28 lands
  /// on exactly the 40px minimum target, which buys back 2px a button without
  /// going under the touch floor. Desktop keeps 30 and is unchanged.
  double get _footerIcon => RelicTheme.isMobileOf(context) ? 28 : 30;

  /// Save-to-device icon with the ported state colors (warning on error,
  /// success when saved, faint while saving).
  Widget _saveIconAction(RelicColors c) {
    final icon = _saveError != null
        ? LucideIcons.triangleAlert
        : (_saved ? LucideIcons.check : LucideIcons.download);
    final color = _saveError != null
        ? c.warning
        : (_saved ? c.success : (_saving ? c.textFaint : null));
    final tip = _saveError != null
        ? 'Couldn’t save: $_saveError'
        : (_saved
            ? (_savedTo != null ? 'Saved to $_savedTo' : 'Saved')
            : 'Save to device');
    return color != null
        ? GhostButton(
            iconBuilder: (s, _) => Icon(icon, size: s, color: color),
            size: _footerIcon,
            iconSize: 14,
            tooltip: tip,
            onTap: _save)
        : GhostIconButton(
            icon: icon,
            size: _footerIcon,
            iconSize: 14,
            tooltip: tip,
            onTap: _save);
  }

  Widget _openIconAction(RelicColors c) {
    final color = _opening ? c.textFaint : null;
    return color != null
        ? GhostButton(
            iconBuilder: (s, _) => Icon(LucideIcons.externalLink, size: s, color: color),
            size: _footerIcon,
            iconSize: 14,
            tooltip: 'Open file',
            onTap: _open)
        : GhostIconButton(
            icon: LucideIcons.externalLink,
            size: _footerIcon,
            iconSize: 14,
            tooltip: 'Open file',
            onTap: _open);
  }

  // --- edit fields (title / note / tags / attachments) ---

  /// Existing attachments (X marks for removal, struck-through until saved,
  /// tap again to keep) + newly picked files + the Add files button. Mirrors
  /// the composer's picker incl. the running-total cap.
  Widget _attachmentsSection(RelicColors c) {
    final cap = widget.repo.maxItemBytes;
    final existing = widget.relic.attachments;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final a in existing)
        Container(
          margin: const EdgeInsets.only(bottom: Insets.sm),
          padding: const EdgeInsets.fromLTRB(Insets.md, 6, 6, 6),
          decoration: BoxDecoration(
            color: c.inset,
            borderRadius: BorderRadius.circular(Radii.row),
          ),
          child: Row(children: [
            Icon(fileIconFor(a.name),
                size: 15,
                color: _removedIds.contains(a.id)
                    ? c.textFaintest
                    : c.textSecondary),
            const SizedBox(width: Insets.md),
            Expanded(
              child: Text(
                a.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: RelicTheme.sans(
                  size: 12.5,
                  color: _removedIds.contains(a.id) ? c.textFaintest : c.text,
                ).copyWith(
                  decoration: _removedIds.contains(a.id)
                      ? TextDecoration.lineThrough
                      : null,
                ),
              ),
            ),
            const SizedBox(width: Insets.sm),
            Text(humanBytes(a.size),
                style: RelicTheme.mono(size: 10.5, color: c.textFaint)),
            const SizedBox(width: Insets.xs),
            GhostIconButton(
              icon: _removedIds.contains(a.id)
                  ? LucideIcons.undo2
                  : LucideIcons.x,
              size: 26,
              iconSize: 14,
              onTap: () => setState(() {
                if (!_removedIds.remove(a.id)) _removedIds.add(a.id);
              }),
            ),
          ]),
        ),
      for (var i = 0; i < _added.length; i++)
        Container(
          margin: const EdgeInsets.only(bottom: Insets.sm),
          padding: const EdgeInsets.fromLTRB(Insets.md, 6, 6, 6),
          decoration: BoxDecoration(
            // Newly picked files sit on the warm tag ground so "added, not yet
            // saved" reads without an outlined-gold box.
            color: c.tagBg,
            borderRadius: BorderRadius.circular(Radii.row),
          ),
          child: Row(children: [
            Icon(fileIconFor(_added[i].$1), size: 15, color: c.accent),
            const SizedBox(width: Insets.md),
            Expanded(
              child: Text(_added[i].$1,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: RelicTheme.sans(size: 12.5, color: c.text)),
            ),
            const SizedBox(width: Insets.sm),
            Text(humanBytes(_added[i].$3.length),
                style: RelicTheme.mono(size: 10.5, color: c.tagText)),
            const SizedBox(width: Insets.xs),
            GhostIconButton(
              icon: LucideIcons.x,
              size: 26,
              iconSize: 14,
              onTap: () => setState(() {
                _added.removeAt(i);
                _attachNote = null;
              }),
            ),
          ]),
        ),
      Row(children: [
        GhostButton(
          icon: LucideIcons.paperclip,
          label: _attachPicking ? 'Adding…' : 'Add files',
          size: 30,
          iconSize: 13,
          onTap: _pickAttachFiles,
        ),
        const SizedBox(width: Insets.md),
        if (existing.isNotEmpty || _added.isNotEmpty)
          Text(
            '${humanBytes(_keptExistingBytes + _addedBytes)} / ${humanBytes(cap)}',
            style: RelicTheme.mono(size: 10.5, color: c.textFaint),
          ),
      ]),
      if (_attachNote != null)
        Padding(
          padding: const EdgeInsets.only(top: Insets.sm),
          child: Text(_attachNote!,
              style: RelicTheme.sans(size: 11, color: c.warning)),
        ),
    ]);
  }

  /// Ported from ComposeDialog._pickFiles: native-modal guard, refocus, and
  /// the per-item cap accumulated over kept existing + already-added bytes.
  Future<void> _pickAttachFiles() async {
    if (_attachPicking) return;
    final mobile = RelicTheme.isMobileOf(context);
    setState(() => _attachPicking = true);
    if (!mobile) gNativeModalOpen = true;
    try {
      final res = await FilePicker.platform
          .pickFiles(allowMultiple: true, withData: true);
      if (!mobile) await windowManager.focus();
      if (res == null) return;
      final cap = widget.repo.maxItemBytes;
      var total = _keptExistingBytes + _addedBytes;
      var skipped = 0;
      final added = <(String, String?, Uint8List)>[];
      for (final f in res.files) {
        final b = f.bytes;
        if (b == null || total + b.length > cap) {
          skipped++;
          continue;
        }
        total += b.length;
        added.add((f.name, null, Uint8List.fromList(b)));
      }
      setState(() {
        _added.addAll(added);
        _attachNote = skipped > 0
            ? '$skipped file${skipped == 1 ? '' : 's'} skipped, over the '
                '${humanBytes(cap)} limit'
            : null;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _attachNote = 'Could not open the file picker: $e');
      }
    } finally {
      if (!mobile) gNativeModalOpen = false;
      if (mounted) setState(() => _attachPicking = false);
    }
  }

  Widget _label(RelicColors c, String t) => Padding(
        padding: const EdgeInsets.only(bottom: Insets.sm),
        child: Text(t.toUpperCase(), style: RelicTheme.label(c.textMuted)),
      );

  Widget _field(RelicColors c, TextEditingController ctl, FocusNode fn,
      {bool focused = false,
      double minHeight = 0,
      int maxLines = 1,
      bool mono = false}) {
    return Container(
      constraints: BoxConstraints(minHeight: minHeight),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: Insets.md),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(Radii.input),
        border: Border.all(color: focused ? c.accent : c.borderStrong, width: focused ? 1.5 : 1),
      ),
      child: TextField(
        controller: ctl,
        focusNode: fn,
        style: mono
            ? RelicTheme.mono(size: 12.5, color: c.text, height: 1.55)
            : RelicTheme.sans(size: 13.5, color: c.text, height: 1.4),
        cursorColor: c.accent,
        maxLines: maxLines,
        minLines: 1,
        decoration: kBareField,
      ),
    );
  }

  /// One-tap chips for your existing / created tags that aren't applied yet.
  Widget _suggestions(RelicColors c) {
    final avail = _allUserTags.where((t) => !_tags.contains(t)).take(24).toList();
    if (avail.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: Insets.md),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text('YOUR TAGS · TAP TO ADD', style: RelicTheme.kicker(c.textMuted)),
        const SizedBox(height: Insets.sm),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final t in avail)
            _AddTagChip(label: t, onTap: () => setState(() => _tags.add(t))),
        ]),
      ]),
    );
  }

  Widget _tagsField(RelicColors c) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Insets.md, vertical: Insets.md),
      decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(Radii.input), border: Border.all(color: c.borderStrong, width: 1)),
      child: Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
        // auto-assigned (machine) tags — removable, EXCEPT `secret`: dropping
        // it here would silently unmask the value, so it shows a lock instead.
        for (final t in _machine)
          _TagChip(
            label: t,
            trailingIcon: t == 'secret' ? LucideIcons.lock : LucideIcons.x,
            onTrailingTap: t == 'secret'
                ? null
                : () => setState(() => _machine.remove(t)),
          ),
        for (final t in _tags)
          _TagChip(
            label: t,
            trailingIcon: LucideIcons.x,
            onTrailingTap: () => setState(() => _tags.remove(t)),
          ),
        IntrinsicWidth(
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 60),
            child: TextField(
              controller: _tag,
              focusNode: _tagF,
              style: RelicTheme.mono(size: 12, color: c.text),
              cursorColor: c.accent,
              maxLines: 1,
              decoration: kBareField,
              onSubmitted: (v) {
                // Same normalization as TagsSheet create / addCustomTag — a
                // tag with spaces or casing drift is unfilterable (`tag:x`
                // takes one token, and matching is lowercase).
                final t =
                    v.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '-');
                if (t.isNotEmpty && !_tags.contains(t)) setState(() => _tags.add(t));
                _tag.clear();
                _tagF.requestFocus();
              },
            ),
          ),
        ),
      ]),
    );
  }
}


/// The "+" composer — author a relic by hand: a text body, optional title,
/// tags, and any number of file attachments (packed into one bundle blob). The
/// displayed type auto-derives from the result. Opened from the header + button.
class ComposeDialog extends StatefulWidget {
  final RelicRepo repo;
  final VoidCallback onCancel;

  /// Build the relic. The host calls `repo.createNote(...)` with these values.
  final void Function(
    String? title,
    String body,
    List<String> userTags,
    List<(String name, String? mime, Uint8List bytes)> files,
    bool promote,
  ) onCreate;

  /// When true (feature_snippets on), the composer offers a "Save as snippet"
  /// toggle that tags the new relic with the reserved `snippet` tag.
  final bool allowSnippet;

  const ComposeDialog({
    super.key,
    required this.repo,
    required this.onCancel,
    required this.onCreate,
    this.allowSnippet = false,
  });

  @override
  State<ComposeDialog> createState() => _ComposeDialogState();
}

class _ComposeDialogState extends State<ComposeDialog> {
  final _title = TextEditingController();
  final _body = TextEditingController();
  final _tag = TextEditingController();
  final _titleF = FocusNode();
  final _bodyF = FocusNode();
  final _tagF = FocusNode();
  final List<String> _tags = [];
  final List<(String name, String? mime, Uint8List bytes)> _files = [];
  late final List<String> _allUserTags =
      (widget.repo.tagFrequencies().user.keys.toList())..sort();
  bool _promote = false;
  bool _asSnippet = false;
  bool _picking = false;
  String? _capNote;

  int get _attachBytes => _files.fold(0, (n, f) => n + f.$3.length);
  bool get _canCreate => _body.text.trim().isNotEmpty || _files.isNotEmpty;

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    _tag.dispose();
    _titleF.dispose();
    _bodyF.dispose();
    _tagF.dispose();
    super.dispose();
  }

  Future<void> _pickFiles() async {
    if (_picking) return;
    // The popup-auto-hide guard and window refocus are desktop-only (no
    // window_manager on mobile, and nothing to re-focus).
    final mobile = RelicTheme.isMobileOf(context);
    setState(() => _picking = true);
    // Keep the popup from auto-hiding while the native dialog has focus.
    if (!mobile) gNativeModalOpen = true;
    try {
      final res = await FilePicker.platform
          .pickFiles(allowMultiple: true, withData: true);
      // Bring our window back to front after the OS dialog closes.
      if (!mobile) await windowManager.focus();
      if (res == null) return;
      final cap = widget.repo.maxItemBytes;
      var total = _attachBytes;
      var skipped = 0;
      final added = <(String, String?, Uint8List)>[];
      for (final f in res.files) {
        final b = f.bytes;
        if (b == null) {
          skipped++;
          continue;
        }
        if (total + b.length > cap) {
          skipped++;
          continue;
        }
        total += b.length;
        added.add((f.name, null, Uint8List.fromList(b)));
      }
      setState(() {
        _files.addAll(added);
        _capNote = skipped > 0
            ? '$skipped file${skipped == 1 ? '' : 's'} skipped, over the '
                '${humanBytes(cap)} limit'
            : null;
      });
    } catch (e) {
      if (mounted) setState(() => _capNote = 'Couldn’t open the file picker: $e');
    } finally {
      if (!mobile) gNativeModalOpen = false;
      if (mounted) setState(() => _picking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    return Container(
      width: 460,
      decoration: _modalDecoration(c),
      clipBehavior: Clip.antiAlias,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        _dialogHeader(
            c,
            Icon(_asSnippet ? LucideIcons.scrollText : LucideIcons.plus,
                size: 15, color: c.textSecondary),
            _asSnippet ? 'New snippet' : 'New relic',
            widget.onCancel),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(Insets.xl, Insets.xl, Insets.xl, Insets.lg),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (widget.allowSnippet) ...[
                GestureDetector(
                  onTap: () => setState(() => _asSnippet = !_asSnippet),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: Insets.lg, vertical: Insets.md),
                      decoration: BoxDecoration(
                        // Selected: warm tint + the system's gold hairline, the
                        // same treatment the edit screen's snippet box gets.
                        color: _asSnippet ? c.tagBg : c.surface,
                        borderRadius: BorderRadius.circular(Radii.row),
                        border: Border.all(
                            color: _asSnippet ? c.selectedBorder : c.border),
                      ),
                      child: Row(children: [
                        Icon(
                            _asSnippet
                                ? LucideIcons.checkSquare
                                : LucideIcons.square,
                            size: 16,
                            color: _asSnippet ? c.accent : c.textSecondary),
                        const SizedBox(width: Insets.md),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Save as snippet',
                                  style: RelicTheme.sans(
                                      size: 13,
                                      weight: FontWeight.w500,
                                      color: c.text)),
                              const SizedBox(height: 2),
                              Text(
                                  'Type its trigger in the picker and it jumps to the top.',
                                  style: RelicTheme.sans(
                                      size: 11, color: c.textSecondary)),
                            ],
                          ),
                        ),
                      ]),
                    ),
                  ),
                ),
                const SizedBox(height: Insets.xl),
              ],
              _label(c, _asSnippet ? 'Trigger label (e.g. ;welcome)' : 'Title (optional)'),
              _field(c, _title, _titleF),
              const SizedBox(height: Insets.xl),
              _label(c, _asSnippet ? 'Snippet text' : 'Text'),
              _field(c, _body, _bodyF,
                  focused: true, minHeight: 84, maxLines: 8),
              const SizedBox(height: Insets.xl),
              _label(c, 'Tags'),
              _tagsField(c),
              _suggestions(),
              const SizedBox(height: Insets.xl),
              _label(c, 'Attachments'),
              _attachments(c),
            ]),
          ),
        ),
        _footer(c),
      ]),
    );
  }

  Widget _footer(RelicColors c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: Insets.xl, vertical: Insets.md),
        decoration: BoxDecoration(
            border: Border(top: BorderSide(color: c.border, width: 1))),
        child: Row(children: [
          GestureDetector(
            onTap: () => setState(() => _promote = !_promote),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(_promote ? LucideIcons.checkSquare : LucideIcons.square,
                    size: 15, color: _promote ? c.accent : c.textSecondary),
                const SizedBox(width: Insets.sm),
                Text('Save to Vault',
                    style: RelicTheme.sans(
                        size: 12.5,
                        color: _promote ? c.text : c.textSecondary)),
              ]),
            ),
          ),
          const Spacer(),
          GhostButton(label: 'Cancel', size: 30, onTap: widget.onCancel),
          const SizedBox(width: Insets.sm),
          Opacity(
            opacity: _canCreate ? 1 : 0.4,
            child: _primaryButton(c, LucideIcons.check, 'Create', () {
              if (!_canCreate) return;
              final tags = _asSnippet && !_tags.contains('snippet')
                  ? [..._tags, 'snippet']
                  : _tags;
              widget.onCreate(
                _title.text.trim().isEmpty ? null : _title.text.trim(),
                _body.text,
                tags,
                _files,
                _promote,
              );
            }),
          ),
        ]),
      );

  Widget _attachments(RelicColors c) {
    final cap = widget.repo.maxItemBytes;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (_files.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: Insets.sm),
          child: Column(
            children: [
              for (var i = 0; i < _files.length; i++) _attachRow(c, i),
            ],
          ),
        ),
      Row(children: [
        GhostButton(
          icon: LucideIcons.paperclip,
          label: _picking ? 'Adding…' : 'Add files',
          size: 30,
          iconSize: 13,
          onTap: _pickFiles,
        ),
        const SizedBox(width: Insets.md),
        if (_files.isNotEmpty)
          Text('${humanBytes(_attachBytes)} / ${humanBytes(cap)}',
              style: RelicTheme.mono(size: 10.5, color: c.textFaint)),
      ]),
      if (_capNote != null)
        Padding(
          padding: const EdgeInsets.only(top: Insets.sm),
          child: Text(_capNote!,
              style: RelicTheme.sans(size: 11, color: c.warning)),
        ),
    ]);
  }

  Widget _attachRow(RelicColors c, int i) {
    final f = _files[i];
    return Container(
      margin: const EdgeInsets.only(bottom: Insets.sm),
      padding: const EdgeInsets.fromLTRB(Insets.md, 6, 6, 6),
      decoration: BoxDecoration(
        color: c.inset,
        borderRadius: BorderRadius.circular(Radii.row),
      ),
      child: Row(children: [
        Icon(fileIconFor(f.$1), size: 15, color: c.textSecondary),
        const SizedBox(width: Insets.md),
        Expanded(
          child: Text(f.$1,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: RelicTheme.sans(size: 12.5, color: c.text)),
        ),
        const SizedBox(width: Insets.sm),
        Text(humanBytes(f.$3.length),
            style: RelicTheme.mono(size: 10.5, color: c.textFaint)),
        const SizedBox(width: Insets.xs),
        GhostIconButton(
          icon: LucideIcons.x,
          size: 26,
          iconSize: 14,
          onTap: () => setState(() {
            _files.removeAt(i);
            _capNote = null;
          }),
        ),
      ]),
    );
  }

  // --- shared field widgets (mirrors EditDialog) ---

  Widget _label(RelicColors c, String t) => Padding(
        padding: const EdgeInsets.only(bottom: Insets.sm),
        child: Text(t.toUpperCase(), style: RelicTheme.label(c.textMuted)),
      );

  Widget _field(RelicColors c, TextEditingController ctl, FocusNode fn,
      {bool focused = false,
      double minHeight = 0,
      int maxLines = 1,
      bool mono = false}) {
    return Container(
      constraints: BoxConstraints(minHeight: minHeight),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: Insets.md),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(Radii.input),
        border: Border.all(
            color: focused ? c.accent : c.borderStrong,
            width: focused ? 1.5 : 1),
      ),
      child: TextField(
        controller: ctl,
        focusNode: fn,
        style: mono
            ? RelicTheme.mono(size: 12.5, color: c.text, height: 1.55)
            : RelicTheme.sans(size: 13.5, color: c.text, height: 1.4),
        cursorColor: c.accent,
        maxLines: maxLines,
        minLines: 1,
        onChanged: (_) => setState(() {}),
        decoration: kBareField,
      ),
    );
  }

  Widget _suggestions() {
    final avail = _allUserTags.where((t) => !_tags.contains(t)).take(20).toList();
    if (avail.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: Insets.md),
      child: Wrap(spacing: 6, runSpacing: 6, children: [
        for (final t in avail)
          _AddTagChip(label: t, onTap: () => setState(() => _tags.add(t))),
      ]),
    );
  }

  Widget _tagsField(RelicColors c) {
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: Insets.md, vertical: Insets.md),
      decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(Radii.input),
          border: Border.all(color: c.borderStrong, width: 1)),
      child: Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final t in _tags)
              _TagChip(
                label: t,
                trailingIcon: LucideIcons.x,
                onTrailingTap: () => setState(() => _tags.remove(t)),
              ),
            IntrinsicWidth(
              child: ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 60),
                child: TextField(
                  controller: _tag,
                  focusNode: _tagF,
                  style: RelicTheme.mono(size: 12, color: c.text),
                  cursorColor: c.accent,
                  maxLines: 1,
                  decoration: kBareField,
                  onSubmitted: (v) {
                    // Normalized like every other tag-creation path.
                    final t =
                        v.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '-');
                    if (t.isNotEmpty && !_tags.contains(t)) {
                      setState(() => _tags.add(t));
                    }
                    _tag.clear();
                    _tagF.requestFocus();
                  },
                ),
              ),
            ),
          ]),
    );
  }
}

/// Browse every tag present — the user's own and the auto-assigned — with
/// counts; tap one to filter the list. Opened from the popup header's # button.
class TagsSheet extends StatefulWidget {
  final RelicRepo repo;
  final bool vaultOnly;

  /// Toggle a tag in/out of the active filter. The sheet stays open and the
  /// passed-in [selected] list reflects the change so the user can multi-select
  /// and unselect without the menu closing.
  final void Function(String tag) onPick;

  /// The currently-active filter tags (live reference — mutated by [onPick]).
  final List<String> selected;

  /// Create + persist a reusable tag from the Tags pane.
  final Future<void> Function(String tag) onCreateTag;
  final VoidCallback onClose;
  const TagsSheet({
    super.key,
    required this.repo,
    required this.vaultOnly,
    required this.onPick,
    required this.selected,
    required this.onCreateTag,
    required this.onClose,
  });

  @override
  State<TagsSheet> createState() => _TagsSheetState();
}

class _TagsSheetState extends State<TagsSheet> {
  final _q = TextEditingController();
  final _qf = FocusNode();
  late var _freq = widget.repo.tagFrequencies(vaultOnly: widget.vaultOnly);

  // inline rename/delete editor (long-press a chip)
  String? _editing;
  bool _editingUser = false;
  final _editCtl = TextEditingController();
  final _editF = FocusNode();

  // "+ New tag" creator
  bool _creating = false;
  final _newCtl = TextEditingController();
  final _newF = FocusNode();

  @override
  void initState() {
    super.initState();
    _qf.requestFocus();
  }

  @override
  void dispose() {
    _q.dispose();
    _qf.dispose();
    _editCtl.dispose();
    _editF.dispose();
    _newCtl.dispose();
    _newF.dispose();
    super.dispose();
  }

  bool _isSelected(String tag) => widget.selected.contains(tag);

  void _toggle(String tag) {
    widget.onPick(tag); // mutates widget.selected + re-runs the query
    setState(() {}); // re-render this sheet's highlight
  }

  void _startCreate() {
    setState(() {
      _creating = true;
      _newCtl.clear();
    });
    _newF.requestFocus();
  }

  Future<void> _commitCreate() async {
    final raw = _newCtl.text.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '-');
    if (raw.isNotEmpty) await widget.onCreateTag(raw);
    if (!mounted) return;
    setState(() {
      _creating = false;
      _freq = widget.repo.tagFrequencies(vaultOnly: widget.vaultOnly);
    });
  }

  void _enterEdit(String tag, bool user) {
    setState(() {
      _editing = tag;
      _editingUser = user;
      _editCtl.text = tag;
    });
    _editF.requestFocus();
  }

  Future<void> _commitRename() async {
    final from = _editing;
    if (from == null) return;
    final to = _editCtl.text.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '-');
    if (to.isNotEmpty && to != from) {
      await widget.repo.renameTag(from, to, userTag: _editingUser);
    }
    _finishEdit();
  }

  Future<void> _commitDelete() async {
    final t = _editing;
    if (t == null) return;
    await widget.repo.deleteTag(t, userTag: _editingUser);
    _finishEdit();
  }

  void _finishEdit() {
    if (!mounted) return;
    setState(() {
      _editing = null;
      _freq = widget.repo.tagFrequencies(vaultOnly: widget.vaultOnly);
    });
  }

  List<MapEntry<String, int>> _filtered(Map<String, int> m) {
    final query = _q.text.trim().toLowerCase();
    final e = m.entries.where((x) => query.isEmpty || x.key.toLowerCase().contains(query)).toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return e;
  }

  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    final user = _filtered(_freq.user);
    final machine = _filtered(_freq.machine);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 460),
      child: Container(
        width: double.infinity, // fits the popup width (mini → standard)
        decoration: _modalDecoration(c),
        clipBehavior: Clip.antiAlias,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          _dialogHeader(c, Icon(LucideIcons.hash, size: 15, color: c.textSecondary),
              widget.vaultOnly ? 'Tags · Vault' : 'Tags', widget.onClose),
          // search
          Padding(
            padding: const EdgeInsets.fromLTRB(Insets.xl, Insets.lg, Insets.xl, 6),
            child: GestureDetector(
              onTap: _qf.requestFocus,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: Insets.md, vertical: Insets.md),
                decoration: BoxDecoration(
                  color: c.surface,
                  borderRadius: BorderRadius.circular(Radii.input),
                  border: Border.all(color: c.borderStrong),
                ),
                child: Row(children: [
                  Icon(LucideIcons.search, size: 14, color: c.textFaintest),
                  const SizedBox(width: Insets.md),
                  Expanded(
                    child: TextField(
                      controller: _q,
                      focusNode: _qf,
                      onChanged: (_) => setState(() {}),
                      style: RelicTheme.mono(size: 12.5, color: c.text),
                      cursorColor: c.accent,
                      maxLines: 1,
                      decoration: kBareField.copyWith(
                        hintText: 'Filter tags…',
                        hintStyle:
                            RelicTheme.mono(size: 12.5, color: c.textFaintest),
                      ),
                    ),
                  ),
                ]),
              ),
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(Insets.xl, Insets.sm, Insets.xl, Insets.xl),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _section(c, 'YOUR TAGS'),
                if (_creating) _newTagInput(c),
                // The "+ New tag" lives inline as the first chip, so it always
                // sits with the tags instead of floating in the header corner.
                _chips(c, user,
                    accent: true, leading: _creating ? null : _addChip()),
                if (machine.isNotEmpty) ...[
                  _section(c, 'AUTO'),
                  _chips(c, machine, accent: false),
                ],
                const SizedBox(height: Insets.xl),
                Row(children: [
                  Icon(LucideIcons.info, size: 12, color: c.textFaintest),
                  const SizedBox(width: Insets.sm),
                  Flexible(
                    child: Text('Tap to filter (tap again to unselect) · long-press to rename or delete.',
                        style: RelicTheme.sans(size: 11, color: c.textFaintest)),
                  ),
                ]),
              ]),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _section(RelicColors c, String t) => Padding(
        padding: const EdgeInsets.fromLTRB(2, Insets.lg, 0, Insets.md),
        child: Text(t, style: RelicTheme.kicker(c.textMuted)),
      );

  /// The "+ New tag" creator, flowing inline with the user's tags (the first
  /// item in the YOUR TAGS wrap). It is the pane's one gold CTA: creating a tag
  /// is the only thing here that isn't filtering, so it takes the filled
  /// gradient pill and every other chip stays on the warm tint.
  Widget _addChip() {
    final m = RelicTheme.isMobileOf(context);
    return GhostButton(
      icon: LucideIcons.plus,
      label: 'New tag',
      size: m ? 36 : 32,
      iconSize: m ? 14 : 12,
      fontSize: m ? 12.5 : 11.5,
      style: GhostStyle.filled,
      onTap: _startCreate,
    );
  }

  /// Inline input for creating a reusable tag.
  Widget _newTagInput(RelicColors c) => Padding(
        padding: const EdgeInsets.only(bottom: Insets.sm),
        child: Container(
          padding: const EdgeInsets.fromLTRB(Insets.md, Insets.xs, Insets.xs, Insets.xs),
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(Radii.input),
            border: Border.all(color: c.accent, width: 1.5),
          ),
          child: Row(children: [
            Text('#', style: RelicTheme.mono(size: 12, color: c.textFaintest)),
            const SizedBox(width: Insets.xs),
            Expanded(
              child: TextField(
                controller: _newCtl,
                focusNode: _newF,
                onChanged: (_) => setState(() {}),
                style: RelicTheme.mono(size: 12, color: c.text),
                cursorColor: c.accent,
                maxLines: 1,
                decoration: kBareField.copyWith(
                  hintText: 'name your tag…',
                  hintStyle: RelicTheme.mono(size: 12, color: c.textFaintest),
                ),
                onSubmitted: (_) => _commitCreate(),
              ),
            ),
            _iconBtn(c, LucideIcons.check, c.successDim, _commitCreate),
            _iconBtn(c, LucideIcons.x, c.textFaint, () => setState(() => _creating = false)),
          ]),
        ),
      );

  Widget _chips(RelicColors c, List<MapEntry<String, int>> tags,
      {required bool accent, Widget? leading}) {
    final m = RelicTheme.isMobileOf(context);
    // Force the Wrap to take the full dialog width so chips flow as pills,
    // multiple per row — never one-per-row.
    return SizedBox(
      width: double.infinity,
      child: Wrap(
      spacing: 7,
      runSpacing: 7,
      alignment: WrapAlignment.start,
      children: [
        ?leading,
        for (final e in tags)
          if (_editing == e.key && _editingUser == accent)
            _editChip(c)
          else
            Builder(builder: (_) {
              final sel = _isSelected(e.key);
              // The machine `secret` chip is filter-only: renaming/deleting it
              // would unmask the whole vault (the repo refuses too — this just
              // avoids offering a dead editor).
              final locked = !accent && e.key == 'secret';
              return GestureDetector(
                onTap: () => _toggle(e.key),
                onLongPress: locked ? null : () => _enterEdit(e.key, accent),
                onSecondaryTap: locked ? null : () => _enterEdit(e.key, accent),
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Container(
                    height: m ? 36 : 32,
                    // NB: no `alignment` here — a Container with an alignment +
                    // bounded constraints expands to fill the width, which made
                    // every pill full-width (one per row). The fixed height +
                    // the Row (mainAxisSize.min, default center) centers content
                    // vertically while letting each pill hug its text.
                    padding: EdgeInsets.fromLTRB(sel ? 10 : 12, 0, 12, 0),
                    decoration: BoxDecoration(
                      // Selected: a flat gold fill — loud, but deliberately not
                      // the gradient, which belongs to the one CTA above.
                      // Unselected: the warm tag chip — tint ground, deep-gold
                      // mono, no hairline in either palette.
                      color: sel ? c.accent : c.tagBg,
                      borderRadius: BorderRadius.circular(Radii.pill),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      if (sel) ...[
                        Icon(LucideIcons.check, size: 11, color: c.onAccent),
                        const SizedBox(width: Insets.xs),
                      ],
                      Text(e.key,
                          style: RelicTheme.mono(
                              size: m ? 13 : 12,
                              color: sel ? c.onAccent : c.tagText)),
                      const SizedBox(width: 6),
                      Text('${e.value}',
                          style: RelicTheme.mono(
                              size: 10.5,
                              color: sel
                                  ? c.onAccent.withValues(alpha: 0.7)
                                  : c.tagText.withValues(alpha: 0.7))),
                    ]),
                  ),
                ),
              );
            }),
      ],
      ),
    );
  }

  /// Inline rename/delete editor shown in place of a long-pressed chip.
  Widget _editChip(RelicColors c) => Container(
        padding: const EdgeInsets.fromLTRB(Insets.md, 3, Insets.xs, 3),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(Radii.pill),
          border: Border.all(color: c.accent, width: 1.5),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 50, maxWidth: 140),
            child: IntrinsicWidth(
              child: TextField(
                controller: _editCtl,
                focusNode: _editF,
                style: RelicTheme.mono(size: 12, color: c.text),
                cursorColor: c.accent,
                maxLines: 1,
                decoration: kBareField,
                onSubmitted: (_) => _commitRename(),
              ),
            ),
          ),
          const SizedBox(width: 4),
          _iconBtn(c, LucideIcons.check, c.successDim, _commitRename),
          _iconBtn(c, LucideIcons.trash2, c.dangerText, _commitDelete),
          _iconBtn(c, LucideIcons.x, c.textFaint, () => setState(() => _editing = null)),
        ]),
      );

  Widget _iconBtn(RelicColors c, IconData icon, Color color, VoidCallback onTap) => Hoverable(
        onTap: onTap,
        builder: (context, hovered) => Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: hovered ? c.ghostHover : const Color(0x00000000),
            borderRadius: BorderRadius.circular(Radii.chip),
          ),
          child: Icon(icon, size: 14, color: color),
        ),
      );
}

/// A small confirm / cancel modal for destructive actions (e.g. deleting a
/// vault item). Matches the app's modal styling.
/// Minimal one-field prompt used by the popup's multi-select bar: type a tag,
/// apply it to every selected relic's user tags. Normalization mirrors the
/// TagsSheet create field.
class BulkTagDialog extends StatefulWidget {
  final int count;
  final void Function(String tag) onApply;
  final VoidCallback onCancel;
  const BulkTagDialog({
    super.key,
    required this.count,
    required this.onApply,
    required this.onCancel,
  });
  @override
  State<BulkTagDialog> createState() => _BulkTagDialogState();
}

class _BulkTagDialogState extends State<BulkTagDialog> {
  final _ctl = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _ctl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _apply() {
    final tag =
        _ctl.text.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '-');
    if (tag.isEmpty) return;
    widget.onApply(tag);
  }

  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: Container(
        width: 360,
        decoration: _modalDecoration(c),
        clipBehavior: Clip.antiAlias,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          _dialogHeader(
            c,
            Icon(LucideIcons.hash, size: 15, color: c.textSecondary),
            'Tag ${widget.count} items',
            widget.onCancel,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Insets.xl, Insets.xl, Insets.xl, Insets.xs),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: Insets.md),
              decoration: BoxDecoration(
                color: c.surface,
                borderRadius: BorderRadius.circular(Radii.input),
                border: Border.all(color: c.borderStrong),
              ),
              child: TextField(
                controller: _ctl,
                focusNode: _focus,
                style: RelicTheme.sans(size: 13.5, color: c.text),
                cursorColor: c.accent,
                maxLines: 1,
                decoration: kBareField.copyWith(
                  hintText: 'tag name…',
                  hintStyle:
                      RelicTheme.sans(size: 13.5, color: c.textFaintest),
                ),
                onSubmitted: (_) => _apply(),
              ),
            ),
          ),
          Container(
            margin: const EdgeInsets.only(top: Insets.lg),
            padding: const EdgeInsets.symmetric(horizontal: Insets.xl, vertical: Insets.md),
            decoration: BoxDecoration(
                border: Border(top: BorderSide(color: c.border, width: 1))),
            child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              GhostButton(label: 'Cancel', size: 30, onTap: widget.onCancel),
              const SizedBox(width: Insets.sm),
              _primaryButton(c, null, 'Apply', _apply),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// Friendly time label for a reminder ("Today 6:00 PM", "Tomorrow 9:00 AM",
/// "Jul 20, 6:00 PM"). Local time.
String _fmtRemindAt(DateTime at) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(at.year, at.month, at.day);
  final diff = day.difference(today).inDays;
  final h = at.hour == 0 ? 12 : (at.hour > 12 ? at.hour - 12 : at.hour);
  final m = at.minute.toString().padLeft(2, '0');
  final ap = at.hour < 12 ? 'AM' : 'PM';
  final t = '$h:$m $ap';
  if (diff == 0) return 'Today $t';
  if (diff == 1) return 'Tomorrow $t';
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  return '${months[at.month - 1]} ${at.day}, $t';
}

/// Schedule (or clear) a reminder for one item: pick a day on the calendar and
/// a time on the wheels, then hit Set. Nothing fires until Set. [pending] is
/// (reminderId, remindAtMs). Times are epoch ms.
class RemindDialog extends StatefulWidget {
  final String preview;
  final List<(int, int)> pending;
  final void Function(int remindAtMs) onPick;
  final void Function(int id) onClear;
  final VoidCallback onCancel;
  const RemindDialog({
    super.key,
    required this.preview,
    required this.pending,
    required this.onPick,
    required this.onClear,
    required this.onCancel,
  });

  @override
  State<RemindDialog> createState() => _RemindDialogState();
}

class _RemindDialogState extends State<RemindDialog> {
  // Source of truth: the chosen calendar day plus a 24h time.
  late DateTime _day; // date-only (local midnight)
  late int _hour24;
  late int _minute; // stepped to 5

  static int _ms(DateTime d) => d.millisecondsSinceEpoch;

  @override
  void initState() {
    super.initState();
    // Default: an hour from now, rounded up to the next 5 minutes.
    var t = DateTime.now().add(const Duration(hours: 1));
    var m = ((t.minute + 4) ~/ 5) * 5;
    if (m >= 60) {
      m = 0;
      t = t.add(const Duration(hours: 1));
    }
    _day = DateTime(t.year, t.month, t.day);
    _hour24 = t.hour;
    _minute = m;
  }

  int get _hour12 {
    final h = _hour24 % 12;
    return h == 0 ? 12 : h;
  }

  bool get _isPm => _hour24 >= 12;

  void _setHour12(int h12) {
    // Keep AM/PM, change only the 1..12 part.
    var h = h12 % 12; // 12 -> 0
    if (_isPm) h += 12;
    setState(() => _hour24 = h);
  }

  void _setPm(bool pm) {
    setState(() {
      final base = _hour24 % 12; // 0..11
      _hour24 = pm ? base + 12 : base;
    });
  }

  DateTime get _resolved =>
      DateTime(_day.year, _day.month, _day.day, _hour24, _minute);

  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final valid = _resolved.isAfter(now);

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 340),
      child: Container(
        width: 340,
        decoration: _modalDecoration(c),
        clipBehavior: Clip.antiAlias,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          _dialogHeader(
            c,
            Icon(LucideIcons.alarmClock, size: 15, color: c.textSecondary),
            'Remind me',
            widget.onCancel,
          ),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (widget.preview.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(Insets.xl, Insets.lg, Insets.xl, 0),
                      child: Text(
                        widget.preview,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: RelicTheme.sans(size: 12, color: c.textSecondary),
                      ),
                    ),
                  // Date: a normal month calendar (Material, themed on-palette).
                  Theme(
                    data: materialThemeFor(c),
                    child: Material(
                      type: MaterialType.transparency,
                      child: CalendarDatePicker(
                        initialDate: _day,
                        firstDate: today,
                        lastDate: today.add(const Duration(days: 365)),
                        onDateChanged: (d) => setState(
                            () => _day = DateTime(d.year, d.month, d.day)),
                      ),
                    ),
                  ),
                  Container(height: 1, color: c.border),
                  // Time: hour / minute steppers (carets) + AM/PM. Minutes
                  // step by 5; both wrap around.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(Insets.xl, Insets.lg, Insets.xl, Insets.lg),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _stepper(
                          c,
                          value: '$_hour12',
                          onUp: () =>
                              _setHour12(_hour12 == 12 ? 1 : _hour12 + 1),
                          onDown: () =>
                              _setHour12(_hour12 == 1 ? 12 : _hour12 - 1),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
                          child: Text(':',
                              style: RelicTheme.mono(size: 22, color: c.textFaint)),
                        ),
                        _stepper(
                          c,
                          value: _minute.toString().padLeft(2, '0'),
                          onUp: () =>
                              setState(() => _minute = (_minute + 5) % 60),
                          onDown: () => setState(
                              () => _minute = (_minute - 5 + 60) % 60),
                        ),
                        const SizedBox(width: Insets.xl),
                        Column(mainAxisSize: MainAxisSize.min, children: [
                          _ampmBtn(c, 'AM', !_isPm, () => _setPm(false)),
                          const SizedBox(height: 6),
                          _ampmBtn(c, 'PM', _isPm, () => _setPm(true)),
                        ]),
                      ],
                    ),
                  ),
                  if (widget.pending.isNotEmpty) ...[
                    Container(height: 1, color: c.border),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(Insets.xl, Insets.md, Insets.md, Insets.xs),
                      child: Text('SCHEDULED',
                          style: RelicTheme.kicker(c.textMuted)),
                    ),
                    for (final (id, at) in widget.pending)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(Insets.xl, 2, Insets.md, 2),
                        child: Row(children: [
                          Expanded(
                            child: Text(
                              _fmtRemindAt(
                                  DateTime.fromMillisecondsSinceEpoch(at)),
                              style: RelicTheme.sans(size: 12.5, color: c.text),
                            ),
                          ),
                          GhostIconButton(
                            icon: LucideIcons.x,
                            size: 26,
                            iconSize: 14,
                            onTap: () => widget.onClear(id),
                          ),
                        ]),
                      ),
                    const SizedBox(height: 6),
                  ],
                  // Air below the last caret so it never sits flush against the
                  // footer border when the body scrolls in a short window.
                  const SizedBox(height: 14),
                ],
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: Insets.xl, vertical: Insets.md),
            decoration: BoxDecoration(
                border: Border(top: BorderSide(color: c.border, width: 1))),
            child: Row(children: [
              Expanded(
                child: Text(
                  valid ? _fmtRemindAt(_resolved) : 'Pick a future time',
                  style: RelicTheme.sans(
                      size: 11.5,
                      color: valid ? c.textSecondary : c.textFaintest),
                ),
              ),
              GhostButton(label: 'Close', size: 30, onTap: widget.onCancel),
              const SizedBox(width: Insets.sm),
              Opacity(
                opacity: valid ? 1 : 0.4,
                child: _primaryButton(c, LucideIcons.alarmClock, 'Set', () {
                  if (valid) widget.onPick(_ms(_resolved));
                }),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _stepper(
    RelicColors c, {
    required String value,
    required VoidCallback onUp,
    required VoidCallback onDown,
  }) {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      _caret(LucideIcons.chevronUp, onUp),
      const SizedBox(height: Insets.xs),
      Container(
        width: 58,
        padding: const EdgeInsets.symmetric(vertical: Insets.sm),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(Radii.input),
          border: Border.all(color: c.borderStrong),
        ),
        // A clock reading is a machine fact, so it stays mono — proportional
        // headline digits would jitter as the stepper runs.
        child: Text(value, style: RelicTheme.mono(size: 22, color: c.text)),
      ),
      const SizedBox(height: Insets.xs),
      _caret(LucideIcons.chevronDown, onDown),
    ]);
  }

  Widget _caret(IconData icon, VoidCallback onTap) => GhostIconButton(
        icon: icon,
        size: 34,
        iconSize: 20,
        onTap: onTap,
      );

  Widget _ampmBtn(RelicColors c, String label, bool on, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          width: 46,
          padding: const EdgeInsets.symmetric(vertical: Insets.sm),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            // On: the warm tag ground with the system's gold hairline — never
            // gold text on bare white.
            color: on ? c.tagBg : c.surface,
            borderRadius: BorderRadius.circular(Radii.input),
            border: Border.all(color: on ? c.selectedBorder : c.borderStrong),
          ),
          child: Text(label,
              style: RelicTheme.mono(
                  size: 11.5,
                  weight: FontWeight.w600,
                  color: on ? c.tagText : c.textSecondary)),
        ),
      ),
    );
  }
}

class ConfirmDialog extends StatelessWidget {
  final String title;
  final String message;
  final String confirmLabel;
  final bool danger;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;
  const ConfirmDialog({
    super.key,
    required this.title,
    required this.message,
    required this.confirmLabel,
    this.danger = true,
    required this.onConfirm,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 380),
      child: Container(
        width: 380,
        decoration: _modalDecoration(c),
        clipBehavior: Clip.antiAlias,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          _dialogHeader(
            c,
            Icon(danger ? LucideIcons.triangleAlert : LucideIcons.info,
                size: 15, color: danger ? c.dangerText : c.textSecondary),
            title,
            onCancel,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Insets.xl, Insets.xl, Insets.xl, Insets.xxl),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(message,
                  style: RelicTheme.sans(size: 13.5, color: c.textSecondary, height: 1.55)),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: Insets.xl, vertical: Insets.md),
            decoration: BoxDecoration(border: Border(top: BorderSide(color: c.border, width: 1))),
            child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              GhostButton(label: 'Cancel', size: 30, onTap: onCancel),
              const SizedBox(width: Insets.sm),
              // Destructive confirm is a standing tint (dangerBg + dangerText),
              // no longer a solid-red button; non-destructive is the accent CTA.
              if (danger)
                GhostButton(
                  label: confirmLabel,
                  size: 30,
                  style: GhostStyle.dangerTint,
                  onTap: onConfirm,
                )
              else
                PrimaryButton(label: confirmLabel, onTap: onConfirm),
            ]),
          ),
        ]),
      ),
    );
  }
}
