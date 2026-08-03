import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart'
    show CircularProgressIndicator, TextField, InputDecoration, InputBorder,
        Tooltip;
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme/relic_theme.dart';
import '../theme/tokens.dart';
import 'controls.dart';
import 'relic_mark.dart';

enum Scope { all, vault }

enum SyncKind { synced, pending, offline, quotaFull }

class SyncState {
  final SyncKind kind;
  final int pending;
  const SyncState(this.kind, {this.pending = 0});
}

/// Popup header: wordmark · sync state · settings gear · close.
class PopupHeader extends StatelessWidget {
  final SyncState sync;
  final bool syncing;
  final VoidCallback onSettings;
  final VoidCallback? onClose;
  final VoidCallback? onTags;
  final VoidCallback? onCompose;
  // Pin: keep the popup open across focus loss (desktop only; blur-to-close
  // is a desktop behavior, so mobile never shows the button).
  final bool pinned;
  final VoidCallback? onPinToggle;
  // Optional anchors for first-run coach marks (desktop).
  final Key? composeKey;
  final Key? settingsKey;
  // Chip click: hosts wire this to "Sync now" when healthy and to the
  // sync-issues sheet when items are blocked. Null = inert chip.
  final VoidCallback? onSyncTap;
  // Tooltip line for the chip ("Last synced 12s ago" / "Not synced yet").
  final String? syncTooltip;
  // Aggregate blob-upload progress (0..1) while any attachment is uploading, or
  // null. When set the chip shows "Uploading NN%" as a global cue.
  final double? uploadFraction;
  const PopupHeader({
    super.key,
    required this.sync,
    this.syncing = false,
    required this.onSettings,
    this.onClose,
    this.onTags,
    this.onCompose,
    this.pinned = false,
    this.onPinToggle,
    this.composeKey,
    this.settingsKey,
    this.onSyncTap,
    this.syncTooltip,
    this.uploadFraction,
  });

  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 11, 14, 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.border, width: 1)),
      ),
      child: Row(
        children: [
          const RelicIcon(size: 16),
          const SizedBox(width: 8),
          Text(
            'RELIC',
            style: RelicTheme.mono(
              size: 11,
              weight: FontWeight.w600,
              color: c.textMuted,
              letterSpacing: 2,
            ),
          ),
          const Spacer(),
          _SyncChip(
            sync: sync,
            syncing: syncing,
            uploadFraction: uploadFraction,
            onTap: onSyncTap,
            tooltip: syncTooltip,
          ),
          const SizedBox(width: 9),
          // Desktop opens the composer from the header "+"; mobile uses the
          // floating action button instead, so hide this to avoid two add paths.
          if (onCompose != null && !RelicTheme.isMobileOf(context)) ...[
            _HeaderBtn(
                key: composeKey,
                icon: LucideIcons.plus,
                onTap: onCompose!,
                filled: true),
            const SizedBox(width: 7),
          ],
          if (onTags != null) ...[
            _HeaderBtn(icon: LucideIcons.hash, onTap: onTags!),
            const SizedBox(width: 7),
          ],
          if (onPinToggle != null && !RelicTheme.isMobileOf(context)) ...[
            _HeaderBtn(icon: LucideIcons.pin, active: pinned, onTap: onPinToggle!),
            const SizedBox(width: 7),
          ],
          _HeaderBtn(key: settingsKey, icon: LucideIcons.settings, onTap: onSettings),
          // The close (X) only makes sense on desktop, where it dismisses the
          // popup window. On mobile there's nothing to close — hide it.
          if (onClose != null && !RelicTheme.isMobileOf(context)) ...[
            const SizedBox(width: 7),
            _HeaderBtn(icon: LucideIcons.x, onTap: onClose!),
          ],
        ],
      ),
    );
  }
}

