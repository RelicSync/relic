import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../data/voice_controller.dart';
import '../theme/relic_theme.dart';
import '../theme/tokens.dart';
import '../widgets/controls.dart';
import '../widgets/fields.dart';
import '../widgets/settings_controls.dart';

class VoiceSettings extends StatefulWidget {
  const VoiceSettings({super.key, required this.voice});
  final VoiceController voice;
  @override
  State<VoiceSettings> createState() => _VoiceSettingsState();
}

class _VoiceSettingsState extends State<VoiceSettings> {
  late final _vocabulary = TextEditingController(
    text: widget.voice.vocabulary.join('\n'),
  );
  late final _corrections = TextEditingController(
    text: widget.voice.corrections
        .map(
          (r) =>
              '${r['heard']} => ${r['replacement']}${(r['app'] as String? ?? '').isEmpty ? '' : ' | ${r['app']}'}',
        )
        .join('\n'),
  );
  String _message = '';
  @override
  void dispose() {
    _vocabulary.dispose();
    _corrections.dispose();
    super.dispose();
  }

  Future<void> _saveWords() async {
    final vocabulary = _vocabulary.text
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList();
    final rules = <Map<String, dynamic>>[];
    for (final line
        in _corrections.text.split('\n').where((s) => s.trim().isNotEmpty)) {
      final parts = line.split('=>');
      if (parts.length != 2 ||
          parts.first.trim().isEmpty ||
          parts.last.trim().isEmpty) {
        setState(
          () =>
              _message = 'Use heard phrase => replacement, one rule per line.',
        );
        return;
      }
      final target = parts.last.split('|');
      if (target.length > 2 ||
          target.first.trim().isEmpty ||
          (target.length == 2 && target.last.trim().isEmpty)) {
        setState(
          () =>
              _message = 'Use a replacement, optionally followed by | app.exe.',
        );
        return;
      }
      final heard = parts.first.trim();
      final app = target.length > 1 ? target.last.trim().toLowerCase() : '';
      if (rules.any(
        (r) =>
            (r['heard'] as String).toLowerCase() == heard.toLowerCase() &&
            r['app'] == app,
      )) {
        setState(
          () => _message = 'Keep one replacement per heard phrase and app.',
        );
        return;
      }
      rules.add({
        'heard': heard,
        'replacement': target.first.trim(),
        'app': app,
        'enabled': true,
      });
    }
    if (vocabulary.length > 500 ||
        vocabulary.any((v) => v.length > 80) ||
        rules.length > 500 ||
        rules.any(
          (r) =>
              (r['heard'] as String).length > 160 ||
              (r['replacement'] as String).length > 160,
        )) {
      setState(
        () => _message =
            'Use up to 500 entries. Spellings: 80 characters. Corrections: 160 characters.',
      );
      return;
    }
    widget.voice.vocabulary = vocabulary;
    widget.voice.corrections = rules;
    try {
      await widget.voice.savePreferences();
      if (mounted) {
        setState(
          () => _message = 'Saved on this device. Applies to new recordings.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() => _message = 'Could not save settings. Try again.');
      }
    }
  }

  bool _showRaw = false;

  Widget _description(RelicColors c, String text) => Text(
    text,
    style: RelicTheme.sans(size: 11.5, color: c.textMuted, height: 1.45),
  );

  Widget _heading(RelicColors c, String text) => Padding(
    padding: const EdgeInsets.fromLTRB(0, Insets.xxl, 0, Insets.sm),
    child: Text(
      text.toUpperCase(),
      style: RelicTheme.kicker(c.accentMuted, size: 10),
    ),
  );

  Widget _wordsField(
    RelicColors c,
    TextEditingController controller,
    String hint,
  ) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
    decoration: BoxDecoration(
      color: c.surface,
      borderRadius: BorderRadius.circular(Radii.input),
      border: Border.all(color: c.border),
    ),
    child: TextField(
      controller: controller,
      minLines: 3,
      maxLines: 8,
      style: RelicTheme.sans(size: 13, color: c.text),
      cursorColor: c.accent,
      decoration: kBareField.copyWith(
        hintText: hint,
        hintStyle: RelicTheme.sans(size: 13, color: c.textFaintest),
      ),
    ),
  );

