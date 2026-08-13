import 'dart:async';
import 'dart:io';

import 'package:clipboard_watcher/clipboard_watcher.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:super_clipboard/super_clipboard.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

import 'app_globals.dart';
import 'platform/app_activation.dart';
import 'platform/app_install.dart';
import 'platform/clipboard_bridge.dart';
import 'platform/foreground_app.dart';
import 'platform/gem_toast.dart';
import 'platform/input_injector.dart';
import 'platform/sound.dart';
import 'data/api.dart';
import 'data/desktop_links.dart';
import 'data/device_directory.dart';
import 'data/hotkeys.dart';
import 'data/local_desk_repo.dart';
import 'data/recovery.dart';
import 'data/self_update.dart';
import 'data/supabase_auth.dart';
import 'data/update_check.dart';
import 'models/relic.dart';
import 'onboarding/add_device.dart';
import 'onboarding/install_offer.dart';
import 'services/onboarding_service.dart';
import 'theme/relic_theme.dart';
import 'theme/tokens.dart';
import 'onboarding/desktop_onboarding.dart';
import 'ui/popup.dart';
import 'ui/settings.dart';
import 'platform/popup_placement.dart';
import 'widgets/result_row.dart' show MiniResultRow;

/// Your deployed Worker, pre-filled into the connect form. The device token is
/// intentionally NOT committed (it's a credential) — paste it into the connect
/// field, or set it here locally for a one-field connect.
const _workerUrl = kWorkerBaseUrl;

/// The real product: tray-resident, clipboard-capturing, hotkey-summoned.
///
/// [args] is the process command line: on Windows a `relic://` deep link (from
/// the URL-scheme handler) arrives here, so we surface the window on launch
/// instead of settling silently into the tray.
Future<void> runRealApp(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // file_picker's desktop backends are FFI dart-plugins that Flutter's tooling
  // fails to auto-register on Windows/Linux (so FilePicker.platform would throw
  // LateInitializationError). Set the platform by hand. (The analyzer resolves
  // the conditional export to a stub, but the Windows/Linux build uses the real
  // FFI class — both expose the constructor used here.)
  if (Platform.isWindows) {
    FilePicker.platform = FilePickerWindows();
  } else if (Platform.isLinux) {
    FilePicker.platform = FilePickerLinux();
  }
  await windowManager.ensureInitialized();
  await localNotifier.setup(appName: 'Relic'); // native tray notifications
  await hotKeyManager.unregisterAll();

  const options = WindowOptions(
    size: Size(460, 560),
    center: true,
    skipTaskbar: true,
    // Opaque background: a transparent window forces Flutter's Windows
    // layered-window present path, which never clears the prior frame —
    // causing ghost/double text and frozen animations (flutter/flutter#71735).
    backgroundColor: Color(0xFF16130E), // RelicColors.dark.base
    titleBarStyle: TitleBarStyle.hidden,
    alwaysOnTop: true,
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.setAsFrameless();
    await windowManager.hide(); // start in the tray, summon with the hotkey
  });

  final repo = LocalDeskRepo();
  await repo.load();
  await repo
      .tryAutoConnect(); // silently resume cross-device sync if configured
  // Windows delivers a relic:// launch link as an argv entry; macOS delivers it
  // through app_links once the app is up (DesktopLinks.init, below).
  final launchLink = DesktopLinks.launchLinkFromArgs(args);
  // The run-at-login entry passes --autostart (input_win.dart): settle straight
  // into the tray, never surface a window or the first-run onboarding.
  final autostart = args.contains('--autostart');
  runApp(RealApp(
      repo: repo, showOnLaunch: launchLink != null, autostart: autostart));
  // macOS: begin listening for the launch URL event + any later links.
  unawaited(DesktopLinks.init());
}

class RealApp extends StatefulWidget {
  final LocalDeskRepo repo;
  /// True when the process was started by a `relic://` deep link, so the popup
  /// should surface on launch rather than starting hidden in the tray.
  final bool showOnLaunch;
  /// True when launched by the run-at-login entry (--autostart): stay hidden in
  /// the tray, skipping even the first-run onboarding, so login never surfaces
  /// a window that grabs focus.
  final bool autostart;
  const RealApp({
    super.key,
    required this.repo,
    this.showOnLaunch = false,
    this.autostart = false,
  });
  @override
  State<RealApp> createState() => _RealAppState();
}

