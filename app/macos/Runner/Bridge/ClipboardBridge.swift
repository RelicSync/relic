import Cocoa
import FlutterMacOS

/// relic/clipboard — the NSPasteboard operations the cross-platform plugins
/// don't cover: the change counter, privacy markers, Finder file copies, raw
/// TIFF fallback and sensitive writes. Dart client:
/// app/lib/platform/src/macos/clipboard_macos.dart.
enum ClipboardBridge {
  /// Community pasteboard-privacy markers (http://nspasteboard.org) —
  /// password managers set these so history tools skip the entry.
  static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
  static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "relic/clipboard", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      let pb = NSPasteboard.general
      switch call.method {
      case "changeCount":
        result(pb.changeCount)

      case "shouldBeIgnored":
        let types = pb.types ?? []
        result(types.contains(concealed) || types.contains(transient))

      case "clear":
        pb.clearContents()
        result(true)

      case "markSensitive":
        // Append the marker types to whatever is on the pasteboard now. The
        // marker's *presence* is the signal; its data is irrelevant.
        pb.addTypes([concealed, transient], owner: nil)
        pb.setData(Data(), forType: concealed)
        pb.setData(Data(), forType: transient)
        result(true)

      case "writeSensitiveText":
        guard let args = call.arguments as? [String: Any],
              let text = args["text"] as? String else {
          result(false)
          return
        }
        pb.clearContents()
        pb.declareTypes([.string, concealed, transient], owner: nil)
        let ok = pb.setString(text, forType: .string)
        pb.setData(Data(), forType: concealed)
        pb.setData(Data(), forType: transient)
        result(ok)

      case "filePaths":
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = pb.readObjects(forClasses: [NSURL.self], options: opts) as? [URL] ?? []
        result(urls.map { $0.path })

      case "rawImage":
        // TIFF is macOS's native raster interchange; sources that don't add a
        // PNG rep (some screenshot paths, drawing apps) still provide this.
        if let data = pb.data(forType: .tiff) {
          result(FlutterStandardTypedData(bytes: data))
        } else {
          result(nil)
        }

      case "writeFile":
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else {
          result(false)
          return
        }
        let url = URL(fileURLWithPath: path)
        pb.clearContents()
        let ok = pb.writeObjects([url as NSURL])
        if ok {
          pb.addTypes([concealed, transient], owner: nil)
          pb.setData(Data(), forType: concealed)
          pb.setData(Data(), forType: transient)
        }
        result(ok)

      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
