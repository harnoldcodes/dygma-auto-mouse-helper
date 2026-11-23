import AppKit
import Combine
import CoreGraphics
import QuartzCore

/// The Auto-Mouse Layer, Drag Scroll and Toggle Scroll. Runs on the main thread: trackball
/// input arrives from Devices, the scroll key from the event tap.
final class Engine: ObservableObject {
  enum ScrollState: Equatable { case off, drag, toggle }
  struct Axes: OptionSet, Equatable {
    let rawValue: Int
    static let x = Axes(rawValue: 1), y = Axes(rawValue: 2)
    static let both: Axes = [.x, .y]
  }

  @Published private(set) var layerActive = false
  @Published private(set) var scroll: ScrollState = .off
  /// The directions scrolling moves in (a key for one direction scrolls only that way).
  @Published private(set) var scrollAxes: Axes = .both
  /// Paused from the menu: the layer and scrolling are off and the keyboard is let go.
  @Published private(set) var userPaused = false
  /// How the last press of a scroll button or key was counted, for trying out the tap settings.
  @Published private(set) var lastPress: PressReport?

  struct PressReport: Equatable {
    var source: TapSource
    var ms: Int
    var motion: Int
    var outcome: String
    var at = Date()
  }

  let focus: Focus
  let store: ConfigStore
  private var cfg: AppConfig { store.config }

  private enum Source: Hashable { case key(ScrollKeyRole), button(String), toggle }  // button: its device
  private var sources = Set<Source>()
  private var scrollActive: Bool { !sources.isEmpty }
  private var toggled: Bool { sources.contains(.toggle) }
  private var toggleAxes: Axes = .both
  private var toggledBy: TapSource = .button

  private func axes(_ s: Source) -> Axes {
    switch s {
    case .key(.vertical): return .y
    case .key(.horizontal): return .x
    case .toggle: return toggleAxes
    default: return .both
    }
  }
  private var activeAxes: Axes { sources.reduce(Axes()) { $0.union(axes($1)) } }

  // A press of a scroll key or button: a tap is Toggle Scroll, a hold is Drag Scroll.
  private struct Press {
    var at: CFTimeInterval
    var motion = 0
    var startedScrolling: Bool  // nothing else was scrolling when it went down
    var endsToggle: Bool        // it went down during Toggle Scroll: its release ends Scroll Mode
  }
  private var presses: [Source: Press] = [:]

  // layer activation
  private var accum = 0
  private var lastMotion: CFTimeInterval = 0
  private var lastActivity: CFTimeInterval = 0
  private var activeLayer: Int?  // the layer number that was switched on

  // scroll emission
  private var pendDX = 0, pendDY = 0
  private var flushScheduled = false
  private var remX = 0.0, remY = 0.0
  private var phaseBegan = false
  private(set) var anchor = CGPoint.zero

  private var ticker: Timer?

  init(focus: Focus, store: ConfigStore) {
    self.focus = focus
    self.store = store
  }

  var isScrolling: Bool { scrollActive }

  func start() {
    let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
    RunLoop.main.add(t, forMode: .common)
    ticker = t
  }

  func setUserPaused(_ p: Bool) {
    guard p != userPaused else { return }
    if p { stopAll("paused") }
    userPaused = p
    focus.setPaused(p || externalPause, reason: p ? "paused from the menu" : "resumed")
    log(p ? "paused from the menu" : "resumed from the menu")
  }

  /// An app from keyboard.pauseWhileRunning is running (Bazecor).
  private(set) var externalPause = false
  func setExternalPause(_ p: Bool, app: String) {
    guard p != externalPause else { return }
    externalPause = p
    if p { stopAll("\(app) is open") }
    focus.setPaused(p || userPaused, reason: p ? "\(app) launched" : "\(app) quit")
  }

  /// Settings changed: let go of a layer that is no longer the Auto-Mouse Layer.
  func configChanged(old: AppConfig, new: AppConfig) {
    if old.autoMouseLayer != new.autoMouseLayer, let l = activeLayer {
      focus.send("layer.deactivate \(l)")
      activeLayer = nil
      layerActive = false
    }
    if old.keyboardVendorId != new.keyboardVendorId || old.keyboardProductIds != new.keyboardProductIds {
      focus.configure(vendorId: new.keyboardVendorId, productIds: new.keyboardProductIds)
    }
    for d in old.devices where new.devices.first(where: { $0.key == d.key })?.scrollButton != d.scrollButton {
      release(.button(d.key))
      if toggledBy == .button { endToggleScroll("scroll button changed") }
    }
    for r in ScrollKeyRole.allCases where old[keyPath: r.keyPath] != new[keyPath: r.keyPath] { release(.key(r)) }
    if old.buttonTap.toggleScroll && !new.buttonTap.toggleScroll && toggledBy == .button { endToggleScroll("Toggle Scroll turned off for the buttons") }
    if old.keyTap.toggleScroll && !new.keyTap.toggleScroll && toggledBy == .key { endToggleScroll("Toggle Scroll turned off for the keys") }
  }

