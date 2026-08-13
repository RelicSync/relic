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

  // Single-instance guard, the macOS analog of the Windows runner's named
  // mutex (windows/runner/main.cpp). Launch Services only de-duplicates
  // launches of the SAME bundle path; a copy opened from a still-mounted DMG
  // or a stray build product is a real second process — two capture loops
  // writing one SQLite WAL, two menu-bar items. If another instance of our
  // bundle id is already running, ask it to surface (a reopen event, which
  // its applicationShouldHandleReopen below turns into a presented window)
  // and bow out before the Flutter engine touches the database.
  //
  // Carve-outs, same as Windows: RELIC_DATA_DIR instances own a separate
  // data dir + DB, so they may coexist (self-host harness, portable runs).
  // Debug builds skip the guard entirely — `flutter run` next to an
  // installed Relic is the daily dev loop.
  //
  // It runs from init (nib load, before any launching notification) because
  // FlutterAppDelegate implements the applicationWillFinishLaunching /
  // ...DidFinishLaunching pair PRIVATELY — not in its public header — so a
  // subclass method would silently shadow engine work with no super to call.
  override init() {
    AppDelegate.exitIfAlreadyRunning()
    super.init()
  }

  private static func exitIfAlreadyRunning() {
    #if !DEBUG
    if ProcessInfo.processInfo.environment["RELIC_DATA_DIR"] == nil,
       let bundleId = Bundle.main.bundleIdentifier {
      let myPid = ProcessInfo.processInfo.processIdentifier
      let other = NSRunningApplication
        .runningApplications(withBundleIdentifier: bundleId)
        .first { $0.processIdentifier != myPid && !$0.isTerminated }
      if let other {
        if let url = other.bundleURL {
          // Block until Launch Services has taken the reopen request —
          // exit(0) straight after the call could race the XPC send.
          let sent = DispatchSemaphore(value: 0)
          NSWorkspace.shared.openApplication(
            at: url, configuration: NSWorkspace.OpenConfiguration()
          ) { _, _ in sent.signal() }
          _ = sent.wait(timeout: .now() + 3)
        } else {
          other.activate(options: [])
        }
        exit(0)
      }
    }
    #endif
  }

  // Launching the app again (Dock, Finder, `open -a Relic`) surfaces the
  // existing instance's window — the macOS analog of the Windows runner's
  // RelicShowExisting broadcast (windows/runner/main.cpp). Launch Services
  // routes a same-bundle relaunch here; a different-copy launch arrives as
  // the reopen sent by the guard above.
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
