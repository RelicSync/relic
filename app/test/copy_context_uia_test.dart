// The Windows UI Automation reader against real controls, without touching
// the user's focus: a helper process shows an off-screen window that never
// activates, holding a RichEdit (text pattern) and a plain edit box, each with
// a selection set in code. The reader is rooted at that window's handle.
//
// Windows only, opt-in (it starts a window):
//   RELIC_UIA_TEST=1 flutter test test/copy_context_uia_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/platform/src/windows/copy_context_win.dart';

const _helper = r'''
Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing -TypeDefinition @"
using System; using System.Drawing; using System.Windows.Forms;
public class QuietForm : Form {
  protected override bool ShowWithoutActivation { get { return true; } }
  protected override CreateParams CreateParams { get {
    var p = base.CreateParams; p.ExStyle |= 0x08000000 | 0x80; return p; } } // NOACTIVATE | TOOLWINDOW
}
public static class Harness {
  public static void Run(string a, string b, string copied) {
    var f = new QuietForm { StartPosition = FormStartPosition.Manual, Location = new Point(-3000, -3000), Size = new Size(600, 400), ShowInTaskbar = false };
    var rich = new RichTextBox { Dock = DockStyle.Top, Height = 200, HideSelection = false, Text = a };
    var edit = new TextBox { Dock = DockStyle.Bottom, Multiline = true, Height = 150, HideSelection = false, Text = b };
    f.Controls.Add(rich); f.Controls.Add(edit);
    f.Shown += (s, e) => {
      rich.Select(a.IndexOf(copied), copied.Length);
      edit.Select(b.IndexOf(copied), copied.Length);
      Console.WriteLine("HWND " + rich.Handle.ToInt64() + " " + edit.Handle.ToInt64());
      Console.Out.Flush();
    };
    Application.Run(f);
  }
}
"@
[Harness]::Run($args[0], $args[1], $args[2])
''';

void main() {
  final run = Platform.isWindows && Platform.environment['RELIC_UIA_TEST'] == '1';

  test('reads the words around a selection through UI Automation', () async {
    if (!run) {
      markTestSkipped('set RELIC_UIA_TEST=1 on Windows to run');
      return;
    }
    const copied = '150 mm/s';
    const rich = 'I calibrated the extruder and set the outer perimeter speed to '
        '150 mm/s but the blobs still show up at every layer change.';
    const plain = 'Notes for the printer: travel at 150 mm/s and retract 2 mm.';
    final script = File('${Directory.systemTemp.path}/relic_uia_harness.ps1')
      ..writeAsStringSync(_helper);
    final proc = await Process.start('powershell',
        ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script.path, rich, plain, copied]);
    addTearDown(() => proc.kill());
    final line = await proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .firstWhere((l) => l.startsWith('HWND '))
        .timeout(const Duration(seconds: 30));
    final handles = line.split(' ').skip(1).map(int.parse).toList();

    final fromRich = await surroundingTextOfWindow(handles[0], copied);
    expect(fromRich, isNotNull, reason: 'RichEdit exposes a text pattern');
    expect(fromRich!.before, endsWith('outer perimeter speed to'));
    expect(fromRich.after, startsWith('but the blobs still show up'));

    final fromEdit = await surroundingTextOfWindow(handles[1], copied);
    expect(fromEdit, isNotNull, reason: 'edit box: text pattern or value fallback');
    expect(fromEdit!.before, contains('travel at'));
    expect(fromEdit.after, contains('retract 2 mm'));

    // A copy that is not the current selection must not borrow its context.
    final wrong = await surroundingTextOfWindow(handles[0], 'retract 2 mm');
    expect(wrong, isNull);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
