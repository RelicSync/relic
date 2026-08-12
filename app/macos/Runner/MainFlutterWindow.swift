import Cocoa
import FlutterMacOS

/// Relic's single window — and it is a panel on purpose.
///
/// The app is a menu-bar agent (LSUIElement). Summoning the history popup must
/// not pull the foreground away from whatever the user was typing in: the whole
/// paste-into-the-previous-app handover depends on that app still being active
/// when we hide again. A plain NSWindow cannot do that. Only an NSPanel carries
/// `.nonactivatingPanel`, which is documented as "the panel can receive
/// keyboard input without activating the owning application" — exactly the
/// popup's contract (type in the search field, the app you came from keeps the
/// foreground).
///
/// Settings and onboarding are a full app UI hosted in this same window, so the
/// window switches MODE rather than switching windows: [present] with
/// `activate: true` takes the foreground for real, `activate: false` is the
/// agent-mode popup. Dart drives both through ActivationBridge (`relic/activate`
/// present/dismiss), so the whole policy lives in one place per side.
class MainFlutterWindow: NSPanel {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    RelicBridges.register(with: flutterViewController.engine.binaryMessenger)

    // Panel traits. The style mask is applied through our own setter below, so
    // .nonactivatingPanel is in the mask from here on no matter who edits it.
    styleMask.insert(.nonactivatingPanel)
    isFloatingPanel = true
    // A panel normally waits to be clicked before it takes key. The popup is
    // summoned by a hotkey and the first keystroke belongs to its search field,
    // so it takes key the moment it is ordered on screen.
    becomesKeyOnlyIfNeeded = false
    // Settings/onboarding must survive the user alt-tabbing away mid-flow (to
    // copy a token, to read a passphrase). Dismissal is Dart's decision, in
    // onWindowBlur, which knows which surface is up.
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    // Over full-screen apps and on whichever Space the user is on: a clipboard
    // popup that only appears on the Space it was launched from is useless.
    // (window_manager's setAlwaysOnTop(true) also sets .floating; we set it
    // here so the very first summon is already correct.)
    level = .floating
    collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])

    super.awakeFromNib()
  }

  /// Panels are not key while the app is inactive unless they say so. Ours has
  /// to be, or the popup's search box would never see a keystroke.
  override var canBecomeKey: Bool { true }

  /// Main-window status belongs to windows that activate their app, which this
  /// one deliberately does not. Leaving it false also keeps window_manager's
  /// focus/blur stream single-sourced: it emits blur from windowDidResignMain
  /// AND (for panels) windowDidResignKey, so a window that could be both would
  /// fire two blurs per dismiss and hide the popup twice.
  override var canBecomeMain: Bool { false }

  /// window_manager edits the style mask from Dart — setAsFrameless and
  /// setTitleBarStyle insert .fullSizeContentView, setResizable/setClosable/
  /// setMinimizable insert and remove their own flags, and setAlwaysOnTop(false)
  /// explicitly REMOVES .nonactivatingPanel (WindowManager.swift:362). Losing
  /// that bit turns every summon back into an app switch, which is the bug this
  /// whole file exists to prevent, so re-assert it on every write.
  override var styleMask: NSWindow.StyleMask {
    get { super.styleMask }
    set { super.styleMask = newValue.union(.nonactivatingPanel) }
  }

  /// Order the window on screen and give it key status.
  ///
  /// [activate] false is agent mode: key (typing lands in the search field)
  /// without taking the foreground, so the app the user summoned us from is
  /// still frontmost when we hide again and the synthetic ⌘V has somewhere to
  /// land. [activate] true is app mode (settings, onboarding, the recovery
  /// kit): an LSUIElement agent is refused a polite activation while another
  /// app is frontmost, so it has to ask forcefully.
  ///
  /// Not window_manager's show(): that one calls
  /// `NSApp.activate(ignoringOtherApps: true)` unconditionally, one runloop turn
  /// after it replies to Dart, so every popup summon would steal the foreground
  /// and there would be no way to opt out from Dart.
  func present(activate: Bool) {
    // [dismiss] hides the whole app to hand the foreground back; a hidden app
    // cannot put a window on screen, so undo that first (without activating —
    // NSApp.unhide(_:) would make us active as a side effect).
    if NSApp.isHidden { NSApp.unhideWithoutActivation() }
    orderFrontRegardless()
    if activate { NSApp.activate(ignoringOtherApps: true) }
    makeKey()
  }

  /// Order the window off screen, and hand the foreground back when we hold it.
  ///
  /// In agent mode there is nothing to hand back — the popup never took it. But
  /// after settings/onboarding (or any OS dialog we opened) the app IS active,
  /// and an agent with no windows left stays active with the user's app dead
  /// behind it: keystrokes would go nowhere. NSApp.hide is what yields to the
  /// next app in line, and it leaves the menu-bar item and capture untouched.
  func dismiss() {
    orderOut(nil)
    if NSApp.isActive { NSApp.hide(nil) }
  }
}
