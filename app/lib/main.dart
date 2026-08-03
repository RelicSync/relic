import 'dart:async';
import 'dart:io' show Directory, File, Platform;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'data/api.dart';
import 'data/boot_trace.dart';
import 'data/crash_log.dart';
import 'data/local_desk_repo.dart';
import 'data/repo.dart';
import 'data/worker_repo.dart';
import 'desktop.dart';
import 'mobile.dart';
import 'models/relic.dart';
import 'theme/relic_theme.dart';
import 'theme/tokens.dart';
import 'ui/connect.dart';
import 'ui/dialogs.dart';
import 'ui/onboarding.dart';
import 'ui/popup.dart';
import 'ui/settings.dart';
import 'ui/share_dialog.dart';
import 'ui/toast.dart';
import 'widgets/controls.dart';
import 'widgets/relic_mark.dart';

/// `relic_app` → the real tray-resident product.
/// `relic_app --gallery` → the design storybook (every surface).
/// Gallery extras for scripted review screenshots:
/// `--surface=<Surface.name>` opens on that surface, `--light` starts light.
void main(List<String> args) {
  BootTrace.begin(); // first statement: everything after this is measured
  initCrashLogging();
  BootTrace.mark('crash logging');
  runZonedGuarded(() {
    if (args.contains('--gallery')) {
      final sArg = args
          .firstWhere((a) => a.startsWith('--surface='), orElse: () => '')
          .replaceFirst('--surface=', '');
      runApp(GalleryApp(
        initialSurface: Surface.values
            .where((v) => v.name == sArg)
            .firstOrNull ??
            Surface.popup,
        initialDark: !args.contains('--light'),
      ));
    } else if (Platform.isAndroid || Platform.isIOS) {
      runMobileApp(); // the phone "lens": browse + search, no tray/hotkeys
    } else {
      runRealApp(args); // args may carry a relic:// deep link (Windows cold start)
    }
  }, (error, stack) => appendCrash(error, stack));
}

enum Surface {
  popup('History popup'),
  setupNew('Setup · new account'),
  setupExisting('Setup · existing'),
  setupChecking('Setup · checking'),
  setupError('Setup · offline'),
  recovery('Recovery kit'),
  lock('Lock'),
  lockError('Lock · wrong pass'),
  settings('Settings'),
  dialogConfirm('Dialog · confirm'),
  dialogEdit('Dialog · item'),
  dialogEditImage('Dialog · item image'),
  share('Dialog · share'),
  toasts('Toasts'),
  components('Components'),
  connect('Connect (live data)');

  final String label;
  const Surface(this.label);
}

class GalleryApp extends StatefulWidget {
  final Surface initialSurface;
  final bool initialDark;
  const GalleryApp({
    super.key,
    this.initialSurface = Surface.popup,
    this.initialDark = true,
  });
  @override
  State<GalleryApp> createState() => _GalleryAppState();
}

class _GalleryAppState extends State<GalleryApp> {
  late bool _dark = widget.initialDark;
  late Surface _surface = widget.initialSurface;
  final _repo = _GalleryRepo();
  late final Future<void> _loaded = _repo.load();
  // Design-board preview only: Settings needs a LocalDeskRepo for its sync pane.
  final _designRepo = LocalDeskRepo();
  WorkerRepo? _liveRepo;
  // One toast of each severity, pre-enqueued so the Toasts surface renders the
  // real ToastStack (not a hand-drawn mock). Long duration so they stay up for
  // the screenshot.
  late final ToastQueue _toasts = ToastQueue()
    ..show(ToastMsg('Saved to Vault',
        severity: ToastSeverity.success,
        icon: LucideIcons.star,
        duration: const Duration(days: 1)))
    ..show(ToastMsg('Copied to clipboard',
        severity: ToastSeverity.accent,
        icon: LucideIcons.copy,
        duration: const Duration(days: 1)))
    ..show(ToastMsg('Relic deleted',
        severity: ToastSeverity.neutral,
        icon: LucideIcons.trash2,
        action: 'Undo',
        onAction: () {},
        duration: const Duration(days: 1)))
    ..show(ToastMsg('Sync paused, offline',
        severity: ToastSeverity.warning,
        icon: LucideIcons.triangleAlert,
        duration: const Duration(days: 1)))
    ..show(ToastMsg("Couldn't reach the server",
        severity: ToastSeverity.danger,
        icon: LucideIcons.circleX,
        duration: const Duration(days: 1)));

