import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../data/api.dart';
import '../data/device_directory.dart';
import '../models/relic.dart' show relativeAge;
import '../data/pairing.dart';
import '../platform/store_safe.dart';
import '../data/recovery.dart';
import '../data/save_prefs.dart';
import '../services/onboarding_service.dart';
import '../theme/relic_theme.dart';
import '../theme/tokens.dart';
import '../widgets/controls.dart';
import '../widgets/drill_shell.dart';
import '../widgets/passphrase_field.dart';

/// Ghost action row shared by the drill-down screens, mirroring the settings
/// pane rows: Lucide icon, sans title with muted subtitle, hairline bottom
/// separator instead of a Material Divider, rounded hover tint when tappable.
Widget _drillRow(
  RelicColors c, {
  required IconData icon,
  Color? iconColor,
  required String title,
  Color? titleColor,
  Widget? badge,
  String? subtitle,

  /// The subtitle is a machine fact (platform · last seen · version), so it is
  /// set in mono rather than the prose face.
  bool subtitleMono = false,
  Widget? trailing,
  VoidCallback? onTap,
  bool last = false,
}) =>
    Hoverable(
      onTap: onTap,
      builder: (context, hovered) => Container(
        decoration: BoxDecoration(
          border: last ? null : Border(bottom: BorderSide(color: c.border)),
        ),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 2),
          padding: const EdgeInsets.symmetric(
              horizontal: Insets.sm, vertical: Insets.md),
          decoration: BoxDecoration(
            color: hovered && onTap != null
                ? c.surfaceHover
                : const Color(0x00000000),
            borderRadius: BorderRadius.circular(Radii.tile),
          ),
          child: Row(
            children: [
              Icon(icon, size: 16, color: iconColor ?? c.textSecondary),
              const SizedBox(width: Insets.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            overflow: TextOverflow.ellipsis,
                            style: RelicTheme.sans(
                              size: 13,
                              color: titleColor ?? c.text,
                            ),
                          ),
                        ),
                        if (badge != null) ...[
                          const SizedBox(width: Insets.sm),
                          badge,
                        ],
                      ],
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: subtitleMono
                            ? RelicTheme.mono(
                                size: 10.5,
                                color: c.textMuted,
                                height: 1.4,
                              )
                            : RelicTheme.sans(
                                size: 11.5,
                                color: c.textMuted,
                                height: 1.35,
                              ),
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: Insets.sm),
                trailing,
              ],
            ],
          ),
        ),
      ),
    );

/// Trusted-device side of QR pairing (docs/cloudflare/13 §5): an already-unlocked
/// device shows a QR, waits for a new device to scan it, verifies the 4-digit SAS
/// matches, and on approval delivers the (sealed) master key.
class AddDeviceScreen extends StatefulWidget {
  final Uint8List masterKey;
  final Future<String?> Function() bearer;

  /// The Supabase user id, when connected via an account session. When set, the
  /// screen mints a v2 QR *and* a typed pairing code (both account-bound); when
  /// null (legacy device-token repos) it falls back to today's v1-QR-only screen.
  final String? accountId;
  const AddDeviceScreen(
      {super.key,
      required this.masterKey,
      required this.bearer,
      this.accountId});

  @override
  State<AddDeviceScreen> createState() => _AddDeviceScreenState();
}

enum _Phase { starting, waiting, confirm, delivering, done, error }

class _AddDeviceScreenState extends State<AddDeviceScreen> {
  _Phase _phase = _Phase.starting;
  String? _qr;
  String? _code; // the typed pairing code (Supabase mode only)
  String? _sas;
  String? _error;
  TrustedDevicePairing? _pairing;

  @override
  void initState() {
    super.initState();
    _begin();
  }

  @override
  void dispose() {
    // Stop the orphan relay poll (up to ~110s) if the screen pops mid-handshake.
    _pairing?.cancel();
    super.dispose();
  }

  /// Tear down whatever session is live and mint a fresh one. Backs the
  /// "Try again" on the error screen: the relay slots are single-use with a
  /// ~2-minute TTL, so recovery is always a brand-new QR/code, never a resume.
  void _restart() {
    _pairing?.cancel();
    setState(() {
      _pairing = null;
      _qr = null;
      _code = null;
      _sas = null;
      _error = null;
      _phase = _Phase.starting;
    });
    _begin();
  }

  Future<void> _begin() async {
    try {
      final id = await DeviceId.get();
      final svc = OnboardingService(deviceId: id);
      final relay = svc.relayWith(widget.bearer);
      // Supabase mode: one session, two doors (v2 QR + typed code), account-bound.
      // Legacy device-token repos have no accountId → today's v1-QR-only screen.
      final trusted = widget.accountId == null
          ? await TrustedDevicePairing.display(relay, widget.masterKey)
          : await TrustedDevicePairing.displayWithCode(relay, widget.masterKey,
              accountId: widget.accountId!);
      if (!mounted) return;
      setState(() {
        _pairing = trusted;
        _qr = trusted.qr;
        _code = widget.accountId == null ? null : trusted.code;
        _phase = _Phase.waiting;
      });
      final sas = await trusted.handshake(); // blocks until the new device scans
      if (!mounted) return;
      setState(() {
        _sas = sas;
        _phase = _Phase.confirm;
      });
    } on PairingCancelled {
      // The screen was disposed mid-handshake; nothing to show.
    } on PairingTimeout {
      if (mounted) {
        setState(() {
          _error = 'No device connected in time. The code is only live for '
              'about two minutes.';
          _phase = _Phase.error;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString().replaceFirst('StateError: ', '');
          _phase = _Phase.error;
        });
      }
    }
  }