class _SyncChip extends StatelessWidget {
  final SyncState sync;
  final bool syncing;
  final VoidCallback? onTap;
  final String? tooltip;
  final double? uploadFraction;
  const _SyncChip({
    required this.sync,
    this.syncing = false,
    this.uploadFraction,
    this.onTap,
    this.tooltip,
  });
  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    Widget chip;
    final up = uploadFraction;
    // An active upload wins the chip: a determinate ring + "Uploading NN%" is
    // the clearest global cue that a large image/file copy is in flight.
    if (up != null) {
      chip = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 11,
            height: 11,
            child: CircularProgressIndicator(
              value: up <= 0 ? null : up,
              strokeWidth: 1.6,
              color: c.accent,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            up <= 0 ? 'Uploading…' : 'Uploading ${(up * 100).round()}%',
            style: RelicTheme.mono(size: 10, color: c.accentMuted),
          ),
        ],
      );
    } else
    // A sync in flight wins: show a live spinner + "Syncing…".
    if (syncing) {
      chip = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 11,
            height: 11,
            child: CircularProgressIndicator(strokeWidth: 1.6, color: c.accent),
          ),
          const SizedBox(width: 6),
          Text('Syncing…', style: RelicTheme.mono(size: 10, color: c.accentMuted)),
        ],
      );
    } else if (sync.kind == SyncKind.synced) {
      // Idle & healthy: a quiet green dot + muted 'Synced' (the de-boxed
      // language — no icon glyph, no color-loud text).
      chip = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: c.success, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text('Synced', style: RelicTheme.mono(size: 10, color: c.textMuted)),
        ],
      );
    } else {
      late final IconData icon;
      late final Color color;
      late final String label;
      switch (sync.kind) {
        case SyncKind.synced:
          icon = LucideIcons.circleCheck;
          color = c.successDim;
          label = 'Synced';
        case SyncKind.pending:
          icon = LucideIcons.refreshCw;
          color = c.warningDim;
          label = '${sync.pending} pending';
        case SyncKind.offline:
          icon = LucideIcons.cloudOff;
          color = c.textMuted;
          label = 'Offline';
        case SyncKind.quotaFull:
          icon = LucideIcons.refreshCw;
          color = c.warningDim;
          label = '${sync.pending} not synced';
      }
      chip = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 5),
          Text(label, style: RelicTheme.mono(size: 10, color: color)),
        ],
      );
    }
    if (tooltip != null) {
      chip = Tooltip(
        message: tooltip!,
        waitDuration: const Duration(milliseconds: 500),
        textStyle: RelicTheme.mono(size: 10, color: c.text),
        decoration: BoxDecoration(
          color: c.panel,
          borderRadius: BorderRadius.circular(Radii.chip),
          border: Border.all(color: c.borderStrong, width: 1),
        ),
        child: chip,
      );
    }
    if (onTap != null) {
      chip = MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(onTap: onTap, child: chip),
      );
    }
    return chip;
  }
}

class _HeaderBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool active; // toggled-on state (e.g. pin) → GhostStyle.active
  final bool filled; // the one filled CTA (compose +) → GhostStyle.filled
  const _HeaderBtn({
    super.key,
    required this.icon,
    required this.onTap,
    this.active = false,
    this.filled = false,
  });
  @override
  Widget build(BuildContext context) {
    final m = RelicTheme.isMobileOf(context);
    // Keep today's exact footprint: 24px square desktop / 36px mobile, with the
    // slightly-larger-than-default glyph the header has always used. Passing the
    // size explicitly per platform sidesteps GhostButton's icon-only mobile
    // clamp (which would land at ~34, not 36).
    return GhostButton(
      icon: icon,
      size: m ? 36 : 24,
      iconSize: m ? 19 : 13,
      radius: Radii.chip,
      style: filled
          ? GhostStyle.filled
          : (active ? GhostStyle.active : GhostStyle.ghost),
      onTap: onTap,
    );
  }
}

