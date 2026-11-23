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
  /// Another app has the device to itself, so the helper can't read it.
  var held = false
  /// That app, when it's one the helper recognises (see knownHolder).
  var holder: String?
  var key: String { DeviceRef.key(vendorId, productId) }
}

/// IOKit's "exclusive access" and "not permitted" results.
private let exclusiveAccess = IOReturn(bitPattern: 0xe00002c5)
private let notPermitted = IOReturn(bitPattern: 0xe00002e2)
/// I/O Kit messages to a device's users: another app is taking it over, and someone closed it.
private let requestingClose: UInt32 = 0xe0000100  // kIOMessageServiceIsRequestingClose
private let wasClosed: UInt32 = 0xe0000110        // kIOMessageServiceWasClosed

/// One device's message subscription, and what the messages need to find the device again.
private final class Watch {
  weak var owner: Devices?
  let id: ObjectIdentifier
  var note: io_object_t = 0
  init(_ owner: Devices, _ id: ObjectIdentifier) { self.owner = owner; self.id = id }
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
  /// Why the mice and trackballs can't be read, when it isn't the missing permission.
  @Published private(set) var openFailure: String?
  private var devices: [ObjectIdentifier: PointerDevice] = [:]
  private var refs: [ObjectIdentifier: IOHIDDevice] = [:]
  /// Tells when another app takes a device over or lets go of it (see message()).
  private var watches: [ObjectIdentifier: Watch] = [:]
  private var notifyPort: IONotificationPortRef?
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
    if notifyPort == nil, let port = IONotificationPortCreate(kIOMainPortDefault) {
      CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
      notifyPort = port
    }
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
    if r == exclusiveAccess {
      // Another app has one of the devices to itself (a key remapper takes the whole Defy,
      // its mouse interface included). The others are open and read; attached() works out
      // which device it is.
      log("devices: another app has one of the mice or trackballs to itself; reading the others")
    } else if r != kIOReturnSuccess {
      log(String(format: "devices: can't open the mice and trackballs (0x%08x)%@", r, r == notPermitted ? "; Input Monitoring?" : ""))
      // Not permitted is the missing permission, which the window already explains.
      openFailure = r == notPermitted ? nil : String(format: "macOS wouldn't open them (error 0x%08x)", r)
      IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
      return false
    }
    opened = true
    openFailure = nil
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
    // The Defy's mouse keys: not used, so it doesn't matter if a key remapper has them.
    if p.vendorId == cfg.keyboardVendorId && cfg.keyboardProductIds.contains(p.productId) { return }
    // The built-in keyboard and trackpad: the trackpad's movement never reaches IOKit HID
    // (macOS works out the pointer from touches), so it can't switch the layer.
    if (Devices.prop(d, kIOHIDBuiltInKey) as? Bool) == true { return }
    // The manager opens every device but doesn't say which one failed; opening it here too
    // tells (and, if the manager hasn't got to it yet, opens it).
    let id = ObjectIdentifier(d)
    let r = IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone))
    if r != kIOReturnSuccess && r != exclusiveAccess { log(String(format: "devices: can't open %@ (0x%08x)", p.name, r)) }
    devices[id] = p
    refs[id] = d
    watch(d, id)
    vlog("devices: attached \(p.name) (\(p.key), \(p.transport))")
    if store.config.usesDevice(p.vendorId, p.productId) { log("trackball connected: \(p.name)") }
    if r == exclusiveAccess { setHeld(id, true) } else { updateList() }
  }

  /// Subscribes to the device's I/O Kit messages, which say when another app takes it over
  /// or lets go of it.
  private func watch(_ d: IOHIDDevice, _ id: ObjectIdentifier) {
    guard let port = notifyPort, watches[id] == nil else { return }
    let w = Watch(self, id)
    let r = IOServiceAddInterestNotification(port, IOHIDDeviceGetService(d), kIOGeneralInterest, { ref, _, type, _ in
      guard let ref else { return }
      let w = Unmanaged<Watch>.fromOpaque(ref).takeUnretainedValue()
      w.owner?.message(type, w.id)
    }, Unmanaged.passUnretained(w).toOpaque(), &w.note)
    if r == KERN_SUCCESS { watches[id] = w } else { vlog(String(format: "devices: can't watch %@ (0x%08x)", devices[id]?.name ?? "?", r)) }
  }

  /// An app taking a device over first asks the device's other users to let go, and an app
  /// closing it says so. Opening the device again then tells whether it's held: the seize is
  /// already in place when the message arrives, and so is the release.
  private func message(_ type: UInt32, _ id: ObjectIdentifier) {
    guard let d = refs[id], let p = devices[id], type == requestingClose || (type == wasClosed && p.held) else { return }
    let r = IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone))
    if r == exclusiveAccess && !p.held { setHeld(id, true) }
    if r == kIOReturnSuccess && p.held { setHeld(id, false) }
  }

  /// Marks a device held by another app, or free again. A model can have several interfaces;
  /// the log and the engine hear about the model once.
  private func setHeld(_ id: ObjectIdentifier, _ held: Bool) {
    guard let d = refs[id], var p = devices[id] else { return }
    let wasHeld = devices.values.contains { $0.held && $0.key == p.key }
    p.held = held
    p.holder = held ? Devices.holder(of: d) : nil
    devices[id] = p
    let nowHeld = devices.values.contains { $0.held && $0.key == p.key }
    if nowHeld && !wasHeld {
      log("devices: \(p.holder ?? "another app") has \(p.name) to itself, so the helper can't read it until it lets go")
      // A scroll button held down on it would never come up.
      if store.config.usesDevice(p.vendorId, p.productId) { engine.deviceRemoved(p.key) }
    }
    if wasHeld && !nowHeld { log("devices: \(p.name) is free again; reading it") }
    updateList()
  }

  /// Which app has a device to itself, when it's one the helper recognises: the device's
  /// clients in the I/O Registry, checked against knownHolder's list.
  private static func holder(of d: IOHIDDevice) -> String? {
    var it: io_iterator_t = 0
    guard IORegistryEntryGetChildIterator(IOHIDDeviceGetService(d), kIOServicePlane, &it) == KERN_SUCCESS else { return nil }
    defer { IOObjectRelease(it) }
    var creators: [String] = []
    while case let client = IOIteratorNext(it), client != 0 {
      if let c = IORegistryEntryCreateCFProperty(client, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? String { creators.append(c) }
      IOObjectRelease(client)
    }
    return knownHolder(creators, ownPid: getpid())
  }

  private func removed(_ d: IOHIDDevice) {
    refs.removeValue(forKey: ObjectIdentifier(d))
    if let w = watches.removeValue(forKey: ObjectIdentifier(d)) { IOObjectRelease(w.note) }
    guard let p = devices.removeValue(forKey: ObjectIdentifier(d)) else { return }
    vlog("devices: removed \(p.name)")
    if store.config.usesDevice(p.vendorId, p.productId) {
      log("trackball disconnected: \(p.name)")
      engine.deviceRemoved(p.key)
    }
    updateList()
  }

  /// The ticked trackballs that another app has to itself.
  func held(_ cfg: AppConfig) -> [PointerDevice] {
    connected.filter { $0.held && cfg.usesDevice($0.vendorId, $0.productId) }
  }

  /// One row per model; a model with any of its interfaces held counts as held.
  private func updateList() {
    var byKey: [String: PointerDevice] = [:]
    for p in devices.values.sorted(by: { ($0.name, $0.key) < ($1.name, $1.key) }) {
      guard var first = byKey[p.key] else { byKey[p.key] = p; continue }
      if p.held && !first.held { first.held = true; first.holder = p.holder }
      byKey[p.key] = first
    }
    let list = byKey.values.sorted { ($0.name, $0.key) < ($1.name, $1.key) }
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
