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

      case "copyContext":
        result(copyContext())

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

  /// Where the current copy came from, read through the Accessibility API
  /// while the source app still owns the focus (Dart: copy_context.dart).
  /// Answers raw pieces and lets Dart decide whether the selection is really
  /// the copied text:
  ///   title     the focused window's title
  ///   selected  the focused text's current selection
  ///   before / after   up to 1,500 characters either side of it, when the
  ///             element exposes plain-text ranges (native text views, most
  ///             editors)
  ///   value     the element's whole text (capped), when ranges are missing,
  ///             so Dart can split it around a unique copy
  /// Secure text fields answer the title only. Needs the AX grant Relic
  /// already holds for paste; untrusted, everything fails and this is nil.
  private static func copyContext() -> [String: String]? {
    let system = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(system, 0.25)
    guard let focused = axElement(system, kAXFocusedUIElementAttribute) else { return nil }
    var out: [String: String] = [:]
    if let window = axElement(focused, kAXWindowAttribute),
       let title = axString(window, kAXTitleAttribute), !title.isEmpty {
      out["title"] = title
    }
    let role = axString(focused, kAXRoleAttribute) ?? ""
    let subrole = axString(focused, kAXSubroleAttribute) ?? ""
    if role == "AXSecureTextField" || subrole == "AXSecureTextField" {
      return out.isEmpty ? nil : out
    }
    // The focused element is often a link or a run inside the text that owns
    // the selection, so look a few ancestors up.
    var element: AXUIElement? = focused
    for _ in 0..<5 {
      guard let el = element else { break }
      if let selected = axString(el, kAXSelectedTextAttribute), !selected.isEmpty {
        out["selected"] = selected
        if let around = textAround(el) {
          out["before"] = around.before
          out["after"] = around.after
        } else if let value = axString(el, kAXValueAttribute) {
          out["value"] = String(value.prefix(200_000))
        }
        break
      }
      element = axElement(el, kAXParentAttribute)
    }
    return out.isEmpty ? nil : out
  }

  /// Up to 1,500 characters either side of [element]'s selected range.
  private static func textAround(_ element: AXUIElement) -> (before: String, after: String)? {
    var rangeRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
          let rangeAny = rangeRef,
          CFGetTypeID(rangeAny) == AXValueGetTypeID()
    else { return nil }
    var range = CFRange()
    guard AXValueGetValue(rangeAny as! AXValue, .cfRange, &range) else { return nil }
    var countRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
            element, kAXNumberOfCharactersAttribute as CFString, &countRef) == .success,
          let total = countRef as? Int
    else { return nil }
    let start = max(0, range.location - 1500)
    let end = range.location + range.length
    let before = stringForRange(element, location: start, length: range.location - start) ?? ""
    let after = stringForRange(element, location: end, length: max(0, min(1500, total - end))) ?? ""
    return (before, after)
  }

  private static func stringForRange(_ element: AXUIElement, location: Int, length: Int) -> String? {
    guard length > 0 else { return "" }
    var range = CFRange(location: location, length: length)
    guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
    var out: CFTypeRef?
    guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue, &out) == .success
    else { return nil }
    return out as? String
  }

  private static func axElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
          let any = ref, CFGetTypeID(any) == AXUIElementGetTypeID()
    else { return nil }
    return (any as! AXUIElement)
  }

  private static func axString(_ element: AXUIElement, _ attribute: String) -> String? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success
    else { return nil }
    return ref as? String
  }

  /// `{bundleId, name}` for an app, or nil when it has no bundle id (the id is
  /// the identity the blocklist stores; a nameless app still resolves).
  private static func describe(_ app: NSRunningApplication?) -> [String: String]? {
    guard let id = app?.bundleIdentifier, !id.isEmpty else { return nil }
    return ["bundleId": id, "name": app?.localizedName ?? ""]
  }
}
