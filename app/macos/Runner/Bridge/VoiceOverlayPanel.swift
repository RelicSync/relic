import Cocoa
import QuartzCore

/// The Voice mark: a small transparent panel showing the Relic shard with a
/// pulsing shadow while the microphone is open (slow) or the transcript is
/// being worked out (fast). No text, no recording dot; detailed status lives
/// in Voice settings. The mac twin of the voice half of
/// windows/runner/native_gem_toast.cpp: same 112 pt square, same pulse
/// periods, same gold gradient, the mark grows with microphone level.
///
/// A nonactivating, click-through panel on every Space, so it never takes the
/// foreground from the field the words are about to land in.
final class VoiceOverlayPanel {
  static let shared = VoiceOverlayPanel()

  private var panel: NSPanel?
  private var mark: CAShapeLayer?
  private var recording = false
  private var levelSmoothed = 0.0
  private var levelTarget = 0.0
  private var levelAt = Date.distantPast
  private var frameTimer: Timer?

  private static let size: CGFloat = 112
  private static let markHeight: CGFloat = 44
  private static let viewBox = CGSize(width: 148, height: 150)

  /// Show the mark, or switch it between the recording and processing pulse
  /// without a visual restart.
  func show(recording: Bool, on screen: NSScreen?) {
    if let panel, panel.isVisible {
      if self.recording != recording {
        self.recording = recording
        pulse()
      }
      return
    }
    self.recording = recording
    levelSmoothed = 0
    levelTarget = 0
    let panel = self.panel ?? makePanel()
    self.panel = panel
    let target = screen ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    if let target {
      let area = target.visibleFrame
      let x = area.midX - Self.size / 2
      let y = area.minY + 56
      panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
    panel.orderFrontRegardless()
    pulse()
    frameTimer?.invalidate()
    frameTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
      self?.frame()
    }
    RunLoop.main.add(frameTimer!, forMode: .common)
  }

  func update(level: Double) {
    levelTarget = min(1, max(0, level))
    levelAt = Date()
  }

  func hide() {
    frameTimer?.invalidate()
    frameTimer = nil
    mark?.removeAllAnimations()
    panel?.orderOut(nil)
  }

  // MARK: - drawing

  private func makePanel() -> NSPanel {
    let rect = NSRect(x: 0, y: 0, width: Self.size, height: Self.size)
    let panel = NSPanel(
      contentRect: rect,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    panel.isExcludedFromWindowsMenu = true
    let view = NSView(frame: rect)
    view.wantsLayer = true
    view.layer?.backgroundColor = NSColor.clear.cgColor
    let shape = CAShapeLayer()
    shape.frame = rect
    shape.path = Self.markPath(in: rect)
    shape.fillColor = NSColor(red: 1, green: 206 / 255, blue: 6 / 255, alpha: 1).cgColor
    shape.shadowColor = NSColor(red: 218 / 255, green: 158 / 255, blue: 18 / 255, alpha: 1).cgColor
    shape.shadowOffset = .zero
    shape.shadowOpacity = 0.4
    shape.shadowRadius = 6
    // The gradient the widget tree uses (relic_mark.dart), clipped by the shard.
    let gradient = CAGradientLayer()
    gradient.frame = rect
    gradient.colors = [
      NSColor(red: 1, green: 226 / 255, blue: 74 / 255, alpha: 1).cgColor,
      NSColor(red: 1, green: 206 / 255, blue: 6 / 255, alpha: 1).cgColor,
      NSColor(red: 242 / 255, green: 169 / 255, blue: 59 / 255, alpha: 1).cgColor,
    ]
    gradient.startPoint = CGPoint(x: 0, y: 0.5)
    gradient.endPoint = CGPoint(x: 1, y: 0.5)
    let clip = CAShapeLayer()
    clip.frame = rect
    clip.path = shape.path
    gradient.mask = clip
    shape.addSublayer(gradient)
    view.layer?.addSublayer(shape)
    panel.contentView = view
    mark = shape
    return panel
  }

  /// The shard outline from logo-mark.svg, the same control points as
  /// relic_mark.dart and native_gem_toast.cpp, scaled to 44 pt tall and
  /// centred in the panel. Core Animation's y axis points up, so the path is
  /// flipped from the SVG's top-left origin.
  private static func markPath(in rect: CGRect) -> CGPath {
    let unit = markHeight / viewBox.height
    let width = viewBox.width * unit
    let x0 = rect.midX - width / 2
    let y0 = rect.midY - markHeight / 2
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
      CGPoint(x: x0 + x * unit, y: y0 + (viewBox.height - y) * unit)
    }
    let path = CGMutablePath()
    path.move(to: p(27.4388, 140.916))
    path.addLine(to: p(132.709, 140.969))
    path.addCurve(to: p(145.013, 125.51), control1: p(140.828, 140.973), control2: p(146.838, 133.421))
    path.addLine(to: p(121.339, 22.9363))
    path.addCurve(to: p(111.656, 13.4276), control1: p(120.235, 18.1532), control2: p(116.458, 14.4442))
    path.addLine(to: p(80.9218, 6.92219))
    path.addCurve(to: p(68.4338, 11.4098), control1: p(76.2452, 5.93228), control2: p(71.4106, 7.66958))
    path.addLine(to: p(52.6439, 31.2487))
    path.addLine(to: p(20.1246, 72.1069))
    path.addLine(to: p(4.33476, 91.9458))
    path.addCurve(to: p(2.76379, 105.122), control1: p(1.35791, 95.686), control2: p(0.749738, 100.787))
    path.addLine(to: p(15.9997, 133.613))
    path.addCurve(to: p(27.4388, 140.916), control1: p(18.0679, 138.064), control2: p(22.53, 140.913))
    path.closeSubpath()
    return path
  }

  /// The shadow pulse: 2.4 s while recording, 0.55 s while transcribing. A
  /// reduced-motion setting gets a steady mid-strength shadow instead.
  private func pulse() {
    guard let mark else { return }
    mark.removeAllAnimations()
    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      mark.shadowOpacity = 0.5
      mark.shadowRadius = 12
      return
    }
    let period = recording ? 2.4 : 0.55
    let opacity = CABasicAnimation(keyPath: "shadowOpacity")
    opacity.fromValue = 0.16
    opacity.toValue = 0.68
    let radius = CABasicAnimation(keyPath: "shadowRadius")
    radius.fromValue = 4
    radius.toValue = 14
    let group = CAAnimationGroup()
    group.animations = [opacity, radius]
    group.duration = period / 2
    group.autoreverses = true
    group.repeatCount = .infinity
    group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    mark.add(group, forKey: "pulse")
  }

  /// Level follow: fast attack, slow release, the same constants as the
  /// Windows overlay. The mark grows up to 18% with the voice.
  private func frame() {
    guard let mark else { return }
    let stale = Date().timeIntervalSince(levelAt) > 0.35
    let target = recording && !stale ? levelTarget : 0
    let response = target > levelSmoothed ? 0.065 : 0.19
    levelSmoothed += (target - levelSmoothed) * (1 - exp(-(1.0 / 30.0) / response))
    let scale = 1 + 0.18 * levelSmoothed
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    mark.transform = CATransform3DMakeScale(scale, scale, 1)
    CATransaction.commit()
  }
}
