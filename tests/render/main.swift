import AppKit
import SwiftUI

// Draws the settings window and the menu bar icon to PNGs, light and dark (see render.sh).
//   tests/render.sh <out dir> <focus dump .json>   every state, with your keymap: never publish
//   tests/render.sh <out dir> --docs                the README's screenshots, made-up data only
let out = CommandLine.arguments[1]
let docs = CommandLine.arguments.dropFirst(2).first == "--docs"
func nums(_ s: Any?) -> [Int] { (s as? String ?? "").split(separator: " ").compactMap { Int($0) } }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let d = AppDelegate()  // not launched: nothing is read, written or opened
d.permissions.inputMonitoring = true
d.permissions.accessibility = true
d.model.focusStatus = .open("/dev/cu.usbmodem1101")
d.model.loginStatus = "On (login item)"

/// A made-up Defy keymap: QWERTY on layer 0 and an Auto-Mouse Layer on layer 8 (clicks under
/// the left hand, the scroll key on a thumb), everything else transparent.
func sampleKeymap() -> [Int] {
  var k = [Int](repeating: Keymap.transparent, count: 10 * Keymap.keysPerLayer)
  let rows: [[Int]] = [  // columns 0-15 of rows 0-3 (7 and 8, and 6 and 9 on row 3, aren't keys)
    [41, 30, 31, 32, 33, 34, 35, 0, 0, 36, 37, 38, 39, 45, 46, 42],
    [43, 20, 26, 8, 21, 23, 47, 0, 0, 48, 28, 24, 12, 18, 19, 49],
    [57, 4, 22, 7, 9, 10, 74, 0, 0, 77, 11, 13, 14, 15, 51, 52],
    [225, 29, 27, 6, 25, 5, 0, 0, 0, 0, 17, 16, 54, 55, 56, 229],
  ]
  for (r, row) in rows.enumerated() { for (c, code) in row.enumerated() where Keymap.geometry[r * 16 + c] != nil { k[r * 16 + c] = code } }
  let thumbs = [64: 224, 65: 226, 66: 227, 67: 44, 68: 40, 69: 76, 70: 17451, 71: 41,
                79: 228, 78: 230, 77: 231, 76: 44, 75: 42, 74: 76, 73: 17451, 72: 43]
  for (i, code) in thumbs { k[i] = code }
  let nav = 8 * Keymap.keysPerLayer
  for (i, code) in [33: Keymap.backClick, 34: Keymap.middleClick, 35: Keymap.rightClick, 36: Keymap.leftClick,
                    37: Keymap.forwardClick, 67: 111 /* F20, the scroll key */] { k[nav + i] = code }
  return k
}

if docs {
  d.keyboard.setData(keymap: sampleKeymap(), superkeys: [],
                     layerNames: ["Base", "Symbols", "Numbers", "Navigation", "Media", "", "", "", "Mouse", ""])
  d.devices.showSample([
    PointerDevice(vendorId: 0x047d, productId: 0x2041, name: "Kensington Slimblade Trackball", manufacturer: "Kensington", transport: "USB"),
    PointerDevice(vendorId: 0x046d, productId: 0xb034, name: "MX Master 3S", manufacturer: "Logitech", transport: "Bluetooth Low Energy"),
    PointerDevice(vendorId: 0x056e, productId: 0x010c, name: "HUGE TrackBall", manufacturer: "ELECOM", transport: "USB"),
  ], moved: [DeviceRef.key(0x047d, 0x2041)])
  d.devices.opened = true  // as if listening, so the status counts the sample devices
} else {
  let dump = try! JSONSerialization.jsonObject(with: FileManager.default.contents(atPath: CommandLine.arguments[2])!) as! [String: Any]
  d.keyboard.setData(keymap: nums(dump["keymap.custom"]), superkeys: Keymap.splitSuperkeys(nums(dump["superkeys.map"])),
                     layerNames: KeyboardModel.bazecorLayerNames())
  d.keyboard.setPending(layer: 8, key: 68, code: Keymap.middleClick)
  // Lists the real devices. Their input must not reach this engine: it would scroll and
  // hold the pointer alongside the real helper.
  d.engine.setUserPaused(true)
  _ = d.devices.start()
}

/// Draws its controls as in the frontmost window (switches in the accent colour, not grey),
/// without taking focus from the app you're using.
final class ActiveWindow: NSWindow {
  override var isKeyWindow: Bool { true }
  override var isMainWindow: Bool { true }
}

func render(_ name: String, tab: SettingsTab, dark: Bool, size: NSSize = NSSize(width: 760, height: 760), banner: Bool = false) {
  d.permissions.inputMonitoring = !banner
  let root = SettingsView(app: d, tab: tab)
    .environmentObject(d.store).environmentObject(d.engine).environmentObject(d.devices)
    .environmentObject(d.keyboard).environmentObject(d.permissions).environmentObject(d.model)
    .background(Color(nsColor: .windowBackgroundColor))  // the window draws this on screen
  let host = NSHostingView(rootView: root)
  let w = ActiveWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size), styleMask: [.titled], backing: .buffered, defer: false)
  w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
  w.contentView = host
  w.orderFrontRegardless()
  RunLoop.main.run(until: Date().addingTimeInterval(1.0))
  let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
  host.cacheDisplay(in: host.bounds, to: rep)
  try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
  w.orderOut(nil)
  print("wrote \(name).png")
}