/// Search field — mono, leading magnifier (amber while focused/non-empty),
/// trailing Esc hint pill.
class SearchField extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;

  /// Desktop: opens the search-and-shortcuts cheatsheet ("?" button).
  final VoidCallback? onHelp;
  const SearchField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    this.onHelp,
  });

  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    final m = RelicTheme.isMobileOf(context);
    return AnimatedBuilder(
      animation: Listenable.merge([controller, focusNode]),
      builder: (context, _) {
        final empty = controller.text.isEmpty;
        final active = !empty || focusNode.hasFocus;
        return Padding(
          padding: EdgeInsets.fromLTRB(16, m ? 16 : 14, 16, m ? 14 : 12),
          child: Row(
            children: [
              Icon(
                LucideIcons.search,
                size: m ? 20 : 17,
                color: active ? c.accent : c.textFaintest,
              ),
              SizedBox(width: m ? 12 : 11),
              Expanded(
                child: TextField(
                  controller: controller,
                  focusNode: focusNode,
                  onChanged: onChanged,
                  style: RelicTheme.mono(size: m ? 16 : 14, color: c.text),
                  cursorColor: c.accent,
                  cursorWidth: 2,
                  maxLines: 1,
                  decoration: InputDecoration(
                    isCollapsed: true,
                    border: InputBorder.none,
                    hintText: 'Search relics…',
                    hintStyle: RelicTheme.mono(
                      size: m ? 16 : 14,
                      color: c.textFaintest,
                    ),
                  ),
                ),
              ),
              // Phones: a clear button at the far right wipes the whole query
              // in one tap (no Esc key, and holding backspace is a chore).
              if (m && !empty) ...[
                const SizedBox(width: 8),
                GhostButton(
                  icon: LucideIcons.x,
                  size: 26,
                  iconSize: 16,
                  onTap: () {
                    controller.clear();
                    onChanged('');
                  },
                ),
              ],
              // The Esc pill is a desktop affordance; phones use Back instead.
              if (!m) ...[
                if (onHelp != null) ...[
                  const SizedBox(width: 8),
                  Tooltip(
                    message: 'Search operators & shortcuts',
                    waitDuration: const Duration(milliseconds: 500),
                    textStyle: RelicTheme.mono(size: 10, color: c.text),
                    decoration: BoxDecoration(
                      color: c.panel,
                      borderRadius: BorderRadius.circular(Radii.chip),
                      border: Border.all(color: c.borderStrong, width: 1),
                    ),
                    child: GestureDetector(
                      onTap: onHelp,
                      child: MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(Radii.chip),
                            border: Border.all(color: c.borderStrong, width: 1),
                          ),
                          child: Text(
                            '?',
                            style: RelicTheme.mono(
                                size: 10, color: c.textFaintest),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(Radii.chip),
                    border: Border.all(color: c.borderStrong, width: 1),
                  ),
                  child: Text(
                    'Esc',
                    style: RelicTheme.mono(size: 10, color: c.textFaintest),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// All/Vault segmented control — spans the full popup width.
class ScopeBar extends StatelessWidget {
  final Scope scope;
  final ValueChanged<Scope> onChanged;

  /// Slim variant for the desktop control row: the outer border is dropped
  /// (the row already reads as a region) and the segments hug their labels
  /// instead of stretching full width. Non-compact stays pixel-identical to
  /// today (mobile relies on it).
  final bool compact;
  const ScopeBar({
    super.key,
    required this.scope,
    required this.onChanged,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: c.isDark ? c.panel : c.footer,
        borderRadius: BorderRadius.circular(Radii.input),
        border: compact ? null : Border.all(color: c.border, width: 1),
      ),
      child: Row(
        mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
        children: [
          for (final s in Scope.values)
            compact
                ? _seg(c, s, RelicTheme.isMobileOf(context))
                : Expanded(child: _seg(c, s, RelicTheme.isMobileOf(context))),
        ],
      ),
    );
  }

  Widget _seg(RelicColors c, Scope s, bool m) {
    final on = s == scope;
    return GestureDetector(
      onTap: () => onChanged(s),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          padding: compact
              ? const EdgeInsets.symmetric(horizontal: 14, vertical: 6)
              : EdgeInsets.symmetric(vertical: m ? 8 : 6),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: on ? c.selected : const Color(0x00000000),
            borderRadius: BorderRadius.circular(Radii.chip),
          ),
          child: Text(
            switch (s) {
              Scope.all => 'All',
              Scope.vault => 'Vault',
            },
            style: RelicTheme.mono(
              size: m ? 13 : 11,
              weight: FontWeight.w600,
              color: on ? c.textOnSelected : c.textMuted,
              letterSpacing: 0.4,
            ),
          ),
        ),
      ),
    );
  }
}
