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
      // Only our own window: NSApp.windows also holds the menu-bar item's
      // status window, which AppKit owns and must not be ordered around.
      // Launching by hand is an explicit ask, so this is app mode — come
      // forward properly instead of appearing behind the current app.
      for window in sender.windows.compactMap({ $0 as? MainFlutterWindow }) {
        window.present(activate: true)
      }
    }
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