  /// TRUSTED declines the join. Cancel before delivering — the MK never posts —
  /// and leave with a reassuring note.
  void _cancelApproval() {
    _pairing?.cancel(); // the MK never posts
    final messenger = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);
    if (nav.canPop()) nav.pop();
    messenger.showSnackBar(
        const SnackBar(content: Text('Pairing canceled. Nothing was shared.')));
  }

  Future<void> _approve() async {
    setState(() => _phase = _Phase.delivering);
    try {
      await _pairing!.approveAndDeliver();
      if (mounted) setState(() => _phase = _Phase.done);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _phase = _Phase.error;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    return DrillShell(
      title: 'Add a device',
      center: true,
      child: _body(c),
    );
  }

  Widget _body(RelicColors c) {
    switch (_phase) {
      case _Phase.starting:
        return Center(child: CircularProgressIndicator(color: c.accent));
      case _Phase.waiting:
        return Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Scan this with your other device',
              style: RelicTheme.headline(size: 17, color: c.text)),
          const SizedBox(height: Insets.sm),
          Text('On the new device: open Relic, choose Add this device, then Scan a QR.',
              textAlign: TextAlign.center,
              style: RelicTheme.sans(
                  size: 13, color: c.textSecondary, height: 1.5)),
          const SizedBox(height: Insets.xxl),
          // The code sits on a real card, not a bare white block: the panel
          // carries the card's radius, hairline and resting shadow, and the
          // QR keeps its own white tile inside so it stays scannable on dark.
          Container(
            padding: const EdgeInsets.all(Insets.lg),
            decoration: BoxDecoration(
              color: c.panel,
              borderRadius: BorderRadius.circular(Radii.cardLarge),
              border: Border.all(color: c.border),
              boxShadow: Shadows.card(c),
            ),
            child: Container(
              padding: const EdgeInsets.all(Insets.md),
              // Deliberately white in both themes so the QR stays scannable.
              decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(Radii.card)),
              child:
                  QrImageView(data: _qr!, size: 240, version: QrVersions.auto),
            ),
          ),
          if (_code != null) ...[
            const SizedBox(height: Insets.xxl),
            Row(children: [
              Expanded(child: Container(height: 1, color: c.border)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Insets.md),
                child: Text('or',
                    style: RelicTheme.sans(size: 12, color: c.textMuted)),
              ),
              Expanded(child: Container(height: 1, color: c.border)),
            ]),
            const SizedBox(height: Insets.md),
            Text('No camera on the other device? Type this code instead:',
                textAlign: TextAlign.center,
                style: RelicTheme.sans(
                    size: 12.5, color: c.textMuted, height: 1.45)),
            const SizedBox(height: Insets.md),
            // A pairing code is a machine fact: mono, in a recessed well.
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                  horizontal: Insets.lg, vertical: Insets.md),
              decoration: BoxDecoration(
                color: c.inset,
                borderRadius: BorderRadius.circular(Radii.input),
                border: Border.all(color: c.isDark ? c.selected : c.border),
              ),
              child: SelectableText(_code!,
                  textAlign: TextAlign.center,
                  style: RelicTheme.mono(
                      size: 18,
                      weight: FontWeight.w600,
                      color: c.accentDeep,
                      letterSpacing: 2)),
            ),
          ],
          const SizedBox(height: Insets.xxl),
          Text('Waiting for the other device…',
              style: RelicTheme.sans(size: 12.5, color: c.textMuted)),
        ]);
      case _Phase.confirm:
      case _Phase.delivering:
        return Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Do the codes match?',
              style: RelicTheme.headline(size: 17, color: c.text)),
          const SizedBox(height: Insets.sm),
          Text('This 4-digit code should be identical on both devices.',
              textAlign: TextAlign.center,
              style: RelicTheme.sans(
                  size: 13, color: c.textSecondary, height: 1.5)),
          const SizedBox(height: Insets.xxl),
          // The verification code is a machine fact: mono, in a recessed well.
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(
                horizontal: Insets.lg, vertical: Insets.xl),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: c.inset,
              borderRadius: BorderRadius.circular(Radii.input),
              border: Border.all(color: c.isDark ? c.selected : c.border),
            ),
            child: Text(_sas ?? '----',
                style: RelicTheme.mono(
                    size: 46,
                    weight: FontWeight.w700,
                    color: c.accentDeep,
                    letterSpacing: 12)),
          ),
          const SizedBox(height: Insets.xxl),
          if (_phase == _Phase.delivering)
            CircularProgressIndicator(color: c.accent)
          else ...[
            PrimaryButton(
              label: 'Yes, approve this device',
              height: 38,
              onTap: _approve,
            ),
            const SizedBox(height: Insets.md),
            GhostButton(
              label: 'No, cancel',
              size: 34,
              onTap: _cancelApproval,
            ),
          ],
        ]);
      case _Phase.done:
        return Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(LucideIcons.circleCheck, color: c.accent, size: 48),
          const SizedBox(height: Insets.lg),
          Text('Device added',
              style: RelicTheme.headline(size: 17, color: c.text)),
          const SizedBox(height: Insets.sm),
          Text('Your other device is now connected to your vault.',
              textAlign: TextAlign.center,
              style: RelicTheme.sans(
                  size: 13, color: c.textSecondary, height: 1.5)),
          const SizedBox(height: Insets.xxl),
          PrimaryButton(
            label: 'Done',
            height: 34,
            onTap: () => Navigator.of(context).pop(),
          ),
        ]);
      case _Phase.error:
        return Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(LucideIcons.circleAlert, color: c.dangerText, size: 44),
          const SizedBox(height: Insets.lg),
          Text(_error ?? 'Something went wrong.',
              textAlign: TextAlign.center,
              style: RelicTheme.sans(size: 13, color: c.text, height: 1.5)),
          const SizedBox(height: Insets.xxl),
          PrimaryButton(label: 'Try again', height: 36, onTap: _restart),
          const SizedBox(height: Insets.sm),
          GhostButton(
            label: 'Close',
            size: 32,
            onTap: () => Navigator.of(context).pop(),
          ),
        ]);
    }
  }
}

/// True when [typed] matches [accountEmail] case-insensitively (both trimmed),
/// and the account email is non-empty. Backs the delete-account confirm field.
/// Pure so the match rule is unit-testable.
bool emailConfirmMatches(String typed, String accountEmail) {
  final acct = accountEmail.trim().toLowerCase();
  return acct.isNotEmpty && typed.trim().toLowerCase() == acct;
}

/// The one-line warning that heads a downloaded recovery kit file.
const recoveryKitDownloadWarning =
    'This code IS your vault key. Anyone with it can read your vault. Store it offline.';