  Widget _progress(RelicColors c, double value, String label) => Padding(
    padding: const EdgeInsets.symmetric(vertical: Insets.sm),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(Radii.pill),
      child: LinearProgressIndicator(
        value: value,
        minHeight: 3,
        color: c.accent,
        backgroundColor: c.track,
        semanticsLabel: label,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.voice,
    builder: (context, _) {
      final v = widget.voice;
      final c = RelicTheme.of(context);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(0, Insets.md, 0, Insets.sm),
            child: Text(
              'Voice',
              style: RelicTheme.headline(size: 22, color: c.text),
            ),
          ),
          _description(
            c,
            'Speak into a text field and keep a copy in Relic. Voice notes go straight to your vault. English, processed on this PC. Audio is never saved.',
          ),
          SettingsToggleRow(
            title: 'Enable Voice',
            sub:
                'On by default. Downloads 716 MB of models automatically during first setup.',
            value: v.enabled,
            onChanged: v.hasPending ? null : (on) => v.setEnabled(on),
          ),
          SettingsRow(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  v.status,
                  style: RelicTheme.sans(size: 12, color: c.textSecondary),
                ),
                if (v.enabled && !v.ready && v.progress > 0 && v.progress < 1)
                  _progress(c, v.progress, 'Voice setup download'),
                if (v.enabled && !v.ready && !v.busy) ...[
                  const SizedBox(height: Insets.sm),
                  GhostButton(
                    icon: LucideIcons.refreshCw,
                    label: 'Retry setup',
                    onTap: v.retry,
                  ),
                ],
              ],
            ),
          ),
          SettingsToggleRow(
            title: 'Right Alt shortcuts',
            sub: 'You can also start and stop Voice from the tray menu.',
            value: v.shortcuts,
            onChanged: v.busy
                ? null
                : (on) {
                    v.shortcuts = on;
                    v.savePreferences();
                  },
          ),
          SettingsRow(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _description(
                  c,
                  'Hold Right Alt to dictate. Release to finish. Double-tap to keep recording, then tap once to finish. Hold Left Ctrl first to save a voice note instead. Escape cancels.',
                ),
                const SizedBox(height: Insets.sm),
                _description(
                  c,
                  'Pressing Right Alt briefly opens the microphone while checking the gesture. Wait for the pulsing shadow before speaking. The icon follows your voice. Recording ends after 60 seconds.',
                ),
              ],
            ),
          ),
          SettingsToggleRow(
            title: 'Punctuation and capitalization',
            value: v.punctuation,
            onChanged: (on) {
              v.punctuation = on;
              v.savePreferences();
            },
          ),
          if (v.devices.isNotEmpty)
            SettingsRow(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Microphone',
                    style: RelicTheme.sans(size: 13, color: c.text),
                  ),
                  const SizedBox(height: Insets.sm),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 11),
                    decoration: BoxDecoration(
                      color: c.surface,
                      borderRadius: BorderRadius.circular(Radii.input),
                      border: Border.all(color: c.border),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<int>(
                        value: v.device ?? -1,
                        isExpanded: true,
                        dropdownColor: c.surface,
                        borderRadius: BorderRadius.circular(Radii.input),
                        style: RelicTheme.sans(size: 13, color: c.text),
                        icon: Icon(
                          LucideIcons.chevronDown,
                          size: 15,
                          color: c.textMuted,
                        ),
                        items: v.devices
                            .map(
                              (d) => DropdownMenuItem<int>(
                                value: d['id'] as int? ?? -1,
                                child: Text(
                                  d['name'] as String,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: v.busy
                            ? null
                            : (value) {
                                v.device = value == -1 ? null : value;
                                v.savePreferences();
                              },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          SettingsRow(
            last: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: Insets.sm,
                  runSpacing: Insets.sm,
                  children: [
                    GhostButton(
                      icon: LucideIcons.mic,
                      label: 'Test microphone and transcription',
                      onTap: v.ready && !v.busy && !v.hasPending
                          ? () => v.start(practice: true)
                          : null,
                    ),
                    if (v.recording) GhostButton(label: 'Stop', onTap: v.stop),
                    if (v.busy) GhostButton(label: 'Cancel', onTap: v.cancel),
                  ],
                ),
                if (v.recording)
                  _progress(c, (v.level * 8).clamp(0, 1), 'Microphone volume'),
                if (v.lastText.isNotEmpty) ...[
                  const SizedBox(height: Insets.md),
                  SelectableText(
                    v.lastText,
                    style: RelicTheme.sans(
                      size: 13,
                      color: c.text,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: Insets.sm),
                  Wrap(
                    spacing: Insets.sm,
                    runSpacing: Insets.sm,
                    children: [
                      GhostButton(
                        icon: LucideIcons.copy,
                        label: 'Copy result',
                        onTap: () =>
                            Clipboard.setData(ClipboardData(text: v.lastText)),
                      ),
                      GhostButton(
                        icon: _showRaw
                            ? LucideIcons.chevronUp
                            : LucideIcons.chevronDown,
                        label: 'Raw transcript',
                        onTap: () => setState(() => _showRaw = !_showRaw),
                      ),
                    ],
                  ),
                  if (_showRaw)
                    Padding(
                      padding: const EdgeInsets.only(top: Insets.sm),
                      child: SelectableText(
                        v.lastRaw,
                        style: RelicTheme.sans(size: 12, color: c.textMuted),
                      ),
                    ),
                ],
                if (v.hasPending)
                  Wrap(
                    spacing: Insets.sm,
                    runSpacing: Insets.sm,
                    children: [
                      PrimaryButton(
                        icon: LucideIcons.refreshCw,
                        label: 'Retry save',
                        onTap: v.retrySave,
                      ),
                      GhostButton(
                        label: 'Discard unsaved result',
                        style: GhostStyle.danger,
                        onTap: v.discardPending,
                      ),
                    ],
                  ),
              ],
            ),
          ),
          _heading(c, 'Preferred spelling'),
          _description(
            c,
            'One word or phrase per line, for example Claude or Relic. This fixes spelling and capitalization after recognition. It does not boost what the speech model hears.',
          ),
          const SizedBox(height: Insets.sm),
          _wordsField(c, _vocabulary, 'Claude\nRelic\nPostgreSQL'),
          _heading(c, 'Word corrections'),
          _description(
            c,
            'Explicit replacements, one per line: cloud code => Claude Code. Whole phrases only. Rules never cascade. To limit a rule to an app, add | code.exe. Voice notes use global rules.',
          ),
          const SizedBox(height: Insets.sm),
          _wordsField(c, _corrections, 'cloud code => Claude Code'),
          const SizedBox(height: Insets.md),
          PrimaryButton(
            icon: LucideIcons.check,
            label: 'Save words and corrections',
            onTap: _saveWords,
          ),
          if (_message.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: Insets.sm),
              child: _description(c, _message),
            ),
          const SizedBox(height: Insets.md),
          _description(
            c,
            'Words and corrections stay on this device. Saved dictations follow normal history retention. Promote one to keep it, or use Voice note.',
          ),
        ],
      );
    },
  );
}
