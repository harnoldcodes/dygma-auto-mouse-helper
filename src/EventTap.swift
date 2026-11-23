import AppKit
import CoreGraphics

/// A session event tap: catches the scroll key (so apps never see it), records a new scroll
/// key, swallows the scroll button's clicks when it is an ordinary mouse button, and holds
/// the pointer still while scrolling. Needs Accessibility.
final class EventTap {
  private let engine: Engine
  private let store: ConfigStore
  private var tap: CFMachPort?
  /// Set to record the next key pressed as the scroll key. Gets nil for Escape (cancel).
  var recordKey: ((Int?) -> Void)?

  init(engine: Engine, store: ConfigStore) {
    self.engine = engine
    self.store = store
  }

  var running: Bool { tap != nil }

  /// Returns false when macOS refuses (Accessibility not granted, or granted after this
  /// process started).
  @discardableResult
  func start() -> Bool {
    if tap != nil { return true }
    let types: [CGEventType] = [.keyDown, .keyUp, .mouseMoved, .leftMouseDragged, .rightMouseDragged,
                                .otherMouseDragged, .leftMouseDown, .leftMouseUp, .rightMouseDown,
                                .rightMouseUp, .otherMouseDown, .otherMouseUp]
    let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
    let ctx = Unmanaged.passUnretained(self).toOpaque()
    guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                    eventsOfInterest: mask, callback: { _, type, event, ctx in
                                      Unmanaged<EventTap>.fromOpaque(ctx!).takeUnretainedValue().handle(type, event)
                                    }, userInfo: ctx) else {
      log("event tap: can't create it (Accessibility?)")
      return false
    }
    tap = t
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0), .commonModes)
    CGEvent.tapEnable(tap: t, enable: true)
    log("event tap: running")
    return true
  }

  private func swallowMotion(_ event: CGEvent) -> Unmanaged<CGEvent>? {
    // If detaching the pointer didn't hold, pin it back.
    let a = engine.anchor
    if hypot(event.location.x - a.x, event.location.y - a.y) > 1 { CGWarpMouseCursorPosition(a) }
    return nil
  }

  private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
    let pass = Unmanaged.passUnretained(event)
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
      log("event tap: disabled by macOS (\(type.rawValue)); re-enabling")
      if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
      return pass
    case .keyDown, .keyUp:
      let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
      if let rec = recordKey {
        if type == .keyDown {
          recordKey = nil
          DispatchQueue.main.async { rec(code == 53 ? nil : code) }  // Escape cancels
        }
        return nil
      }
      if let role = store.config.scrollKeyRole(for: code) {
        if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { engine.scrollKey(role, down: type == .keyDown) }
        return nil  // scroll keys never reach apps
      }
    case .otherMouseDown, .otherMouseUp, .otherMouseDragged:
      // An ordinary mouse button used as the scroll button doesn't click. (The event doesn't
      // say which mouse sent it, so that button number is swallowed for every mouse.)
      let number = event.getIntegerValueField(.mouseEventButtonNumber)
      if store.config.devices.contains(where: { d in
        d.scrollButton.map { $0.isMouseButton && Int64($0.usage - 1) == number } ?? false
      }) {
        return type == .otherMouseDragged && engine.isScrolling ? swallowMotion(event) : nil
      }
      if type == .otherMouseDragged && engine.isScrolling { return swallowMotion(event) }
      engine.activity()
    case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
      if engine.isScrolling { return swallowMotion(event) }
    default:
      engine.activity()  // clicks keep the layer on
    }
    return pass
  }
}
