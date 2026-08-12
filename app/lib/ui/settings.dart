import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart'
    show
        TextField,
        InputDecoration,
        InputBorder,
        MaterialPageRoute,
        AlertDialog,
        TextButton,
        showDialog,
        Theme,
        LicensePage;
import 'package:file_picker/file_picker.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/backup_file.dart';
import '../data/crash_log.dart';
import '../data/hotkeys.dart';
import '../platform/input_injector.dart';
import '../platform/running_apps.dart';
import '../platform/shell.dart';
import '../data/self_update.dart';
import '../data/sift.dart' show SiftSidecar;
import '../data/update_check.dart';
import '../data/local_desk_repo.dart';
import '../data/repo.dart';
import '../models/relic.dart' show relativeAge, formatCaptureDate;
import '../data/selfhost_link.dart';
import '../onboarding/add_device.dart';
import '../theme/relic_theme.dart';
import '../theme/tokens.dart';
import 'connect_dialog.dart';
import '../widgets/controls.dart';
import '../widgets/passphrase_field.dart';
import '../widgets/relic_mark.dart';

/// Settings window (design §14): sidebar of sections + one scrolling pane.
/// Every control is wired to [LocalDeskRepo]; changes persist to prefs.json and
/// take effect live.
class SettingsView extends StatefulWidget {
  final VoidCallback onClose;
  final LocalDeskRepo repo;

  /// Open the connect flow (passphrase entry). Settings closes; the connect
  /// surface takes over. Null-safe: if absent the Connect button is hidden.
  final VoidCallback? onConnect;
  final VoidCallback? onDisconnect;

  /// Guided "switch account": disconnect, then re-open onboarding on the sign-in
  /// step. Null hides the action.
  final VoidCallback? onSwitchAccount;

  /// Run the shared post-connect step (show the recovery kit on a freshly created
  /// vault, register the device) after an in-Settings self-host connect. The
  /// self-host path connects inside the Settings modal, so it can't reach the
  /// desktop shell's `_afterDesktopConnect` on its own. No-ops on an existing
  /// vault or a cancelled dialog.
  final Future<void> Function()? onSelfHostPostConnect;

  /// Open Stripe checkout for the Pro monthly plan — the device-cap dialog's
  /// "Upgrade" action. Null omits the upgrade button in that dialog.
  final Future<void> Function()? onUpgrade;

  /// Rename THIS device's local label to keep captures in step with a rename
  /// made from the devices list.
  final Future<void> Function(String label)? onRenameThisDevice;

  /// A billing link (Manage plan / Upgrade checkout) just opened in the
  /// browser. Desktop hides the window so the page isn't covered by it.
  final VoidCallback? onBillingOpened;

  /// Land directly on the Sync & account section (e.g. opened to link a device).
  final bool startOnSync;

  const SettingsView({
    super.key,
    required this.onClose,
    required this.repo,
    this.onConnect,
    this.onDisconnect,
    this.onSwitchAccount,
    this.onSelfHostPostConnect,
    this.onUpgrade,
    this.onRenameThisDevice,
    this.onBillingOpened,
    this.startOnSync = false,
  });
  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView>
    with WidgetsBindingObserver {
  late int _section = widget.startOnSync ? 4 : 0;
  static const _sections = [
    ('General', LucideIcons.slidersHorizontal),
    ('Capture', LucideIcons.clipboard),
    ('Search & AI', LucideIcons.sparkles),
    ('Vault & storage', LucideIcons.vault),
    ('Sync & account', LucideIcons.userRound),
    ('About', LucideIcons.info),
  ];

  // transient status line for the storage actions
  String _storageMsg = '';
  bool _storageBusy = false;
  bool _personalCleared = false;

  // Search & AI: downloaded-models size (null = loading) + remove feedback
  int? _modelsBytes;
  SiftStatus? _lastSiftStatus;
  String _modelsMsg = '';
  bool _diagCopied = false;

  // app version (single-sourced from pubspec via package_info_plus) + the
  // result of a manual "check for updates" tap.
  String _appVersion = '';
  String _updateMsg = '';
  bool _updateBusy = false;
  bool _updateInstalling = false;
  bool _updateFailed = false; // the check itself failed, ≠ "you're current"
  UpdateInfo? _updateAvailable;

  // billing: lazily-loaded plan list + an in-flight guard for Upgrade/Manage,
  // plus the last failure, shown inline under the billing row.
  Future<List<BillingPlan>>? _plansFuture;
  bool _billingBusy = false;
  String? _billingError;

  // export-vault flow (storage pane)
  bool _exportConfirming = false;
  bool _exportIncludeSecrets = false;
  bool _exportBusy = false;
  String _exportMsg = '';
  String? _exportDir;
  String? _exportPath;

  // import-vault flow (storage pane)
  bool _importConfirming = false;
  bool _importBusy = false;
  String _importMsg = '';
  String? _importDir;

  // manual "Sync now" in-flight guard (sync pane)
  bool _syncingNow = false;

  // auto-backup action feedback
  bool _backupBusy = false;
  String _backupMsg = '';

  // sealed-backup setup panel (first enable / change passphrase)
  bool _backupSetupOpen = false;
  bool _backupSetupBusy = false;
  String _backupSetupErr = '';
  String? _backupSetupDir;
  final TextEditingController _bkPassC = TextEditingController();
  final TextEditingController _bkConfirmC = TextEditingController();

  // re-enter passphrase when the stored backup key went missing
  final TextEditingController _bkReauthC = TextEditingController();
  bool _bkReauthBusy = false;

  // restore-from-backup-file flow (storage pane)
  String? _restoreFile;
  bool _restoreConfirming = false;
  bool _restoreBusy = false;
  String _restoreMsg = '';
  final TextEditingController _restorePassC = TextEditingController();

  /// Sync pane status line: live last-synced age instead of static copy.
  String _syncStatusLine() {
    final t = widget.repo.lastSyncedAt;
    if (t == null) {
      return 'This device syncs to your vault. Captures replicate within ~8s.';
    }
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final secs = t.millisecondsSinceEpoch ~/ 1000;
    final a = relativeAge(secs, now);
    if (a == 'just now') return 'Last synced just now · syncs automatically.';
    if (now - secs >= 3 * 86400) return 'Last synced $a · syncs automatically.';
    return 'Last synced $a ago · syncs automatically.';
  }

  Future<void> _syncNow() async {
    setState(() => _syncingNow = true);
    try {
      await widget.repo.syncNow();
    } finally {
      if (mounted) setState(() => _syncingNow = false);
    }
  }

  late final TextEditingController _deviceCtl = TextEditingController(
    text: widget.repo.deviceName,
  );
  final FocusNode _deviceF = FocusNode();

  // macOS Accessibility (TCC) grant — the gate paste-on-select and the save &
  // annotate hotkey's selection grab ride on. Null until the first check lands.
  bool? _axTrusted;
  bool _axBusy = false;

  // "Never capture from" picker: running apps fetched on open
  bool _blockPickerOpen = false;
  bool _blockPickerLoading = false;
  List<RunningApp> _blockPickerApps = const [];

  @override
  void initState() {
    super.initState();
    // rebuild on any repo change (async ML status, storage, sync) even when the
    // host isn't already listening (e.g. the design gallery).
    widget.repo.addListener(_onRepo);
    // persist the device name when the field loses focus
    _deviceF.addListener(() {
      if (!_deviceF.hasFocus) widget.repo.setDeviceName(_deviceCtl.text);
    });
    _loadVersion();
    _lastSiftStatus = widget.repo.siftStatus;
    _loadModelsBytes();
    if (Platform.isMacOS) {
      // Watch for resumes so the grant row refreshes itself when the user
      // comes back from System Settings.
      WidgetsBinding.instance.addObserver(this);
      _refreshAccessibility();
    }
  }

  /// macOS: re-read the Accessibility grant. Cheap channel call, so it also
  /// backs the manual "Re-check" action.
  Future<void> _refreshAccessibility() async {
    final ok = await inputInjectionAvailable();
    if (mounted) setState(() => _axTrusted = ok);
  }

  /// macOS: ask the system to show its one-time grant dialog, then open System
  /// Settings → Privacy & Security → Accessibility so the switch is right in
  /// front of the user. Coming back to Relic re-checks the status.
  Future<void> _grantAccessibility() async {
    setState(() => _axBusy = true);
    final ok = await inputInjectionAvailable(prompt: true);
    if (!ok) await openInputPermissionSettings();
    if (!mounted) return;
    setState(() {
      _axTrusted = ok;
      _axBusy = false;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && Platform.isMacOS) {
      _refreshAccessibility();
    }
  }

  Future<void> _loadModelsBytes() async {
    final b = await widget.repo.modelsBytes();
    if (mounted) setState(() => _modelsBytes = b);
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) setState(() => _appVersion = info.version);
    } catch (_) {}
  }

  @override
  void dispose() {
    if (Platform.isMacOS) WidgetsBinding.instance.removeObserver(this);
    widget.repo.removeListener(_onRepo);
    _deviceCtl.dispose();
    _deviceF.dispose();
    _bkPassC.dispose();
    _bkConfirmC.dispose();
    _bkReauthC.dispose();
    _restorePassC.dispose();
    super.dispose();
  }