/// Pick two distinct group indices to quiz the user on for the re-entry proof.
/// Degrades gracefully for tiny counts (kits always have 14 groups in practice).
(int, int) pickTwoGroups(int n) {
  if (n <= 1) return (0, 0);
  final rng = Random();
  final a = rng.nextInt(n);
  var b = rng.nextInt(n - 1);
  if (b >= a) b += 1;
  return (a, b);
}

/// Write [kitText] to `relic-recovery-kit.txt`. The file leads with
/// [recoveryKitDownloadWarning]; the kit body already carries the account email
/// and the groups.
///
/// On mobile this MUST NOT go through FileSaver.saveFile: that writes to
/// getExternalFilesDir, which no file manager can browse on Android 11+ and
/// which is deleted on uninstall. The recovery kit is the only way back into a
/// vault whose passphrase is lost, so a kit the user cannot find — or that
/// vanishes with the app — is worse than no kit at all. Mobile therefore uses
/// the same user-visible destinations as "Save to device".
Future<void> downloadRecoveryKit(String kitText) async {
  final contents = '$recoveryKitDownloadWarning\n\n$kitText';
  final bytes = Uint8List.fromList(utf8.encode(contents));
  if (Platform.isAndroid || Platform.isIOS) {
    await saveFileOnMobile(
      bytes: bytes,
      base: 'relic-recovery-kit',
      ext: 'txt',
      mime: 'text/plain',
    );
    return;
  }
  await FileSaver.instance.saveFile(
    name: 'relic-recovery-kit',
    bytes: bytes,
    fileExtension: 'txt',
    mimeType: MimeType.text,
  );
}

/// Shown once right after a vault is first created (docs/cloudflare/13 §2.4).
/// The kit is the raw master key — the only way back in if the passphrase is
/// forgotten. On first save ([requireProof] = true) the user must re-type two
/// random groups to prove they actually captured it before continuing; the
/// Security-screen re-show passes [requireProof] = false (they already have an
/// unlocked vault) so it is just a Copy/Download reference.
class RecoveryKitScreen extends StatefulWidget {
  final String kitText;
  final bool requireProof;
  const RecoveryKitScreen(
      {super.key, required this.kitText, this.requireProof = true});

  @override
  State<RecoveryKitScreen> createState() => _RecoveryKitScreenState();
}

class _RecoveryKitScreenState extends State<RecoveryKitScreen> {
  final _a = TextEditingController();
  final _b = TextEditingController();
  late final List<String> _groups = RecoveryKit.groups(widget.kitText);
  late final (int, int) _picks = pickTwoGroups(_groups.length);

  // inline feedback (the drill card has no Scaffold, so no snackbars):
  // transient Copied flip on the key-block chip + a status line for Download.
  bool _copied = false;
  Timer? _copiedT;
  String? _msg;
  bool _msgError = false;

  @override
  void dispose() {
    _copiedT?.cancel();
    _a.dispose();
    _b.dispose();
    super.dispose();
  }

  void _copy() {
    Clipboard.setData(ClipboardData(text: widget.kitText));
    _copiedT?.cancel();
    setState(() => _copied = true);
    _copiedT = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  bool get _proofOk {
    if (!widget.requireProof) return true;
    if (_groups.isEmpty) return false;
    return Crockford.normalize(_a.text) == Crockford.normalize(_groups[_picks.$1]) &&
        Crockford.normalize(_b.text) == Crockford.normalize(_groups[_picks.$2]);
  }

  Future<void> _download() async {
    try {
      await downloadRecoveryKit(widget.kitText);
      if (mounted) {
        setState(() {
          _msg = 'Recovery kit saved';
          _msgError = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _msg = 'Could not save the recovery kit';
          _msgError = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    return DrillShell(
      title: 'Recovery kit',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Save your recovery kit',
              style: RelicTheme.headline(size: 17, color: c.text)),
          const SizedBox(height: Insets.sm),
          // Gold as text, so it takes the tag tint under it: the system's
          // chip, never a bare gold line on the card.
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: Insets.sm, vertical: 3),
            decoration: BoxDecoration(
              color: c.tagBg,
              borderRadius: BorderRadius.circular(Radii.tag),
            ),
            child: Text('RELIC KEEPS NO COPY · STORE IT OFFLINE',
                style: RelicTheme.kicker(c.tagText, size: 10)),
          ),
          const SizedBox(height: Insets.md),
          Text(
              'The only way back into your data if you forget your vault passphrase. We cannot recover it for you. Print it or store it in a password manager.',
              style: RelicTheme.sans(
                  size: 13, color: c.textSecondary, height: 1.5)),
          const SizedBox(height: Insets.lg),
          // The kit itself is the machine fact: mono, in a recessed well.
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(Insets.lg),
            decoration: BoxDecoration(
                color: c.inset,
                borderRadius: BorderRadius.circular(Radii.input),
                border: Border.all(color: c.isDark ? c.selected : c.border)),
            child: Stack(children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('RECOVERY KIT',
                      style: RelicTheme.kicker(c.textFaintest)),
                  const SizedBox(height: Insets.md),
                  Padding(
                    // keep the kit text clear of the copy button
                    padding: const EdgeInsets.only(right: 96),
                    child: SelectableText(widget.kitText,
                        style: RelicTheme.mono(
                            size: 13,
                            color: c.accentDeep,
                            height: 1.7,
                            letterSpacing: 0.6)),
                  ),
                ],
              ),
              Positioned(
                top: 0,
                right: 0,
                child: GhostButton(
                  icon: _copied ? LucideIcons.check : LucideIcons.copy,
                  label: _copied ? 'Copied' : 'Copy',
                  size: 26,
                  iconSize: 13,
                  fontSize: 11.5,
                  onTap: _copy,
                ),
              ),
            ]),
          ),
          const SizedBox(height: Insets.md),
          Row(children: [
            GhostButton(
              icon: LucideIcons.download,
              label: 'Download',
              size: 32,
              onTap: _download,
            ),
            if (_msg != null) ...[
              const SizedBox(width: Insets.md),
              Flexible(
                child: Text(_msg!,
                    style: RelicTheme.sans(
                        size: 11.5,
                        color: _msgError ? c.dangerText : c.success)),
              ),
            ],
          ]),
          if (widget.requireProof && _groups.isNotEmpty) ...[
            const SizedBox(height: Insets.xl),
            Text('Confirm you saved it: re-type these two groups from your kit.',
                style: RelicTheme.sans(
                    size: 12.5, color: c.textMuted, height: 1.45)),
            const SizedBox(height: Insets.md),
            _proofField(c, _a, 'Type group ${_picks.$1 + 1}'),
            const SizedBox(height: Insets.md),
            _proofField(c, _b, 'Type group ${_picks.$2 + 1}'),
          ],
          const SizedBox(height: Insets.xl),
          Row(children: [
            PrimaryButton(
              label: 'Continue',
              height: 38,
              onTap: _proofOk ? () => Navigator.of(context).pop() : null,
            ),
          ]),
        ],
      ),
    );
  }

  /// Re-typing a kit group is a machine fact too: mono, on the recessed well.
  Widget _proofField(RelicColors c, TextEditingController ctrl, String hint) =>
      TextField(
        controller: ctrl,
        onChanged: (_) => setState(() {}),
        autocorrect: false,
        enableSuggestions: false,
        style: RelicTheme.mono(size: 13, color: c.text, letterSpacing: 2),
        textCapitalization: TextCapitalization.characters,
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: RelicTheme.sans(size: 12.5, color: c.textFaintest),
          filled: true,
          fillColor: c.inset,
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(Radii.input),
              borderSide: BorderSide(color: c.borderStrong)),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(Radii.input),
              borderSide: BorderSide(color: c.accent, width: 1.5)),
        ),
      );
}

