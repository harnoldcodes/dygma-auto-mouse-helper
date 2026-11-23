import Foundation
import IOKit
import IOKit.hid

/// A connected mouse or trackball, one row per model (vendor and product ID).
struct PointerDevice: Identifiable, Hashable {
  var id: String { key }
  var vendorId: Int
  var productId: Int
  var name: String
  var manufacturer: String
  var transport: String
  var key: String { DeviceRef.key(vendorId, productId) }
}

/// Finds every mouse and trackball (IOKit HID, so it sees raw movement and buttons macOS
/// ignores), and passes input from the ticked ones to the engine.
final class Devices: ObservableObject {
  @Published private(set) var connected: [PointerDevice] = []
  /// Devices that moved in the last moment, for the "this one" dot in the list.
  @Published private(set) var recentlyMoved: Set<String> = []
  /// Learn mode: the next button pressed on this device (vendor:product key) becomes its
  /// scroll button.
  @Published private(set) var learning: String?
  /// What learning said last, and for which device.
  @Published private(set) var learnMessage = ""
  @Published private(set) var learnMessageFor: String?

  var onLearned: ((ScrollButton, String) -> Void)?
  var opened = false

  private let engine: Engine
  private let store: ConfigStore
  private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
  private var devices: [ObjectIdentifier: PointerDevice] = [:]
  private var lastMoved: [String: CFAbsoluteTime] = [:]
  private var movedTimer: Timer?
  private var learnTimeout: DispatchWorkItem?

  init(engine: Engine, store: ConfigStore) {
    self.engine = engine
    self.store = store
  }

  /// Lists these devices instead of the connected ones, without listening to any (the
  /// README's screenshots).
  func showSample(_ list: [PointerDevice], moved: Set<String> = []) {
    connected = list
    recentlyMoved = moved
  }