  void _onRepo() {
    if (!mounted) return;
    // A download finishing or a removal completing changes siftStatus —
    // that's the cue to re-measure the models dir.
    final s = widget.repo.siftStatus;
    if (s != _lastSiftStatus) {
      _lastSiftStatus = s;
      _loadModelsBytes();
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    return SizedBox(
      width: 740,
      height: 560,
      child: Container(
        decoration: BoxDecoration(
          color: c.base,
          borderRadius: BorderRadius.circular(Radii.popup),
          border: Border.all(color: c.border),
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
        child: Column(
          children: [
            // header
            Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: c.border)),
              ),
              child: Row(
                children: [
                  const RelicIcon(size: 16),
                  const SizedBox(width: 9),
                  Text(
                    'RELIC',
                    style: RelicTheme.mono(
                      size: 11,
                      weight: FontWeight.w600,
                      color: c.textMuted,
                      letterSpacing: 2,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '· Settings',
                    style: RelicTheme.sans(
                      size: 13,
                      weight: FontWeight.w500,
                      color: c.text,
                    ),
                  ),
                  const Spacer(),
                  GhostIconButton(
                    icon: LucideIcons.x,
                    size: 26,
                    iconSize: 15,
                    onTap: widget.onClose,
                  ),
                ],
              ),
            ),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // sidebar
                  Container(
                    width: 204,
                    decoration: BoxDecoration(
                      color: c.isDark ? c.footer : c.panel,
                      border: Border(right: BorderSide(color: c.border)),
                    ),
                    padding: const EdgeInsets.all(10),
                    child: Column(
                      children: [
                        for (var i = 0; i < _sections.length; i++)
                          _navItem(c, i),
                      ],
                    ),
                  ),
                  // pane
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(22, 8, 22, 20),
                      child: _pane(c),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _navItem(RelicColors c, int i) {
    final on = i == _section;
    return Hoverable(
      onTap: () => setState(() => _section = i),
      builder: (context, hovered) => Container(
        margin: const EdgeInsets.only(bottom: 2),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
        decoration: BoxDecoration(
          color: on
              ? c.selected
              : (hovered ? c.surfaceHover : const Color(0x00000000)),
          borderRadius: BorderRadius.circular(7),
        ),
        child: Row(
          children: [
            Icon(
              _sections[i].$2,
              size: 16,
              color: on ? c.accent : c.textMuted,
            ),
            const SizedBox(width: 10),
            Text(
              _sections[i].$1,
              style: RelicTheme.sans(
                size: 13,
                weight: on ? FontWeight.w500 : FontWeight.w400,
                color: on ? c.textOnSelected : c.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pane(RelicColors c) {
    final repo = widget.repo;
    switch (_section) {
      case 0:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionLabel(c, 'General'),
            _toggleRow(
              c,
              'Launch Relic at login',
              repo.launchAtLogin,
              repo.setLaunchAtLogin,
              sub: 'Start capturing the moment you sign in.',
            ),
            _shortcutsSection(c),
            _toggleRow(
              c,
              'Show icon in menu bar',
              repo.showTrayIcon,
              repo.setShowTrayIcon,
              sub: 'Hide it to run purely from the hotkey.',
            ),
            _appearanceRow(c),
            _popupSizeRow(c),
            _toggleRow(
              c,
              'Paste directly on select',
              repo.pasteOnSelect,
              repo.setPasteOnSelect,
              sub: 'Copy and paste into the frontmost app in one press.',
            ),
            _toggleRow(
              c,
              'Show vault animation',
              repo.vaultAnimation,
              repo.setVaultAnimation,
              sub: 'Show the gemstone flourish for vault feedback.',
            ),
            _toggleRow(
              c,
              'Play sound on promotion',
              repo.promotionSound,
              repo.setPromotionSound,
              sub: 'Use the bundled Relic WAV only when an item is promoted.',
            ),
            if (Platform.isMacOS) _accessibilitySection(c),
            _sectionLabel(c, 'Power features'),
            _toggleRow(
              c,
              'Multi-select to combine',
              repo.multiCombine,
              repo.setMultiCombine,
              sub: 'Pick several history items, then paste them as one block.',
            ),
            _toggleRow(
              c,
              'Clip reminders',
              repo.reminders,
              repo.setReminders,
              sub: 'Set a reminder on any item and get a nudge later.',
              last: !Platform.isWindows,
            ),
            if (Platform.isWindows)
              _toggleRow(
                c,
                'Open history at the cursor',
                repo.pasteAtCaret,
                repo.setPasteAtCaret,
                sub: 'Summon the picker near your text cursor when we can.',
                last: true,
              ),
          ],
        );
      case 1:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionLabel(c, 'Capture'),
            _toggleRow(
              c,
              'Capture text',
              repo.captureTextEnabled,
              repo.setCaptureText,
              leadingTx: true,
            ),
            _toggleRow(
              c,
              'Capture images',
              repo.captureImagesEnabled,
              repo.setCaptureImages,
              leading: LucideIcons.image,
            ),
            _toggleRow(
              c,
              'Capture files',
              repo.captureFilesEnabled,
              repo.setCaptureFiles,
              leading: LucideIcons.file,
            ),
            _toggleRow(
              c,
              'Detect & mask secrets',
              repo.maskSecrets,
              repo.setMaskSecrets,
              sub: 'API keys, tokens & card numbers are masked in the list.',
              recommended: true,
            ),
            _toggleRow(
              c,
              'Clear clipboard 30 s after copying a secret',
              repo.clearSecretClipboard,
              repo.setClearSecretClipboard,
              sub:
                  'The secret is scrubbed unless you’ve copied something else since.',
              recommended: true,
            ),
            _toggleRow(
              c,
              'Save everything to Vault',
              repo.autoVault,
              repo.setAutoVault,
              sub:
                  'Auto-save every capture to your Vault so nothing expires. Turning this on also saves everything already in your history.',
              leading: LucideIcons.vault,
            ),
            _maxSizeRow(c),
            _blocklistSection(c),
          ],
        );
      case 2:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [_sectionLabel(c, 'Search & AI'), _mlSection(c)],
        );
      case 3:
        return _storagePane(c);
      case 4:
        return _syncPane(c);
      case 5:
        return _aboutPane(c);
      default:
        return const SizedBox.shrink();
    }
  }

  // --- Sync & account ---

  Widget _syncPane(RelicColors c) {
    final connected = widget.repo.syncEnabled;
    final acct = widget.repo.account;
    final selfHost = widget.repo.isSelfHost;
    // Self-host shows a "Self-hosted" chip instead of the managed Plan + billing
    // rows; cloud shows Plan (+ billing when applicable).
    final showPlanRow = connected && (selfHost || acct != null);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel(c, 'Sync & account'),
        _row(
          c,
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      !connected
                          ? 'Not connected'
                          : selfHost
                              ? 'Connected to your own server, end-to-end encrypted'
                              : 'Connected, end-to-end encrypted',
                      style: RelicTheme.sans(
                        size: 13,
                        weight: FontWeight.w500,
                        color: c.text,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      connected
                          ? [
                              // WHO/WHERE is connected — for cloud the account
                              // email, for self-host the server host.
                              if (selfHost)
                                ?_selfHostHost()
                              else
                                ?widget.repo.accountEmail,
                              _syncStatusLine(),
                            ].join(' · ')
                          : 'Link this device to your vault to sync across computers.',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: RelicTheme.sans(
                        size: 11.5,
                        color: c.textMuted,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              if (connected) ...[
                _btn(
                  c,
                  _syncingNow ? 'Syncing…' : 'Sync now',
                  LucideIcons.refreshCw,
                  onTap: _syncingNow ? null : _syncNow,
                ),
                const SizedBox(width: 8),
                if (widget.onSwitchAccount != null && !selfHost) ...[
                  _btn(
                    c,
                    'Switch account',
                    LucideIcons.repeat,
                    onTap: _confirmSwitchAccount,
                  ),
                  const SizedBox(width: 8),
                ],
                _btn(
                  c,
                  'Disconnect',
                  LucideIcons.logOut,
                  danger: true,
                  onTap: widget.onDisconnect == null ? null : _confirmDisconnect,
                ),
              ] else
                _btn(
                  c,
                  'Connect…',
                  LucideIcons.link,
                  accent: true,
                  onTap: widget.onConnect == null ? null : _openConnect,
                ),
            ],
          ),
        ),
        if (connected && widget.repo.heldCount > 0) _mergeOfferRow(c),
        _row(
          c,
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Device name',
                      style: RelicTheme.sans(size: 13, color: c.text),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Labels what this machine captures. Defaults to the hostname.',
                      style: RelicTheme.sans(size: 11.5, color: c.textMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              SizedBox(width: 160, child: _deviceField(c)),
            ],
          ),
          last: false,
        ),
        if (connected)
          _row(
            c,
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Devices',
                          style: RelicTheme.sans(size: 13, color: c.text)),
                      const SizedBox(height: 2),
                      Text('Add another device with a QR, or remove one.',
                          style: RelicTheme.sans(size: 11.5, color: c.textMuted)),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                _btn(c, 'Manage', LucideIcons.smartphone,
                    onTap: () => _openDevices(context)),
              ],
            ),
          ),
        if (connected && selfHost)
          _row(
            c,
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Add a device',
                          style: RelicTheme.sans(size: 13, color: c.text)),
                      const SizedBox(height: 2),
                      Text('Show a QR to point another device at this server.',
                          style: RelicTheme.sans(size: 11.5, color: c.textMuted)),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                _btn(c, 'Show QR', LucideIcons.qrCode,
                    onTap: _showSelfHostQr),
              ],
            ),
          ),
        if (connected)
          _row(
            c,
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Security',
                          style: RelicTheme.sans(size: 13, color: c.text)),
                      const SizedBox(height: 2),
                      Text('Change your vault passphrase or view your recovery kit.',
                          style: RelicTheme.sans(size: 11.5, color: c.textMuted)),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                _btn(c, 'Open', LucideIcons.shieldCheck,
                    onTap: () => _openSecurity(context)),
              ],
            ),
            last: !showPlanRow,
          ),
        if (connected && selfHost)
          _row(
            c,
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Plan',
                    style: RelicTheme.sans(size: 13, color: c.text),
                  ),
                ),
                Text(
                  'Self-hosted',
                  style: RelicTheme.mono(size: 12, color: c.textSecondary),
                ),
              ],
            ),
            last: true,
          )
        else if (connected && acct != null) ...[
          _row(
            c,
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Plan',
                    style: RelicTheme.sans(size: 13, color: c.text),
                  ),
                ),
                Text(
                  acct.tier,
                  style: RelicTheme.mono(size: 12, color: c.textSecondary),
                ),
              ],
            ),
            last: !_showBilling(acct.tier),
          ),
          if (_showBilling(acct.tier))
            _row(c, _billingActions(c, acct.tier), last: true),
        ],
      ],
    );
  }

  /// The host portion of the connected self-host server URL (for the pane
  /// subtitle), e.g. `192.168.1.10:8787`. Null if not applicable.
  String? _selfHostHost() {
    final u = widget.repo.syncUrl;
    if (u == null) return null;
    try {
      final uri = Uri.parse(u);
      return uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
    } catch (_) {
      return null;
    }
  }

  /// Open the two-step Connect dialog: Relic Cloud hands off to the existing
  /// onboarding ([widget.onConnect]); Your own server connects in-place via
  /// [LocalDeskRepo.connectSelfHost] and stays in Settings. After the dialog
  /// closes, run the shared post-connect step so a freshly created self-host
  /// vault shows its recovery kit (no-ops on an existing vault or a cancel).
  Future<void> _openConnect() async {
    final c = RelicTheme.of(context);
    await showConnectDialog(
      context,
      colors: c,
      onCloud: () => widget.onConnect?.call(),
      onSelfHost: (url, pass, secret) async {
        try {
          await widget.repo.connectSelfHost(url, pass, enrollSecret: secret);
          if (mounted) setState(() {});
          return null;
        } catch (e) {
          return e.toString();
        }
      },
    );
    if (mounted) await widget.onSelfHostPostConnect?.call();
  }

  /// Show a QR encoding this self-host server's address so another device can
  /// scan instead of typing the IP. The QR carries only the URL, never the
  /// passphrase (the user still enters that on the other device).
  void _showSelfHostQr() {
    final url = widget.repo.syncUrl;
    if (url == null) return;
    final c = RelicTheme.of(context);
    final payload = SelfHostLink.build(url);
    showDialog<void>(
      context: context,
      barrierColor: const Color(0x99000000),
      builder: (dctx) => RelicTheme(
        colors: c,
        child: Center(
          child: SizedBox(
            width: 360,
            child: Container(
              decoration: BoxDecoration(
                color: c.base,
                borderRadius: BorderRadius.circular(Radii.popup),
                border: Border.all(color: c.border),
              ),
              padding: const EdgeInsets.fromLTRB(28, 26, 28, 22),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text('Add a device',
                    style: RelicTheme.sans(
                        size: 18, weight: FontWeight.w600, color: c.text)),
                const SizedBox(height: 6),
                Text(
                  'Scan this in the Relic app on your other device (Add this device → Use your own server → Scan QR), then enter the same passphrase.',
                  textAlign: TextAlign.center,
                  style: RelicTheme.sans(size: 12.5, color: c.textMuted, height: 1.45),
                ),
                const SizedBox(height: 18),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFFFFF),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: QrImageView(data: payload, size: 220, version: QrVersions.auto),
                ),
                const SizedBox(height: 14),
                Text(url,
                    textAlign: TextAlign.center,
                    style: RelicTheme.mono(size: 12, color: c.textSecondary)),
                const SizedBox(height: 18),
                GestureDetector(
                  onTap: () => Navigator.of(dctx).pop(),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                      decoration: BoxDecoration(
                        color: c.surface,
                        borderRadius: BorderRadius.circular(Radii.input),
                        border: Border.all(color: c.border),
                      ),
                      child: Text('Done',
                          style: RelicTheme.sans(
                              size: 13, weight: FontWeight.w500, color: c.textSecondary)),
                    ),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  // --- Vault & storage ---

  Widget _storagePane(RelicColors c) {
    final repo = widget.repo;
    final acct = repo.account;
    final cacheBytes = repo.localBlobBytes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel(c, 'Vault & storage'),
        if (acct != null) ...[
          _storageUsage(c, acct),
          _row(
            c,
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Saved items (Vault)',
                        style: RelicTheme.sans(size: 13, color: c.text),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Promoted relics never expire on any tier.',
                        style: RelicTheme.sans(size: 11.5, color: c.textMuted),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Text(
                  acct.vaultCap == null
                      ? '${acct.vaultCount}'
                      : '${acct.vaultCount} / ${acct.vaultCap}',
                  style: RelicTheme.mono(size: 12, color: c.textSecondary),
                ),
              ],
            ),
          ),
        ],
        if (repo.vaultFull) _vaultFullBanner(c),
        _retentionRow(c),
        _clearHistoryRow(c),
        // local image cache
        _row(
          c,
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Local image cache',
                      style: RelicTheme.sans(size: 13, color: c.text),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      repo.canRedownload
                          ? 'Downloaded thumbnails & blobs on this device. Clearing only removes items already synced. They re-download on demand.'
                          : 'Downloaded thumbnails & blobs on this device.',
                      style: RelicTheme.sans(
                        size: 11.5,
                        color: c.textMuted,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Text(
                _fmtBytes(cacheBytes),
                style: RelicTheme.mono(size: 12, color: c.textSecondary),
              ),
              const SizedBox(width: 10),
              if (repo.canRedownload)
                _btn(
                  c,
                  'Clear',
                  LucideIcons.eraser,
                  onTap: _storageBusy ? null : _clearCache,
                ),
            ],
          ),
        ),
        if (repo.canRedownload)
          _row(
            c,
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Re-download images',
                        style: RelicTheme.sans(size: 13, color: c.text),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Pull any missing image blobs from your vault back to this device.',
                        style: RelicTheme.sans(
                          size: 11.5,
                          color: c.textMuted,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                _btn(
                  c,
                  'Re-download',
                  LucideIcons.cloudDownload,
                  onTap: _storageBusy ? null : _redownload,
                ),
              ],
            ),
          ),
        // where the viewer's "Save" writes images/files
        _saveLocationRow(c),
        // data folder
        _row(
          c,
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Data folder',
                      style: RelicTheme.sans(size: 13, color: c.text),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      repo.dataDirPath,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: RelicTheme.mono(size: 11, color: c.textMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              // Index size — the only footprint local-only users can't
              // otherwise see (the usage bar above is account-gated).
              Text(
                _fmtBytes(repo.dbBytes),
                style: RelicTheme.mono(size: 12, color: c.textSecondary),
              ),
              const SizedBox(width: 10),
              _btn(c, 'Open', LucideIcons.folderOpen, onTap: _openDataFolder),
            ],
          ),
        ),
        _exportRow(c),
        _importRow(c),
        _backupRows(c),
        if (_storageMsg.isNotEmpty) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(
                _storageBusy
                    ? LucideIcons.loaderCircle
                    : LucideIcons.circleCheck,
                size: 14,
                color: c.successDim,
              ),
              const SizedBox(width: 8),
              Text(
                _storageMsg,
                style: RelicTheme.mono(size: 11, color: c.textSecondary),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _storageUsage(RelicColors c, dynamic acct) {
    final used = acct.usedBytes as int;
    final quota = acct.quotaBytes as int;
    final metered = quota > 0;
    final frac = metered ? (used / quota).clamp(0.0, 1.0) : 0.0;
    return _row(
      c,
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Storage used',
                  style: RelicTheme.sans(size: 13, color: c.text),
                ),
              ),
              Text(
                metered
                    ? '${_fmtBytes(used)} / ${_fmtBytes(quota)}'
                    : '${_fmtBytes(used)} · unmetered text',
                style: RelicTheme.mono(size: 12, color: c.textSecondary),
              ),
            ],
          ),
          if (metered) ...[
            const SizedBox(height: 9),
            Stack(
              children: [
                Container(
                  height: 6,
                  decoration: BoxDecoration(
                    color: c.track,
                    borderRadius: BorderRadius.circular(Radii.pill),
                  ),
                ),
                FractionallySizedBox(
                  widthFactor: frac,
                  child: Container(
                    height: 6,
                    decoration: BoxDecoration(
                      color: frac > 0.9 ? c.warning : c.accent,
                      borderRadius: BorderRadius.circular(Radii.pill),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _clearCache() async {
    setState(() {
      _storageBusy = true;
      _storageMsg = 'Clearing cache…';
    });
    final freed = await widget.repo.clearLocalBlobCache();
    if (!mounted) return;
    setState(() {
      _storageBusy = false;
      _storageMsg = 'Freed ${_fmtBytes(freed)}.';
    });
  }

  Future<void> _redownload() async {
    setState(() {
      _storageBusy = true;
      _storageMsg = 'Re-downloading images…';
    });
    final n = await widget.repo.redownloadBlobs();
    if (!mounted) return;
    setState(() {
      _storageBusy = false;
      _storageMsg = n == 0
          ? 'Nothing to download. All images are local.'
          : 'Re-downloaded $n image(s).';
    });
  }

  Future<void> _openDataFolder() =>
      revealInFileManager(widget.repo.dataDirPath);

  /// "Export vault" row: pick a folder, confirm (with the include-secrets
  /// choice), then write vault.json + blobs/ with live progress. All state is
  /// inline — settings has no modal infra and doesn't need any here.
  Widget _exportRow(RelicColors c) {
    const last = false; // import + backup rows follow
    return _row(
      c,
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Export vault',
                        style: RelicTheme.sans(size: 13, color: c.text)),
                    const SizedBox(height: 2),
                    Text(
                      'Write every item to a plain JSON file (plus copies of local images and files). Readable by anything, so keep it somewhere you trust. For an encrypted copy, use automatic backup below.',
                      style: RelicTheme.sans(
                          size: 11.5, color: c.textMuted, height: 1.4),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              _btn(c, 'Export…', LucideIcons.download,
                  onTap: _exportBusy ? null : _pickExportDir),
            ],
          ),
          if (_exportConfirming && _exportDir != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: c.surface,
                borderRadius: BorderRadius.circular(Radii.input),
                border: Border.all(color: c.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('To: $_exportDir',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: RelicTheme.mono(size: 11, color: c.textMuted)),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      _Toggle(
                        on: _exportIncludeSecrets,
                        onTap: () => setState(() =>
                            _exportIncludeSecrets = !_exportIncludeSecrets),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Include secret contents (otherwise secrets are exported redacted)',
                          style: RelicTheme.sans(
                              size: 11.5, color: c.textSecondary),
                        ),
                      ),
                      _btn(c, 'Cancel', LucideIcons.x,
                          onTap: () =>
                              setState(() => _exportConfirming = false)),
                      const SizedBox(width: 8),
                      _btn(c, 'Export', LucideIcons.check, onTap: _runExport),
                    ],
                  ),
                ],
              ),
            ),
          ],
          if (_exportMsg.isNotEmpty) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(
                  _exportBusy
                      ? LucideIcons.loaderCircle
                      : LucideIcons.circleCheck,
                  size: 14,
                  color: c.successDim,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_exportMsg,
                      style:
                          RelicTheme.mono(size: 11, color: c.textSecondary)),
                ),
                if (!_exportBusy && _exportPath != null)
                  _btn(c, 'Open folder', LucideIcons.folderOpen,
                      onTap: () => revealInFileManager(_exportPath!)),
              ],
            ),
          ],
        ],
      ),
      last: last,
    );
  }

  Future<void> _pickExportDir() async {
    try {
      final dir = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Choose where to export your vault',
      );
      if (dir == null || dir.isEmpty) return;
      setState(() {
        _exportDir = dir;
        _exportConfirming = true;
        _exportMsg = '';
        _exportPath = null;
      });
    } catch (_) {}
  }

  Future<void> _runExport() async {
    final dir = _exportDir;
    if (dir == null) return;
    setState(() {
      _exportConfirming = false;
      _exportBusy = true;
      _exportMsg = 'Exporting…';
    });
    try {
      final res = await widget.repo.exportVault(
        dir,
        includeSecrets: _exportIncludeSecrets,
        onProgress: (done, total) {
          if (mounted) setState(() => _exportMsg = 'Exporting… $done / $total');
        },
      );
      if (mounted) {
        setState(() {
          _exportBusy = false;
          _exportMsg =
              'Exported ${res.items} items (${res.blobs} files)';
          _exportPath = res.path;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _exportBusy = false;
          _exportMsg = 'Export failed: $e';
        });
      }
    }
  }

  /// Restore a previous export: pick the folder containing vault.json,
  /// confirm, run. Items already in the vault are skipped (idempotent).
  Widget _importRow(RelicColors c) {
    return _row(
      c,
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Import vault',
                        style: RelicTheme.sans(size: 13, color: c.text)),
                    const SizedBox(height: 2),
                    Text(
                      'Restore items from an encrypted backup file or an export folder. Items you already have are skipped.',
                      style: RelicTheme.sans(
                          size: 11.5, color: c.textMuted, height: 1.4),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              _btn(c, 'Backup file…', LucideIcons.fileKey,
                  onTap: _importBusy || _restoreBusy ? null : _pickRestoreFile),
              const SizedBox(width: 8),
              _btn(c, 'Folder…', LucideIcons.upload,
                  onTap: _importBusy || _restoreBusy ? null : _pickImportDir),
            ],
          ),
          if (_restoreConfirming && _restoreFile != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: c.surface,
                borderRadius: BorderRadius.circular(Radii.input),
                border: Border.all(color: c.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('From: $_restoreFile',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: RelicTheme.mono(size: 11, color: c.textMuted)),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _restorePassC,
                          obscureText: true,
                          autocorrect: false,
                          enableSuggestions: false,
                          style: RelicTheme.sans(size: 12.5, color: c.text),
                          decoration: InputDecoration(
                            isDense: true,
                            hintText: 'Backup passphrase',
                            hintStyle:
                                RelicTheme.sans(size: 12.5, color: c.textMuted),
                            filled: true,
                            fillColor: c.inset,
                            border: InputBorder.none,
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 10),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _btn(c, 'Cancel', LucideIcons.x,
                          onTap: () =>
                              setState(() => _restoreConfirming = false)),
                      const SizedBox(width: 8),
                      _btn(c, 'Restore', LucideIcons.check, onTap: _runRestore),
                    ],
                  ),
                ],
              ),
            ),
          ],
          if (_restoreMsg.isNotEmpty) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(
                  _restoreBusy
                      ? LucideIcons.loaderCircle
                      : LucideIcons.circleCheck,
                  size: 14,
                  color: c.successDim,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_restoreMsg,
                      style:
                          RelicTheme.mono(size: 11, color: c.textSecondary)),
                ),
              ],
            ),
          ],
          if (_importConfirming && _importDir != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: c.surface,
                borderRadius: BorderRadius.circular(Radii.input),
                border: Border.all(color: c.border),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text('From: $_importDir',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: RelicTheme.mono(size: 11, color: c.textMuted)),
                  ),
                  _btn(c, 'Cancel', LucideIcons.x,
                      onTap: () => setState(() => _importConfirming = false)),
                  const SizedBox(width: 8),
                  _btn(c, 'Import', LucideIcons.check, onTap: _runImport),
                ],
              ),
            ),
          ],
          if (_importMsg.isNotEmpty) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(
                  _importBusy
                      ? LucideIcons.loaderCircle
                      : LucideIcons.circleCheck,
                  size: 14,
                  color: c.successDim,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_importMsg,
                      style:
                          RelicTheme.mono(size: 11, color: c.textSecondary)),
                ),
              ],
            ),
          ],
        ],
      ),
      last: false,
    );
  }

  Future<void> _pickImportDir() async {
    try {
      final dir = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Choose a Relic export folder (contains vault.json)',
      );
      if (dir == null || dir.isEmpty) return;
      setState(() {
        _importDir = dir;
        _importConfirming = true;
        _importMsg = '';
      });
    } catch (_) {}
  }

  Future<void> _runImport() async {
    final dir = _importDir;
    if (dir == null) return;
    setState(() {
      _importConfirming = false;
      _importBusy = true;
      _importMsg = 'Importing…';
    });
    try {
      final res = await widget.repo.importVault(
        dir,
        onProgress: (done, total) {
          if (mounted) {
            setState(() => _importMsg = 'Importing… $done / $total');
          }
        },
      );
      if (mounted) {
        setState(() {
          _importBusy = false;
          _importMsg = [
            'Imported ${res.imported} items (${res.blobs} files)',
            if (res.skipped > 0) '${res.skipped} already present',
            if (res.failed > 0) '${res.failed} unreadable',
          ].join(' · ');
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _importBusy = false;
          _importMsg = 'Import failed: $e';
        });
      }
    }
  }

  Future<void> _pickRestoreFile() async {
    try {
      final res = await FilePicker.platform.pickFiles(
        dialogTitle: 'Choose a Relic backup file',
        type: FileType.custom,
        allowedExtensions: [BackupFile.ext],
      );
      final path = res?.files.single.path;
      if (path == null || path.isEmpty) return;
      setState(() {
        _restoreFile = path;
        _restoreConfirming = true;
        _restoreMsg = '';
        _restorePassC.clear();
      });
    } catch (_) {}
  }

  Future<void> _runRestore() async {
    final path = _restoreFile;
    if (path == null) return;
    if (_restorePassC.text.isEmpty) {
      setState(() => _restoreMsg = 'Enter the backup passphrase.');
      return;
    }
    setState(() {
      _restoreConfirming = false;
      _restoreBusy = true;
      _restoreMsg = 'Restoring…';
    });
    try {
      final res = await widget.repo.importSealedBackup(
        path,
        _restorePassC.text,
        onProgress: (done, total) {
          if (mounted) {
            setState(() => _restoreMsg = 'Restoring… $done / $total');
          }
        },
      );
      if (mounted) {
        setState(() {
          _restoreBusy = false;
          _restoreMsg = [
            'Restored ${res.imported} items (${res.blobs} files)',
            if (res.skipped > 0) '${res.skipped} already present',
            if (res.failed > 0) '${res.failed} unreadable',
          ].join(' · ');
          _restorePassC.clear();
        });
      }
    } on BackupWrongPassphrase {
      if (mounted) {
        setState(() {
          _restoreBusy = false;
          _restoreConfirming = true; // reopen so they can try again
          _restoreMsg = 'Wrong backup passphrase.';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _restoreBusy = false;
          _restoreMsg = 'Restore failed: $e';
        });
      }
    }
  }

  /// Weekly encrypted backup: one sealed .relicvault file per run, opened
  /// only by the backup passphrase — safe to point at a cloud-synced folder.
  /// First enable walks through folder + passphrase setup inline.
  Widget _backupRows(RelicColors c) {
    final repo = widget.repo;
    final on = repo.autoBackup && repo.backupConfigured;
    return _row(
      c,
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Back up automatically',
                        style: RelicTheme.sans(size: 13, color: c.text)),
                    const SizedBox(height: 2),
                    Text(
                      'Writes a weekly encrypted backup file and keeps the newest 4. Only your backup passphrase opens it, so the folder can safely live in Google Drive, OneDrive or Dropbox.',
                      style: RelicTheme.sans(
                          size: 11.5, color: c.textMuted, height: 1.4),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              _Toggle(
                on: on,
                onTap: () {
                  if (!on && !repo.backupConfigured) {
                    _openBackupSetup();
                    return;
                  }
                  repo.setAutoBackup(!on);
                  if (mounted) setState(() {});
                },
              ),
            ],
          ),
          if (_backupSetupOpen) _backupSetupPanel(c),
          if (on && !_backupSetupOpen) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Text(
                    repo.backupDir ?? 'No folder chosen',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: RelicTheme.mono(size: 11, color: c.textMuted),
                  ),
                ),
                const SizedBox(width: 8),
                _btn(c, 'Change', LucideIcons.folderOpen, onTap: () async {
                  final dir = await FilePicker.platform.getDirectoryPath(
                    dialogTitle: 'Choose where backups are written',
                  );
                  if (dir == null || dir.isEmpty) return;
                  repo.setBackupDir(dir);
                  if (mounted) setState(() {});
                }),
                const SizedBox(width: 8),
                _btn(c, _backupBusy ? 'Backing up…' : 'Back up now',
                    LucideIcons.databaseBackup,
                    onTap: _backupBusy ? null : _runBackupNow),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              repo.backupStatus ??
                  (repo.lastBackupAt == 0
                      ? 'Last backed up: never'
                      : [
                          'Last backed up ${formatCaptureDate(repo.lastBackupAt)}',
                          if (repo.lastBackupSummary.isNotEmpty)
                            repo.lastBackupSummary,
                        ].join(' · ')),
              style: RelicTheme.mono(
                  size: 10.5,
                  color: repo.backupStatus != null
                      ? c.dangerText
                      : c.textFaintest),
            ),
            if (repo.backupNeedsReauth) _backupReauthPanel(c),
            if (_backupMsg.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(_backupMsg,
                  style: RelicTheme.mono(size: 10.5, color: c.textSecondary)),
            ],
            const SizedBox(height: 6),
            _accentLink(c, 'Change backup passphrase', _openBackupSetup),
          ],
        ],
      ),
      last: _storageMsg.isEmpty,
    );
  }

  /// Small accent text action, matching the "Clear learned ranking" pattern.
  Widget _accentLink(RelicColors c, String label, VoidCallback onTap) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Text(label,
            style: RelicTheme.sans(size: 11.5, color: c.accent)),
      ),
    );
  }

  Future<void> _openBackupSetup() async {
    var dir = widget.repo.backupDir;
    if (dir == null) {
      // Default beside the user's documents; they can change it in the panel.
      try {
        final docs = await getApplicationDocumentsDirectory();
        dir = '${docs.path}${Platform.pathSeparator}Relic Backups';
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _backupSetupOpen = true;
      _backupSetupErr = '';
      _backupSetupDir = dir;
      _bkPassC.clear();
      _bkConfirmC.clear();
    });
  }

  /// Inline setup: folder + passphrase (with strength meter) + confirm.
  /// Doubles as "change passphrase" — a new key is minted either way; files
  /// already written keep opening with the passphrase they were sealed under.
  Widget _backupSetupPanel(RelicColors c) {
    final changing = widget.repo.backupConfigured;
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(Radii.input),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'To: ${_backupSetupDir ?? 'No folder chosen'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: RelicTheme.mono(size: 11, color: c.textMuted),
                ),
              ),
              _btn(c, 'Change', LucideIcons.folderOpen, onTap: () async {
                final dir = await FilePicker.platform.getDirectoryPath(
                  dialogTitle: 'Choose where backups are written',
                );
                if (dir == null || dir.isEmpty) return;
                setState(() => _backupSetupDir = dir);
              }),
            ],
          ),
          const SizedBox(height: 12),
          VaultPassphraseField(
            controller: _bkPassC,
            confirmController: _bkConfirmC,
            hint: changing ? 'New backup passphrase' : 'Backup passphrase',
          ),
          TextField(
            controller: _bkConfirmC,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            style: RelicTheme.sans(size: 12.5, color: c.text),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Repeat the backup passphrase',
              hintStyle: RelicTheme.sans(size: 12.5, color: c.textMuted),
              filled: true,
              fillColor: c.inset,
              border: InputBorder.none,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'This passphrase is separate from your vault passphrase and never leaves this computer. If you lose it, your backup files cannot be opened.',
            style:
                RelicTheme.sans(size: 11.5, color: c.textMuted, height: 1.4),
          ),
          if (_backupSetupErr.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(_backupSetupErr,
                style: RelicTheme.sans(size: 11.5, color: c.dangerText)),
          ],
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              _btn(c, 'Cancel', LucideIcons.x,
                  onTap: _backupSetupBusy
                      ? null
                      : () => setState(() => _backupSetupOpen = false)),
              const SizedBox(width: 8),
              _btn(
                  c,
                  _backupSetupBusy
                      ? 'Backing up…'
                      : (changing ? 'Change passphrase' : 'Turn on'),
                  LucideIcons.check,
                  onTap: _backupSetupBusy ? null : _confirmBackupSetup),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _confirmBackupSetup() async {
    final dir = _backupSetupDir;
    final pass = _bkPassC.text;
    if (dir == null || dir.isEmpty) {
      setState(() => _backupSetupErr = 'Choose a folder for your backups.');
      return;
    }
    if (pass.isEmpty) {
      setState(() => _backupSetupErr = 'Choose a backup passphrase.');
      return;
    }
    if (pass != _bkConfirmC.text) {
      setState(() => _backupSetupErr = "Passphrases don't match.");
      return;
    }
    setState(() {
      _backupSetupBusy = true;
      _backupSetupErr = '';
    });
    final err = await widget.repo.setupBackup(dir: dir, passphrase: pass);
    if (!mounted) return;
    setState(() {
      _backupSetupBusy = false;
      if (err != null) {
        _backupSetupErr = err;
      } else {
        _backupSetupOpen = false;
        _backupMsg = 'Backed up.';
        _bkPassC.clear();
        _bkConfirmC.clear();
      }
    });
  }

  /// Shown when the stored backup key is gone (cleared Credential Manager,
  /// new user profile): re-enter the passphrase to resume scheduled backups.
  Widget _backupReauthPanel(RelicColors c) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(Radii.input),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _bkReauthC,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              style: RelicTheme.sans(size: 12.5, color: c.text),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Backup passphrase',
                hintStyle: RelicTheme.sans(size: 12.5, color: c.textMuted),
                filled: true,
                fillColor: c.inset,
                border: InputBorder.none,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              ),
            ),
          ),
          const SizedBox(width: 8),
          _btn(c, _bkReauthBusy ? 'Checking…' : 'Resume',
              LucideIcons.lockOpen,
              onTap: _bkReauthBusy
                  ? null
                  : () async {
                      setState(() => _bkReauthBusy = true);
                      final ok = await widget.repo
                          .reauthorizeBackup(_bkReauthC.text);
                      if (!mounted) return;
                      setState(() {
                        _bkReauthBusy = false;
                        if (ok) {
                          _bkReauthC.clear();
                          _backupMsg = 'Backups resumed.';
                        } else {
                          _backupMsg = 'Wrong backup passphrase.';
                        }
                      });
                    }),
        ],
      ),
    );
  }

  Future<void> _runBackupNow() async {
    setState(() {
      _backupBusy = true;
      _backupMsg = '';
    });
    final err = await widget.repo.runBackupNow();
    if (mounted) {
      setState(() {
        _backupBusy = false;
        _backupMsg = err ?? 'Backed up.';
      });
    }
  }

  /// Where the viewer's "Save" writes blobs. Defaults to the OS Downloads
  /// folder; "Change" opens a native folder picker, "Reset" clears the override.
  Widget _saveLocationRow(RelicColors c) {
    final loc = widget.repo.saveDir;
    return _row(
      c,
      Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Save location',
                  style: RelicTheme.sans(size: 13, color: c.text),
                ),
                const SizedBox(height: 2),
                Text(
                  loc ?? 'Downloads',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: RelicTheme.mono(size: 11, color: c.textMuted),
                ),
                const SizedBox(height: 2),
                Text(
                  'Where “Save” writes images and files from the viewer.',
                  style: RelicTheme.sans(size: 11.5, color: c.textMuted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          if (loc != null) ...[
            _btn(
              c,
              'Reset',
              LucideIcons.rotateCcw,
              onTap: () => widget.repo.setSaveDir(null),
            ),
            const SizedBox(width: 10),
          ],
          _btn(c, 'Change', LucideIcons.folderOpen, onTap: _chooseSaveDir),
        ],
      ),
    );
  }

  Future<void> _chooseSaveDir() async {
    try {
      final dir = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Choose where Relic saves files',
      );
      if (dir != null && dir.isNotEmpty) widget.repo.setSaveDir(dir);
    } catch (_) {}
  }

  // --- About ---

  Widget _aboutPane(RelicColors c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel(c, 'About'),
        const SizedBox(height: 6),
        Row(
          children: [
            const RelicIcon(size: 32),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Relic',
                  style: RelicTheme.sans(
                    size: 18,
                    weight: FontWeight.w600,
                    color: c.text,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Never lose anything you’ve ever copied.',
                  style: RelicTheme.sans(size: 12, color: c.textMuted),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 8),
        _aboutRow(c, 'Version', _appVersion.isEmpty ? '—' : _appVersion),
        _aboutRow(c, 'Encryption', 'End-to-end · XChaCha20-Poly1305'),
        _aboutRow(c, 'Local index', 'SQLite + FTS5, on this device'),
        _aboutRow(
          c,
          'Platform',
          Platform.isMacOS ? 'macOS desktop' : 'Windows desktop',
          last: true,
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            _btn(
              c,
              _updateBusy ? 'Checking…' : 'Check for updates',
              LucideIcons.refreshCw,
              // Tappable even when the version is unknown: the check now
              // reports that as a failure with a reason, which beats a dead
              // button that looks like nothing happened.
              onTap: _updateBusy ? null : _checkUpdates,
            ),
            const SizedBox(width: 10),
            _btn(c, 'Open logs', LucideIcons.fileText, onTap: _openLogs),
            const SizedBox(width: 10),
            _btn(
              c,
              _diagCopied ? 'Copied' : 'Copy diagnostics',
              _diagCopied ? LucideIcons.check : LucideIcons.clipboardCopy,
              onTap: _copyDiagnostics,
            ),
          ],
        ),
        if (_updateMsg.isNotEmpty) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              Flexible(
                child: Text(
                  _updateMsg,
                  style: RelicTheme.sans(
                    size: 12,
                    color: _updateAvailable != null
                        ? c.accent
                        : _updateFailed
                            ? c.warning
                            : c.textMuted,
                  ),
                ),
              ),
              if (_updateAvailable != null) ...[
                const SizedBox(width: 12),
                _btn(
                  c,
                  'Update now',
                  LucideIcons.download,
                  accent: true,
                  onTap: _updateInstalling ? null : _installUpdate,
                ),
              ] else if (_updateFailed) ...[
                const SizedBox(width: 12),
                _btn(
                  c,
                  'Open download page',
                  LucideIcons.externalLink,
                  onTap: () => _openUrl('https://relic.space/download/windows'),
                ),
              ],
            ],
          ),
          // What's in it: the manifest's release notes, finally shown at the
          // moment the user decides to update.
          if (_updateAvailable?.notes case final notes?
              when notes.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Text(
                notes.trim(),
                style: RelicTheme.sans(
                    size: 11.5, color: c.textMuted, height: 1.45),
              ),
            ),
          ],
        ],
        const SizedBox(height: 16),
        Text(
          'Your content is encrypted with a key only you hold. The operator stores ciphertext and minimal metadata and cannot decrypt it.',
          style: RelicTheme.sans(size: 11.5, color: c.textMuted, height: 1.5),
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 18,
          runSpacing: 8,
          children: [
            _accentLink(c, 'Website',
                () => _openUrl('https://relic.space')),
            _accentLink(c, 'Contact support',
                () => _openUrl('mailto:support@relic.space')),
            _accentLink(c, 'Privacy policy',
                () => _openUrl('https://relic.space/legal/privacy')),
            _accentLink(c, 'Terms',
                () => _openUrl('https://relic.space/legal/terms')),
            _accentLink(c, 'Open-source licenses', _openLicenses),
          ],
        ),
      ],
    );
  }

  /// Flutter's stock license index (auto-collects every pub dependency's
  /// LICENSE), pushed under the app palette so it doesn't flash white.
  void _openLicenses() {
    final c = RelicTheme.of(context);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Theme(
          data: materialThemeFor(c),
          child: LicensePage(
            applicationName: 'Relic',
            applicationVersion: _appVersion,
          ),
        ),
      ),
    );
  }

  Future<void> _copyDiagnostics() async {
    final line = [
      'Relic ${_appVersion.isEmpty ? '?' : _appVersion}',
      Platform.operatingSystemVersion.trim(),
      'device "${widget.repo.deviceName.isEmpty ? (Platform.environment['COMPUTERNAME'] ?? '?') : widget.repo.deviceName}"',
    ].join(' · ');
    await Clipboard.setData(ClipboardData(text: line));
    if (!mounted) return;
    setState(() => _diagCopied = true);
    Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _diagCopied = false);
    });
  }

  Future<void> _checkUpdates() async {
    if (_updateBusy) return;
    setState(() {
      _updateBusy = true;
      _updateMsg = '';
      _updateAvailable = null;
      _updateFailed = false;
    });
    final res = await checkForUpdate(_appVersion);
    if (!mounted) return;
    setState(() {
      _updateBusy = false;
      _updateAvailable = res.info;
      _updateFailed = res.isFailed;
      _updateMsg = switch (res.outcome) {
        UpdateOutcome.available => 'Update available: ${res.info!.version}',
        UpdateOutcome.upToDate => "You're on the latest version.",
        UpdateOutcome.failed =>
          "Couldn't check for updates. ${res.reason ?? ''}".trim(),
      };
    });
  }

  /// One-click in-place update: download → verify → silent installer →
  /// the app exits and the new build relaunches into the tray by itself.
  /// Anything that can't self-install (no sha256 in the manifest, non-
  /// Windows, download failure) falls back to the browser download page.
  Future<void> _installUpdate() async {
    final info = _updateAvailable;
    if (info == null || _updateInstalling) return;
    setState(() => _updateInstalling = true);
    try {
      await installUpdate(info, onStatus: (s) {
        if (mounted) setState(() => _updateMsg = s);
      }); // no return on success: the app exits and relaunches
    } catch (_) {
      if (mounted) {
        setState(() {
          _updateInstalling = false;
          _updateMsg = 'Could not update in place. Opening the download page.';
        });
      }
      await _openUrl(info.url);
    }
  }

  Future<void> _openLogs() async {
    try {
      await revealInFileManager(crashLogDir());
    } catch (_) {}
  }

  Future<bool> _openUrl(String url) async {
    try {
      return await launchUrl(Uri.parse(url),
          mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }

  // --- billing (Upgrade / Manage) ---
  bool _showBilling(String tier) =>
      tier == 'Free' || tier == 'Pro' || tier == 'Max';

  Future<List<BillingPlan>> _loadPlans() =>
      _plansFuture ??= widget.repo.billingPlans();

  Future<void> _openCheckout(String priceId) =>
      _billingAction(() => widget.repo.checkoutUrl(priceId));

  Future<void> _openPortal() => _billingAction(widget.repo.portalUrl);

  /// Run a billing call with the busy guard and error surfacing: a failure
  /// shows up inline under the billing row instead of dying silently.
  Future<void> _billingAction(Future<String?> Function() link) async {
    if (_billingBusy) return;
    setState(() {
      _billingBusy = true;
      _billingError = null;
    });
    String? url, error;
    try {
      url = await link();
      if (url == null) error = 'Billing is unavailable while sync is off.';
    } on BillingException catch (e) {
      error = e.message;
    }
    if (!mounted) return;
    setState(() {
      _billingBusy = false;
      _billingError = error;
    });
    if (url != null) {
      if (await _openUrl(url)) {
        widget.onBillingOpened?.call();
      } else if (mounted) {
        setState(() => _billingError = 'Could not open your browser.');
      }
    }
  }

  Widget _billingActions(RelicColors c, String tier) {
    final body = _billingBody(c, tier);
    if (_billingError == null) return body;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        body,
        const SizedBox(height: 6),
        Text(
          _billingError!,
          style: RelicTheme.sans(size: 11.5, color: c.dangerText),
        ),
      ],
    );
  }

  Widget _billingBody(RelicColors c, String tier) {
    if (tier == 'Pro' || tier == 'Max') {
      return Row(
        children: [
          Expanded(
            child: Text(
              'Manage your plan, payment method, invoices, or cancel.',
              style: RelicTheme.sans(size: 11.5, color: c.textMuted),
            ),
          ),
          const SizedBox(width: 16),
          _btn(
            c,
            _billingBusy ? 'Opening…' : 'Manage',
            LucideIcons.creditCard,
            accent: true,
            onTap: _billingBusy ? null : _openPortal,
          ),
        ],
      );
    }
    // Free tier → show upgrade options pulled from the Worker.
    return FutureBuilder<List<BillingPlan>>(
      future: _loadPlans(),
      builder: (ctx, snap) {
        final plans = snap.data ?? const <BillingPlan>[];
        if (plans.isEmpty) {
          return Text(
            'Upgrade for more storage and an unlimited vault.',
            style: RelicTheme.sans(size: 11.5, color: c.textMuted),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Upgrade: more storage, unlimited vault',
              style: RelicTheme.sans(size: 13, color: c.text),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final p in plans)
                  _btn(
                    c,
                    p.label,
                    LucideIcons.zap,
                    accent: p.tier == 'pro' && p.interval == 'month',
                    onTap: _billingBusy ? null : () => _openCheckout(p.priceId),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _aboutRow(RelicColors c, String k, String v, {bool last = false}) =>
      _row(
        c,
        Row(
          children: [
            Expanded(
              child: Text(k, style: RelicTheme.sans(size: 13, color: c.text)),
            ),
            Text(v, style: RelicTheme.mono(size: 11.5, color: c.textSecondary)),
          ],
        ),
        last: last,
      );

  // --- shared building blocks ---

  void _openDevices(BuildContext ctx) {
    Navigator.of(ctx).push(MaterialPageRoute(
      builder: (_) => DevicesScreen(
        bearer: () async => widget.repo.syncBearer,
        selfLabel: Platform.localHostname,
        masterKey: widget.repo.masterKey,
        accountId: widget.repo.supabaseUserId,
        onRenameThisDevice: widget.onRenameThisDevice,
        onUpgrade: widget.onUpgrade,
      ),
    ));
  }

  void _openSecurity(BuildContext ctx) {
    final mk = widget.repo.masterKey;
    if (mk == null) return;
    Navigator.of(ctx).push(MaterialPageRoute(
      builder: (_) => SecurityScreen(
        masterKey: mk,
        accountEmail: widget.repo.accountEmail ?? '',
        onChangePassphrase: widget.repo.changePassphrase,
        onChangeEmail:
            widget.repo.isSupabase ? widget.repo.changeEmail : null,
        onSignOutEverywhere:
            widget.repo.isSupabase ? widget.repo.signOutEverywhere : null,
        // Raw disconnect (the Disconnect button owns the confirmation); the
        // sign-out-everywhere follow-through has already confirmed by the time
        // it calls this.
        onDisconnect: widget.onDisconnect,
        onDeleteAccount:
            widget.repo.isSupabase ? widget.repo.deleteAccount : null,
      ),
    ));
  }

  /// Confirm before disconnecting this computer. Mirrors the mobile flow: the
  /// button owns the dialog so the host callback stays a raw disconnect (which
  /// the Security screen's sign-out-everywhere follow-through also reuses).
  /// "Clear all history": bulk-delete every unpromoted item. The popup's
  /// Ctrl+A + Delete only covers the loaded window; this is the real one.
  Widget _clearHistoryRow(RelicColors c) {
    final repo = widget.repo;
    final n = repo.historyCount;
    return _row(
      c,
      Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Clear all history',
                    style: RelicTheme.sans(size: 13, color: c.text)),
                const SizedBox(height: 2),
                Text(
                  'Deletes every unsaved history item on this device${repo.syncEnabled ? ' and your synced devices' : ''}. Saved (Vault) items are kept.',
                  style: RelicTheme.sans(
                      size: 11.5, color: c.textMuted, height: 1.4),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Text(
            _fmtCount(n),
            style: RelicTheme.mono(size: 12, color: c.textSecondary),
          ),
          const SizedBox(width: 10),
          _btn(
            c,
            'Clear…',
            LucideIcons.trash2,
            danger: true,
            onTap: _storageBusy || n == 0 ? null : _confirmClearHistory,
          ),
        ],
      ),
    );
  }

  Future<void> _confirmClearHistory() async {
    final c = RelicTheme.of(context);
    final n = widget.repo.historyCount;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => RelicTheme(
        colors: c,
        child: AlertDialog(
          backgroundColor: c.panel,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.card),
            side: BorderSide(color: c.borderStrong),
          ),
          title: Text('Delete ${_fmtCount(n)} history items?',
              style: RelicTheme.sans(
                  size: 17, weight: FontWeight.w600, color: c.text)),
          content: Text(
            'Everything not saved to your Vault is deleted${widget.repo.syncEnabled ? ' from this device and, as it syncs, from your other devices' : ''}. This can\'t be undone.',
            style: RelicTheme.sans(
                size: 13.5, color: c.textSecondary, height: 1.5),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dctx, false),
              child: Text('Cancel',
                  style: RelicTheme.sans(size: 13.5, color: c.textSecondary)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dctx, true),
              child: Text('Delete history',
                  style: RelicTheme.sans(
                      size: 13.5, weight: FontWeight.w600, color: c.danger)),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _storageBusy = true;
      _storageMsg = 'Clearing history…';
    });
    final cleared = await widget.repo.clearHistory();
    if (!mounted) return;
    setState(() {
      _storageBusy = false;
      _storageMsg = 'Cleared ${_fmtCount(cleared)} items.';
    });
  }

  Future<void> _confirmDisconnect() async {
    final onDisconnect = widget.onDisconnect;
    if (onDisconnect == null) return;
    final c = RelicTheme.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => RelicTheme(
        colors: c,
        child: AlertDialog(
          backgroundColor: c.panel,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.card),
            side: BorderSide(color: c.borderStrong),
          ),
          title: Text('Disconnect this computer?',
              style:
                  RelicTheme.sans(size: 17, weight: FontWeight.w600, color: c.text)),
          content: Text(
            'Sync stops and the vault key is removed from this computer. To reconnect you will need your vault passphrase or your recovery kit. Your local history stays on this computer.',
            style:
                RelicTheme.sans(size: 13.5, color: c.textSecondary, height: 1.5),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dctx, false),
              child: Text('Cancel',
                  style: RelicTheme.sans(size: 13.5, color: c.textSecondary)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dctx, true),
              child: Text('Disconnect',
                  style: RelicTheme.sans(
                      size: 13.5, weight: FontWeight.w600, color: c.danger)),
            ),
          ],
        ),
      ),
    );
    if (ok == true) onDisconnect();
  }

  /// Confirm before switching accounts. Same warning as Disconnect, but on
  /// confirm the host disconnects and re-opens onboarding on the sign-in step.
  Future<void> _confirmSwitchAccount() async {
    final onSwitch = widget.onSwitchAccount;
    if (onSwitch == null) return;
    final c = RelicTheme.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => RelicTheme(
        colors: c,
        child: AlertDialog(
          backgroundColor: c.panel,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.card),
            side: BorderSide(color: c.borderStrong),
          ),
          title: Text('Switch account?',
              style: RelicTheme.sans(
                  size: 17, weight: FontWeight.w600, color: c.text)),
          content: Text(
            'Sync stops and the vault key is removed from this computer, then you sign in to another account. To reconnect this one you will need its vault passphrase or recovery kit. Your local history stays on this computer.',
            style: RelicTheme.sans(size: 13.5, color: c.textSecondary, height: 1.5),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dctx, false),
              child: Text('Cancel',
                  style: RelicTheme.sans(size: 13.5, color: c.textSecondary)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dctx, true),
              child: Text('Switch account',
                  style: RelicTheme.sans(
                      size: 13.5, weight: FontWeight.w600, color: c.accent)),
            ),
          ],
        ),
      ),
    );
    if (ok == true) onSwitch();
  }

  /// Shown after a bind detected an account switch: the previous account's
  /// items were held back instead of auto-uploading, and are tucked away out of
  /// the history list so they don't read as this account's broken sync. The
  /// user decides — bring them into this account, leave them tucked away, or
  /// delete them from the device.
  Widget _mergeOfferRow(RelicColors c) {
    final n = widget.repo.heldCount;
    // After "keep them tucked away" the offer stops asking, but the items are
    // still here — the row stays (quieter, minus the dismiss button) so the
    // decision can still be changed instead of becoming a dead end.
    final asking = widget.repo.mergeOfferCount > 0;
    return _row(
      c,
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            asking ? 'Items from before this sign-in' : 'Tucked-away items',
            style: RelicTheme.sans(
              size: 13,
              weight: FontWeight.w500,
              color: c.text,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            asking
                ? '${_fmtCount(n)} items on this device belong to a different '
                    'account, so they are tucked away and hidden from your '
                    'history. Nothing has been uploaded here.'
                : '${_fmtCount(n)} items from another account are tucked away '
                    'on this device. They come back on their own if you sign '
                    'back into that account.',
            style: RelicTheme.sans(
              size: 11.5,
              color: c.textMuted,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _btn(
                c,
                'Upload all',
                LucideIcons.upload,
                accent: asking,
                onTap: _confirmMergeUpload,
              ),
              if (asking) ...[
                const SizedBox(width: 8),
                _btn(
                  c,
                  'Keep them tucked away',
                  LucideIcons.eyeOff,
                  onTap: () => setState(widget.repo.dismissMergeOffer),
                ),
              ],
              const SizedBox(width: 8),
              _btn(
                c,
                'Delete from device',
                LucideIcons.trash2,
                danger: true,
                onTap: _confirmMergeDelete,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _confirmMergeUpload() async {
    final c = RelicTheme.of(context);
    final n = widget.repo.heldCount;
    final who = widget.repo.accountEmail ?? 'this account';
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => RelicTheme(
        colors: c,
        child: AlertDialog(
          backgroundColor: c.panel,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.card),
            side: BorderSide(color: c.borderStrong),
          ),
          title: Text('Upload ${_fmtCount(n)} items?',
              style: RelicTheme.sans(
                  size: 17, weight: FontWeight.w600, color: c.text)),
          content: Text(
            'The tucked-away items come back into your history and upload to '
            '$who, counting against its storage. If they belong to someone '
            'else\'s account, leave them tucked away instead.',
            style:
                RelicTheme.sans(size: 13.5, color: c.textSecondary, height: 1.5),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dctx, false),
              child: Text('Cancel',
                  style: RelicTheme.sans(size: 13.5, color: c.textSecondary)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dctx, true),
              child: Text('Upload',
                  style: RelicTheme.sans(
                      size: 13.5, weight: FontWeight.w600, color: c.accent)),
            ),
          ],
        ),
      ),
    );
    if (ok == true && mounted) {
      await widget.repo.acceptMergeOffer();
      if (mounted) setState(() {});
    }
  }

  /// The third option on the merge offer: the previous account's items are gone
  /// from this machine for good. Confirm-gated like clearing history, and worth
  /// spelling out that signing back in won't bring them back here.
  Future<void> _confirmMergeDelete() async {
    final c = RelicTheme.of(context);
    final n = widget.repo.heldCount;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => RelicTheme(
        colors: c,
        child: AlertDialog(
          backgroundColor: c.panel,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.card),
            side: BorderSide(color: c.borderStrong),
          ),
          title: Text('Delete ${_fmtCount(n)} items from this device?',
              style: RelicTheme.sans(
                  size: 17, weight: FontWeight.w600, color: c.text)),
          content: Text(
            'These items are erased from this computer. They are not touched '
            'on the account they came from, so any device still signed into '
            'that account keeps its copy. This can\'t be undone here.',
            style:
                RelicTheme.sans(size: 13.5, color: c.textSecondary, height: 1.5),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dctx, false),
              child: Text('Cancel',
                  style: RelicTheme.sans(size: 13.5, color: c.textSecondary)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dctx, true),
              child: Text('Delete',
                  style: RelicTheme.sans(
                      size: 13.5, weight: FontWeight.w600, color: c.danger)),
            ),
          ],
        ),
      ),
    );
    if (ok == true && mounted) {
      await widget.repo.deleteMergeOffer();
      if (mounted) setState(() {});
    }
  }

  Widget _btn(
    RelicColors c,
    String label,
    IconData icon, {
    bool accent = false,
    bool danger = false,
    VoidCallback? onTap,
  }) {
    if (accent) {
      return PrimaryButton(icon: icon, label: label, onTap: onTap);
    }
    return GhostButton(
      icon: icon,
      label: label,
      style: danger ? GhostStyle.danger : GhostStyle.ghost,
      onTap: onTap,
    );
  }

  Future<void> _openBlockPicker() async {
    setState(() {
      _blockPickerOpen = true;
      _blockPickerLoading = true;
    });
    final apps = await runningApps();
    if (!mounted) return;
    setState(() {
      _blockPickerApps = apps;
      _blockPickerLoading = false;
    });
  }

  /// Blocklist fallback for programs that aren't running: pick the .exe
  /// itself; the stored key is the file's stem, same as the watcher reads.
  /// Windows-only — a macOS key comes from the .app's bundle id, which no file
  /// pick can give us, so the Mac relies on the running-apps list.
  Future<void> _browseBlockExe() async {
    try {
      final res = await FilePicker.platform.pickFiles(
        dialogTitle: 'Choose a program to never capture from',
        type: FileType.custom,
        allowedExtensions: ['exe'],
      );
      final path = res?.files.single.path;
      if (path == null || path.isEmpty) return;
      final base = path.split(RegExp(r'[\\/]')).last;
      widget.repo.addCaptureBlock(base); // normExe strips .exe + lowercases
      if (mounted) setState(() {});
    } catch (_) {}
  }

  /// "Never capture from" — a chip list of blocked apps plus a picker of
  /// what's open right now (same app-key identity the watcher gate uses),
  /// with browse-for-.exe covering programs that aren't running on Windows.
  Widget _blocklistSection(RelicColors c) {
    final blocked = widget.repo.captureBlocklist.toList()..sort();
    final pickable = _blockPickerApps
        .where((a) => !widget.repo.captureBlocklist.contains(a.key))
        .toList();
    return _row(
      c,
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Never capture from',
              style: RelicTheme.sans(
                  size: 13.5, weight: FontWeight.w500, color: c.text)),
          const SizedBox(height: 3),
          Text(
            'Copies from these apps never enter Relic. Good for password managers.',
            style: RelicTheme.sans(size: 11.5, color: c.textMuted),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final t in blocked)
                Container(
                  padding: const EdgeInsets.fromLTRB(9, 4, 6, 4),
                  decoration: BoxDecoration(
                    color: c.surface,
                    borderRadius: BorderRadius.circular(Radii.chip),
                    border: c.isDark ? null : Border.all(color: c.border),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(t,
                          style: RelicTheme.mono(size: 11.5, color: c.text)),
                      const SizedBox(width: 5),
                      Hoverable(
                        onTap: () => widget.repo.removeCaptureBlock(t),
                        builder: (context, hovered) => Icon(
                          LucideIcons.x,
                          size: 12,
                          color: hovered ? c.dangerText : c.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              if (!_blockPickerOpen)
                _btn(c, 'Add app…', LucideIcons.plus,
                    onTap: _openBlockPicker),
            ],
          ),
          if (_blockPickerOpen) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: c.surface,
                borderRadius: BorderRadius.circular(Radii.input),
                border: Border.all(color: c.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text('Open right now',
                            style: RelicTheme.sans(
                                size: 11.5, color: c.textMuted)),
                      ),
                      Hoverable(
                        onTap: _blockPickerLoading ? null : _openBlockPicker,
                        builder: (context, hovered) => Icon(
                            LucideIcons.refreshCw,
                            size: 13,
                            color: hovered ? c.text : c.textMuted),
                      ),
                      const SizedBox(width: 10),
                      if (Platform.isWindows) ...[
                        _btn(c, 'Browse…', LucideIcons.folderOpen,
                            onTap: _browseBlockExe),
                        const SizedBox(width: 8),
                      ],
                      _btn(c, 'Done', LucideIcons.x,
                          onTap: () =>
                              setState(() => _blockPickerOpen = false)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (_blockPickerLoading)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Text('Looking at open windows…',
                          style: RelicTheme.mono(
                              size: 11, color: c.textFaintest)),
                    )
                  else if (pickable.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Text(
                          Platform.isWindows
                              ? 'Nothing else is open. Use Browse to pick a program file.'
                              : 'Nothing else is open. Open the app you want to block, then refresh.',
                          style: RelicTheme.sans(
                              size: 11.5, color: c.textMuted)),
                    )
                  else
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 210),
                      child: SingleChildScrollView(
                        child: Column(
                          children: [
                            for (final a in pickable)
                              Hoverable(
                                onTap: () {
                                  widget.repo.addCaptureBlock(a.key);
                                  setState(() {});
                                },
                                builder: (context, hovered) => Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: hovered
                                        ? c.surfaceHover
                                        : const Color(0x00000000),
                                    borderRadius:
                                        BorderRadius.circular(Radii.chip),
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(LucideIcons.appWindow,
                                          size: 13, color: c.textMuted),
                                      const SizedBox(width: 8),
                                      Text(a.key,
                                          style: RelicTheme.mono(
                                              size: 11.5, color: c.text)),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Text(a.title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: RelicTheme.sans(
                                                size: 11,
                                                color: c.textFaintest)),
                                      ),
                                      if (hovered)
                                        Icon(LucideIcons.plus,
                                            size: 13, color: c.accent),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
      last: true,
    );
  }

  Widget _deviceField(RelicColors c) => GestureDetector(
    onTap: _deviceF.requestFocus,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(Radii.input),
        border: Border.all(color: c.border),
      ),
      child: TextField(
        controller: _deviceCtl,
        focusNode: _deviceF,
        style: RelicTheme.sans(size: 13, color: c.text),
        cursorColor: c.accent,
        maxLines: 1,
        decoration: const InputDecoration(
            isCollapsed: true, border: InputBorder.none),
        onSubmitted: widget.repo.setDeviceName,
      ),
    ),
  );

  Widget _sectionLabel(RelicColors c, String t) => Padding(
    padding: const EdgeInsets.fromLTRB(0, 18, 0, 2),
    child: Text(
      t.toUpperCase(),
      style: RelicTheme.mono(size: 10, color: c.accentDeep, letterSpacing: 1.2),
    ),
  );

  Widget _row(RelicColors c, Widget child, {bool last = false}) => Container(
    padding: const EdgeInsets.symmetric(vertical: 13),
    decoration: BoxDecoration(
      border: last ? null : Border(bottom: BorderSide(color: c.border)),
    ),
    child: child,
  );

  Widget _toggleRow(
    RelicColors c,
    String title,
    bool value,
    ValueChanged<bool> onChanged, {
    String? sub,
    bool last = false,
    bool recommended = false,
    IconData? leading,
    bool leadingTx = false,
  }) {
    return _row(
      c,
      Row(
        children: [
          if (leadingTx) ...[
            Text(
              'Aa',
              style: RelicTheme.mono(
                size: 14,
                weight: FontWeight.w700,
                color: c.textSecondary,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(width: 10),
          ] else if (leading != null) ...[
            Icon(leading, size: 17, color: c.textSecondary),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      title,
                      style: RelicTheme.sans(size: 13, color: c.text),
                    ),
                    if (recommended) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: c.secretBg,
                          borderRadius: BorderRadius.circular(5),
                          border: Border.all(
                            color: c.secret.withValues(alpha: 0.35),
                          ),
                        ),
                        child: Text(
                          'recommended',
                          style: RelicTheme.mono(size: 9, color: c.secret),
                        ),
                      ),
                    ],
                  ],
                ),
                if (sub != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    sub,
                    style: RelicTheme.sans(size: 11.5, color: c.textMuted),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 16),
          _Toggle(on: value, onTap: () => onChanged(!value)),
        ],
      ),
      last: last,
    );
  }

  /// macOS only: the Accessibility (TCC) grant. Windows synthesizes keystrokes
  /// with no permission at all, so this whole block is a Mac concern, gated the
  /// same way the Windows-only rows in this pane are.
  Widget _accessibilitySection(RelicColors c) {
    final trusted = _axTrusted;
    final (status, tone) = switch (trusted) {
      null => ('Checking…', c.textMuted),
      true => ('Allowed', c.accent),
      false => ('Not allowed yet', c.warning),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel(c, 'Accessibility'),
        _row(
          c,
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    LucideIcons.accessibility,
                    size: 17,
                    color: c.textSecondary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Let Relic paste for you',
                      style: RelicTheme.sans(size: 13, color: c.text),
                    ),
                  ),
                  Text(status, style: RelicTheme.mono(size: 10.5, color: tone)),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'macOS asks permission before any app can press keys for you. '
                'Relic uses it to paste the item you pick straight into the app '
                'you were just in, and to grab your selection when you press '
                'the save & annotate hotkey.',
                style: RelicTheme.sans(
                  size: 11.5,
                  color: c.textMuted,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Everything else works without it. Picking an item still copies '
                'it, you just press ⌘V yourself.',
                style: RelicTheme.sans(
                  size: 11.5,
                  color: c.textMuted,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  _btn(
                    c,
                    trusted == true
                        ? 'Open Accessibility settings'
                        : 'Allow Relic to paste',
                    LucideIcons.accessibility,
                    accent: trusted == false,
                    onTap: _axBusy ? null : _grantAccessibility,
                  ),
                  const SizedBox(width: 10),
                  _btn(
                    c,
                    'Re-check',
                    LucideIcons.refreshCw,
                    onTap: _axBusy ? null : _refreshAccessibility,
                  ),
                ],
              ),
            ],
          ),
          last: true,
        ),
      ],
    );
  }

  Widget _shortcutsSection(RelicColors c) {
    final repo = widget.repo;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _HotkeyRow(
          repo: repo,
          title: 'Open history shortcut',
          sub: 'Global hotkey to summon the full popup.',
          binding: repo.historyHotkey,
          onChanged: repo.setHistoryHotkey,
          registerFailed: repo.failedHotkeys.contains('history'),
        ),
        // Both desktops register this hotkey (desktop.dart _initHotkeys), so
        // the row shows on both: hiding it on macOS left a live chord nobody
        // could see, rebind, or be told about when registration failed.
        _HotkeyRow(
          repo: repo,
          title: 'Mini picker shortcut',
          sub: 'Summon the compact, cursor-anchored picker.',
          binding: repo.miniHotkey,
          onChanged: repo.setMiniHotkey,
          registerFailed: repo.failedHotkeys.contains('mini'),
        ),
        _HotkeyRow(
          repo: repo,
          title: 'Save & annotate shortcut',
          sub: 'Capture the selection or clipboard to your Vault and label it.',
          binding: repo.captureHotkey,
          onChanged: repo.setCaptureHotkey,
          registerFailed: repo.failedHotkeys.contains('capture'),
        ),
        _HotkeyRow(
          repo: repo,
          title: 'Promote-last shortcut',
          sub: 'Keep the most recent capture in place.',
          binding: repo.promoteHotkey,
          onChanged: repo.setPromoteHotkey,
          registerFailed: repo.failedHotkeys.contains('promote'),
        ),
        for (var i = 0; i < repo.quickPasteHotkeys.length; i++)
          _HotkeyRow(
            repo: repo,
            title: 'Quick-paste #${i + 1} shortcut',
            sub: i == 0
                ? 'Paste the newest item from any device into the app you\'re in.'
                : 'Paste the #${i + 1} most-recent item from any device.',
            binding: repo.quickPasteHotkeys[i],
            onChanged: (b) => repo.setQuickPasteHotkey(i, b),
            registerFailed: repo.failedHotkeys.contains('quickPaste${i + 1}'),
          ),
      ],
    );
  }

  Widget _mlSection(RelicColors c) {
    final repo = widget.repo;
    final available = repo.mlAvailable;
    final (status, statusColor) = switch (repo.siftStatus) {
      SiftStatus.unavailable => (
        // The binary is sift.exe on Windows, sift on macOS — name the right one.
        'Engine not found. Bundle ${SiftSidecar.binaryName}',
        c.textFaintest,
      ),
      SiftStatus.off => ('Off', c.textMuted),
      SiftStatus.downloading => (
        'Downloading models (~750 MB, one-time)…',
        c.accent,
      ),
      SiftStatus.stageA => ('Basic tags now · loading ML models…', c.accent),
      SiftStatus.keywordOnly => (
        'Ready: semantic search off (embeddings disabled)',
        c.textMuted,
      ),
      SiftStatus.ready => ('Ready: full local ML', c.successDim),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _row(
          c,
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'On-device smart tags',
                      style: RelicTheme.sans(size: 13, color: c.text),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Classifies saved (Vault) items locally: categories, content tags, and searchable OCR text from images. Nothing leaves your device.',
                      style: RelicTheme.sans(
                        size: 11.5,
                        color: c.textMuted,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      status,
                      style: RelicTheme.mono(size: 10, color: statusColor),
                    ),
                    if (repo.mlEnrich && repo.enrichBacklog > 0) ...[
                      const SizedBox(height: 3),
                      Text(
                        'tagging ${_fmtCount(repo.enrichBacklog)} items…',
                        style: RelicTheme.mono(size: 10, color: c.accent),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 16),
              _Toggle(
                on: repo.mlEnrich,
                onTap: available
                    ? () => repo.setMlEnrich(!repo.mlEnrich)
                    : () {},
              ),
            ],
          ),
        ),
        if (repo.mlEnrich) ...[
          _toggleRow(
            c,
            'Image text (OCR)',
            repo.aiOcr,
            repo.setAiOcr,
            sub: 'Pull searchable text out of images and screenshots.',
          ),
          _toggleRow(
            c,
            'Smart content tags',
            repo.aiImageTags,
            repo.setAiImageTags,
            sub:
                'Tag what an image shows (people, animal, product…). The primary category is kept either way.',
          ),
          _toggleRow(
            c,
            'Semantic search',
            repo.aiEmbeddings,
            repo.setAiEmbeddings,
            sub:
                'Embed items so you can search by meaning, not just keywords. Off makes search lexical-only.',
          ),
          _toggleRow(
            c,
            'Describe items',
            repo.describeItems,
            repo.setDescribeItems,
            sub:
                'Give saved items a short title and topic tags, so you can search what a photo shows or what a note is about. Applies to vault items and every photo. Off by default: it downloads ~666 MB and runs in the background at about a second per item.',
          ),
          _analysisSpeedRow(c),
          // Only meaningful once descriptions are on at all.
          if (repo.describeItems)
            _toggleRow(
              c,
              'Describe history too',
              repo.describeEverything,
              repo.setDescribeEverything,
              sub:
                  'Also describe clipboard items you never saved to the vault. Most copies are throwaway and each costs about a second, so this is off unless you want everything covered.',
            ),
        ],
        if (repo.mlAvailable) _modelsRow(c),
        _toggleRow(
          c,
          'Personalized ranking',
          repo.personalRank,
          repo.setPersonalRank,
          sub:
              'Items you pick often, for a search or into an app, rank higher over time. Learned and stored on this device only.',
          last: !repo.personalRank,
        ),
        if (repo.personalRank)
          _row(
            c,
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Start fresh: forget which items ranking has learned to favor.',
                    style: RelicTheme.sans(size: 11.5, color: c.textMuted),
                  ),
                ),
                const SizedBox(width: 16),
                GestureDetector(
                  onTap: () {
                    widget.repo.clearPersonalMemory();
                    setState(() => _personalCleared = true);
                    Timer(const Duration(seconds: 2), () {
                      if (mounted) setState(() => _personalCleared = false);
                    });
                  },
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: Text(
                      _personalCleared ? 'Cleared' : 'Clear learned ranking',
                      style: RelicTheme.mono(
                        size: 11,
                        color: _personalCleared ? c.successDim : c.accent,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            last: true,
          ),
      ],
    );
  }

  /// Downloaded-models footprint + reclaim. The models are a roach motel
  /// otherwise: toggling smart tags off leaves ~1 GB on disk forever.
  Widget _modelsRow(RelicColors c) {
    final repo = widget.repo;
    final bytes = _modelsBytes;
    if (bytes != null && bytes == 0 && !repo.downloadingModels) {
      return const SizedBox.shrink(); // nothing downloaded, nothing to say
    }
    final canRemove = !repo.mlEnrich &&
        !repo.downloadingModels &&
        !repo.removingModels &&
        (bytes ?? 0) > 0;
    return _row(
      c,
      Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Downloaded ML models',
                    style: RelicTheme.sans(size: 13, color: c.text)),
                const SizedBox(height: 2),
                Text(
                  'Power smart tags and semantic search. Remove them to reclaim the space; they re-download if you turn smart tags back on.${repo.mlEnrich ? ' Turn off on-device smart tags first.' : ''}',
                  style: RelicTheme.sans(
                      size: 11.5, color: c.textMuted, height: 1.4),
                ),
                if (_modelsMsg.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(_modelsMsg,
                      style:
                          RelicTheme.mono(size: 10.5, color: c.successDim)),
                ],
              ],
            ),
          ),
          const SizedBox(width: 16),
          Text(
            bytes == null ? '…' : _fmtBytes(bytes),
            style: RelicTheme.mono(size: 12, color: c.textSecondary),
          ),
          const SizedBox(width: 10),
          _btn(
            c,
            repo.removingModels ? 'Removing…' : 'Remove',
            LucideIcons.trash2,
            danger: true,
            onTap: canRemove ? _removeModels : null,
          ),
        ],
      ),
    );
  }

  Future<void> _removeModels() async {
    setState(() => _modelsMsg = '');
    final freed = await widget.repo.removeModels();
    await _loadModelsBytes();
    if (!mounted) return;
    setState(() =>
        _modelsMsg = freed > 0 ? 'Freed ${_fmtBytes(freed)}.' : '');
    if (freed > 0) {
      Timer(const Duration(seconds: 4), () {
        if (mounted) setState(() => _modelsMsg = '');
      });
    }
  }

  Widget _analysisSpeedRow(RelicColors c) {
    final speeds = AnalysisSpeed.values;
    final sel = speeds.indexOf(widget.repo.analysisSpeed);
    return _row(
      c,
      Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Analysis speed',
                  style: RelicTheme.sans(size: 13, color: c.text),
                ),
                const SizedBox(height: 2),
                Text(
                  'How much CPU the background passes may use. Gentle keeps an old '
                  'or busy machine responsive; Fast finishes sooner but competes '
                  'with what you are doing.',
                  style: RelicTheme.sans(size: 11.5, color: c.textMuted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          _Segmented(
            options: [for (final s in speeds) s.label],
            selected: sel < 0 ? 1 : sel,
            onChanged: (i) => widget.repo.setAnalysisSpeed(speeds[i]),
          ),
        ],
      ),
    );
  }

  Widget _popupSizeRow(RelicColors c) {
    final sizes = PopupSize.values;
    final sel = sizes.indexOf(widget.repo.popupSize);
    return _row(
      c,
      Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Popup size',
                  style: RelicTheme.sans(size: 13, color: c.text),
                ),
                const SizedBox(height: 2),
                Text(
                  'How tall the history popup opens. Mini shows just the last few items.',
                  style: RelicTheme.sans(size: 11.5, color: c.textMuted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          _Segmented(
            options: [for (final s in sizes) s.label],
            selected: sel < 0 ? 1 : sel,
            onChanged: (i) => widget.repo.setPopupSize(sizes[i]),
          ),
        ],
      ),
    );
  }

  Widget _appearanceRow(RelicColors c) {
    final sel = Appearance.values.indexOf(widget.repo.appearance);
    return _row(
      c,
      Row(
        children: [
          Expanded(
            child: Text(
              'Appearance',
              style: RelicTheme.sans(size: 13, color: c.text),
            ),
          ),
          _Segmented(
            options: const ['System', 'Dark', 'Light'],
            selected: sel < 0 ? 0 : sel,
            onChanged: (i) => widget.repo.setAppearance(Appearance.values[i]),
          ),
        ],
      ),
    );
  }

  /// "Keep N items" retention control. Local installs get Keep everything +
  /// presets; Free is fixed at its server ring; Paid spans 100–10,000.
  Widget _retentionRow(RelicColors c) {
    final repo = widget.repo;
    final lim = repo.retentionLimits;
    const presets = [100, 500, 1000, 10000];
    final values = <int?>[
      if (lim.allowUnlimited) null,
      ...presets.where((p) => p >= lim.ringMin && p <= lim.ringMax),
    ];
    final labels = [
      for (final v in values) v == null ? 'Keep everything' : _fmtCount(v),
    ];
    var sel = values.indexWhere((v) => v == repo.retainCount);
    if (sel < 0) sel = lim.allowUnlimited ? 0 : values.length - 1;
    final fixed = lim.ringMin == lim.ringMax;
    return _row(
      c,
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Keep recent history',
            style: RelicTheme.sans(size: 13, color: c.text),
          ),
          const SizedBox(height: 2),
          Text(
            fixed
                ? 'Your plan keeps the ${_fmtCount(lim.ringMax)} most recent history items. Saved (Vault) items are never auto-deleted.'
                : 'Automatically remove the oldest history items beyond this limit. Saved (Vault) items are never auto-deleted.',
            style: RelicTheme.sans(size: 11.5, color: c.textMuted, height: 1.4),
          ),
          const SizedBox(height: 10),
          if (values.length > 1)
            _Segmented(
              options: labels,
              selected: sel,
              onChanged: (i) => repo.setRetainCount(values[i]),
            )
          else
            Text(
              labels.isEmpty ? '—' : labels.first,
              style: RelicTheme.mono(size: 12, color: c.textSecondary),
            ),
          // Age cap: local installs only, composable with keep-N (both
          // apply). Synced accounts are ringed server-side per tier.
          if (lim.allowUnlimited) ...[
            const SizedBox(height: 14),
            Text(
              'Remove history older than',
              style: RelicTheme.sans(size: 12, color: c.textSecondary),
            ),
            const SizedBox(height: 8),
            Builder(builder: (_) {
              const dayValues = <int?>[null, 30, 90, 365];
              var dsel = dayValues.indexOf(repo.retainDays);
              if (dsel < 0) dsel = 0;
              return _Segmented(
                options: const ['Never', '30 days', '90 days', '1 year'],
                selected: dsel,
                onChanged: (i) => repo.setRetainDays(dayValues[i]),
              );
            }),
          ],
        ],
      ),
    );
  }

  Widget _vaultFullBanner(RelicColors c) => _row(
    c,
    Row(
      children: [
        Icon(LucideIcons.triangleAlert, size: 16, color: c.secret),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            'Vault is full. Free up space or upgrade to keep saving items.',
            style: RelicTheme.sans(size: 12, color: c.text),
          ),
        ),
        const SizedBox(width: 12),
        _btn(c, 'Dismiss', LucideIcons.x, onTap: widget.repo.clearVaultFull),
      ],
    ),
  );

  static String _fmtCount(int n) {
    final s = n.toString();
    final b = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
      b.write(s[i]);
    }
    return b.toString();
  }

  Widget _maxSizeRow(RelicColors c) => _row(
    c,
    Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Max item size',
                style: RelicTheme.sans(size: 13, color: c.text),
              ),
              const SizedBox(height: 2),
              Text(
                'Skip captures larger than this. Bigger files are kept as a path only.',
                style: RelicTheme.sans(size: 11.5, color: c.textMuted),
              ),
              const SizedBox(height: 10),
              _SizeSlider(
                mb: widget.repo.maxItemMb,
                onChanged: (mb) => widget.repo.setMaxItemMb(mb),
              ),
            ],
          ),
        ),
        const SizedBox(width: 16),
        SizedBox(
          width: 56,
          child: Text(
            '${widget.repo.maxItemMb} MB',
            textAlign: TextAlign.right,
            style: RelicTheme.mono(size: 12, color: c.text),
          ),
        ),
      ],
    ),
  );

  static String _fmtBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
    final mb = bytes / (1024 * 1024);
    return mb >= 1024
        ? '${(mb / 1024).toStringAsFixed(2)} GB'
        : '${mb.toStringAsFixed(1)} MB';
  }
}

