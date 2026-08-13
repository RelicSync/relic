import Cocoa
import FlutterMacOS

/// relic/frontmost — which app owns the foreground right now, for capture-time
/// source attribution ("copied from chrome") and the capture blocklist. Dart
/// client: app/lib/platform/src/macos/foreground_macos.dart (which normalizes
/// the bundle id into the platform-neutral "app key").
///
/// Both methods answer with `{bundleId, name}` maps: the localized name is the
/// only readable fallback for bundle ids whose last component is meaningless
/// ("com.spotify.client"), so it always travels with the id.
enum ForegroundAppBridge {
  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "relic/frontmost", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "frontmost":
        result(describe(NSWorkspace.shared.frontmostApplication))

      case "runningApps":
        // .regular = has a Dock icon and can own the foreground; agents and
        // daemons can never be a copy source, so they'd only be picker noise.
        result(NSWorkspace.shared.runningApplications
          .filter { $0.activationPolicy == .regular }
          .compactMap { describe($0) })

      case "caretScreenPoint":
        result(caretScreenPoint())

      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// The focused control's text caret as `[x, y]` global points (top-left
  /// origin, caret's bottom-left corner), or nil when no app reports one.
  /// Read through the Accessibility API, so it needs the same AX grant the
  /// paste injection already holds — untrusted, every call fails and the
  /// caller falls back to the mouse, same as Windows does for apps whose
  /// GetGUIThreadInfo comes back empty.
  private static func caretScreenPoint() -> [Double]? {
    let system = AXUIElementCreateSystemWide()
    // A hung or slow app must not stall the popup summon this read precedes:
    // the timeout on the system-wide element applies process-wide.
    AXUIElementSetMessagingTimeout(system, 0.15)
    var focusedRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
          let focusedAny = focusedRef,
          CFGetTypeID(focusedAny) == AXUIElementGetTypeID()
    else { return nil }
    let focused = focusedAny as! AXUIElement
    var rangeRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
            focused, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
          let rangeAny = rangeRef,
          CFGetTypeID(rangeAny) == AXValueGetTypeID()
    else { return nil }
    var range = CFRange()
    guard AXValueGetValue(rangeAny as! AXValue, .cfRange, &range) else { return nil }

    // The caret is a zero-length selection; ask for the bounds of the
    // character after it, then before it (caret at end of text), then the
    // empty range itself (empty field). First sane rect wins. For the
    // before-caret character the caret sits at its RIGHT edge.
    if let r = boundsForRange(focused, location: range.location, length: 1) {
      return [r.minX, r.maxY]
    }
    if range.location > 0,
       let r = boundsForRange(focused, location: range.location - 1, length: 1) {
      return [r.maxX, r.maxY]
    }
    if let r = boundsForRange(focused, location: range.location, length: 0) {
      return [r.minX, r.maxY]
    }
    return nil
  }

  /// kAXBoundsForRange for one range, filtered down to rects that can anchor
  /// a window: on-screen-ish, finite, and no taller than a text line has any
  /// business being (a bogus screen-sized rect would anchor the picker to a
  /// corner of the display).
  private static func boundsForRange(
    _ element: AXUIElement, location: Int, length: Int
  ) -> CGRect? {
    var range = CFRange(location: location, length: length)
    guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
    var boundsRef: CFTypeRef?
    guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue, &boundsRef) == .success,
          let boundsAny = boundsRef,
          CFGetTypeID(boundsAny) == AXValueGetTypeID()
    else { return nil }
    var rect = CGRect.zero
    guard AXValueGetValue(boundsAny as! AXValue, .cgRect, &rect) else { return nil }
    guard rect.origin.x.isFinite, rect.origin.y.isFinite,
          rect.height > 0, rect.height < 120,
          rect != .zero
    else { return nil }
    return rect
  }

  /// `{bundleId, name}` for an app, or nil when it has no bundle id (the id is
  /// the identity the blocklist stores; a nameless app still resolves).
  private static func describe(_ app: NSRunningApplication?) -> [String: String]? {
    guard let id = app?.bundleIdentifier, !id.isEmpty else { return nil }
    return ["bundleId": id, "name": app?.localizedName ?? ""]
  }
}