/// Settings → Security (docs/cloudflare/13 §7): rotate the passphrase (re-wraps
/// the master key, no re-encryption) and re-display the recovery kit. Both work
/// from the in-memory master key; the kit stays valid across passphrase changes.
class SecurityScreen extends StatefulWidget {
  final Uint8List masterKey;
  final String accountEmail;
  final Future<void> Function(String newPassphrase) onChangePassphrase;

  /// Change the login (account) email at the IdP. GoTrue confirms on both the
  /// old and new address before the change lands. Null hides the row (e.g.
  /// legacy device-token connections with no Supabase session). Separate from
  /// the vault passphrase.
  final Future<void> Function(String newEmail)? onChangeEmail;

  /// Account-wide kill switch (docs/cloudflare/13 §7): revoke every device's
  /// session at the identity provider. Null hides the action (e.g. legacy
  /// device-token connections that have no Supabase session to revoke).
  final Future<void> Function()? onSignOutEverywhere;

  /// Disconnect this device (the same path as settings → Disconnect). Wired from
  /// the host so the "sign out everywhere" follow-through can offer to also drop
  /// this device, which would otherwise limp on a doomed token for ~1h. Null
  /// hides that follow-up.
  final VoidCallback? onDisconnect;

  /// Permanently delete the synced vault + account on the server (repo
  /// deleteAccount). Null hides the danger row (e.g. legacy device-token
  /// connections). On success the screen runs [onDisconnect] and pops.
  final Future<void> Function()? onDeleteAccount;
  const SecurityScreen({
    super.key,
    required this.masterKey,
    required this.accountEmail,
    required this.onChangePassphrase,
    this.onChangeEmail,
    this.onSignOutEverywhere,
    this.onDisconnect,
    this.onDeleteAccount,
  });

  @override
  State<SecurityScreen> createState() => _SecurityScreenState();
}

class _SecurityScreenState extends State<SecurityScreen> {
  final _phrase = TextEditingController();
  final _confirm = TextEditingController();
  final _email = TextEditingController();
  bool _changing = false;
  bool _changingEmail = false;
  bool _busy = false;
  String? _error;
  String? _ok;

  @override
  void dispose() {
    _phrase.dispose();
    _confirm.dispose();
    _email.dispose();
    super.dispose();
  }

  Future<void> _submitEmail() async {
    final cb = widget.onChangeEmail;
    if (cb == null) return;
    final addr = _email.text.trim();
    if (addr.isEmpty) {
      setState(() => _error = 'Enter the new email address.');
      return;
    }
    if (addr.toLowerCase() == widget.accountEmail.toLowerCase()) {
      setState(() => _error = 'That is already your email.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _ok = null;
    });
    try {
      await cb(addr);
      if (mounted) {
        setState(() {
          _busy = false;
          _changingEmail = false;
          _ok =
              'Confirmation links sent to your current and new address. The change takes effect once you open both.';
          _email.clear();
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.toString().replaceFirst('StateError: ', '');
        });
      }
    }
  }

