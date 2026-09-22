import AVFoundation
import Carbon.HIToolbox
import Cocoa
import FlutterMacOS

/// relic/voice on macOS: the Right Option gesture, the focused-target snapshot,
/// guarded Unicode insertion, the microphone permission and the overlay. The
/// mac twin of windows/runner/native_voice.cpp; the Dart side
/// (app/lib/data/voice_controller.dart) is shared and drives both through the
/// same method names and the same `event` payloads.
///
/// The key is physical Right Option (kVK_RightOption). Only its own
/// flagsChanged events are ever swallowed, and only while a gesture owns them:
/// a key pressed with Option held still arrives at the app with the Option
/// flag set, so Option-character entry (⌥e, ⌥8 …) keeps working exactly as
/// before, and the gesture bows out (forwarding) the moment it sees one.
///
/// Key events are read through a CGEvent tap, which needs the same
/// Accessibility grant the paste injection already asks for. Without it
/// `enable` answers false and the controller says the shortcut is unavailable;
/// tray/menu starts still work.
final class VoiceBridge {
  static let shared = VoiceBridge()

  private var channel: FlutterMethodChannel?
  private var gesture = VoiceGesture()
  private var enabled = false, validTarget = false, finishing = false
  private var keyTap: CFMachPort?, mouseTap: CFMachPort?
  private var keySource: CFRunLoopSource?, mouseSource: CFRunLoopSource?
  private var timer: Timer?
  private var blocked: [String] = []
  private var leftCtrlDownSeen = false

  // The target snapshot taken when a gesture becomes a candidate.
  private var targetPid: pid_t = 0
  private var targetKey = ""
  private var focus: AXUIElement?
  private var clipboardAtStart = 0
  private var targetGeneration: UInt64 = 0

  private static let ownEventTag: Int64 = 0x5245_4c56  // "RELV": our own posts, ignored by the tap
  private static let voiceKey = CGKeyCode(kVK_RightOption)
  // NX device-specific modifier bits, the only way to tell right from left.
  private static let rightOptionBit: UInt64 = 0x40
  private static let leftOptionBit: UInt64 = 0x20
  private static let leftControlBit: UInt64 = 0x1
  private static let rightControlBit: UInt64 = 0x2000
  private static let anyShiftBits: UInt64 = 0x2 | 0x4
  private static let anyCommandBits: UInt64 = 0x8 | 0x10

  static func register(with messenger: FlutterBinaryMessenger) {
    shared.install(messenger)
  }