  /// A seeded text relic for the view / share surfaces (from MemoryRepo's
  /// fixtures — relic '4', a titled command with tags). Null until [_loaded].
  Relic? get _sampleRelic {
    for (final r in _repo.all) {
      if (r.uid == '4') return r;
    }
    return _repo.all.isEmpty ? null : _repo.all.first;
  }

  /// A seeded photo relic for the image-body surface (MemoryRepo fixture '3', a
  /// screenshot). Falls back to the first photo, then any relic. Null until
  /// [_loaded].
  Relic? get _samplePhoto {
    for (final r in _repo.all) {
      if (r.uid == '3') return r;
    }
    for (final r in _repo.all) {
      if (r.kind == Kind.photo) return r;
    }
    return _repo.all.isEmpty ? null : _repo.all.first;
  }

  @override
  Widget build(BuildContext context) {
    final colors = _dark ? RelicColors.dark : RelicColors.light;
    final backdrop = colors.backdrop;

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Relic',
      home: RelicTheme(
        colors: colors,
        child: Scaffold(
          backgroundColor: backdrop,
          body: Row(children: [
            _Rail(
              dark: _dark,
              surface: _surface,
              onSurface: (s) => setState(() => _surface = s),
              onToggleTheme: () => setState(() => _dark = !_dark),
            ),
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(40),
                  child: _surfaceWidget(),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _surfaceWidget() {
    switch (_surface) {
      case Surface.popup:
        return SizedBox(
          width: 460,
          height: 560,
          child: _liveRepo != null
              ? PopupView(repo: _liveRepo!, onClose: () {}, onSettings: () => setState(() => _surface = Surface.settings))
              : FutureBuilder(
                  future: _loaded,
                  builder: (context, snap) => snap.connectionState == ConnectionState.done
                      ? PopupView(repo: _repo, onClose: () {}, onSettings: () => setState(() => _surface = Surface.settings))
                      : const SizedBox.shrink(),
                ),
        );
      case Surface.setupNew:
        return const SetupView(kind: SetupKind.newAccount);
      case Surface.setupExisting:
        return const SetupView(kind: SetupKind.existing);
      case Surface.setupChecking:
        return const SetupView(kind: SetupKind.checking);
      case Surface.setupError:
        return const SetupView(kind: SetupKind.error);
      case Surface.recovery:
        return const RecoveryKitView();
      case Surface.lock:
        return const LockView();
      case Surface.lockError:
        return const LockView(error: true);
      case Surface.settings:
        return SettingsView(
            repo: _designRepo, onClose: () => setState(() => _surface = Surface.popup));
      case Surface.dialogConfirm:
        return ConfirmDialog(
          title: 'Delete relic?',
          message:
              'This removes it from every device. If sync is on, it cannot be undone.',
          confirmLabel: 'Delete',
          danger: true,
          onConfirm: () {},
          onCancel: () {},
        );
      case Surface.dialogEdit:
        return _seeded((r) => EditDialog(
              relic: r,
              repo: _repo,
              onCancel: () {},
              onCopy: () {},
              onDelete: () {},
              onShare: () {},
              onSave: (t, n, u, m, c2, a, rm) async {},
            ));
      case Surface.dialogEditImage:
        // The image body wants a Kind.photo relic; MemoryRepo's fixtures carry
        // one at uid '3'. _seededPhoto also serves a real decodable image path
        // for it (see _GalleryPhotoRepo) so the inline preview renders.
        return _seededPhoto((r) => EditDialog(
              relic: r,
              repo: _repo,
              onCancel: () {},
              onCopy: () {},
              onDelete: () {},
              onShare: () {},
              onSave: (t, n, u, m, c2, a, rm) async {},
            ));
      case Surface.share:
        return _seeded((r) => ShareDialog(
              relic: r,
              repo: _repo,
              onClose: () {},
            ));
      case Surface.toasts:
        // The real ToastStack, driven by a pre-enqueued ToastQueue — one toast
        // of every severity.
        return SizedBox(width: 380, child: ToastStack(queue: _toasts));
      case Surface.components:
        return const _ComponentsBoard();
      case Surface.connect:
        return ConnectView(
          defaultUrl: kWorkerBaseUrl,
          onConnect: (url, token, pass) async {
            try {
              final repo = WorkerRepo(baseUrl: url, token: token, passphrase: pass);
              await repo.load();
              setState(() {
                _liveRepo = repo;
                _surface = Surface.popup;
              });
              return null;
            } catch (e) {
              return e.toString();
            }
          },
        );
    }
  }

  /// Build a dialog over the seeded [MemoryRepo], waiting on [_loaded] so the
  /// sample relic exists before the dialog reads it.
  Widget _seeded(Widget Function(Relic relic) build) => FutureBuilder(
        future: _loaded,
        builder: (context, snap) {
          final r = _sampleRelic;
          if (snap.connectionState != ConnectionState.done || r == null) {
            return const SizedBox.shrink();
          }
          return build(r);
        },
      );

  /// Like [_seeded] but feeds the photo fixture. The preview PNG is written
  /// synchronously first: the screenshot harness runs under fake async, where
  /// a real-IO future never completes and the surface would render blank.
  Widget _seededPhoto(Widget Function(Relic relic) build) {
    _repo.warmGalleryImage();
    return FutureBuilder(
      future: _loaded,
      builder: (context, snap) {
        final r = _samplePhoto;
        if (snap.connectionState != ConnectionState.done || r == null) {
          return const SizedBox.shrink();
        }
        return build(r);
      },
    );
  }
}

/// Gallery-only [MemoryRepo] that hands back a real, decodable image for its
/// photo fixtures so the screenshot surfaces render a picture instead of the
/// placeholder. A tiny PNG is generated from const bytes and written to a temp
/// file once; [localImagePath] returns it for any photo relic.
class _GalleryRepo extends MemoryRepo {
  String? _imagePath;

  /// Generate (once) the preview PNG and cache its path. Synchronous IO on
  /// purpose (see _seededPhoto) and best-effort: on any failure the surface
  /// simply falls back to the placeholder.
  void warmGalleryImage() {
    if (_imagePath != null) return;
    try {
      final dir = Directory.systemTemp.createTempSync('relic_gallery_');
      final f = File('${dir.path}/preview.png');
      f.writeAsBytesSync(_kGalleryPngBytes);
      _imagePath = f.path;
    } catch (_) {
      _imagePath = null;
    }
  }

  @override
  String? localImagePath(Relic r) =>
      r.kind == Kind.photo ? _imagePath : super.localImagePath(r);
}

/// A minimal valid 8x8 PNG (a muted solid fill), embedded as const bytes so the
/// gallery never has to reach the network or bundle an asset. Generated with a
/// correct zlib stream + CRCs (tools/gen scratch), so it decodes for real.
const List<int> _kGalleryPngBytes = [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // signature
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR length + type
  0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x08, // 8 x 8
  0x08, 0x02, 0x00, 0x00, 0x00, 0x4B, 0x6D, 0x29, 0xDC, // depth 8, RGB + CRC
  0x00, 0x00, 0x00, 0x11, 0x49, 0x44, 0x41, 0x54, // IDAT length + type
  0x78, 0xDA, 0x63, 0xD0, 0xF3, 0x8F, 0xC2, 0x8A,
  0x18, 0x86, 0x96, 0x04, 0x00, 0xF5, 0xF4, 0x35,
  0xC1, 0x01, 0x3B, 0x62, 0xFF, // IDAT data + CRC
  0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, // IEND
  0xAE, 0x42, 0x60, 0x82,
];

class _Rail extends StatelessWidget {
  final bool dark;
  final Surface surface;
  final ValueChanged<Surface> onSurface;
  final VoidCallback onToggleTheme;
  const _Rail({
    required this.dark,
    required this.surface,
    required this.onSurface,
    required this.onToggleTheme,
  });

  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    return Container(
      width: 230,
      decoration: BoxDecoration(
        color: c.footer,
        border: Border(right: BorderSide(color: c.border)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 22, 18, 18),
          child: Row(children: [
            Container(
              width: 30,
              height: 30,
              // Brand tile: deliberately dark in both themes so the gem reads.
              decoration: BoxDecoration(color: const Color(0xFF16130E), borderRadius: BorderRadius.circular(8)),
              alignment: Alignment.center,
              child: const RelicIcon(size: 22),
            ),
            const SizedBox(width: 10),
            Text('RELIC',
                style: RelicTheme.mono(size: 16, weight: FontWeight.w700, color: c.text, letterSpacing: 1.4)),
          ]),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            children: [
              for (final s in Surface.values)
                _RailItem(label: s.label, selected: s == surface, onTap: () => onSurface(s)),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: GestureDetector(
            onTap: onToggleTheme,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: c.surface,
                  borderRadius: BorderRadius.circular(Radii.input),
                  border: Border.all(color: c.border),
                ),
                child: Row(children: [
                  Icon(dark ? LucideIcons.moon : LucideIcons.sun, size: 15, color: c.accent),
                  const SizedBox(width: 9),
                  Text(dark ? 'Dark theme' : 'Light theme',
                      style: RelicTheme.sans(size: 12.5, color: c.textSecondary)),
                ]),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

class _RailItem extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _RailItem({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          margin: const EdgeInsets.only(bottom: 2),
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
          decoration: BoxDecoration(
            color: selected ? c.selected : const Color(0x00000000),
            borderRadius: BorderRadius.circular(7),
          ),
          child: Text(label,
              style: RelicTheme.sans(
                  size: 13,
                  weight: selected ? FontWeight.w500 : FontWeight.w400,
                  color: selected ? c.accent : c.textSecondary)),
        ),
      ),
    );
  }
}

/// Gallery-only reference board for the shared control set + the new tokens.
/// This is the surface screenshotted for design review, so it shows every
/// GhostStyle, both button variants, the enabled/disabled primary, and a row
/// of the new color tokens as labeled swatches. All idle (no live callbacks).
class _ComponentsBoard extends StatelessWidget {
  const _ComponentsBoard();

  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    return SizedBox(
      width: 560,
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: c.panel,
          borderRadius: BorderRadius.circular(Radii.card),
          border: Border.all(color: c.border, width: 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _sectionLabel(c, 'GHOST BUTTON · STYLES'),
            Wrap(spacing: 10, runSpacing: 10, children: [
              GhostButton(icon: LucideIcons.copy, label: 'Ghost', onTap: () {}),
              GhostButton(
                  icon: LucideIcons.check,
                  label: 'Filled',
                  style: GhostStyle.filled,
                  onTap: () {}),
              GhostButton(
                  icon: LucideIcons.trash2,
                  label: 'Danger',
                  style: GhostStyle.danger,
                  onTap: () {}),
              GhostButton(
                  icon: LucideIcons.trash2,
                  label: 'Danger tint',
                  style: GhostStyle.dangerTint,
                  onTap: () {}),
              GhostButton(
                  icon: LucideIcons.pin,
                  label: 'Active',
                  style: GhostStyle.active,
                  onTap: () {}),
            ]),
            const SizedBox(height: 22),
            _sectionLabel(c, 'GHOST BUTTON · ICON-ONLY'),
            Wrap(spacing: 10, runSpacing: 10, children: [
              GhostButton(icon: LucideIcons.copy, onTap: () {}),
              GhostButton(
                  icon: LucideIcons.check,
                  style: GhostStyle.filled,
                  onTap: () {}),
              GhostButton(
                  icon: LucideIcons.trash2,
                  style: GhostStyle.danger,
                  onTap: () {}),
              GhostButton(
                  icon: LucideIcons.trash2,
                  style: GhostStyle.dangerTint,
                  onTap: () {}),
              GhostButton(
                  icon: LucideIcons.pin,
                  style: GhostStyle.active,
                  onTap: () {}),
              GhostIconButton(icon: LucideIcons.x, onTap: () {}),
            ]),
            const SizedBox(height: 22),
            _sectionLabel(c, 'PRIMARY BUTTON'),
            Wrap(spacing: 10, runSpacing: 10, children: [
              PrimaryButton(
                  icon: LucideIcons.check, label: 'Enabled', onTap: () {}),
              const PrimaryButton(
                  icon: LucideIcons.check, label: 'Disabled', onTap: null),
            ]),
            const SizedBox(height: 22),
            _sectionLabel(c, 'NEW TOKENS'),
            Wrap(spacing: 12, runSpacing: 12, children: [
              _swatch(c, 'ghostHover', c.ghostHover),
              _swatch(c, 'selectedCard', c.selectedCard),
              _swatch(c, 'surfaceRaised', c.surfaceRaised),
              _swatch(c, 'track', c.track),
              _swatch(c, 'inset', c.inset),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _sectionLabel(RelicColors c, String t) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(t,
            style:
                RelicTheme.mono(size: 10, color: c.textMuted, letterSpacing: 0.8)),
      );

  Widget _swatch(RelicColors c, String name, Color color) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 84,
            height: 44,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(Radii.input),
              border: Border.all(color: c.border, width: 1),
            ),
          ),
          const SizedBox(height: 5),
          Text(name, style: RelicTheme.mono(size: 9, color: c.textMuted)),
        ],
      );
}