RunLoop.main.run(until: Date().addingTimeInterval(0.5))
d.store.edit { $0.pauseShortcut = Shortcut(key: 35, modifiers: [.control, .option]) }
if docs {
  // The README's screenshots (docs/screenshots): one per tab, light and dark, then the icon.
  for dark in [false, true] {
    let sfx = dark ? "-dark" : ""
    render("scroll-button\(sfx)", tab: .scrollButton, dark: dark, size: NSSize(width: 760, height: 740))
    render("scroll-key\(sfx)", tab: .scrollKey, dark: dark, size: NSSize(width: 760, height: 650))
    render("sensitivity\(sfx)", tab: .sensitivity, dark: dark, size: NSSize(width: 760, height: 790))
    render("auto-mouse-layer\(sfx)", tab: .autoMouseLayer, dark: dark, size: NSSize(width: 900, height: 645))
  }
  renderIcons("menu-bar-icons")
  exit(0)
}
render("1-general", tab: .general, dark: false)
d.store.edit { $0.devices.append(DeviceRef(vendorId: 0x046d, productId: 0xb042, name: "MX Master 4")) }
render("3-scroll-button", tab: .scrollButton, dark: false, size: NSSize(width: 760, height: 1000))
render("2-scroll-key", tab: .scrollKey, dark: false, size: NSSize(width: 820, height: 900))
render("4-sensitivity", tab: .sensitivity, dark: false, size: NSSize(width: 760, height: 1050))
render("5-layer", tab: .autoMouseLayer, dark: false, size: NSSize(width: 820, height: 760))
render("5-layer-big-dark", tab: .autoMouseLayer, dark: true, size: NSSize(width: 1300, height: 1000))
render("6-permissions", tab: .general, dark: false, banner: true)
d.model.pausedBy = "Bazecor"
render("7-bazecor", tab: .scrollButton, dark: false, size: NSSize(width: 760, height: 1000))
render("7-bazecor-dark", tab: .scrollKey, dark: true, size: NSSize(width: 820, height: 1000))
d.model.pausedBy = nil
d.store.edit { $0.sameTapTiming = false; $0.keyTap.maxMs = 320 }
// Separate scroll keys (the settings go to the temporary file render.sh passes with --config).
d.store.edit { $0.setScrollKey(.vertical, 90); $0.setScrollKey(.horizontal, 80); $0.horizontalKeyRolling = .upMovesLeft }
render("2b-scroll-key-separate", tab: .scrollKey, dark: true, size: NSSize(width: 820, height: 1000))
render("4b-sensitivity-dark", tab: .sensitivity, dark: true, size: NSSize(width: 760, height: 1050))
// A scroll key changed while the Defy still sends the old one (the app calls follow itself).
d.store.edit { $0.setScrollKey(.vertical, 79) }
d.keyboard.follow(.vertical, from: 90, to: 79)
render("10-scroll-key-changed", tab: .scrollKey, dark: false, size: NSSize(width: 820, height: 1000))
render("10b-layer-changed", tab: .autoMouseLayer, dark: true, size: NSSize(width: 900, height: 1000))
d.keyboard.discard(d.store.config) { _, _ in }
d.model.focusStatus = .notFound
render("11-no-keyboard", tab: .general, dark: false, size: NSSize(width: 760, height: 560))
render("11b-no-keyboard-dark", tab: .general, dark: true, size: NSSize(width: 760, height: 560))

for dark in [false, true] {
  let host = NSHostingView(rootView: KeyPicker(current: 90, others: [80: "Sideways key"], pick: { _ in }, cancel: {})
    .background(Color(nsColor: .windowBackgroundColor)))
  let w = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 400, height: 470), styleMask: [.titled], backing: .buffered, defer: false)
  w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
  w.contentView = host
  w.orderFrontRegardless()
  RunLoop.main.run(until: Date().addingTimeInterval(1.0))
  let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
  host.cacheDisplay(in: host.bounds, to: rep)
  try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/8-key-picker\(dark ? "-dark" : "").png"))
  w.orderOut(nil)
  print("wrote 8-key-picker")
}

// The menu bar icon in each state, on a light and a dark bar, drawn at 4x.
struct IconStrip: View {
  let dark: Bool
  var body: some View {
    let states: [(String, NSImage, Color?)] = [
      ("normal", StatusIcon.image(active: false, description: ""), nil),
      ("active", StatusIcon.image(active: true, description: ""), nil),
      ("paused", StatusIcon.image(active: false, dimmed: true, badge: .paused, description: ""), nil),
      ("Bazecor", StatusIcon.image(active: false, dimmed: true, badge: .pausedBy, description: ""), nil),
      ("warning", StatusIcon.image(active: false, dimmed: true, badge: .warning, description: ""), nil),
      ("no keyboard", StatusIcon.image(active: false, dimmed: true, badge: .noKeyboard, description: ""), nil),
    ]
    HStack(spacing: 24) {
      ForEach(states.indices, id: \.self) { i in
        VStack(spacing: 6) {
          Image(nsImage: states[i].1).renderingMode(states[i].1.isTemplate ? .template : .original)
            .foregroundStyle(states[i].2 ?? (dark ? Color.white : Color.black))
          Text(states[i].0).font(.system(size: 9))
        }
      }
    }
    .padding(12)
    .background(dark ? Color(white: 0.12) : Color(white: 0.9))
    .environment(\.colorScheme, dark ? .dark : .light)
  }
}
func renderIcons(_ name: String) {
  for dark in [false, true] {
    let host = NSHostingView(rootView: IconStrip(dark: dark))
    let w = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 400, height: 70), styleMask: [.borderless], backing: .buffered, defer: false)
    w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    w.contentView = host
    w.orderFrontRegardless()
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 400 * 4, pixelsHigh: 70 * 4, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = host.bounds.size
    host.cacheDisplay(in: host.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name)\(dark ? "-dark" : "").png"))
    w.orderOut(nil)
    print("wrote \(name)")
  }
}
renderIcons("9-menu-bar-icons")