  Future<void> _signOutEverywhere() async {
    final cb = widget.onSignOutEverywhere;
    if (cb == null) return;
    final c = RelicTheme.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dc) => Theme(
        data: materialThemeFor(c),
        child: AlertDialog(
          backgroundColor: c.panel,
          title: Text('Sign out everywhere?',
              style: RelicTheme.headline(size: 17, color: c.text)),
          content: Text(
              'Every device signs out of your Relic account. Other devices lose access right away; this device stays connected until its session next refreshes. Your vault and recovery kit are unaffected.',
              style: RelicTheme.sans(
                  size: 13, color: c.textSecondary, height: 1.5)),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dc, false),
                child: Text('Cancel',
                    style: RelicTheme.sans(
                        size: 13,
                        weight: FontWeight.w500,
                        color: c.textMuted))),
            TextButton(
                onPressed: () => Navigator.pop(dc, true),
                child: Text('Sign out all',
                    style: RelicTheme.sans(
                        size: 13,
                        weight: FontWeight.w600,
                        color: c.dangerText))),
          ],
        ),
      ),
    );
    if (ok != true) return;
    setState(() {
      _busy = true;
      _error = null;
      _ok = null;
    });
    try {
      await cb();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _ok = 'Signed out on all devices.';
      });
      // This device is still connected on a token that now dies at its next
      // refresh (~1h). Offer to disconnect here and now instead of limping.
      final disconnect = widget.onDisconnect;
      if (disconnect == null) return;
      final also = await showDialog<bool>(
        context: context,
        builder: (dc) => Theme(
          data: materialThemeFor(c),
          child: AlertDialog(
            backgroundColor: c.panel,
            title: Text('Signed out everywhere',
                style: RelicTheme.headline(size: 17, color: c.text)),
            content: Text('Also disconnect this device now?',
                style: RelicTheme.sans(
                    size: 13, color: c.textSecondary, height: 1.5)),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dc, false),
                  child: Text('Not now',
                      style: RelicTheme.sans(
                          size: 13,
                          weight: FontWeight.w500,
                          color: c.textMuted))),
              TextButton(
                  onPressed: () => Navigator.pop(dc, true),
                  child: Text('Disconnect',
                      style: RelicTheme.sans(
                          size: 13,
                          weight: FontWeight.w600,
                          color: c.dangerText))),
            ],
          ),
        ),
      );
      if (!mounted) return;
      if (also == true) {
        disconnect();
        Navigator.of(context).pop(); // leave Security; host swaps to onboarding
      } else {
        setState(() => _ok =
            'This device will lose sync within about an hour. Disconnect and sign in again when ready.');
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.toString().replaceFirst('StateError: ', '');
        });
      }
    }
  }

  /// Delete the account for good: explain, require the user to type their
  /// signed-in email (case-insensitive), call the repo, then run the host's
  /// disconnect path and leave. Nothing local is deleted.
  Future<void> _deleteAccount() async {
    final del = widget.onDeleteAccount;
    if (del == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => _DeleteAccountDialog(accountEmail: widget.accountEmail),
    );
    if (confirmed != true) return;
    setState(() {
      _busy = true;
      _error = null;
      _ok = null;
    });
    try {
      await del();
      if (!mounted) return;
      // Run the host's disconnect path and leave Security; the host lands on
      // onboarding welcome (mobile) / the disconnected surface (desktop).
      widget.onDisconnect?.call();
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.toString().replaceFirst('StateError: ', '');
        });
      }
    }
  }

  Future<void> _submit() async {
    if (_phrase.text.isEmpty) return;
    if (_phrase.text != _confirm.text) {
      setState(() => _error = "Passphrases don't match.");
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _ok = null;
    });
    try {
      await widget.onChangePassphrase(_phrase.text);
      if (mounted) {
        setState(() {
          _busy = false;
          _changing = false;
          _ok = 'Passphrase changed.';
          _phrase.clear();
          _confirm.clear();
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.toString().replaceFirst('StateError: ', '');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    return DrillShell(
      title: 'Security',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _drillRow(
            c,
            icon: LucideIcons.keyRound,
            title: 'Show recovery kit',
            subtitle: 'Your way back in if you forget your vault passphrase.',
            trailing: Icon(LucideIcons.chevronRight,
                size: 14, color: c.textFaintest),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => RecoveryKitScreen(
                    requireProof: false,
                    kitText: RecoveryKit.fromMk(
                        widget.masterKey, widget.accountEmail)))),
          ),
          _drillRow(
            c,
            icon: LucideIcons.rectangleEllipsis,
            title: 'Change vault passphrase',
            subtitle: 'Re-wraps your key. Your recovery kit stays valid.',
            trailing: Icon(
                _changing ? LucideIcons.chevronUp : LucideIcons.chevronDown,
                size: 14,
                color: c.textFaintest),
            onTap: () => setState(() => _changing = !_changing),
          ),
          if (_changing)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  Insets.sm, Insets.lg, Insets.sm, Insets.xl),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  VaultPassphraseField(
                    controller: _phrase,
                    confirmController: _confirm,
                    hint: 'New vault passphrase',
                  ),
                  _box(TextField(
                    controller: _confirm,
                    obscureText: true,
                    style: RelicTheme.sans(size: 13.5, color: c.text),
                    decoration: _dec(c, 'Repeat the vault passphrase'),
                  )),
                  const SizedBox(height: Insets.md),
                  Row(children: [
                    PrimaryButton(
                      label: 'Change passphrase',
                      height: 36,
                      onTap: _busy ? null : _submit,
                    ),
                  ]),
                ],
              ),
            ),
          if (widget.onChangeEmail != null) ...[
            _drillRow(
              c,
              icon: LucideIcons.atSign,
              title: 'Change account email',
              subtitle:
                  'Your login email. We confirm on both addresses. Your vault passphrase is separate.',
              trailing: Icon(
                  _changingEmail
                      ? LucideIcons.chevronUp
                      : LucideIcons.chevronDown,
                  size: 14,
                  color: c.textFaintest),
              onTap: () => setState(() => _changingEmail = !_changingEmail),
            ),
            if (_changingEmail)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    Insets.sm, Insets.lg, Insets.sm, Insets.xl),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _box(TextField(
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      autocorrect: false,
                      style: RelicTheme.sans(size: 13.5, color: c.text),
                      decoration: _dec(c, 'New account email'),
                    )),
                    const SizedBox(height: Insets.md),
                    Row(children: [
                      PrimaryButton(
                        label: 'Send confirmation links',
                        height: 36,
                        onTap: _busy ? null : _submitEmail,
                      ),
                    ]),
                  ],
                ),
              ),
          ],
          if (widget.onSignOutEverywhere != null)
            _drillRow(
              c,
              icon: LucideIcons.logOut,
              iconColor: c.dangerText,
              title: 'Sign out everywhere',
              subtitle:
                  'Sign every device out of your account. Use this if a device is lost.',
              onTap: _busy ? null : _signOutEverywhere,
            ),
          if (widget.onDeleteAccount != null) ...[
            const SizedBox(height: Insets.xxl),
            _drillRow(
              c,
              icon: LucideIcons.trash2,
              iconColor: c.danger,
              title: 'Delete account',
              titleColor: c.danger,
              subtitle:
                  'Permanently delete your synced vault and account on our servers.',
              onTap: _busy ? null : _deleteAccount,
              last: true,
            ),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: Insets.md),
              child: Text(_error!,
                  style: RelicTheme.sans(
                      size: 12, color: c.dangerText, height: 1.45)),
            ),
          if (_ok != null)
            Padding(
              padding: const EdgeInsets.only(top: Insets.md),
              child: Text(_ok!,
                  style: RelicTheme.sans(
                      size: 12, color: c.success, height: 1.45)),
            ),
        ],
      ),
    );
  }

  Widget _box(Widget child) => child;

  InputDecoration _dec(RelicColors c, String hint) => InputDecoration(
        hintText: hint,
        hintStyle: RelicTheme.sans(size: 13.5, color: c.textFaintest),
        filled: true,
        fillColor: c.surface,
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(Radii.input),
            borderSide: BorderSide(color: c.borderStrong)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(Radii.input),
            borderSide: BorderSide(color: c.accent, width: 1.5)),
      );
}

