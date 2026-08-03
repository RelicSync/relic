import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  // Tray-resident agent (LSUIElement): closing/hiding the popup must NOT quit —
  // capture keeps running and the hotkey/menu-bar item bring the window back.
  // Mirrors the Windows build, where the app lives in the tray.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  // Launching the app again (Dock, Finder, `open -a Relic`) surfaces the
  // existing instance's window — the macOS analog of the Windows runner's
  // RelicShowExisting broadcast (windows/runner/main.cpp). Launch Services
  // already prevents a true second instance of a bundled app.
  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag {
      for window in sender.windows {
        window.makeKeyAndOrderFront(self)
      }
      NSApp.activate(ignoringOtherApps: true)
    }
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