  private func install(_ messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "relic/voice", binaryMessenger: messenger)
    self.channel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(FlutterMethodNotImplemented); return }
      let args = call.arguments as? [String: Any]
      switch call.method {
      case "enable":
        self.setEnabled(call.arguments as? Bool ?? false)
        result(self.enabled)
      case "blocklist":
        self.blocked = (call.arguments as? [Any] ?? []).compactMap { $0 as? String }
        result(nil)
      case "complete":
        self.targetGeneration &+= 1
        self.gesture.complete()
        self.finishing = false
        self.validTarget = false
        result(nil)
      case "processing":
        self.gesture.state = .processing
        self.finishing = true
        result(nil)
      case "start":
        guard self.enabled, self.gesture.state == .idle else { result(false); return }
        self.gesture.note = (args?["mode"] as? String) == "voice_note"
        self.gesture.state = .latched
        self.snapshot()
        self.emit("candidate")
        self.emit("latched")
        result(true)
      case "insert":
        result(self.insert(args?["text"] as? String ?? ""))
      case "level":
        VoiceOverlayPanel.shared.update(level: call.arguments as? Double ?? 0)
        result(nil)
      case "overlay":
        let phase = args?["phase"] as? String ?? ""
        if phase == "recording" || phase == "processing" {
          VoiceOverlayPanel.shared.show(recording: phase == "recording", on: self.targetScreen())
        } else {
          VoiceOverlayPanel.shared.hide()
        }
        result(nil)
      case "microphone":
        result(Self.microphoneStatus())
      case "requestMicrophone":
        AVCaptureDevice.requestAccess(for: .audio) { granted in
          DispatchQueue.main.async { result(granted) }
        }
      case "openMicrophoneSettings":
        let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    let center = NSWorkspace.shared.notificationCenter
    for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
      center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.interrupted() }
    }
    DistributedNotificationCenter.default().addObserver(
      forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
    ) { [weak self] _ in self?.interrupted() }
  }

  /// "authorized", "denied", "restricted" or "undetermined", as the OS reports
  /// microphone access for this app.
  private static func microphoneStatus() -> String {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: return "authorized"
    case .denied: return "denied"
    case .restricted: return "restricted"
    case .notDetermined: return "undetermined"
    @unknown default: return "undetermined"
    }
  }

  /// Sleep, session switch or the lock screen: whatever was recording is
  /// gone, and the transcript would have nowhere sensible to land.
  private func interrupted() {
    emit("cancel")
    gesture.complete()
    finishing = false
    validTarget = false
    VoiceOverlayPanel.shared.hide()
  }

  // MARK: - gesture plumbing

  private static var now: UInt64 { DispatchTime.now().uptimeNanoseconds / 1_000_000 }

  private func setEnabled(_ value: Bool) {
    targetGeneration &+= 1
    enabled = value
    uninstallTaps()
    timer?.invalidate()
    timer = nil
    if gesture.forwarding && gesture.altDown && !CGEventSource.keyState(.combinedSessionState, key: Self.voiceKey) {
      replayAlt(up: true)
    }
    gesture = VoiceGesture()
    finishing = false
    validTarget = false
    leftCtrlDownSeen = false
    guard value else { return }
    guard AXIsProcessTrustedWithOptions(nil) else { enabled = false; return }
    enabled = installTaps()
    if enabled {
      let t = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
        guard let self, self.enabled else { return }
        self.dispatch(self.gesture.tick(Self.now))
      }
      RunLoop.main.add(t, forMode: .common)
      timer = t
    }
  }

  private func installTaps() -> Bool {
    let keyMask: CGEventMask =
      (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
    let mouseMask: CGEventMask =
      (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.rightMouseDown.rawValue)
      | (1 << CGEventType.scrollWheel.rawValue)
    let me = Unmanaged.passUnretained(self).toOpaque()
    guard let key = CGEvent.tapCreate(
      tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
      eventsOfInterest: keyMask, callback: VoiceBridge.keyCallback, userInfo: me),
      let mouse = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
        eventsOfInterest: mouseMask, callback: VoiceBridge.mouseCallback, userInfo: me)
    else {
      uninstallTaps()
      return false
    }
    keyTap = key
    mouseTap = mouse
    keySource = CFMachPortCreateRunLoopSource(nil, key, 0)
    mouseSource = CFMachPortCreateRunLoopSource(nil, mouse, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), keySource, .commonModes)
    CFRunLoopAddSource(CFRunLoopGetMain(), mouseSource, .commonModes)
    CGEvent.tapEnable(tap: key, enable: true)
    CGEvent.tapEnable(tap: mouse, enable: true)
    return true
  }

  private func uninstallTaps() {
    for (tap, source) in [(keyTap, keySource), (mouseTap, mouseSource)] {
      if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
      if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
      if let tap { CFMachPortInvalidate(tap) }
    }
    keyTap = nil
    mouseTap = nil
    keySource = nil
    mouseSource = nil
  }

  private static let keyCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let bridge = Unmanaged<VoiceBridge>.fromOpaque(userInfo).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let tap = bridge.keyTap { CGEvent.tapEnable(tap: tap, enable: true) }
      return Unmanaged.passUnretained(event)
    }
    return bridge.key(type, event) ? nil : Unmanaged.passUnretained(event)
  }

  private static let mouseCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let bridge = Unmanaged<VoiceBridge>.fromOpaque(userInfo).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let tap = bridge.mouseTap { CGEvent.tapEnable(tap: tap, enable: true) }
      return Unmanaged.passUnretained(event)
    }
    if bridge.finishing || bridge.gesture.state == .held || bridge.gesture.state == .latched {
      bridge.validTarget = false
    }
    return Unmanaged.passUnretained(event)
  }

  /// One keyboard event. Returns true when the event is swallowed.
  private func key(_ type: CGEventType, _ event: CGEvent) -> Bool {
    guard enabled else { return false }
    if event.getIntegerValueField(.eventSourceUserData) == Self.ownEventTag { return false }
    let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
    let flags = event.flags.rawValue
    var decision = VoiceDecision()
    if type == .flagsChanged && code == CGKeyCode(kVK_Control) {
      leftCtrlDownSeen = flags & Self.leftControlBit != 0
    }
    if code == Self.voiceKey {
      let down = type == .flagsChanged ? flags & Self.rightOptionBit != 0 : type == .keyDown
      let ctrl = flags & Self.leftControlBit != 0
      var eligible =
        flags & Self.anyShiftBits == 0 && flags & Self.anyCommandBits == 0
        && flags & Self.rightControlBit == 0 && flags & Self.leftOptionBit == 0
      if down && !gesture.altDown && !ctrl && gesture.state == .idle {
        if appBlocked(Self.appKey(NSWorkspace.shared.frontmostApplication)) { eligible = false }
      }
      decision = gesture.alt(down: down, ctrl: ctrl, eligible: eligible, now: Self.now)
    } else {
      let down: Bool
      switch type {
      case .keyDown: down = true
      case .keyUp: down = false
      default: down = Self.modifierDown(code, flags)
      }
      if down && code == CGKeyCode(kVK_Tab) && gesture.state != .idle { validTarget = false }
      if down && finishing && code != CGKeyCode(kVK_Control) && code != CGKeyCode(kVK_RightControl) {
        validTarget = false
      }
      if code != CGKeyCode(kVK_Control) {
        decision = gesture.other(down: down, escape: code == CGKeyCode(kVK_Escape))
      }
    }
    dispatch(decision)
    return decision.swallow
  }

  /// Whether a modifier's own flagsChanged event is a press or a release.
  private static func modifierDown(_ code: CGKeyCode, _ flags: UInt64) -> Bool {
    switch Int(code) {
    case kVK_Shift: return flags & 0x2 != 0
    case kVK_RightShift: return flags & 0x4 != 0
    case kVK_Command: return flags & 0x8 != 0
    case kVK_RightCommand: return flags & 0x10 != 0
    case kVK_Option: return flags & leftOptionBit != 0
    case kVK_RightControl: return flags & rightControlBit != 0
    case kVK_Control: return flags & leftControlBit != 0
    case kVK_CapsLock: return flags & UInt64(CGEventFlags.maskAlphaShift.rawValue) != 0
    case kVK_Function: return flags & UInt64(CGEventFlags.maskSecondaryFn.rawValue) != 0
    default: return false
    }
  }

  private func dispatch(_ d: VoiceDecision) {
    for action in d.actions {
      switch action {
      case .altDown:
        replayAlt(up: false)
        continue
      case .altTap:
        replayAlt(up: false)
        replayAlt(up: true)
        continue
      case .candidate:
        snapshot()
      case .stopNoInsert:
        validTarget = false
        finishing = true
      case .stop:
        finishing = true
      default:
        break
      }
      DispatchQueue.main.async { [weak self] in self?.deliver(action) }
    }
  }

  private func deliver(_ action: VoiceAction) {
    if action == .candidate && !gesture.note && appBlocked(targetKey) {
      gesture.complete()
      validTarget = false
      emit("blocked")
      return
    }
    switch action {
    case .candidate: emit("candidate")
    case .held: emit("held")
    case .latched: emit("latched")
    case .cancel: emit("cancel")
    default: emit("stop")
    }
  }

  private func emit(_ event: String) {
    channel?.invokeMethod(
      "event",
      arguments: [
        "event": event, "note": gesture.note, "waiting": gesture.state == .waiting,
        "app": targetKey, "can_insert": validTarget,
      ] as [String: Any])
  }

  /// Give the app the Option press we swallowed, when the gesture turns out
  /// to be an ordinary Option chord or a plain tap.
  private func replayAlt(up: Bool) {
    guard let event = CGEvent(keyboardEventSource: nil, virtualKey: Self.voiceKey, keyDown: !up) else { return }
    event.flags = up ? [] : .maskAlternate
    event.setIntegerValueField(.eventSourceUserData, value: Self.ownEventTag)
    event.post(tap: .cghidEventTap)
  }

  // MARK: - the target

  private func snapshot() {
    targetGeneration &+= 1
    let app = NSWorkspace.shared.frontmostApplication
    targetPid = app?.processIdentifier ?? 0
    targetKey = Self.appKey(app)
    focus = Self.focusedElement()
    let secure = focus.map(Self.isSecure) ?? false
    validTarget = targetPid != 0 && targetPid != ProcessInfo.processInfo.processIdentifier && !secure
    clipboardAtStart = NSPasteboard.general.changeCount
    finishing = false
  }

  private func targetScreen() -> NSScreen? {
    if let focus, let rect = Self.frame(of: focus) {
      // AX frames are top-left global; NSScreen frames are bottom-left global.
      let flipped = NSRect(
        x: rect.midX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - rect.midY, width: 1, height: 1)
      if let s = NSScreen.screens.first(where: { $0.frame.intersects(flipped) }) { return s }
    }
    return nil
  }

  private static func focusedElement() -> AXUIElement? {
    let system = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(system, 0.15)
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
      let any = ref, CFGetTypeID(any) == AXUIElementGetTypeID()
    else { return nil }
    return (any as! AXUIElement)
  }

  private static func attribute(_ element: AXUIElement, _ name: String) -> String {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success else { return "" }
    return ref as? String ?? ""
  }

  /// A password field: AXSecureTextField as role or subrole.
  private static func isSecure(_ element: AXUIElement) -> Bool {
    attribute(element, kAXRoleAttribute) == "AXSecureTextField"
      || attribute(element, kAXSubroleAttribute) == "AXSecureTextField"
  }

  private static func frame(of element: AXUIElement) -> CGRect? {
    var posRef: CFTypeRef?, sizeRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
      AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
      let posAny = posRef, let sizeAny = sizeRef,
      CFGetTypeID(posAny) == AXValueGetTypeID(), CFGetTypeID(sizeAny) == AXValueGetTypeID()
    else { return nil }
    var origin = CGPoint.zero, size = CGSize.zero
    guard AXValueGetValue(posAny as! AXValue, .cgPoint, &origin), AXValueGetValue(sizeAny as! AXValue, .cgSize, &size)
    else { return nil }
    return CGRect(origin: origin, size: size)
  }

  private func appBlocked(_ key: String) -> Bool {
    !key.isEmpty && blocked.contains(key)
  }

  /// The platform-neutral app key, the same derivation as
  /// app/lib/platform/foreground_app.dart's macAppKey: a friendly name for
  /// the well-known bundle ids, else the localized name squeezed to
  /// [a-z0-9], else the bundle id's last component. Relic itself is "".
  /// Keep the table in step with the Dart one.
  static func appKey(_ app: NSRunningApplication?) -> String {
    guard let app, let id = app.bundleIdentifier?.lowercased(), !id.isEmpty else { return "" }
    if id == "space.relic.mac" { return "" }
    if let friendly = friendlyBundle[id] { return friendly }
    let fromName = (app.localizedName ?? "").lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
    if fromName.count >= 2 { return String(fromName.prefix(24)) }
    return id.split(separator: ".").last.map(String.init) ?? id
  }

  private static let friendlyBundle: [String: String] = [
    "com.microsoft.edgemac": "edge",
    "com.microsoft.vscode": "vscode",
    "com.google.chrome": "chrome",
    "com.brave.browser": "brave",
    "org.mozilla.firefox": "firefox",
    "com.tinyspeck.slackmacgap": "slack",
    "com.hnc.discord": "discord",
    "com.microsoft.word": "word",
    "com.microsoft.powerpoint": "powerpoint",
    "com.microsoft.outlook": "outlook",
    "com.microsoft.teams2": "teams",
    "com.adobe.reader": "acrobat",
    "com.jetbrains.intellij": "intellij",
    "com.jetbrains.pycharm": "pycharm",
    "com.jetbrains.webstorm": "webstorm",
    "com.jetbrains.rider": "rider",
    "com.jetbrains.clion": "clion",
    "com.jetbrains.goland": "goland",
    "com.google.android.studio": "androidstudio",
    "com.spotify.client": "spotify",
    "notion.id": "notion",
    "us.zoom.xos": "zoom",
    "company.thebrowser.browser": "arc",
    "com.apple.mobilesms": "messages",
    "com.apple.terminal": "terminal",
    "com.googlecode.iterm2": "terminal",
    "dev.warp.warp-stable": "terminal",
    "com.mitchellh.ghostty": "terminal",
    "net.kovidgoyal.kitty": "terminal",
    "io.alacritty": "terminal",
    "com.apple.finder": "finder",
    "com.apple.dock": "dock",
    "com.apple.loginwindow": "loginwindow",
    "com.apple.screencaptureui": "screencaptureui",
    "com.apple.universalcontrol": "universalcontrol",
    "com.apple.windowserver": "windowserver",
  ]

  // MARK: - insertion

  /// Why the text must not be typed right now, or "" when it may be. The
  /// same reasons and the same words as the Windows bridge, so the Dart
  /// side treats both alike.
  private func insertionFailure() -> String {
    guard validTarget, targetPid != 0,
      NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPid
    else { return "target_changed" }
    let current = Self.focusedElement()
    if let focus {
      guard let current, CFEqual(focus, current) else { return "target_changed" }
    }
    if let current, Self.isSecure(current) { return "target_changed" }
    if NSPasteboard.general.changeCount != clipboardAtStart { return "clipboard_changed" }
    let held: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
    if !NSEvent.modifierFlags.intersection(held).isEmpty { return "modifiers_held" }
    return ""
  }

  /// Type the transcript as Unicode key events into the snapshotted target.
  /// Exactly one attempt, no clipboard involvement. Every dictation ends
  /// with one space so the next one never runs into it; only the keystrokes
  /// get it, the saved transcript is unchanged.
  private func insert(_ text: String) -> String {
    let failure = insertionFailure()
    if !failure.isEmpty { return failure }
    var units = Array(text.utf16)
    if units.isEmpty || units.count > 16000 { return "unsupported" }
    // Never send Return or Tab to a chat or a terminal; spoken text is one paragraph.
    for i in units.indices where units[i] == 0x0A || units[i] == 0x0D || units[i] == 0x09 { units[i] = 0x20 }
    let whitespace: Set<UInt16> = [0x20, 0x09, 0x0A, 0x0D, 0xA0]
    if let last = units.last, !whitespace.contains(last) { units.append(0x20) }
    validTarget = false
    let source = CGEventSource(stateID: .combinedSessionState)
    var index = 0
    while index < units.count {
      // Keep surrogate pairs whole; a chunk carries at most 20 UTF-16 units.
      var end = min(index + 20, units.count)
      if end < units.count, units[end - 1] & 0xFC00 == 0xD800 { end -= 1 }
      var chunk = Array(units[index..<end])
      guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
      else { return "blocked" }
      for event in [down, up] {
        event.flags = []
        event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
        event.setIntegerValueField(.eventSourceUserData, value: Self.ownEventTag)
        event.post(tap: .cghidEventTap)
      }
      index = end
    }
    return "sent"
  }
}