/// Delete-account confirmation: explains the consequences, then requires the
/// user to type their signed-in email (case-insensitive) before the danger
/// button enables. Pops `true` only when confirmed.
class _DeleteAccountDialog extends StatefulWidget {
  final String accountEmail;
  const _DeleteAccountDialog({required this.accountEmail});

  @override
  State<_DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<_DeleteAccountDialog> {
  final _email = TextEditingController();

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    final matches = emailConfirmMatches(_email.text, widget.accountEmail);
    return Theme(
      data: materialThemeFor(c),
      child: AlertDialog(
        backgroundColor: c.panel,
        title: Text('Delete account?',
            style: RelicTheme.headline(size: 17, color: c.text)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Option A: store-safe builds state facts and stop — no
            // subscription language, and "Manage plan" doesn't exist on iOS.
            Text(
                storeSafeBuild
                    ? 'This permanently deletes your synced vault and account '
                        'on our servers. Local history on your devices is not '
                        'deleted.'
                    : 'This permanently deletes your synced vault and account '
                        'on our servers. Local history on your devices is not '
                        'deleted. If you have an active subscription, cancel '
                        'it first in Manage plan.',
                style: RelicTheme.sans(
                    size: 13, color: c.textSecondary, height: 1.5)),
            const SizedBox(height: Insets.lg),
            Text('Type your email to confirm:',
                style: RelicTheme.label(c.textMuted)),
            const SizedBox(height: Insets.sm),
            TextField(
              controller: _email,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.emailAddress,
              onChanged: (_) => setState(() {}),
              style: RelicTheme.sans(size: 13.5, color: c.text),
              decoration: InputDecoration(
                hintText: widget.accountEmail,
                hintStyle: RelicTheme.sans(size: 13.5, color: c.textFaintest),
                filled: true,
                fillColor: c.surface,
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(Radii.input),
                    borderSide: BorderSide(color: c.borderStrong)),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(Radii.input),
                    borderSide: BorderSide(color: c.accent, width: 1.5)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text('Cancel',
                  style: RelicTheme.sans(
                      size: 13, weight: FontWeight.w500, color: c.textMuted))),
          TextButton(
              onPressed: matches ? () => Navigator.pop(context, true) : null,
              child: Text('Delete account',
                  style: RelicTheme.sans(
                      size: 13,
                      weight: FontWeight.w600,
                      color: matches ? c.danger : c.textFaintest))),
        ],
      ),
    );
  }
}

/// The settings "your devices" list (docs/cloudflare/13 §7), with remote remove.
class DevicesScreen extends StatefulWidget {
  final Future<String?> Function() bearer;

  /// If set, register this device under [selfLabel] before listing, so it shows
  /// up in its own list (mobile already registers on connect; desktop uses this).
  final String? selfLabel;

  /// If set, the screen offers an "Add a device" action (shows a pairing QR).
  final Uint8List? masterKey;

  /// The Supabase user id, forwarded to [AddDeviceScreen] so the pairing surface
  /// can mint an account-bound typed code (Supabase mode). Null on legacy repos.
  final String? accountId;

  /// When set, renaming THIS device also updates the host's local device label
  /// (desktop prefs / mobile creds), so captures pick up the new name too.
  final Future<void> Function(String label)? onRenameThisDevice;