  // MARK: layer

  private func activateAutoMouse() {
    guard activeLayer == nil, !userPaused, !externalPause, case .open = focus.status else { return }
    let l = cfg.autoMouseLayer
    focus.send("layer.activate \(l)")
    activeLayer = l
    layerActive = true
    vlog("layer \(l) on")
  }

  private func deactivateAutoMouse(_ why: String) {
    guard let l = activeLayer else { return }
    activeLayer = nil
    layerActive = false
    focus.send("layer.deactivate \(l)")
    vlog("layer \(l) off (\(why))")
  }

  /// The port closed (keyboard unplugged, Bazecor): the keyboard forgot the layer.
  func portClosed() {
    activeLayer = nil
    layerActive = false
  }

  // MARK: input from Devices / the event tap

  /// Trackball motion, in device counts.
  func motion(dx: Int, dy: Int) {
    guard !userPaused else { return }
    let t = CACurrentMediaTime()
    if scrollActive {
      for s in presses.keys { presses[s]!.motion += abs(dx) + abs(dy) }
      pendDX += dx; pendDY += dy
      lastActivity = t
      activateAutoMouse()  // brings the layer back if it was lost
      scheduleFlush()
      return
    }
    if activeLayer != nil { lastActivity = t; return }
    if t - lastMotion > cfg.activationWindowMs / 1000 { accum = 0 }
    lastMotion = t
    accum += abs(dx) + abs(dy)
    if accum >= cfg.activationThreshold {
      accum = 0
      lastActivity = t
      activateAutoMouse()
    }
  }

  /// A click or wheel turn: keeps the layer on.
  func activity() { if activeLayer != nil { lastActivity = CACurrentMediaTime() } }

  /// A scroll key on the keyboard (from the event tap).
  func scrollKey(_ role: ScrollKeyRole, down: Bool) { press(.key(role), down: down) }

  /// A trackball's scroll button (device: its vendor:product key).
  func scrollButton(_ device: String, down: Bool) { press(.button(device), down: down) }

  /// The scroll key and the scroll button work alike. Held: Drag Scroll, while down. Tapped
  /// outside Scroll Mode: Toggle Scroll, which stays on. Pressed during Toggle Scroll: the
  /// press takes over, so its release ends Scroll Mode whether it was a tap or a hold.
  private func press(_ src: Source, down: Bool) {
    guard !userPaused else { return }
    if down {
      guard !sources.contains(src) else { return }
      let p = Press(at: CACurrentMediaTime(), startedScrolling: sources.isEmpty, endsToggle: toggled)
      presses[src] = p
      setScroll(src, true)
      if p.endsToggle { sources.remove(.toggle) }  // still active: the press holds it
      return
    }
    guard sources.contains(src) else { return }
    if let p = presses.removeValue(forKey: src), let kind = tapSource(src) {
      let ms = (CACurrentMediaTime() - p.at) * 1000
      let t = cfg[keyPath: kind.keyPath]
      let isTap = ms < t.maxMs && p.motion <= t.maxMotion
      let outcome: String
      if p.endsToggle {
        outcome = "pressed during Toggle Scroll, so Scroll Mode ended"
        vlog("Toggle Scroll off (\(src))")
      } else if !isTap {
        outcome = ms >= t.maxMs ? "Drag Scroll: held longer than \(Int(t.maxMs)) ms"
                                : "Drag Scroll: the ball moved more than \(t.maxMotion)"
      } else if !t.toggleScroll {
        outcome = "a tap, but Toggle Scroll is off"
      } else if !p.startedScrolling {
        outcome = "a tap, but Scroll Mode was already on"
      } else {
        outcome = "a tap: Toggle Scroll"
        toggleAxes = axes(src)
        toggledBy = kind
        sources.insert(.toggle)
        vlog(String(format: "Toggle Scroll on (%@ tap: %.0f ms, motion %d)", "\(src)", ms, p.motion))
      }
      lastPress = PressReport(source: kind, ms: Int(ms.rounded()), motion: p.motion, outcome: outcome)
    }
    setScroll(src, false)
  }

  private func tapSource(_ s: Source) -> TapSource? {
    switch s {
    case .button: return .button
    case .key: return .key
    case .toggle: return nil
    }
  }

  /// Let go of a press without starting Toggle Scroll (its key or button changed, or went away).
  private func release(_ src: Source) {
    presses[src] = nil
    setScroll(src, false)
  }

  func endToggleScroll(_ why: String) {
    guard toggled else { return }
    vlog("Toggle Scroll off (\(why))")
    setScroll(.toggle, false)
  }