class _RealAppState extends State<RealApp>
    with
        WidgetsBindingObserver,
        WindowListener,
        TrayListener,
        ClipboardListener {
  bool _paused = false;
  /// Timed pause: auto-resume timer + the moment capture comes back (null =
  /// paused until resumed / not paused). The notifier drives the popup's
  /// "Capture paused" pill live.
  Timer? _pauseTimer;
  DateTime? _pausedUntil;
  final ValueNotifier<bool> _pausedSignal = ValueNotifier(false);
  bool _visible = false;
  bool _connecting = false;
  bool _onboardStartAtSignIn = false; // onboarding step: false = main welcome page
  bool _settingsOpen = false;
  /// Non-null when this copy of Relic is running from the disk image (or the
  /// shadow copy macOS makes of one) and should offer to install itself into
  /// /Applications before anything else. Read once at startup: the answer
  /// cannot change while the process lives.
  final BundleLocation? _installOffer = applicationsInstallOfferForThisProcess();
  final _navKey = GlobalKey<NavigatorState>(); // Esc pops drill-down routes
  bool _showingKit = false; // recovery-kit screen up: don't let blur hide it
  bool _emailBannerDismissed = false; // verify-to-sync banner, session-only
  DateTime? _shownAt; // when the popup was last summoned (guards blur-to-close)

  // Mini picker geometry. Captured once per summon so the window can re-hug the
  // result count without the anchor drifting as the cursor moves.
  static const double _kMiniWidth = 340;
  static const double _kMiniGap = 8; // offset from the caret/cursor
  static const double _kMiniSearchH = 46; // SearchField row (approx)
  static const double _kMiniListPad = 8; // ListView vertical padding (4 + 4)
  Offset? _miniAnchor; // logical-screen caret/cursor point at summon
  Offset? _miniOrigin; // work-area origin of the anchor's monitor
  Size? _miniArea; // work-area size of the anchor's monitor
  bool _miniDown = true; // opened downward (top-anchored) vs upward
  Timer? _miniResizeTimer; // debounces the live re-hug on result changes
  // Whether the CURRENT summon is mini. Set per-summon (which hotkey fired, or
  // the default for tray/launch), read by the popup renderer + window sizing.
  final ValueNotifier<bool> _miniMode = ValueNotifier(false);

  /// Background update-check cadence + once-per-version notification gate +
  /// reentrancy guard for the one-click self-update.
  Timer? _updateCheckTimer;
  final _notifiedUpdates = <String>{};
  bool _selfUpdating = false;

  /// Last check's outcome, mirrored into the tray menu: the update that is
  /// waiting (if any) and a one-line note. Both survive a dismissed or
  /// suppressed notification.
  UpdateInfo? _pendingUpdate;
  String _lastUpdateNote = '';
  DateTime? _lastTooLargeNotice; // 1/hour throttle for the size-cap toast

  /// Ticked on every EXPLICIT close (Esc / X / tray click) → PopupView clears
  /// its search state, so the next summon starts fresh on All.
  final _popupResetTick = ValueNotifier<int>(0);

  /// Ticked on every summon → PopupView re-focuses the search box, so typing
  /// filters immediately no matter where focus ended up last time.
  final _popupSummonTick = ValueNotifier<int>(0);

  /// Resolve the active theme from the user's preference, following the OS when
  /// set to "system".
  bool get _useDark {
    switch (widget.repo.appearance) {
      case Appearance.dark:
        return true;
      case Appearance.light:
        return false;
      case Appearance.system:
        return WidgetsBinding.instance.platformDispatcher.platformBrightness ==
            Brightness.dark;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    windowManager.addListener(this);
    trayManager.addListener(this);
    clipboardWatcher.addListener(this);
    // settings changes take effect live without the repo touching these layers
    widget.repo.onHotkeysChanged = () => _initHotkeys();
    widget.repo.onTrayVisibilityChanged = () => _applyTrayVisibility();
    widget.repo.onAppearanceChanged = () {
      if (mounted) setState(() {});
    };
    // Mini picker: re-hug the window to the result count as the user types.
    widget.repo.addListener(_onRepoTick);
    // Size-cap drops are the one capture skip worth hearing about (privacy /
    // blocklist skips stay silent by design). Throttled to once per hour.
    widget.repo.onCaptureTooLarge = (limitMb) {
      final now = DateTime.now();
      final last = _lastTooLargeNotice;
      if (last != null && now.difference(last) < const Duration(hours: 1)) {
        return;
      }
      _lastTooLargeNotice = now;
      _notify(
        'Too large to capture',
        'The limit is $limitMb MB. You can raise it in Settings.',
      );
    };
    // Clip reminders: the repo sweep hands us the due rows (already marked
    // fired). Coalesce a backlog into one toast; otherwise one rich toast per
    // reminder whose click copies the item and surfaces the window.
    widget.repo.onRemindersDue = (due) {
      if (due.isEmpty) return;
      if (due.length > 3) {
        final n = LocalNotification(
          title: 'Relic reminders',
          body: 'You have ${due.length} reminders due.',
        );
        n.onClick = () => _show(Summon.notification);
        try {
          n.show();
        } catch (_) {}
        return;
      }
      for (final rem in due) {
        final r = widget.repo.relicByUid(rem.relicUid);
        if (r == null) continue; // the item was deleted; skip quietly
        final note = rem.note?.trim();
        final n = LocalNotification(
          title: (note != null && note.isNotEmpty) ? note : 'Reminder',
          body: r.displayTitle,
        );
        n.onClick = () async {
          await widget.repo.putOnClipboard(r);
          await _show(Summon.notification);
        };
        try {
          n.show();
        } catch (_) {}
      }
    };
    _applyTrayVisibility();
    _initHotkeys();
    clipboardWatcher.start();
    _scheduleUpdateChecks();
    // A relic:// link (cold or warm) surfaces the window, like a hotkey summon.
    DesktopLinks.onLink = _handleDeepLink;
    // First launch (empty, unconnected vault): the onboarding will welcome the
    // user; otherwise the app settles into the tray. Decided here because the
    // Accessibility prompt below keys off it too.
    final firstRun = !widget.repo.syncEnabled && widget.repo.isEmpty;
    // macOS: synthetic ⌘C/⌘V (paste-on-select, selection capture) needs the
    // Accessibility grant. Surface the one-time system prompt at startup; if
    // declined, those paths silently degrade to clipboard-only and Settings →
    // System Settings can re-grant later. No-op on Windows.
    //
    // NOT on first run or from a doomed DMG/translocated copy: onboarding's
    // Accessibility step exists to explain the ask before prompting, and this
    // raw dialog was racing it onto a brand-new user's screen (TCC shows the
    // system prompt only once, so firing it here spends the one explained
    // moment on an unexplained popup). Existing installs keep the probe.
    if (Platform.isMacOS && !firstRun && _installOffer == null) {
      unawaited(inputInjectionAvailable(prompt: true));
    }
    // A relic:// launch link surfaces the popup. Otherwise stay hidden in the
    // tray as usual.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // Running out of the disk image: ask about installing before anything
      // else. This one comes ahead of even the autostart shortcut, because a
      // login item can only be pointing at a copy that is about to vanish.
      if (_installOffer != null) {
        await _sizeWindow(460, 420);
        await _present(foreground: true);
        _visible = true;
        return;
      }
      // Launched at login: settle straight into the tray. Never surface a
      // window (not even first-run onboarding) — the user didn't ask for it.
      if (widget.autostart) {
        _visible = false;
        await _dismiss();
        return;
      }
      if (firstRun) {
        setState(() => _connecting = true);
        await _sizeWindow(520, 560);
        await windowManager.center();
        // Onboarding is a whole UI to work in, so it comes forward for real.
        await _present(foreground: true);
        _visible = true;
      } else if (widget.showOnLaunch) {
        await _show(Summon.launch);
      } else {
        _visible = false;
        await _dismiss();
      }
    });
  }

  @override
  void didChangePlatformBrightness() {
    if (widget.repo.appearance == Appearance.system && mounted) setState(() {});
  }

  /// A `relic://` deep link arrived (macOS warm start via app_links, or the
  /// buffered Windows/macOS launch link). Any link just surfaces the app; the
  /// capture/auth hosts are mobile-only, so there is nothing else to route here.
  void _handleDeepLink(Uri uri) {
    if (!mounted) return;
    unawaited(_show(Summon.deepLink));
  }

  @override
  void dispose() {
    DesktopLinks.onLink = null;
    WidgetsBinding.instance.removeObserver(this);
    widget.repo.onHotkeysChanged = null;
    widget.repo.onTrayVisibilityChanged = null;
    widget.repo.onAppearanceChanged = null;
    widget.repo.onCaptureTooLarge = null;
    widget.repo.onRemindersDue = null;
    widget.repo.removeListener(_onRepoTick);
    windowManager.removeListener(this);
    trayManager.removeListener(this);
    clipboardWatcher.removeListener(this);
    clipboardWatcher.stop();
    _updateCheckTimer?.cancel();
    _miniResizeTimer?.cancel();
    _pauseTimer?.cancel();
    _pausedSignal.dispose();
    _popupResetTick.dispose();
    _popupSummonTick.dispose();
    _miniMode.dispose();
    super.dispose();
  }

  Future<void> _initTray() async {
    try {
      // .ico is Windows-only; the menu-bar item on macOS wants a template PNG
      // (monochrome + alpha) so it adapts to light/dark menu bars.
      await trayManager.setIcon(
        Platform.isWindows
            ? 'assets/tray_icon.ico'
            : 'assets/tray_icon_template.png',
        isTemplate: true, // ignored off-macOS
      );
    } catch (_) {}
    await trayManager.setToolTip('Relic: capturing');
    await _rebuildMenu();
  }

  /// Show or hide the tray icon per the user's setting. When hidden, the global
  /// hotkey remains the way back into the app.
  Future<void> _applyTrayVisibility() async {
    if (widget.repo.showTrayIcon) {
      await _initTray();
    } else {
      try {
        await trayManager.destroy();
      } catch (_) {}
    }
  }

  /// After a desktop connect: show the recovery kit once on a fresh create, and
  /// register this device in the account's device list (best-effort).
  Future<void> _afterDesktopConnect() async {
    final repo = widget.repo;
    // An account switch just held the previous account's items back: they are
    // hidden from the history and stay on this machine until the user decides
    // in Settings. Say so out loud once — the popup banner carries it from
    // here, but without this the history just looks like it lost items.
    if (repo.mergeOfferCount > 0) {
      LocalNotification(
        title: 'Your previous items are tucked away',
        body:
            '${repo.mergeOfferCount} items from your last account are hidden '
            'on this device, not uploaded here. Choose what to do in Settings.',
      ).show();
    }
    if (repo.vaultJustCreated && repo.masterKey != null) {
      repo.vaultJustCreated = false;
      final kit = RecoveryKit.fromMk(repo.masterKey!, repo.accountEmail ?? '');
      // The recovery kit is the only way back into the data — make sure it's
      // visible, roomy, and can't be hidden by a stray blur while it's up.
      if (mounted) setState(() => _showingKit = true);
      await _sizeWindow(520, 620);
      // The one screen the user must actually read and save: app mode.
      await _present(foreground: true);
      _visible = true;
      if (mounted) {
        await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => RecoveryKitScreen(kitText: kit)));
      }
      if (mounted) setState(() => _showingKit = false);
      await _sizeWindow(_popupDims.width, _popupDims.height);
    }
    try {
      final id = await DeviceId.get();
      final dir =
          OnboardingService(deviceId: id).devicesWith(() async => repo.syncBearer);
      try {
        await dir.register(
            label: Platform.localHostname, platform: DeviceId.platform());
      } on DeviceCapException catch (e) {
        if (mounted) {
          await showDeviceCapDialog(context,
              directory: dir,
              devices: e.devices,
              label: Platform.localHostname,
              platform: DeviceId.platform(),
              onUpgrade: _upgradeToPro);
        }
      }
    } catch (_) {/* offline: non-fatal */}
  }

  Future<void> _rebuildMenu() async {
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(key: 'show', label: 'Open history'),
          // Timed pause: forgetting a pause used to silently eat copies for
          // days; the timed options resume by themselves and the popup shows
          // a pill while paused either way.
          if (_paused)
            MenuItem(key: 'resume', label: 'Resume capture')
          else
            MenuItem.submenu(
              label: 'Pause capture',
              submenu: Menu(items: [
                MenuItem(key: 'pause_10', label: 'For 10 minutes'),
                MenuItem(key: 'pause_60', label: 'For 1 hour'),
                MenuItem(key: 'pause_inf', label: 'Until I resume it'),
              ]),
            ),
          MenuItem(
            key: 'connect',
            label: widget.repo.syncEnabled
                ? 'Sync: connected'
                : 'Connect to sync…',
          ),
          // The tray menu is the one surface that cannot be swallowed by
          // Focus Assist or a per-app notification block, so the last check's
          // result lives here too — a missed toast used to mean an available
          // update was simply never mentioned again.
          if (_pendingUpdate case final u?)
            MenuItem(key: 'install_update', label: 'Install update ${u.version}')
          else
            MenuItem(key: 'check_update', label: 'Check for updates…'),
          if (_lastUpdateNote.isNotEmpty)
            MenuItem(key: 'update_note', label: _lastUpdateNote, disabled: true),
          MenuItem.separator(),
          MenuItem(key: 'quit', label: 'Quit Relic'),
        ],
      ),
    );
  }

  /// Single owner of the pause state: tray submenu, popup pill, tooltip, and
  /// the auto-resume timer all funnel through here.
  Future<void> _setPaused(bool on, {Duration? duration}) async {
    _pauseTimer?.cancel();
    _pauseTimer = null;
    _paused = on;
    _pausedUntil = null;
    if (on && duration != null) {
      _pausedUntil = DateTime.now().add(duration);
      _pauseTimer = Timer(duration, () => _setPaused(false));
    }
    _pausedSignal.value = on;
    try {
      await trayManager.setToolTip(
        _paused ? 'Relic: paused' : 'Relic: capturing',
      );
    } catch (_) {}
    await _rebuildMenu();
    if (mounted) setState(() {});
  }

  /// (Re)register the three global hotkeys from the user's current bindings.
  /// Called at startup and whenever a binding changes in Settings. Failures
  /// (another app owns the chord) surface in Settings instead of vanishing
  /// into a debug log.
  Future<void> _initHotkeys() async {
    await hotKeyManager.unregisterAll();
    final failed = <String>{};
    Future<void> reg(String key, HotkeyBinding b, HotKeyHandler h) async {
      try {
        await hotKeyManager.register(b.toHotKey(), keyDownHandler: h);
      } catch (e) {
        failed.add(key);
        debugPrint('hotkey register failed for ${b.display}: $e');
      }
    }

    // The two picker hotkeys open the two pickers, always, whatever the "mini
    // picker by default" setting says. That setting used to steer the history
    // hotkey as well, which meant that with it on (the default) both hotkeys
    // opened mini and the full popup was unreachable from the keyboard. See
    // miniForSummon.
    await reg('history', widget.repo.historyHotkey, (_) => _toggle(Summon.historyHotkey));
    await reg('mini', widget.repo.miniHotkey, (_) => _toggle(Summon.miniHotkey));
    await reg('capture', widget.repo.captureHotkey, (_) => _saveAndAnnotate());
    await reg('promote', widget.repo.promoteHotkey, (_) {
      if (widget.repo.promoteLast()) {
        _vaultFeedback('Promoted to Vault', sound: true);
      }
    });
    final quick = widget.repo.quickPasteHotkeys;
    for (var i = 0; i < quick.length; i++) {
      final n = i + 1; // slot 0 → paste #1 (newest)
      await reg('quickPaste$n', quick[i], (_) => _quickPaste(n));
    }
    widget.repo.setFailedHotkeys(failed);
  }

  /// Native OS notification — works whether the app is open, hidden, or in the
  /// tray (unlike an in-app overlay, which needs the window). Fire-and-forget.
  void _notifySaved(String title) {
    try {
      LocalNotification(
        title: title,
        body: 'Relic saved it to your Vault.',
      ).show();
    } catch (_) {}
  }

  void _vaultFeedback(String title, {bool sound = false}) {
    if (sound && widget.repo.promotionSound) unawaited(playPromotionSound());
    if (!widget.repo.vaultAnimation) return;
    showNativeGemToast().then((shown) {
      if (!shown) _notifySaved(title);
    });
  }

  /// Guards against WM_HOTKEY auto-repeat while the chord is held — the paste
  /// handler is long-running (may fetch+decrypt a blob, then a modifier wait).
  bool _pasteInFlight = false;

  /// One "we can't paste for you" notice per run — see [_canSynthesizePaste].
  bool _pasteGrantHintShown = false;

  /// Whether we may synthesize the paste keystroke right now. Always true on
  /// Windows; on macOS it is the Accessibility grant, which the user can revoke
  /// (or never give) at any time.
  ///
  /// Every paste path puts the item on the clipboard BEFORE calling this, so a
  /// denied grant costs the keystroke and nothing else — the user presses ⌘V
  /// themselves. Say that out loud once per run, or a hotkey that quietly does
  /// nothing visible reads as broken.
  Future<bool> _canSynthesizePaste() async {
    if (await inputInjectionAvailable()) return true;
    if (Platform.isMacOS && !_pasteGrantHintShown) {
      _pasteGrantHintShown = true;
      _notify(
        'Copied — press ⌘V to paste',
        'Relic needs Accessibility access to paste for you. Grant it in '
            'System Settings → Privacy & Security → Accessibility.',
      );
    }
    return false;
  }

  /// The quick-paste hotkeys: put the Nth-newest item from ANY device on the
  /// clipboard (decrypting + fetching its blob if needed) and paste it into the
  /// frontmost app. Works straight from the tray — no popup shown. putOnClipboard
  /// arms the echo-suppression guard, so this never re-captures as new history.
  Future<void> _quickPaste(int n) async =>
      _pasteRelic(widget.repo.nthMostRecent(n),
          emptyBody: n == 1
              ? 'No items in Relic yet.'
              : "There's no item #$n yet.");

  /// Shared body of the quick-paste hotkeys: put [r] on the clipboard
  /// (decrypting + fetching its blob if needed) and synth-paste into the
  /// frontmost app. putOnClipboard arms the echo guard so it never re-captures.
  Future<void> _pasteRelic(Relic? r,
      {String emptyBody = 'No items in Relic yet.'}) async {
    if (_pasteInFlight) return;
    _pasteInFlight = true;
    try {
      if (r == null) {
        _notify('Nothing to paste', emptyBody);
        return;
      }
      // Clipboard first, keystroke second: without the macOS Accessibility
      // grant the keystroke never fires, and the item still has to be there.
      await widget.repo.putOnClipboard(r);
      // The chord's modifiers are still physically held; wait for them to clear
      // before synthesizing Ctrl+V, or it lands as a modified chord.
      if (await _canSynthesizePaste()) await sendPasteChordSafe();
    } catch (_) {
      // Most likely the blob isn't downloaded yet (offline, or the peer hasn't
      // finished uploading). It's on the clipboard only if putOnClipboard got
      // that far; tell the user rather than fail silently.
      _notify('Could not paste', "That item couldn't be loaded yet.");
    } finally {
      _pasteInFlight = false;
    }
  }

  Size get _popupDims => Size(widget.repo.popupSize.w, widget.repo.popupSize.h);

  /// [src] is who asked; [miniForSummon] turns that into the picker mode. The
  /// source travels rather than the mode so that no call site can decide the
  /// policy on its own, which is how the full popup once lost its hotkey.
  Future<void> _show(Summon src) async {
    _miniMode.value = miniForSummon(src);
    // Read the summon context FIRST — the summoner still owns the foreground
    // until we take it (same rule as the capture path below). Feeds the
    // destination-context ranking prior; the skip-list nulls Relic itself.
    widget.repo.setSummonApp(await foregroundAppKey());
    // Mini picker: capture the caret/cursor anchor NOW, while the summoner still
    // owns the foreground. Reading the caret after setAlwaysOnTop/focus (below)
    // can miss it — the window may have taken the foreground, whose caret is
    // empty — so it must happen before any windowManager activation.
    if (!_connecting && !_settingsOpen && _miniMode.value) {
      await _captureMiniAnchor();
    }
    // Always undo any leaked click-through, regardless of how we got here.
    try {
      await windowManager.setIgnoreMouseEvents(false);
    } catch (_) {}
    await windowManager.setAlwaysOnTop(true);

    // Popup surface uses the user's chosen footprint; Settings/Connect set their
    // own larger size when they open, so only the popup repositions to cursor.
    // Mini picker uses the anchor captured above, then re-hugs live.
    if (!_connecting && !_settingsOpen) {
      // Atomic size+position (setBounds) avoids the two-step resize/reposition
      // race that left the header clipped.
      if (_miniMode.value) {
        await _applyMiniBounds();
      } else {
        await windowManager.setBounds(await _summonRect(_popupDims));
      }
    }
    // Agent mode (the popup) or app mode (settings, onboarding)? See [_present].
    await _present(foreground: _connecting || _settingsOpen);
    // Re-assert bounds once the window is actually on the target monitor — this
    // corrects a cross-DPI scale mismatch that otherwise renders the content at
    // the wrong size (clipping the X / gear). Cheap and idempotent.
    if (!_connecting && !_settingsOpen) {
      if (_miniMode.value) {
        await _applyMiniBounds();
      } else {
        await windowManager.setBounds(await _summonRect(_popupDims));
      }
    }
    _visible = true;
    _shownAt = DateTime.now();
    // One frame between the resize and the focus. A hidden window produces no
    // frames, so the bounds we just set can leave the tree needing layout with
    // nothing scheduled — and a text field that takes focus in that state
    // measures a render box that was never laid out (the `hasSize` assertion in
    // docs/macos-port.md's QA backlog; the launch-time half of it is fixed in
    // popup.dart). Waiting on the frame is imperceptible and makes the order
    // explicit.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    _popupSummonTick.value++; // focus lands in the search box
    setState(() {});
  }

  /// Put the window on screen.
  ///
  /// [foreground] false is agent mode, the popup: on macOS the window is an
  /// NSPanel that takes key WITHOUT activating the app, so the app you summoned
  /// Relic from keeps the foreground and the paste handover on pick still has
  /// somewhere to land. True is app mode — settings, onboarding, the recovery
  /// kit — which is a whole UI the user is about to work in, so the app comes
  /// forward for real (an LSUIElement agent has to ask forcefully, hence
  /// [activateApp]).
  ///
  /// The fallback is Windows, where taking the foreground on show is the
  /// convention anyway, and any macOS build whose native side predates the
  /// panel bridge.
  Future<void> _present({required bool foreground}) async {
    if (await presentWindow(activate: foreground)) return;
    if (foreground) await activateApp();
    await windowManager.show();
    await windowManager.focus();
  }

  /// Take the window off screen. On macOS this also hands the foreground back
  /// to the previous app whenever Relic holds it (after settings, or any OS
  /// dialog we opened) — the popup itself never took it.
  Future<void> _dismiss() async {
    if (await dismissWindow()) return;
    await windowManager.hide();
  }

  /// Switching the OPEN window from the popup to settings/onboarding. The popup
  /// is showing without the app ever having taken the foreground (agent mode),
  /// and the surface that replaces it is a full UI the user is about to work
  /// in, so the app comes forward. Agent mode returns by itself when the window
  /// hides — [_dismiss] hands the foreground back. No-op on Windows, where the
  /// window took the foreground on show anyway.
  void _toAppMode() => unawaited(activateApp());

  /// The work area (origin + size) of whichever monitor the cursor is on, with
  /// a sane fallback. Shared by the popup and the toast positioning.
  Future<(Offset, Size)> _cursorWorkArea() async {
    final cursor = await screenRetriever.getCursorScreenPoint();
    final displays = await screenRetriever.getAllDisplays();
    for (final d in displays) {
      final o = d.visiblePosition ?? Offset.zero;
      final s = d.visibleSize ?? d.size;
      if (Rect.fromLTWH(o.dx, o.dy, s.width, s.height).contains(cursor)) {
        return (o, s);
      }
    }
    final p = await screenRetriever.getPrimaryDisplay();
    return (p.visiblePosition ?? Offset.zero, p.visibleSize ?? p.size);
  }

  /// Work area of whichever monitor contains screen-space point [p], falling
  /// back to the cursor monitor. Same coordinate space as [_cursorWorkArea].
  Future<(Offset, Size)> _workAreaContaining(Offset p) async {
    try {
      final displays = await screenRetriever.getAllDisplays();
      for (final d in displays) {
        final o = d.visiblePosition ?? Offset.zero;
        final s = d.visibleSize ?? d.size;
        if (Rect.fromLTWH(o.dx, o.dy, s.width, s.height).contains(p)) {
          return (o, s);
        }
      }
    } catch (_) {}
    return _cursorWorkArea();
  }

  /// Where to place the popup on summon. With "open history at the cursor" on
  /// (feature_paste_at_caret), anchor just below the text caret when Windows
  /// reports one; otherwise, and everywhere else, fall back to the mouse-
  /// anchored [_cursorRect]. The caret comes in physical pixels, so the scale
  /// is derived empirically from a cursor read in both coordinate spaces (both
  /// point at the same monitor in practice), and the result is clamped to the
  /// caret monitor's work area so a bad reading can never place it off-screen.
  Future<Rect> _summonRect(Size size) async {
    if (widget.repo.pasteAtCaret) {
      try {
        final anchor = await _caretAnchor();
        if (anchor != null) {
          final (p, origin, area) = anchor;
          return placePopupNear(p, size, origin, area, 6).$1;
        }
      } catch (_) {
        // fall through to the mouse anchor
      }
    }
    return _cursorRect(size);
  }

  /// Rect placing a [size] popup next to the mouse (like Win+V), clamped to the
  /// cursor monitor's work area; centered on the primary display on failure.
  Future<Rect> _cursorRect(Size size) async {
    try {
      final cursor = await screenRetriever.getCursorScreenPoint();
      final (origin, area) = await _cursorWorkArea();
      return placePopupNear(cursor, size, origin, area, 12).$1;
    } catch (_) {
      // center on primary
      final p = await screenRetriever.getPrimaryDisplay();
      final o = p.visiblePosition ?? Offset.zero;
      final a = p.visibleSize ?? p.size;
      return Rect.fromLTWH(
        o.dx + (a.width - size.width) / 2,
        o.dy + (a.height - size.height) / 2,
        size.width,
        size.height,
      );
    }
  }

  /// The text caret as a logical-screen point plus its monitor work area, or
  /// null when Windows reports no caret (web views, etc.). The caret comes in
  /// physical pixels, so the scale is derived empirically from a cursor read in
  /// both coordinate spaces (both point at the same monitor in practice).
  Future<(Offset, Offset, Size)?> _caretAnchor() async {
    final caret = caretScreenPointPhysical();
    if (caret == null) return null;
    final curPhys = cursorScreenPointPhysical();
    final curLog = await screenRetriever.getCursorScreenPoint();
    var scale = 1.0;
    if (curPhys != null) {
      final useX = curPhys[0].abs() >= curPhys[1].abs();
      final denom = useX ? curPhys[0] : curPhys[1];
      final numer = useX ? curLog.dx : curLog.dy;
      if (denom.abs() > 4) {
        final s = numer / denom;
        if (s.isFinite && s > 0.1 && s < 3.0) scale = s;
      }
    }
    final p = Offset(caret[0] * scale, caret[1] * scale);
    final (origin, area) = await _workAreaContaining(p);
    return (p, origin, area);
  }

  // --- mini picker: cursor-anchored, hug-the-results sizing ---

  double _miniHeightFor(int rows) =>
      _kMiniSearchH + _kMiniListPad + rows * MiniResultRow.height;

  /// Current mini window size: width fixed, height sized to the visible rows
  /// (>=1, capped) so the list never scrolls.
  Size _miniSize() {
    var n = widget.repo.visible.length;
    if (n > MiniResultRow.maxRows) n = MiniResultRow.maxRows;
    if (n < 1) n = 1;
    return Size(_kMiniWidth, _miniHeightFor(n));
  }

  /// Capture the mini anchor (the text caret when Windows reports one, else the
  /// mouse) + its monitor, and decide the flip against the MAX height (so later
  /// growth never re-flips). Called before the window activates so the caret of
  /// the app you're working in is still readable.
  Future<void> _captureMiniAnchor() async {
    Offset anchor;
    Offset origin;
    Size area;
    final caret = await _caretAnchor();
    if (caret != null) {
      (anchor, origin, area) = caret;
    } else {
      anchor = await screenRetriever.getCursorScreenPoint();
      (origin, area) = await _cursorWorkArea();
    }
    _miniAnchor = anchor;
    _miniOrigin = origin;
    _miniArea = area;
    final maxSize = Size(_kMiniWidth, _miniHeightFor(MiniResultRow.maxRows));
    _miniDown = placePopupNear(anchor, maxSize, origin, area, _kMiniGap).$2;
  }

  /// Re-place the mini window at the stored anchor with the current size,
  /// keeping the cursor-side edge fixed (no re-flip, no reposition jump).
  Future<void> _applyMiniBounds() async {
    final anchor = _miniAnchor, origin = _miniOrigin, area = _miniArea;
    if (anchor == null || origin == null || area == null) return;
    final size = _miniSize();
    final maxX = origin.dx + area.width - size.width;
    final maxY = origin.dy + area.height - size.height;
    var x = anchor.dx + _kMiniGap;
    if (x > maxX) x = anchor.dx - size.width - _kMiniGap;
    var y = _miniDown
        ? anchor.dy + _kMiniGap
        : anchor.dy - size.height - _kMiniGap;
    x = x.clamp(origin.dx, maxX < origin.dx ? origin.dx : maxX);
    y = y.clamp(origin.dy, maxY < origin.dy ? origin.dy : maxY);
    try {
      await windowManager
          .setBounds(Rect.fromLTWH(x, y, size.width, size.height));
    } catch (_) {}
  }

  /// The repo notifies on every result/query change; when the mini picker is
  /// open, debounce a re-hug so the window tracks the match count smoothly.
  void _onRepoTick() {
    if (!_visible || _connecting || _settingsOpen || !_miniMode.value) {
      return;
    }
    _miniResizeTimer?.cancel();
    _miniResizeTimer = Timer(const Duration(milliseconds: 130), () {
      if (_visible && _miniMode.value) unawaited(_applyMiniBounds());
    });
  }

  /// Hide the popup, and always reset the popup's search state so the NEXT
  /// summon opens fresh on All with an empty box.
  ///
  /// This used to reset only on a deliberate close (Esc / X / tray click), on
  /// the theory that re-summoning after a quick detour should keep your place.
  /// In practice the detour is rarely quick: you click away, come back much
  /// later, and Relic is still showing a search you have forgotten typing, with
  /// most of your history filtered out of view. A stale filter reads as missing
  /// data. Every close resets now, so the window always opens the same way.
  ///
  /// The reset runs while the window is hidden, after [_visible] goes false, so
  /// the mini picker's live re-hug ignores the resulting result-count change.
  Future<void> _hide() async {
    // Clear [_visible] FIRST. On macOS the window is a panel, so ordering it
    // out fires a resign-key blur straight back at [onWindowBlur]; seeing the
    // window already marked hidden is what stops that from re-entering here and
    // firing the tray hint twice.
    _visible = false;
    _pinned = false; // every close path funnels through here
    await _dismiss();
    _popupResetTick.value++;
    // One-time education the first time the window disappears: without this,
    // a new user who clicks away has no idea how to get Relic back.
    if (!widget.repo.trayHintShown) {
      widget.repo.markTrayHintShown();
      _notify(
        'Relic is still running',
        'It lives in your ${Platform.isMacOS ? 'menu bar' : 'tray'}. '
            'Press ${widget.repo.historyHotkey.display} to open it anytime.',
      );
    }
  }

  /// Browser OAuth hands off to the system browser for the provider consent
  /// screen. Our popup is frameless and pinned always-on-top, so it sits over
  /// that screen. Step aside on handoff ([away] true) and reappear on top once
  /// the loopback callback lands ([away] false), so the sign-in is never buried
  /// behind our window. We bypass [_hide] deliberately: no search reset, no
  /// tray-hint notification (we come straight back), and connecting state stays
  /// intact so the passphrase step shows the instant we return.
  Future<void> _oauthBrowserHandoff(bool away) async {
    try {
      if (away) {
        _visible = false;
        await _dismiss();
      } else {
        await windowManager.setAlwaysOnTop(true);
        // App mode: the browser is frontmost and we are coming back to finish
        // the sign-in, so take the foreground (LSUIElement agents are refused a
        // polite activation — [_present] asks forcefully).
        await _present(foreground: true);
        _visible = true;
      }
    } catch (_) {}
  }

  /// Grow the mini picker into the full popup, in place. Used when the user
  /// asks for something the compact window has no room for (today: the editor,
  /// from the pencil on a mini row).
  ///
  /// Deliberately NOT [_show]: that path re-reads the summon context, re-takes
  /// the foreground, and ticks [_popupSummonTick], which would yank focus back
  /// to the search box just as the editor opens. The window is already up and
  /// focused; all that has to change is its mode and its bounds.
  ///
  /// It centers rather than following the cursor. The mini window is anchored
  /// to the caret, often near a screen edge, and growing it from there would
  /// either run off the monitor or shove itself sideways to fit. Centering is
  /// what every other in-session surface change already does (Settings,
  /// Connect), so the motion is one the user has seen before.
  Future<void> _expandFromMini() async {
    if (!_miniMode.value) return;
    _miniResizeTimer?.cancel(); // a pending re-hug must not shrink us back
    _miniMode.value = false;
    await _sizeWindow(_popupDims.width, _popupDims.height);
    if (mounted) setState(() {});
  }

  /// Summon/dismiss. When the popup is already up in the OTHER mode, switch to
  /// the requested one instead of closing — so pressing the mini key over the
  /// full picker (or vice versa) swaps modes rather than dismissing.
  Future<void> _toggle(Summon src) async {
    final want = miniForSummon(src);
    if (_visible && _miniMode.value == want) {
      await _hide();
    } else {
      await _show(src);
    }
  }

  /// Esc backs out of whatever surface is showing: a sub-surface (Settings /
  /// Connect) returns to the popup; the popup itself hides the window to the
  /// tray. This is the catch-all so no surface can ever get "stuck open" —
  /// it fires even when an inner field has focus, since key events bubble up.
  KeyEventResult _onAppKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent || e.logicalKey != LogicalKeyboardKey.escape) {
      return KeyEventResult.ignored;
    }
    if (_settingsOpen) {
      // A settings drill-down (Devices / Security / Recovery kit) or one of
      // its dialogs is a route pushed above the settings card; Esc peels one
      // layer at a time instead of yanking settings out from under it.
      final nav = _navKey.currentState;
      if (nav != null && nav.canPop()) {
        nav.pop();
        return KeyEventResult.handled;
      }
      setState(() => _settingsOpen = false);
      _sizeWindow(_popupDims.width, _popupDims.height);
      return KeyEventResult.handled;
    }
    if (_connecting) {
      setState(() => _connecting = false);
      _sizeWindow(_popupDims.width, _popupDims.height);
      return KeyEventResult.handled;
    }
    _hide();
    return KeyEventResult.handled;
  }

  /// Each surface has its own footprint; the popup window must grow for the
  /// wide Settings pane or its right column (incl. the Connect button) clips.
  Future<void> _sizeWindow(double w, double h) async {
    await windowManager.setSize(Size(w, h));
    await windowManager.center();
  }

  // --- save & annotate (the capture hotkey) ---

  /// Guards against WM_HOTKEY auto-repeat while the chord is held — the
  /// handler below is long-running (modifier wait + clipboard poll).
  bool _annotateInFlight = false;

  /// The pending "open this relic in the editor" request handed to PopupView.
  /// A fresh object per hotkey press (identity-compared there).
  EditRequest? _annotateRequest;

  /// True while PopupView has a modal dialog up (edit/compose/confirm…) —
  /// suspends blur-to-close so alt-tabbing mid-note doesn't destroy the edit.
  bool _popupModalOpen = false;

  /// Header pushpin: keeps the popup open across focus loss. Per-summon only
  /// (reset in _hide) — a forgotten pin must never make the next summon feel
  /// broken. Esc still closes; pin defeats blur only.
  bool _pinned = false;

  void _notify(String title, String body) {
    try {
      LocalNotification(title: title, body: body).show();
    } catch (_) {}
  }

  /// The save & annotate hotkey: capture the current SELECTION (via a
  /// synthesized, chord-safe Ctrl+C) or fall back to the clipboard, save +
  /// PROMOTE it immediately (Esc later loses nothing), then summon the popup
  /// straight into the editor so the next keystrokes are the label.
  Future<void> _saveAndAnnotate() async {
    if (_annotateInFlight) return;
    _annotateInFlight = true;
    try {
      final repo = widget.repo;
      // Attribution first — the source app still owns the foreground.
      final srcApp = await foregroundAppTag();
      // Snapshot so "nothing selected" falls back to what's already copied.
      final seqBefore = await clipboardSequence();
      final before = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
      // Synthesize Ctrl+C at the source app — EXCEPT into a terminal (Ctrl+C
      // with no selection is SIGINT: it would kill whatever's running), when
      // the popup itself is focused (we'd copy our own search box), or when
      // macOS hasn't granted Accessibility (the copy can't fire, and polling
      // 600ms for a clipboard change that will never come just delays the
      // "annotate what you already copied" fallback below).
      final skipCopy =
          _visible || srcApp == 'terminal' || !await inputInjectionAvailable();
      if (!skipCopy) {
        await sendCopyChordSafe();
        // Slow apps (Word/Excel) can take a few hundred ms to render formats.
        for (var i = 0;
            i < 15 && await clipboardSequence() == seqBefore;
            i++) {
          await Future<void>.delayed(const Duration(milliseconds: 40));
        }
      }
      String? text;
      Uint8List? png;
      if (await clipboardSequence() != seqBefore) {
        final c = await _readClipboardContent();
        text = c.text;
        png = c.png;
      }
      // No new copy → the user meant "annotate what I already copied".
      // NB: deliberately NOT gated on clipboardShouldBeIgnored() — an explicit
      // user-invoked save overrides a password manager's history hint (the
      // content is still detected + masked as a secret).
      if (png == null && (text == null || text.trim().isEmpty)) text = before;
      if (png == null && (text == null || text.trim().isEmpty)) {
        _notify('Nothing to save', 'Select or copy something first.');
        return;
      }
      final res = await repo.captureForAnnotate(
        text: png == null ? text : null,
        png: png,
        sourceApp: srcApp,
      );
      if (res == null) {
        _notify('Nothing to save', 'That item couldn’t be captured.');
        return;
      }
      final (r, promoted) = res;
      // Onboarding / recovery-kit surfaces stay — the item is safe either way.
      if (_connecting || _showingKit) {
        _notify(
          promoted ? 'Saved to Vault' : 'Saved to history',
          'Finish setup, then add details from the popup.',
        );
        return;
      }
      if (_settingsOpen) setState(() => _settingsOpen = false);
      _annotateRequest = EditRequest(r, promoted: promoted);
      if (mounted) setState(() {});
      await _show(Summon.annotate);
    } finally {
      _annotateInFlight = false;
    }
  }

  /// Annotate-path clipboard read — the same format ladder as the watcher
  /// (PNG → JPEG → plain text → CF_DIB→PNG → framework text), condensed to a
  /// value return. Keep in step with [onClipboardChanged].
  Future<({String? text, Uint8List? png})> _readClipboardContent() async {
    try {
      final clip = SystemClipboard.instance;
      if (clip != null) {
        final reader = await clip.read();
        for (final f in [Formats.png, Formats.jpeg]) {
          if (reader.canProvide(f)) {
            final done = Completer<Uint8List?>();
            reader.getFile(
              f,
              (file) async => done.complete(await file.readAll()),
              onError: (_) => done.complete(null),
            );
            final bytes = await done.future.timeout(
              const Duration(seconds: 3),
              onTimeout: () => null,
            );
            if (bytes != null && bytes.isNotEmpty) {
              return (text: null, png: bytes);
            }
          }
        }
        if (reader.canProvide(Formats.plainText)) {
          final t = await reader.readValue(Formats.plainText);
          if (t != null && t.trim().isNotEmpty) return (text: t, png: null);
        }
      }
      final fallbackPng = await clipboardImageAsPng();
      if (fallbackPng != null) return (text: null, png: fallbackPng);
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      return (text: data?.text, png: null);
    } catch (_) {
      return (text: null, png: null);
    }
  }

  // --- clipboard ---
  @override
  void onClipboardChanged() async {
    if (_paused) return;
    final repo = widget.repo;
    // Read the source app FIRST — the copier still owns the foreground window
    // when the clipboard event fires (and the macOS bridge awaits don't change
    // the frontmost app, so ordering stays safe).
    final appKey = await foregroundAppKey();
    if (await clipboardShouldBeIgnored()) return;
    // User blocklist: copies from these programs never enter history. (The
    // save & annotate hotkey is deliberately NOT gated — explicit action wins.)
    if (appKey != null && repo.captureBlocklist.contains(appKey)) return;
    final srcApp = foregroundAppTagFrom(appKey);

    // A file copy takes priority over text/image reps. On Windows the change
    // event can land a beat before Explorer finishes placing CF_HDROP (or
    // while Explorer still holds the clipboard open), so a single empty read
    // isn't conclusive — re-poll briefly before giving up on files, or a real
    // Ctrl+C on a file is silently dropped. NSPasteboard has no such race, and
    // the re-poll would cost every non-file capture ~200ms of channel hops.
    var files = await clipboardFilePaths();
    if (Platform.isWindows) {
      for (var tries = 0; files.isEmpty && tries < 5; tries++) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        files = await clipboardFilePaths();
      }
    }
    if (files.isNotEmpty) {
      if (!repo.captureFilesEnabled) return; // files disabled → skip entirely
      final maxBytes = repo.maxItemBytes; // per-item cap (Settings)
      for (final path in files.take(20)) {
        try {
          final f = File(path);
          final len = await f.length();
          if (len > maxBytes) {
            // Over cap: keep the path-only degrade, but say so (throttled) —
            // a silently shrunken capture reads as a dropped one.
            repo.onCaptureTooLarge?.call(repo.maxItemMb);
            repo.captureText(path); // over cap → path-only relic
          } else {
            repo.captureFile(path, await f.readAsBytes());
          }
        } catch (_) {
          repo.captureText(path);
        }
      }
      return;
    }

    final clip = SystemClipboard.instance;
    if (clip != null) {
      final reader = await clip.read();
      // image (e.g. a screenshot — Windows puts a "PNG" format) takes priority
      if (reader.canProvide(Formats.png)) {
        if (repo.captureImagesEnabled) {
          reader.getFile(Formats.png, (file) async {
            final bytes = await file.readAll();
            repo.captureImage(bytes, sourceApp: srcApp);
          });
        }
        return;
      }
      if (reader.canProvide(Formats.jpeg)) {
        if (repo.captureImagesEnabled) {
          reader.getFile(Formats.jpeg, (file) async {
            final bytes = await file.readAll();
            repo.captureImage(bytes, sourceApp: srcApp);
          });
        }
        return;
      }
      if (reader.canProvide(Formats.plainText)) {
        if (repo.captureTextEnabled) {
          final text = await reader.readValue(Formats.plainText);
          if (text != null) repo.captureText(text, sourceApp: srcApp);
        }
        return;
      }
    }
    // raw bitmap fallback (e.g. PrtScn / tools that don't put a PNG format):
    // read the native raster (CF_DIB / TIFF), normalized to PNG.
    if (repo.captureImagesEnabled) {
      final fallbackPng = await clipboardImageAsPng();
      if (fallbackPng != null) {
        repo.captureImage(fallbackPng, sourceApp: srcApp);
        return;
      }
    }
    // fallback: plain text via the framework clipboard
    if (repo.captureTextEnabled) {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (data?.text != null) {
        repo.captureText(data!.text!, sourceApp: srcApp);
      }
    }
  }

  // --- window ---
  // Launching Relic while it's already running shows the existing window
  // NATIVELY (main.cpp broadcasts RelicShowExisting; win32_window.cpp calls
  // ShowWindow + SetForegroundWindow), so Dart never learns and _visible stays
  // false — which made onWindowBlur bail forever: the popup sat on top until
  // an in-app close. Adopt the show when focus arrives while we think we're
  // hidden, so click-away and Esc behave like any hotkey summon.
  @override
  void onWindowFocus() {
    if (_visible) return;
    _visible = true;
    _shownAt = DateTime.now(); // arm the post-summon focus-churn grace period
    _popupSummonTick.value++; // a native show is a summon too — focus search
    if (mounted) setState(() {});
  }

  // Click-away to close: when the popup loses focus to another app/window, hide
  // it to the tray. In-popup interactions (promote, edit, add tags…) don't blur
  // the OS window, so they keep it open; Esc and explicit copy still close it.
  @override
  void onWindowBlur() {
    if (!_visible) return;
    // A native modal (the OS file picker) steals focus — don't hide the popup
    // out from under it; the user is mid-task and expects to come back to it.
    if (gNativeModalOpen) return;
    // A live drag-out steals focus by design (the user is dropping into
    // another app) — hiding now would kill the drag source mid-flight. Also
    // swallow the blur the drop target's activation fires just after the drop.
    if (gDragOutActive) return;
    final dragEnd = gDragOutEndedAt;
    if (dragEnd != null &&
        DateTime.now().difference(dragEnd) <
            const Duration(milliseconds: 400)) {
      return;
    }
    // Don't yank the connect/settings surfaces (or the one-time recovery kit)
    // out from under the user — they may alt-tab to grab a token or passphrase,
    // or need to save their recovery kit, mid-flow. Same for any popup modal
    // (edit/annotate/compose): alt-tabbing to check something mid-note must
    // not destroy a half-typed edit.
    // (and the pushpin keeps the popup up across focus loss by request)
    if (_connecting || _settingsOpen || _showingKit || _popupModalOpen || _pinned) {
      return;
    }
    // Ignore the brief focus churn right after we summon the popup.
    final shown = _shownAt;
    if (shown != null &&
        DateTime.now().difference(shown) < const Duration(milliseconds: 400)) {
      return;
    }
    _hide();
  }

  // --- tray ---
  // Left click opens the history, right click opens the menu — the same
  // mapping on both platforms. macOS menu-bar items more often open their menu
  // on either button, but the whole point of Relic's icon is one click to your
  // clipboard, and the menu's first item is "Open history" for anyone who
  // reaches for it the Mac way. (Control-click can't be told apart here:
  // tray_manager reports a plain mouse-down with no modifiers.)
  @override
  void onTrayIconMouseDown() => _toggle(Summon.tray);
  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();
  @override
  void onTrayMenuItemClick(MenuItem item) async {
    switch (item.key) {
      case 'show':
        _show(Summon.tray);
      case 'pause_10':
        await _setPaused(true, duration: const Duration(minutes: 10));
      case 'pause_60':
        await _setPaused(true, duration: const Duration(hours: 1));
      case 'pause_inf':
        await _setPaused(true);
      case 'resume':
        await _setPaused(false);
      case 'connect':
        setState(() => _connecting = true);
        await _sizeWindow(520, 560);
        await _show(Summon.tray);
      case 'check_update':
        await _checkForUpdates();
      case 'install_update':
        if (_pendingUpdate case final u?) await _runSelfUpdate(u);
      case 'update_note':
        break; // disabled status line
      case 'quit':
        await trayManager.destroy();
        await windowManager.destroy();
    }
  }

  /// First line of the release notes for the update notification — writing
  /// notes into latest.json is finally visible to users.
  static String _updateBody(UpdateInfo info) {
    final first = info.notes
        .split('\n')
        .map((l) => l.trim())
        .firstWhere((l) => l.isNotEmpty, orElse: () => '');
    const tail = 'Click to update. Relic restarts by itself in a few seconds.';
    return first.isEmpty ? tail : '$first\n$tail';
  }

  /// Manual update check from the tray. Reports the result as a native
  /// notification; if an update exists, clicking it installs it in place
  /// (download → verify → silent installer → auto-relaunch).
  Future<void> _checkForUpdates() async {
    var version = '';
    try {
      version = (await PackageInfo.fromPlatform()).version;
    } catch (_) {}
    final res = await checkForUpdate(version);
    final info = res.info;
    await _recordUpdateResult(res);
    try {
      final n = LocalNotification(
        title: switch (res.outcome) {
          UpdateOutcome.available => 'Update available: ${info!.version}',
          UpdateOutcome.upToDate => 'Relic is up to date',
          UpdateOutcome.failed => "Relic couldn't check for updates",
        },
        body: switch (res.outcome) {
          UpdateOutcome.available => _updateBody(info!),
          UpdateOutcome.upToDate => "You're on the latest version.",
          UpdateOutcome.failed => res.reason ?? 'The check did not complete.',
        },
      );
      if (info != null) {
        n.onClick = () => _runSelfUpdate(info);
      }
      await n.show();
    } catch (_) {}
  }

  /// Mirror a check's outcome into the tray menu. An available update becomes
  /// a one-click "Install update X" entry that persists until it is taken, and
  /// a failed check says so instead of leaving the last (possibly reassuring)
  /// state standing.
  Future<void> _recordUpdateResult(UpdateResult res) async {
    if (!mounted) return;
    final now = DateTime.now();
    final at = '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}';
    final next = switch (res.outcome) {
      UpdateOutcome.available => 'Checked $at',
      UpdateOutcome.upToDate => 'Up to date, checked $at',
      UpdateOutcome.failed => "Update check failed at $at",
    };
    if (identical(_pendingUpdate, res.info) && next == _lastUpdateNote) return;
    _pendingUpdate = res.info;
    _lastUpdateNote = next;
    await _rebuildMenu();
  }

  /// Quiet background check: on launch (delayed, so startup stays instant)
  /// and daily after that. Each remote version is announced ONCE per process
  /// — the tray app runs for days, and a daily re-nag would teach people to
  /// ignore it.
  void _scheduleUpdateChecks() {
    Future<void> tick() async {
      if (_selfUpdating || !mounted) return;
      var version = '';
      try {
        version = (await PackageInfo.fromPlatform()).version;
      } catch (_) {}
      final res = await checkForUpdate(version);
      // Record first: the tray entry is how an available update stays visible
      // after its one notification is gone, and how a machine that silently
      // cannot reach the manifest finally says so.
      await _recordUpdateResult(res);
      final info = res.info;
      if (info == null || !_notifiedUpdates.add(info.version)) return;
      try {
        final n = LocalNotification(
          title: 'Relic ${info.version} is available',
          body: _updateBody(info),
        );
        n.onClick = () => _runSelfUpdate(info);
        await n.show();
      } catch (_) {}
    }

    Future.delayed(const Duration(minutes: 2), tick);
    _updateCheckTimer =
        Timer.periodic(const Duration(hours: 24), (_) => tick());
  }

  /// The one-click update path: download the signed installer, verify its
  /// manifest sha256, and hand off to the silent per-user install that
  /// relaunches the app (self_update.dart). Any failure — including an old
  /// manifest without a sha256 — falls back to the browser download page,
  /// which is exactly what the click used to do.
  Future<void> _runSelfUpdate(UpdateInfo info) async {
    if (_selfUpdating) return;
    _selfUpdating = true;
    var announced = false;
    try {
      // The "we're on it" notification waits for the download to actually
      // start. Only Windows has the silent in-place installer; everywhere else
      // installUpdate throws before it touches the network, and promising a
      // restart we are not going to do reads as a broken update.
      await installUpdate(info, onStatus: (_) {
        if (announced) return;
        announced = true;
        _notify('Updating Relic to ${info.version}',
            'Downloading now. Relic will restart by itself.');
      }); // no return on success: the app exits
    } on SelfUpdateUnsupported {
      // macOS ships a DMG you drag to Applications, so the browser is the
      // install path here, not a failure.
      _selfUpdating = false;
      _notify('Relic ${info.version} is ready',
          'Opening the download page in your browser.');
      await _openDownloadPage(info);
    } catch (_) {
      _selfUpdating = false;
      _notify('Update could not install itself',
          'Opening the download page instead.');
      await _openDownloadPage(info);
    }
  }

  Future<void> _openDownloadPage(UpdateInfo info) async {
    try {
      await launchUrl(Uri.parse(info.url), mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  /// Run a desktop connect action: rebuild the tray menu, dismiss the onboarding
  /// surface, and run the post-connect steps (recovery kit on create + device
  /// registration). Returns an error string for the onboarding UI, or null.
  Future<String?> _doDesktopConnect(Future<void> Function() connect) async {
    try {
      await connect();
      await _rebuildMenu();
      if (mounted) setState(() => _connecting = false);
      await _sizeWindow(_popupDims.width, _popupDims.height);
      await _afterDesktopConnect();
      return null;
    } on EmailConfirmationPending {
      // Let the onboarding surface route to its confirm-your-email step rather
      // than flattening this into an error string (which would strand the user
      // with no session and no passphrase saved).
      rethrow;
    } catch (e) {
      return e.toString();
    }
  }

  /// Open Stripe checkout for the Pro monthly plan in the browser — the
  /// device-cap dialog's "Upgrade" action. Best-effort; the dialog surfaces a
  /// failure. Reuses the Settings billing wiring (billingPlans + checkoutUrl).
  Future<void> _upgradeToPro() async {
    final plans = await widget.repo.billingPlans();
    if (plans.isEmpty) throw StateError('Upgrade is unavailable right now.');
    final pick = plans.firstWhere(
      (p) => p.tier == 'pro' && p.interval == 'month',
      orElse: () => plans.first,
    );
    final url = await widget.repo.checkoutUrl(pick.priceId);
    if (url != null) {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    }
  }

  /// Guided "switch account": disconnect, then re-open onboarding on the main
  /// welcome/sign-in page — the full chooser with Google/GitHub/Apple and the
  /// email options — rather than dropping straight onto the email+password form
  /// (which stranded people who sign in with a provider).
  void _switchAccount() {
    widget.repo.disconnectSync();
    _rebuildMenu();
    setState(() {
      _settingsOpen = false;
      _connecting = true;
      _onboardStartAtSignIn = false;
    });
    _sizeWindow(520, 560);
  }

  Widget _buildSurface() {
    // Ahead of onboarding: there is no point signing anyone in on a copy of
    // Relic that the next eject deletes.
    if (_installOffer case final where?) {
      return InstallOfferView(
        where: where,
        onInstall: installIntoApplications,
        onReveal: revealApplicationsFolder,
        onQuit: () async {
          await trayManager.destroy();
          await windowManager.destroy();
        },
      );
    }
    if (_connecting) {
      return DesktopOnboarding(
        startAtSignIn: _onboardStartAtSignIn,
        onBrowserHandoff: _oauthBrowserHandoff,
        // The Accessibility step drops the pin while the user is in System
        // Settings (else we cover the switch), and restores it on the way back.
        // _show also re-asserts the pin on every summon, so a missed restore
        // can never make the pin loss permanent.
        onPinWindow: (pinned) => windowManager.setAlwaysOnTop(pinned),
        onCancel: () {
          setState(() {
            _connecting = false;
            _onboardStartAtSignIn = false;
          });
          _sizeWindow(_popupDims.width, _popupDims.height);
        },
        onTryDemo: () {
          widget.repo.seedDemoIfEmpty(); // local-only sample relics
          setState(() => _connecting = false);
          _sizeWindow(_popupDims.width, _popupDims.height);
        },
        onSignInPassphrase: (email, password, passphrase) => _doDesktopConnect(
            () => widget.repo.connectSupabase(_workerUrl, email, password,
                passphrase,
                signUp: false)),
        onRecoveryKit: (email, password, kit, newPass) => _doDesktopConnect(() =>
            widget.repo.connectSupabaseWithKit(
                _workerUrl, email, password, kit, newPass)),
        onOAuthCreate: (session, passphrase) => _doDesktopConnect(() => widget.repo
            .connectSupabaseSession(_workerUrl, session, passphrase,
                allowCreate: true)),
        onOAuthUnlock: (session, passphrase) => _doDesktopConnect(() => widget.repo
            .connectSupabaseSession(_workerUrl, session, passphrase,
                allowCreate: false)),
        onOAuthRecoveryKit: (session, kit, newPass) => _doDesktopConnect(() =>
            widget.repo.connectSupabaseSessionWithKit(
                _workerUrl, session, kit, newPass)),
        onPairedMk: (session, mk) => _doDesktopConnect(() =>
            widget.repo.connectSupabaseSessionWithMk(_workerUrl, session, mk)),
      );
    }
    if (_settingsOpen) {
      return SettingsView(
        repo: widget.repo,
        startOnSync: !widget.repo.syncEnabled,
        onClose: () {
          setState(() => _settingsOpen = false);
          _sizeWindow(_popupDims.width, _popupDims.height);
        },
        onConnect: () {
          setState(() {
            _settingsOpen = false;
            _connecting = true;
            _onboardStartAtSignIn = false;
          });
          _sizeWindow(520, 560);
        },
        onDisconnect: () async {
          widget.repo.disconnectSync();
          await _rebuildMenu();
          if (mounted) setState(() {});
        },
        onSwitchAccount: _switchAccount,
        // After an in-Settings self-host connect: show the recovery kit on a
        // freshly created vault + register the device (reused whole; it
        // self-guards on vaultJustCreated and no-ops otherwise).
        onSelfHostPostConnect: _afterDesktopConnect,
        onUpgrade: _upgradeToPro,
        onRenameThisDevice: (label) async => widget.repo.setDeviceName(label),
        onBillingOpened: () {
          // Get out of the browser's way: hide the window and leave the next
          // summon on the plain popup, not Settings.
          _hide();
          setState(() => _settingsOpen = false);
          _sizeWindow(_popupDims.width, _popupDims.height);
        },
      );
    }
    final popup = PopupView(
      repo: widget.repo,
      annotate: _annotateRequest,
      onModalChanged: (open) {
        _popupModalOpen = open;
        // A closed modal consumes the pending annotate request; a stale one
        // must not reopen the editor on the next ordinary summon.
        if (!open) _annotateRequest = null;
      },
      onClose: () => _hide(),
      pinned: _pinned,
      onPinToggle: () => setState(() => _pinned = !_pinned),
      resetSignal: _popupResetTick,
      summonSignal: _popupSummonTick,
      miniSignal: _miniMode,
      onExpand: _expandFromMini,
      capturePaused: _pausedSignal,
      pausedUntil: () => _pausedUntil,
      onResumeCapture: () => _setPaused(false),
      globalShortcuts: [
        (widget.repo.historyHotkey.display, 'open your history'),
        (widget.repo.miniHotkey.display, 'open the mini picker'),
        (widget.repo.captureHotkey.display, 'save & annotate the selection'),
        (widget.repo.promoteHotkey.display, 'promote the last capture'),
        (
          '${widget.repo.quickPasteHotkeys.first.display} … ${widget.repo.quickPasteHotkeys.last.label}',
          'paste your 5 most-recent items by position'
        ),
      ],
      onPick: () async {
        // hide first so the keystroke lands in the previously-focused app, then
        // (if enabled) synthesize Ctrl+V to paste the pick directly. The pick
        // already put the item on the clipboard, so a paste we can't fire (no
        // macOS Accessibility grant) leaves the user one ⌘V away.
        //
        // The 120ms is the window actually going away: on macOS windowManager
        // .hide() replies before its orderOut runs, and AppKit hands activation
        // back to the previous app a beat after that. InputBridge waits out the
        // remainder of the handover (it won't post while we're still frontmost),
        // so this delay only has to cover the reply/orderOut gap.
        await _hide();
        if (widget.repo.pasteOnSelect) {
          await Future.delayed(const Duration(milliseconds: 120));
          if (await _canSynthesizePaste()) await sendPaste();
        }
      },
      onSettings: () {
        _toAppMode();
        setState(() => _settingsOpen = true);
        _sizeWindow(780, 600);
      },
      onConnect: () {
        _toAppMode();
        setState(() {
          _connecting = true;
          _onboardStartAtSignIn = false;
        });
        _sizeWindow(520, 560);
      },
    );
    // Stack any of-the-moment banners above the list: verify-to-sync (email not
    // confirmed) and the demo nudge (sample data seeded). Both are dismissible.
    return ValueListenableBuilder<bool>(
      valueListenable: widget.repo.emailUnverified,
      builder: (context, unverified, _) {
        final banners = <Widget>[];
        if (unverified && !_emailBannerDismissed) {
          banners.add(_verifyBanner());
        }
        if (widget.repo.isDemo && !widget.repo.demoNudgeDismissed) {
          banners.add(_demoNudgeBanner());
        }
        if (banners.isEmpty) return popup;
        return Column(children: [...banners, Expanded(child: popup)]);
      },
    );
  }

  /// Verify-to-sync banner (worker VERIFY_GATE 403 email_unverified). Local use
  /// is unaffected; offer a resend and a session-only dismiss.
  Widget _verifyBanner() {
    final c = _useDark ? RelicColors.dark : RelicColors.light;
    return Material(
      color: c.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
        child: Row(children: [
          Icon(Icons.mark_email_unread_outlined, color: c.accent, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
                'Confirm your email to start syncing. Local use is unaffected.',
                style: RelicTheme.sans(size: 12.5, color: c.text, height: 1.35)),
          ),
          TextButton(
            onPressed: () async {
              final email = widget.repo.accountEmail;
              if (email == null || email.isEmpty) return;
              try {
                await SupabaseAuth.resendSignupConfirmation(email);
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Confirmation email sent')));
                }
              } catch (_) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('Could not resend the email.')));
                }
              }
            },
            child: Text('Resend email',
                style: RelicTheme.sans(
                    size: 13, color: c.accent, weight: FontWeight.w600)),
          ),
          IconButton(
            icon: Icon(Icons.close, size: 16, color: c.textMuted),
            tooltip: 'Dismiss',
            onPressed: () => setState(() => _emailBannerDismissed = true),
          ),
        ]),
      ),
    );
  }

  /// One-time demo nudge shown after "Try the demo" seeding. Dismissal persists
  /// (repo prefs), so it never nags twice; the button opens onboarding.
  Widget _demoNudgeBanner() {
    final c = _useDark ? RelicColors.dark : RelicColors.light;
    return Material(
      color: c.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
        child: Row(children: [
          Icon(Icons.auto_awesome, color: c.accent, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
                'This is sample data. Create your vault to keep things for real.',
                style: RelicTheme.sans(size: 12.5, color: c.text, height: 1.35)),
          ),
          TextButton(
            onPressed: () {
              widget.repo.dismissDemoNudge();
              _toAppMode();
              setState(() {
                _connecting = true;
                _onboardStartAtSignIn = false;
              });
              _sizeWindow(520, 560);
            },
            child: Text('Create vault',
                style: RelicTheme.sans(
                    size: 13, color: c.accent, weight: FontWeight.w600)),
          ),
          IconButton(
            icon: Icon(Icons.close, size: 16, color: c.textMuted),
            tooltip: 'Dismiss',
            onPressed: () {
              widget.repo.dismissDemoNudge();
              setState(() {});
            },
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = _useDark ? RelicColors.dark : RelicColors.light;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Relic',
      navigatorKey: _navKey,
      // Theme above the Navigator too, so pushed routes (Devices, Security,
      // AddDevice) and dialogs can read RelicTheme.of without a re-wrap.
      builder: (context, child) => RelicTheme(
        colors: colors,
        child: child ?? const SizedBox.shrink(),
      ),
      home: RelicTheme(
        colors: colors,
        // Opaque Material (not transparency): the whole window is repainted
        // with a solid bg every frame, which avoids the Windows transparent-
        // Always opaque: Flutter's per-pixel window transparency ghosts on this
        // setup (flutter/flutter#71735). Saved-to-vault feedback when the app is
        // hidden goes through native OS notifications instead of a transparent
        // overlay window.
        child: Material(
          color: colors.base,
          child: Focus(
            autofocus: true,
            onKeyEvent: _onAppKey,
            child: ListenableBuilder(
              listenable: widget.repo,
              builder: (context, _) => _buildSurface(),
            ),
          ),
        ),
      ),
    );
  }
}