  /// When set, the device-cap dialog offers an upgrade action (desktop opens
  /// checkout; mobile opens store-safe guidance). See [showDeviceCapDialog].
  final Future<void> Function()? onUpgrade;
  final String upgradeLabel;
  const DevicesScreen(
      {super.key,
      required this.bearer,
      this.selfLabel,
      this.masterKey,
      this.accountId,
      this.onRenameThisDevice,
      this.onUpgrade,
      this.upgradeLabel = 'Upgrade'});

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  DeviceDirectory? _dir;
  List<DeviceEntry>? _devices;
  String? _error;
  String? _actionError; // inline action feedback (the drill card has no snackbars)
  String? _myVersion; // for the "outdated" hint on other devices

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform()
        .then((i) => mounted ? setState(() => _myVersion = i.version) : null)
        .catchError((_) {});
    _load();
  }

  /// Meta line: platform, when the device was last seen syncing, and the app
  /// version it reported. "This device" prefers its own live version over the
  /// (up to an hour stale) server value.
  String _deviceMeta(DeviceEntry d) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final seen = d.lastSeenAt;
    final ver = d.thisDevice ? (_myVersion ?? d.appVersion) : d.appVersion;
    return [
      if (d.thisDevice) 'This device',
      if (d.platform.isNotEmpty) d.platform,
      if (seen != null)
        now - seen < 90 ? 'seen just now' : 'seen ${relativeAge(seen, now)}',
      if (ver != null && ver.isNotEmpty) 'v$ver',
    ].join(' · ');
  }

  /// True when [d] runs an older build than THIS machine. Never flagged when
  /// we're the older one (the chip would point the wrong way).
  bool _outdated(DeviceEntry d) {
    final mine = _myVersion;
    final theirs = d.appVersion;
    if (d.thisDevice || mine == null || theirs == null) return false;
    return compareVersions(theirs, mine) < 0;
  }

  Future<void> _load() async {
    try {
      final id = await DeviceId.get();
      final dir = _dir ??= OnboardingService(deviceId: id).devicesWith(widget.bearer);
      if (widget.selfLabel != null && _devices == null) {
        try {
          await dir.register(label: widget.selfLabel!, platform: DeviceId.platform());
        } on DeviceCapException catch (e) {
          if (mounted) {
            await showDeviceCapDialog(context,
                directory: dir,
                devices: e.devices,
                label: widget.selfLabel!,
                platform: DeviceId.platform(),
                onUpgrade: widget.onUpgrade,
                upgradeLabel: widget.upgradeLabel);
          }
        } catch (_) {/* offline: still show the list */}
      }
      final list = await dir.list();
      if (mounted) setState(() => _devices = list);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _remove(DeviceEntry d) async {
    setState(() => _actionError = null);
    final c = RelicTheme.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dc) => AlertDialog(
        backgroundColor: c.panel,
        title: Text('Remove device?',
            style: RelicTheme.headline(size: 17, color: c.text)),
        content: Text(
            'Remove "${d.label}"? It will lose access to your vault on its next sync.',
            style: RelicTheme.sans(
                size: 13, color: c.textSecondary, height: 1.5)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dc, false),
              child: Text('Cancel',
                  style: RelicTheme.sans(
                      size: 13, weight: FontWeight.w500, color: c.textMuted))),
          TextButton(
              onPressed: () => Navigator.pop(dc, true),
              child: Text('Remove',
                  style: RelicTheme.sans(
                      size: 13,
                      weight: FontWeight.w600,
                      color: c.dangerText))),
        ],
      ),
    );
    if (ok != true) return;
    await _dir!.remove(d.deviceId);
    await _load();
  }

  /// Rename [d] via the PATCH endpoint, prefilled with its current label. A
  /// this-device rename also updates the host's local label (onRenameThisDevice)
  /// so new captures pick up the new name.
  Future<void> _rename(DeviceEntry d) async {
    setState(() => _actionError = null);
    final c = RelicTheme.of(context);
    final controller = TextEditingController(text: d.label);
    final label = await showDialog<String>(
      context: context,
      builder: (dc) => Theme(
        data: materialThemeFor(c),
        child: AlertDialog(
          backgroundColor: c.panel,
          title: Text('Rename device',
              style: RelicTheme.headline(size: 17, color: c.text)),
          content: TextField(
            controller: controller,
            autofocus: true,
            style: RelicTheme.sans(size: 13.5, color: c.text),
            decoration: InputDecoration(
              hintText: 'Device name',
              hintStyle: RelicTheme.sans(size: 13.5, color: c.textFaintest),
              filled: true,
              fillColor: c.surface,
              enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(Radii.input),
                  borderSide: BorderSide(color: c.borderStrong)),
              focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(Radii.input),
                  borderSide: BorderSide(color: c.accent, width: 1.5)),
            ),
            onSubmitted: (v) => Navigator.pop(dc, v.trim()),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dc, null),
                child: Text('Cancel',
                    style: RelicTheme.sans(
                        size: 13,
                        weight: FontWeight.w500,
                        color: c.textMuted))),
            TextButton(
                onPressed: () => Navigator.pop(dc, controller.text.trim()),
                // Not gold: gold as text belongs on a tag tint, and a bare
                // dialog action has none under it.
                child: Text('Save',
                    style: RelicTheme.sans(
                        size: 13, weight: FontWeight.w600, color: c.text))),
          ],
        ),
      ),
    );
    controller.dispose();
    if (label == null || label.isEmpty || label == d.label) return;
    try {
      await _dir!.rename(d.deviceId, label);
      if (d.thisDevice) await widget.onRenameThisDevice?.call(label);
    } catch (_) {
      if (mounted) {
        setState(() => _actionError = 'Could not rename the device.');
      }
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    return DrillShell(
      title: 'Your devices',
      actions: [
        if (widget.masterKey != null)
          GhostButton(
            icon: LucideIcons.plus,
            label: 'Add a device',
            size: 26,
            fontSize: 12,
            onTap: () async {
              await Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => AddDeviceScreen(
                      masterKey: widget.masterKey!,
                      bearer: widget.bearer,
                      accountId: widget.accountId)));
              if (mounted) _load();
            },
          ),
      ],
      child: _error != null
          ? Padding(
              padding: const EdgeInsets.only(top: Insets.xxl),
              child: Text(_error!,
                  style: RelicTheme.sans(size: 12.5, color: c.textMuted)),
            )
          : _devices == null
              ? Padding(
                  padding: const EdgeInsets.only(top: Insets.section),
                  child:
                      Center(child: CircularProgressIndicator(color: c.accent)),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_actionError != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: Insets.sm),
                        child: Text(_actionError!,
                            style: RelicTheme.sans(
                                size: 11.5, color: c.dangerText)),
                      ),
                    for (var i = 0; i < _devices!.length; i++)
                      _drillRow(
                        c,
                        icon: _iconFor(_devices![i].platform),
                        title: _devices![i].label,
                        badge: _outdated(_devices![i])
                            ? Tooltip(
                                message:
                                    'Running v${_devices![i].appVersion}. This device runs v$_myVersion. Update it from relic.space/download.',
                                // The system's meta chip: tag tint, deep-gold
                                // mono, no hairline.
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: Insets.sm, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: c.tagBg,
                                    borderRadius:
                                        BorderRadius.circular(Radii.tag),
                                  ),
                                  child: Text('outdated',
                                      style: RelicTheme.mono(
                                          size: 9.5, color: c.tagText)),
                                ),
                              )
                            : null,
                        subtitle: _deviceMeta(_devices![i]),
                        subtitleMono: true,
                        onTap: () => _rename(_devices![i]),
                        last: i == _devices!.length - 1,
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            GhostIconButton(
                              icon: LucideIcons.pencil,
                              size: 26,
                              iconSize: 14,
                              tooltip: 'Rename',
                              swallowTap: true,
                              onTap: () => _rename(_devices![i]),
                            ),
                            if (!_devices![i].thisDevice) ...[
                              const SizedBox(width: 2),
                              GhostIconButton(
                                icon: LucideIcons.trash2,
                                size: 26,
                                iconSize: 14,
                                tooltip: 'Remove',
                                swallowTap: true,
                                onTap: () => _remove(_devices![i]),
                              ),
                            ],
                          ],
                        ),
                      ),
                  ],
                ),
    );
  }

  IconData _iconFor(String platform) => switch (platform) {
        'android' || 'ios' => LucideIcons.smartphone,
        'windows' || 'macos' || 'linux' => LucideIcons.monitor,
        _ => LucideIcons.monitorSmartphone,
      };
}