  /// Start listening. Returns false when macOS refuses (Input Monitoring not granted yet).
  @discardableResult
  func start() -> Bool {
    if opened { return true }
    // Mice and pointers. The keyboard's own mouse interface is filtered out of the list.
    let matching: [[String: Int]] = [
      [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Mouse],
      [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Pointer],
    ]
    IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
    let ctx = Unmanaged.passUnretained(self).toOpaque()
    IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, device in
      Unmanaged<Devices>.fromOpaque(ctx!).takeUnretainedValue().attached(device)
    }, ctx)
    IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, device in
      Unmanaged<Devices>.fromOpaque(ctx!).takeUnretainedValue().removed(device)
    }, ctx)
    IOHIDManagerRegisterInputValueCallback(manager, { ctx, _, _, value in
      Unmanaged<Devices>.fromOpaque(ctx!).takeUnretainedValue().input(value)
    }, ctx)
    IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    let r = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    if r != kIOReturnSuccess {
      log(String(format: "devices: can't open the mice and trackballs (0x%08x); Input Monitoring?", r))
      IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
      return false
    }
    opened = true
    let t = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in self?.refreshMoved() }
    RunLoop.main.add(t, forMode: .common)
    movedTimer = t
    log("devices: listening")
    return true
  }

  func startLearning(_ device: String) {
    learning = device
    learnMessageFor = device
    learnMessage = "Press the button you want to scroll with."
    learnTimeout?.cancel()
    let w = DispatchWorkItem { [weak self] in self?.stopLearning("Nothing pressed; try again.") }
    learnTimeout = w
    DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: w)
  }

  func stopLearning(_ message: String = "") {
    learning = nil
    learnMessage = message
    learnTimeout?.cancel()
  }

  // MARK: callbacks

  private static func prop(_ d: IOHIDDevice, _ key: String) -> Any? { IOHIDDeviceGetProperty(d, key as CFString) }

  private func describe(_ d: IOHIDDevice) -> PointerDevice {
    PointerDevice(vendorId: Devices.prop(d, kIOHIDVendorIDKey) as? Int ?? 0,
                  productId: Devices.prop(d, kIOHIDProductIDKey) as? Int ?? 0,
                  name: Devices.prop(d, kIOHIDProductKey) as? String ?? "Unnamed device",
                  manufacturer: Devices.prop(d, kIOHIDManufacturerKey) as? String ?? "",
                  transport: Devices.prop(d, kIOHIDTransportKey) as? String ?? "")
  }

  private func attached(_ d: IOHIDDevice) {
    let p = describe(d)
    let cfg = store.config
    if p.vendorId == cfg.keyboardVendorId && cfg.keyboardProductIds.contains(p.productId) { return }  // the Defy's mouse keys
    // The built-in keyboard and trackpad: the trackpad's movement never reaches IOKit HID
    // (macOS works out the pointer from touches), so it can't switch the layer.
    if (Devices.prop(d, kIOHIDBuiltInKey) as? Bool) == true { return }
    devices[ObjectIdentifier(d)] = p
    vlog("devices: attached \(p.name) (\(p.key), \(p.transport))")
    if store.config.usesDevice(p.vendorId, p.productId) { log("trackball connected: \(p.name)") }
    updateList()
  }

  private func removed(_ d: IOHIDDevice) {
    guard let p = devices.removeValue(forKey: ObjectIdentifier(d)) else { return }
    vlog("devices: removed \(p.name)")
    if store.config.usesDevice(p.vendorId, p.productId) {
      log("trackball disconnected: \(p.name)")
      engine.deviceRemoved(p.key)
    }
    updateList()
  }

  private func updateList() {
    var seen = Set<String>()
    let list = devices.values.sorted { ($0.name, $0.key) < ($1.name, $1.key) }.filter { seen.insert($0.key).inserted }
    if list != connected { connected = list }
  }

  private func input(_ value: IOHIDValue) {
    let e = IOHIDValueGetElement(value)
    let device = IOHIDElementGetDevice(e)
    guard let p = devices[ObjectIdentifier(device)] else { return }
    let page = Int(IOHIDElementGetUsagePage(e)), usage = Int(IOHIDElementGetUsage(e))
    let v = IOHIDValueGetIntegerValue(value)
    let isMotion = page == kHIDPage_GenericDesktop && (usage == kHIDUsage_GD_X || usage == kHIDUsage_GD_Y)
    if isMotion && v != 0 { lastMoved[p.key] = CFAbsoluteTimeGetCurrent() }

    if let target = learning, v != 0,
       page == kHIDPage_Button || (page >= 0xff00 && IOHIDElementGetType(e) == kIOHIDElementTypeInput_Button) {
      if p.key != target {
        let name = connected.first { $0.key == target }?.name ?? "the device you're learning"
        learnMessage = "That was \(p.name); press a button on \(name)."
        return
      }
      if page == kHIDPage_Button && usage <= 2 {
        learnMessage = "The left and right buttons can't scroll; press another button."
        return
      }
      let b = ScrollButton(usagePage: page, usage: usage)
      stopLearning("Learned: \(b.description).")
      log("devices: learned scroll button \(b.description) on \(p.name)")
      onLearned?(b, p.key)
      return
    }

    let cfg = store.config
    guard let chosen = cfg.device(p.vendorId, p.productId) else { return }
    if let b = chosen.scrollButton, page == b.usagePage, usage == b.usage {
      vlog("scroll button \(v != 0 ? "down" : "up") on \(p.name)")
      engine.scrollButton(p.key, down: v != 0)
      return
    }
    switch (page, usage) {
    case (kHIDPage_GenericDesktop, kHIDUsage_GD_X): if v != 0 { engine.motion(dx: v, dy: 0) }
    case (kHIDPage_GenericDesktop, kHIDUsage_GD_Y): if v != 0 { engine.motion(dx: 0, dy: v) }
    case (kHIDPage_GenericDesktop, kHIDUsage_GD_Wheel): if v != 0 { engine.activity() }
    case (kHIDPage_Button, _):
      vlog("button \(usage) \(v != 0 ? "down" : "up") on \(p.name)")
      engine.activity()
    case (0xff00...0xffff, _):
      vlog(String(format: "vendor input page 0x%04x usage %d = %d on %@", page, usage, v, p.name))
    default: break
    }
  }

  private func refreshMoved() {
    let now = CFAbsoluteTimeGetCurrent()
    let moved = Set(lastMoved.filter { now - $0.value < 0.4 }.keys)
    if moved != recentlyMoved { recentlyMoved = moved }
  }
}