  /// A trackball was unplugged.
  func deviceRemoved(_ device: String) {
    release(.button(device))
    endToggleScroll("trackball removed")
  }

  // MARK: scrolling

  private func setScroll(_ src: Source, _ down: Bool) {
    let was = scrollActive
    if down { sources.insert(src) } else { sources.remove(src) }
    lastActivity = CACurrentMediaTime()
    if !was && scrollActive { beginScroll(src) }
    if was && !scrollActive {
      endScroll()
      // Leave the layer at once, unless a mouse button is held (a drag keeps it).
      if !anyMouseButtonDown() { deactivateAutoMouse("Scroll Mode off") }
    }
    publishScroll()
  }

  private func publishScroll() {
    let s: ScrollState = !scrollActive ? .off : (sources.contains { $0 != .toggle } ? .drag : .toggle)
    if s != scroll { scroll = s }
    let a = scrollActive ? activeAxes : .both
    if a != scrollAxes { scrollAxes = a }
  }

  private func beginScroll(_ src: Source) {
    activateAutoMouse()  // the scroll button can start it from cold
    anchor = CGEvent(source: nil)?.location ?? .zero
    CGAssociateMouseAndMouseCursorPosition(0)
    pendDX = 0; pendDY = 0; remX = 0; remY = 0; phaseBegan = false
    vlog("Scroll Mode on (\(src))")
  }

  private func endScroll() {
    flush()
    if phaseBegan { postScroll(dy: 0, dx: 0, phase: 4) }  // kCGScrollPhaseEnded
    phaseBegan = false
    CGAssociateMouseAndMouseCursorPosition(1)
    vlog("Scroll Mode off")
  }

  private func scheduleFlush() {
    if flushScheduled { return }
    flushScheduled = true
    DispatchQueue.main.async { [weak self] in self?.flush() }
  }

  private func flush() {
    flushScheduled = false
    guard pendDX != 0 || pendDY != 0 else { return }
    var dx = Double(pendDX), dy = Double(pendDY)
    pendDX = 0; pendDY = 0
    let a = activeAxes
    var invertX = cfg.invertX
    // Only the sideways key is scrolling: it may turn rolling up and down into sideways.
    if a == .x && cfg.horizontalKeyRolling != .sideways {
      dx = cfg.horizontalKeyRolling == .upMovesLeft ? dy : -dy
      dy = 0
      invertX = false  // the setting gives the direction
    }
    // A direction that isn't scrolling drops its movement (the pointer stays put either way).
    if !a.contains(.y) { dy = 0; remY = 0 }
    if !a.contains(.x) { dx = 0; remX = 0 }
    // Natural: the content follows the ball. Ball up = HID dy < 0 = negative wheel1 = content
    // up; ball left = dx < 0 = negative wheel2 = content left.
    let sy = dy * cfg.gainY * (cfg.invertY ? -1 : 1) + remY
    let sx = dx * cfg.gainX * (invertX ? -1 : 1) + remX
    let iy = Int32(sy.rounded(.towardZero)), ix = Int32(sx.rounded(.towardZero))
    remY = sy - Double(iy); remX = sx - Double(ix)
    if iy == 0 && ix == 0 { return }
    postScroll(dy: iy, dx: ix, phase: phaseBegan ? 2 : 1)
    phaseBegan = true
  }

  /// Continuous pixel scrolling with gesture phases, as a trackpad sends.
  private func postScroll(dy: Int32, dx: Int32, phase: Int64) {
    guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                          wheel1: dy, wheel2: dx, wheel3: 0) else { return }
    e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    e.setIntegerValueField(CGEventField(rawValue: 99)!, value: phase)  // kCGScrollWheelEventScrollPhase
    e.location = anchor
    e.post(tap: .cghidEventTap)
  }

  private func anyMouseButtonDown() -> Bool {
    for b in 0..<5 {
      if let mb = CGMouseButton(rawValue: UInt32(b)),
         CGEventSource.buttonState(.combinedSessionState, button: mb) { return true }
    }
    return false
  }

  private func tick() {
    focus.searchIfNeeded()
    guard activeLayer != nil else { return }
    if scrollActive || anyMouseButtonDown() { return }  // kept on during Drag Scroll and Toggle Scroll
    if CACurrentMediaTime() - lastActivity > cfg.idleTimeoutMs / 1000 { deactivateAutoMouse("idle") }
  }

  /// Scrolling off and the layer off (pause, Bazecor, quit).
  func stopAll(_ why: String) {
    presses.removeAll()
    if scrollActive { sources.removeAll(); endScroll(); publishScroll() }
    CGAssociateMouseAndMouseCursorPosition(1)
    deactivateAutoMouse(why)
  }
}