IconData _platformIcon(String platform) => switch (platform) {
      'android' || 'ios' => LucideIcons.smartphone,
      'windows' || 'macos' || 'linux' => LucideIcons.monitor,
      _ => LucideIcons.monitorSmartphone,
    };

/// Reject-but-actionable device cap (docs/cloudflare/13 §10.3). When registering
/// this device would exceed the plan's limit, the backend returns a 409 with the
/// current device list; instead of silently swallowing it, show that list so the
/// user can remove one device (which re-tries registration) or dismiss and keep
/// using the vault on this device unregistered. Returns true if this device was
/// registered (a slot was freed), false if the user dismissed.
Future<bool> showDeviceCapDialog(
  BuildContext context, {
  required DeviceDirectory directory,
  required List<DeviceEntry> devices,
  required String label,
  required String platform,
  Future<void> Function()? onUpgrade,
  String upgradeLabel = 'Upgrade',
}) async {
  final resolved = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _DeviceCapDialog(
      directory: directory,
      devices: devices,
      label: label,
      platform: platform,
      onUpgrade: onUpgrade,
      upgradeLabel: upgradeLabel,
    ),
  );
  return resolved ?? false;
}

class _DeviceCapDialog extends StatefulWidget {
  final DeviceDirectory directory;
  final List<DeviceEntry> devices;
  final String label;
  final String platform;

  /// When set, the copy's "or upgrade your plan" gets a real action. Desktop
  /// opens Stripe checkout; mobile opens store-safe guidance (relic.space).
  final Future<void> Function()? onUpgrade;
  final String upgradeLabel;
  const _DeviceCapDialog({
    required this.directory,
    required this.devices,
    required this.label,
    required this.platform,
    this.onUpgrade,
    this.upgradeLabel = 'Upgrade',
  });

  @override
  State<_DeviceCapDialog> createState() => _DeviceCapDialogState();
}

class _DeviceCapDialogState extends State<_DeviceCapDialog> {
  late List<DeviceEntry> _devices = widget.devices;
  String? _busyId; // device currently being removed
  bool _upgrading = false;
  String? _error;

  Future<void> _upgrade() async {
    final up = widget.onUpgrade;
    if (up == null) return;
    setState(() => _upgrading = true);
    try {
      await up();
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not open the upgrade page.');
      }
    } finally {
      if (mounted) setState(() => _upgrading = false);
    }
  }

  /// Remove [d], then re-try registering this device into the freed slot. On
  /// success the dialog closes with `true`; if the account is somehow still over
  /// the cap, refresh the list and let the user remove another.
  Future<void> _removeAndRetry(DeviceEntry d) async {
    setState(() {
      _busyId = d.deviceId;
      _error = null;
    });
    try {
      await widget.directory.remove(d.deviceId);
      try {
        await widget.directory
            .register(label: widget.label, platform: widget.platform);
        if (mounted) Navigator.of(context).pop(true);
        return;
      } on DeviceCapException catch (e) {
        if (mounted) setState(() => _devices = e.devices);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Could not update devices. Check your connection.');
      }
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    return Theme(
      data: materialThemeFor(c),
      child: Dialog(
        backgroundColor: c.base,
        insetPadding: const EdgeInsets.symmetric(
            horizontal: Insets.xxl, vertical: Insets.section),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.card),
            side: BorderSide(color: c.border)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Padding(
            padding: const EdgeInsets.all(Insets.xxl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Device limit reached',
                    style: RelicTheme.headline(size: 20, color: c.text)),
                const SizedBox(height: Insets.sm),
                // The "or upgrade" clause follows the action: with no upgrade
                // affordance (store-safe iOS builds pass onUpgrade: null) the
                // copy must not steer either (App Store 3.1.1).
                Text(
                    widget.onUpgrade != null
                        ? 'Your plan is full. Remove a device to connect this one, or upgrade your plan for more devices.'
                        : 'Your plan is full. Remove a device to connect this one.',
                    style: RelicTheme.sans(
                        size: 13, color: c.textSecondary, height: 1.5)),
                const SizedBox(height: Insets.xl),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final d in _devices)
                        Container(
                          margin: const EdgeInsets.only(bottom: Insets.sm),
                          decoration: BoxDecoration(
                              color: c.panel,
                              borderRadius: BorderRadius.circular(Radii.row),
                              border: Border.all(color: c.border)),
                          child: ListTile(
                            leading:
                                Icon(_platformIcon(d.platform), color: c.accent),
                            title: Text(d.label,
                                style:
                                    RelicTheme.sans(size: 13, color: c.text)),
                            // The platform is a machine fact, so it is mono.
                            subtitle: Text(d.platform,
                                style: RelicTheme.mono(
                                    size: 11, color: c.textMuted)),
                            trailing: _busyId == d.deviceId
                                ? SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2, color: c.accent))
                                : GhostButton(
                                    label: 'Remove',
                                    size: 28,
                                    fontSize: 12,
                                    style: GhostStyle.danger,
                                    onTap: _busyId == null
                                        ? () => _removeAndRetry(d)
                                        : null,
                                  ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(
                        top: Insets.xs, bottom: Insets.xs),
                    child: Text(_error!,
                        style: RelicTheme.sans(
                            size: 12.5, color: c.dangerText, height: 1.45)),
                  ),
                if (widget.onUpgrade != null) ...[
                  const SizedBox(height: Insets.sm),
                  // The dialog's one gold CTA. While checkout opens the label
                  // holds and the leading glyph becomes the spinner.
                  SizedBox(
                    width: double.infinity,
                    child: GhostButton(
                      label: widget.upgradeLabel,
                      size: 40,
                      fontSize: 13.5,
                      iconSize: 16,
                      style: GhostStyle.filled,
                      icon: _upgrading ? null : LucideIcons.zap,
                      iconBuilder: _upgrading
                          ? (size, color) => SizedBox(
                                width: size,
                                height: size,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: color),
                              )
                          : null,
                      onTap: _upgrading ? null : _upgrade,
                    ),
                  ),
                ],
                const SizedBox(height: Insets.sm),
                Center(
                  child: GhostButton(
                    label: 'Not now',
                    size: 34,
                    fontSize: 12.5,
                    onTap: _busyId == null
                        ? () => Navigator.of(context).pop(false)
                        : null,
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
