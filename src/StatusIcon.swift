import AppKit

/// The menu bar icon: the ball held between up and down chevrons ("Scroll Lock"). Drawn in
/// code, on an 18-point grid, so it stays sharp at every scale.
enum StatusIcon {
  enum Badge {
    case paused     // paused from the menu: a pause mark knocked out of a solid dot
    case pausedBy   // an app such as Bazecor has the keyboard: a red dot with a pause mark
    case warning    // permissions missing or a trackball out of reach: an orange dot with an exclamation mark
    case noKeyboard // no Dygma keyboard on USB: a cross knocked out of a solid dot
  }

  /// The app icon's green: its top colour on a dark menu bar, its middle one on a light bar.
  static let green = NSColor(name: nil) { a in
    a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      ? NSColor(srgbRed: 0x34 / 255.0, green: 0xd3 / 255.0, blue: 0x99 / 255.0, alpha: 1)   // #34d399
      : NSColor(srgbRed: 0x10 / 255.0, green: 0xb9 / 255.0, blue: 0x81 / 255.0, alpha: 1)   // #10b981
  }

  /// active: the ball's ring filled with green (the Auto-Mouse Layer is on). dimmed: drawn faint, under a badge.
  static func image(active: Bool, dimmed: Bool = false, badge: Badge? = nil, description: String) -> NSImage {
    // Without colour the image is a template, so macOS draws it in the menu bar's colour.
    // With colour, the rest is drawn in labelColor, which follows the menu bar too. (A
    // status item ignores a tint colour, so colour has to be in the image.)
    let template = !active && (badge == nil || badge == .paused || badge == .noKeyboard)
    let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
      let ink: NSColor = template ? .black : .labelColor
      NSGraphicsContext.saveGraphicsState()
      if badge != nil {
        // Leave a gap around the badge so it reads on any menu bar.
        let clip = NSBezierPath(rect: NSRect(x: 0, y: 0, width: 18, height: 18))
        clip.appendOval(in: circle(14.25, 14.25, 4.85))
        clip.windingRule = .evenOdd
        clip.addClip()
      }
      ink.withAlphaComponent(dimmed ? 0.45 : 1).set()
      let chevrons = NSBezierPath()
      chevrons.move(to: NSPoint(x: 5.75, y: 4.5)); chevrons.line(to: NSPoint(x: 9, y: 1.75)); chevrons.line(to: NSPoint(x: 12.25, y: 4.5))
      chevrons.move(to: NSPoint(x: 5.75, y: 13.5)); chevrons.line(to: NSPoint(x: 9, y: 16.25)); chevrons.line(to: NSPoint(x: 12.25, y: 13.5))
      chevrons.lineWidth = 1.5
      chevrons.lineCapStyle = .round
      chevrons.lineJoinStyle = .round
      chevrons.stroke()
      let ball = NSBezierPath(ovalIn: circle(9, 9, 3.4))
      if active {
        // The ring stays; its inside fills green, as in the app icon.
        green.setFill()
        ball.fill()
      }
      ball.lineWidth = 1.5
      ball.stroke()
      NSGraphicsContext.restoreGraphicsState()

      guard let badge = badge else { return true }
      let dot = NSBezierPath(ovalIn: circle(14.25, 14.25, 3.6))
      let mark = NSBezierPath()
      switch badge {
      case .paused, .pausedBy:
        mark.appendRoundedRect(NSRect(x: 12.75, y: 12.5, width: 1.15, height: 3.5), xRadius: 0.5, yRadius: 0.5)
        mark.appendRoundedRect(NSRect(x: 14.6, y: 12.5, width: 1.15, height: 3.5), xRadius: 0.5, yRadius: 0.5)
      case .warning:
        mark.appendRoundedRect(NSRect(x: 13.7, y: 12.1, width: 1.1, height: 2.7), xRadius: 0.5, yRadius: 0.5)
        mark.appendOval(in: circle(14.25, 16.0, 0.62))
      case .noKeyboard:
        // Template: the cross is cleared out of the dot.
        NSColor.black.setFill()
        dot.fill()
        let cross = NSBezierPath()
        cross.move(to: NSPoint(x: 12.85, y: 12.85)); cross.line(to: NSPoint(x: 15.65, y: 15.65))
        cross.move(to: NSPoint(x: 15.65, y: 12.85)); cross.line(to: NSPoint(x: 12.85, y: 15.65))
        cross.lineWidth = 1.15
        cross.lineCapStyle = .round
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        cross.stroke()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        return true
      }
      if badge == .paused {
        // Template: the mark is cut out of the dot.
        dot.append(mark)
        dot.windingRule = .evenOdd
        NSColor.black.setFill()
        dot.fill()
      } else {
        (badge == .pausedBy ? NSColor.systemRed : NSColor.systemOrange).setFill()
        dot.fill()
        NSColor.white.setFill()
        mark.fill()
      }
      return true
    }
    img.isTemplate = template
    img.accessibilityDescription = description
    return img
  }

  private static func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> NSRect {
    NSRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)
  }
}