class _Toggle extends StatelessWidget {
  final bool on;
  final VoidCallback onTap;
  const _Toggle({required this.on, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: AnimatedContainer(
          duration: Motion.selection,
          width: 40,
          height: 23,
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: on ? c.accent : c.track,
            borderRadius: BorderRadius.circular(Radii.pill),
          ),
          alignment: on ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 19,
            height: 19,
            decoration: BoxDecoration(
              color: on ? c.toggleKnob : c.textFaintest,
              shape: BoxShape.circle,
            ),
          ),
        ),
      ),
    );
  }
}

class _Segmented extends StatelessWidget {
  final List<String> options;
  final int selected;
  final ValueChanged<int> onChanged;
  const _Segmented({
    required this.options,
    required this.selected,
    required this.onChanged,
  });
  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: c.isDark ? c.panel : c.footer,
        borderRadius: BorderRadius.circular(Radii.input),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < options.length; i++)
            GestureDetector(
              onTap: () => onChanged(i),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: i == selected ? c.selected : const Color(0x00000000),
                    borderRadius: BorderRadius.circular(Radii.chip),
                    boxShadow: i == selected && !c.isDark
                        ? [BoxShadow(color: c.shadowSoft, blurRadius: 6)]
                        : null,
                  ),
                  child: Text(
                    options[i],
                    style: RelicTheme.sans(
                      size: 11.5,
                      weight: FontWeight.w600,
                      color: i == selected ? c.accent : c.textMuted,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Draggable 1–100 MB slider (the app has no Material dependency in this file).
class _SizeSlider extends StatelessWidget {
  final int mb;
  final ValueChanged<int> onChanged;
  const _SizeSlider({required this.mb, required this.onChanged});

  static const _min = 1.0, _max = 100.0;

  void _setFromDx(double dx, double width) {
    final frac = (dx / width).clamp(0.0, 1.0);
    onChanged((_min + frac * (_max - _min)).round());
  }

  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    final frac = ((mb - _min) / (_max - _min)).clamp(0.0, 1.0);
    return LayoutBuilder(
      builder: (context, box) {
        final w = box.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => _setFromDx(d.localPosition.dx, w),
          onHorizontalDragUpdate: (d) => _setFromDx(d.localPosition.dx, w),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: SizedBox(
              height: 18,
              child: Stack(
                alignment: Alignment.centerLeft,
                children: [
                  Container(
                    height: 4,
                    decoration: BoxDecoration(
                      color: c.track,
                      borderRadius: BorderRadius.circular(Radii.pill),
                    ),
                  ),
                  FractionallySizedBox(
                    widthFactor: frac,
                    child: Container(
                      height: 4,
                      decoration: BoxDecoration(
                        color: c.accent,
                        borderRadius: BorderRadius.circular(Radii.pill),
                      ),
                    ),
                  ),
                  Align(
                    alignment: Alignment(frac * 2 - 1, 0),
                    child: Container(
                      width: 15,
                      height: 15,
                      decoration: BoxDecoration(
                        color: c.accent,
                        shape: BoxShape.circle,
                        border: Border.all(color: c.base, width: 2),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A rebindable global-hotkey row: shows the current chord as keycaps, and a
/// "Change" button that records the next chord pressed.
class _HotkeyRow extends StatefulWidget {
  final LocalDeskRepo repo;
  final String title;
  final String sub;
  final HotkeyBinding binding;
  final ValueChanged<HotkeyBinding> onChanged;

  /// True when this chord failed to REGISTER at the OS (another app owns
  /// it) — shown as a persistent warning line so it doesn't die in a log.
  final bool registerFailed;
  const _HotkeyRow({
    required this.repo,
    required this.title,
    required this.sub,
    required this.binding,
    required this.onChanged,
    this.registerFailed = false,
  });

  @override
  State<_HotkeyRow> createState() => _HotkeyRowState();
}

class _HotkeyRowState extends State<_HotkeyRow> {
  final _focus = FocusNode();
  bool _recording = false;
  String? _error;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _start() {
    // suspend the live global hotkeys so the chord we're recording (which may
    // be an existing one) doesn't fire while we capture it.
    hotKeyManager.unregisterAll();
    setState(() {
      _recording = true;
      _error = null;
    });
    _focus.requestFocus();
  }

  void _cancel() {
    setState(() => _recording = false);
    _focus.unfocus();
    widget.repo.onHotkeysChanged?.call(); // restore the live bindings
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (!_recording || e is! KeyDownEvent) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.escape) {
      _cancel();
      return KeyEventResult.handled;
    }
    final b = HotkeyBinding.fromEvent(e);
    if (b == null) {
      return KeyEventResult.handled; // bare modifier — keep waiting
    }
    if (!b.hasModifier) {
      setState(
        () => _error = Platform.isMacOS
            ? 'Use at least one modifier (Ctrl / Option / Shift / Cmd).'
            : 'Use at least one modifier (Ctrl / Alt / Shift / Win).',
      );
      return KeyEventResult.handled;
    }
    setState(() => _recording = false);
    _focus.unfocus();
    widget.onChanged(b); // persists + re-registers the live bindings
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 13),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.title,
                  style: RelicTheme.sans(size: 13, color: c.text),
                ),
                const SizedBox(height: 2),
                Text(
                  _error ??
                      (widget.registerFailed
                          ? 'This shortcut could not register. Another app may already use it; pick a different one.'
                          : widget.sub),
                  style: RelicTheme.sans(
                    size: 11.5,
                    color: (_error != null || widget.registerFailed)
                        ? c.dangerText
                        : c.textMuted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          if (_recording)
            Focus(
              focusNode: _focus,
              onKeyEvent: _onKey,
              child: GestureDetector(
                onTap: _cancel,
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: c.selected,
                      borderRadius: BorderRadius.circular(Radii.chip),
                      border: Border.all(
                        color: c.accent.withValues(alpha: 0.6),
                      ),
                    ),
                    child: Text(
                      'Press a shortcut…  (Esc to cancel)',
                      style: RelicTheme.mono(size: 11, color: c.accent),
                    ),
                  ),
                ),
              ),
            )
          else ...[
            for (final cap in widget.binding.chips) ...[
              Container(
                margin: const EdgeInsets.only(left: 4),
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: BoxDecoration(
                  color: c.isDark ? c.inset : c.surface,
                  borderRadius: BorderRadius.circular(Radii.chip),
                  border: Border.all(color: c.border),
                ),
                child: Text(
                  cap,
                  style: RelicTheme.mono(size: 12, color: c.text),
                ),
              ),
            ],
            const SizedBox(width: 10),
            GhostButton(
              label: 'Change',
              onTap: _start,
            ),
          ],
        ],
      ),
    );
  }
}
