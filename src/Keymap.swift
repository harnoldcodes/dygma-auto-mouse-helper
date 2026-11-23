import Foundation

// The Defy's keymap: what each key code means (Bazecor's numbering), and where each key
// sits, for drawing a layer. Ported from the author's Defy web panel.

enum KeyKind { case none, transparent, plain, mod, superkey, dual, layer, mouse, other }

struct KeyLabel {
  var main: String
  var top: String = ""
  var sub: String = ""
  var kind: KeyKind
  var desc: String
}

enum Keymap {
  static let keysPerLayer = 80
  static let transparent = 65535

  // The click codes the app can put on a key.
  static let leftClick = 20545, rightClick = 20546, middleClick = 20548, backClick = 20552, forwardClick = 20560
  static let clicks: [(code: Int, name: String)] = [
    (leftClick, "Left click"), (rightClick, "Right click"), (middleClick, "Middle click"),
    (backClick, "Back (mouse 4)"), (forwardClick, "Forward (mouse 5)"),
  ]

  /// The keymap code (a HID usage) that makes a Defy key send this macOS key code, so it
  /// can act as the scroll key. Nil for modifiers and media keys.
  static func hidCode(forMacKey k: Int) -> Int? { keyInfo(k)?.hid }

  // MARK: labels

  private static let short: [Int: String] = {
    var m: [Int: String] = [:]
    for i in 0..<26 { m[4 + i] = String(UnicodeScalar(65 + i)!) }
    for (i, d) in "1234567890".enumerated() { m[30 + i] = String(d) }
    for i in 0..<12 { m[58 + i] = "F\(i + 1)"; m[104 + i] = "F\(i + 13)" }
    for i in 0..<9 { m[89 + i] = "KP\(i + 1)" }
    let extra: [Int: String] = [
      40: "⏎", 41: "Esc", 42: "⌫", 43: "Tab", 44: "Space", 45: "-", 46: "=", 47: "[", 48: "]", 49: "\\", 50: "#",
      51: ";", 52: "'", 53: "`", 54: ",", 55: ".", 56: "/", 57: "Caps", 70: "PrtSc", 71: "ScrLk", 72: "Pause",
      73: "Ins", 74: "Home", 75: "PgUp", 76: "⌦", 77: "End", 78: "PgDn", 79: "→", 80: "←", 81: "↓", 82: "↑",
      83: "NumLk", 84: "KP/", 85: "KP*", 86: "KP-", 87: "KP+", 88: "KP⏎", 98: "KP0", 99: "KP.", 100: "ISO\\",
      101: "Menu", 102: "Power", 103: "KP=", 127: "Mute", 128: "Vol+", 129: "Vol−",
      224: "⌃", 225: "⇧", 226: "⌥", 227: "⌘", 228: "R⌃", 229: "R⇧", 230: "R⌥", 231: "R⌘",
    ]
    m.merge(extra) { $1 }
    return m
  }()

  private static let long: [Int: String] = [
    40: "Enter", 41: "Escape", 42: "Backspace", 44: "Space", 57: "Caps Lock", 70: "Print Screen", 71: "Scroll Lock",
    73: "Insert", 75: "Page Up", 76: "Delete", 78: "Page Down", 79: "Right arrow", 80: "Left arrow", 81: "Down arrow",
    82: "Up arrow", 83: "Num Lock", 101: "Menu", 224: "Left Control", 225: "Left Shift", 226: "Left Option",
    227: "Left Command", 228: "Right Control", 229: "Right Shift", 230: "Right Option", 231: "Right Command",
  ]

  private static let shifted: [Int: String] = [30: "!", 31: "@", 32: "#", 33: "$", 34: "%", 35: "^", 36: "&", 37: "*",
    38: "(", 39: ")", 45: "_", 46: "+", 47: "{", 48: "}", 49: "|", 51: ":", 52: "\"", 53: "~", 54: "<", 55: ">", 56: "?"]

  private static func s(_ k: Int) -> String { short[k] ?? String(format: "0x%x", k) }
  private static func l(_ k: Int) -> String { long[k] ?? short[k] ?? String(format: "HID usage 0x%x", k) }

  private static let mods: [(Int, String, String)] = [(1, "⌃", "Control"), (2, "⌥", "Option"), (4, "R⌥", "Right Option"),
                                                      (8, "⇧", "Shift"), (16, "⌘", "Command")]
  private static func modSym(_ f: Int) -> String {
    if f == 11 { return "Meh " }
    if f == 27 { return "Hyper " }
    return mods.filter { f & $0.0 != 0 }.map { $0.1 }.joined()
  }
  private static func modLong(_ f: Int) -> String {
    if f == 11 { return "Meh (Control+Option+Shift)" }
    if f == 27 { return "Hyper (Control+Option+Shift+Command)" }
    return mods.filter { f & $0.0 != 0 }.map { $0.2 }.joined(separator: "+")
  }

  private static let media: [Int: (String, String)] = [18552: ("Cam", "Camera"), 18834: ("Calc", "Calculator"),
    19682: ("Mute", "Mute"), 22709: ("⏭", "Next track"), 22710: ("⏮", "Previous track"), 22711: ("⏹", "Stop"),
    22712: ("⏏", "Eject"), 22713: ("Shfl", "Shuffle"), 22733: ("⏯", "Play / pause"), 23663: ("☀+", "Brightness up"),
    23664: ("☀−", "Brightness down"), 23785: ("Vol+", "Volume up"), 23786: ("Vol−", "Volume down")]
  private static let mouse: [Int: (String, String, String)] = [
    20481: ("↑", "move", "Mouse up"), 20482: ("↓", "move", "Mouse down"), 20484: ("←", "move", "Mouse left"),
    20488: ("→", "move", "Mouse right"), 20497: ("↑", "wheel", "Wheel up"), 20498: ("↓", "wheel", "Wheel down"),
    20500: ("←", "wheel", "Wheel left"), 20504: ("→", "wheel", "Wheel right"),
    20545: ("Left", "click", "Left click"), 20546: ("Right", "click", "Right click"), 20548: ("Mid", "click", "Middle click"),
    20552: ("Back", "click", "Back button (mouse 4)"), 20560: ("Fwd", "click", "Forward button (mouse 5)"),
    20517: ("↖", "warp", "Warp north-west"), 20518: ("↙", "warp", "Warp south-west"), 20521: ("↗", "warp", "Warp north-east"),
    20522: ("↘", "warp", "Warp south-east"), 20576: ("End", "warp", "Warp end")]
  private static let special: [Int: (String, String, String)] = [
    17152: ("Next", "LED", "Next LED effect"), 17153: ("Prev", "LED", "Previous LED effect"), 17154: ("On/Off", "LED", "Toggle LEDs"),
    20865: ("Off", "power", "Shut down"), 20866: ("Sleep", "power", "Sleep"), 54108: ("Batt", "battery", "Battery level"),
    54109: ("Pair", "Bluetooth", "Bluetooth pairing"), 54111: ("Energy", "status", "Energy status"),
    54112: ("RF", "status", "RF status / layer lens"), 54113: ("Lens", "overlay", "Layer lens tap"),
    54114: ("Lens", "overlay", "Layer lens hold")]
  private static let oneShotMods = [("⌃", "Control"), ("⇧", "Shift"), ("⌥", "Option"), ("⌘", "Command"),
                                    ("R⌃", "Right Control"), ("R⇧", "Right Shift"), ("R⌥", "Right Option"), ("R⌘", "Right Command")]
  private static let dual: [(Int, String, String)] = [(49169, "⌃", "Control"), (49425, "⇧", "Shift"), (49681, "⌥", "Option"),
                                                      (49937, "⌘", "Command"), (50705, "R⌥", "Right Option")]

  /// What a key code does. `superkeys` (from superkeys.map) lets superkeys show their tap action.
  /// Like decode, with a key that sends a scroll key marked as one.
  static func label(_ c: Int, superkeys: [[Int]], layers: Int, scrollKeys: [Int: ScrollKeyRole]) -> KeyLabel {
    var l = decode(c, superkeys: superkeys, layers: layers)
    if let r = scrollKeys[c] {
      l.top = r.tag
      l.kind = .mouse
      l.desc = "\(r.title) (\(l.desc))"
    }
    return l
  }

  static func decode(_ c: Int, superkeys: [[Int]] = [], layers: Int = 10) -> KeyLabel {
    switch c {
    case 0, 1: return KeyLabel(main: "", kind: .none, desc: "No key (does nothing)")
    case 65535: return KeyLabel(main: "▽", kind: .transparent, desc: "Transparent: the key from the layer below")
    case 2...255: return KeyLabel(main: s(c), kind: .plain, desc: l(c))
    case 2530: return KeyLabel(main: "Meh", kind: .mod, desc: "Meh (Control+Option+Shift)")
    case 3043: return KeyLabel(main: "Hyper", kind: .mod, desc: "Hyper (Control+Option+Shift+Command)")
    case 256..<8192:
      let f = c >> 8, k = c & 255
      if f == 8, let sh = shifted[k] { return KeyLabel(main: sh, kind: .mod, desc: "\(sh) (Shift+\(l(k)))") }
      return KeyLabel(main: modSym(f) + s(k), kind: .mod, desc: "\(modLong(f))+\(l(k))")
    default: break
    }
    if let (m, t, d) = special[c] { return KeyLabel(main: m, top: t, kind: .other, desc: d) }
    if (17408...17417).contains(c) { return KeyLabel(main: "L\(c - 17408 + 1)", top: "lock", kind: .layer, desc: "Lock layer \(c - 17408 + 1) on") }
    if (17450...17459).contains(c) { return KeyLabel(main: "L\(c - 17450 + 1)", top: "hold", kind: .layer, desc: "Layer \(c - 17450 + 1) while held") }
    if (17492...17501).contains(c) { return KeyLabel(main: "L\(c - 17492 + 1)", top: "go to", kind: .layer, desc: "Move to layer \(c - 17492 + 1)") }
    if let (m, d) = media[c] { return KeyLabel(main: m, top: "media", kind: .other, desc: d) }
    if let (m, t, d) = mouse[c] { return KeyLabel(main: m, top: t, kind: .mouse, desc: d) }
    if (49153...49160).contains(c) {
      let (sym, n) = oneShotMods[c - 49153]
      return KeyLabel(main: sym, top: "one-shot", kind: .mod, desc: "One-shot \(n)")
    }
    if (49161...49168).contains(c) { return KeyLabel(main: "L\(c - 49161 + 1)", top: "one-shot", kind: .layer, desc: "One-shot layer \(c - 49161 + 1)") }
    for (base, sym, name) in dual where c >= base && c < base + 256 {
      let k = c - base
      return KeyLabel(main: s(k), sub: "hold " + sym, kind: .dual, desc: "\(l(k)) on tap, \(name) on hold")
    }
    if c >= 51218 && c < 51218 + 256 * layers {
      let n = (c - 51218) / 256, k = (c - 51218) % 256
      return KeyLabel(main: s(k), sub: "hold L\(n + 1)", kind: .layer, desc: "\(l(k)) on tap, layer \(n + 1) on hold")
    }
    if (53852..<53980).contains(c) { return KeyLabel(main: "M\(c - 53852 + 1)", top: "macro", kind: .other, desc: "Macro \(c - 53852 + 1)") }
    if (53980..<54108).contains(c) {
      let n = c - 53980
      let acts = n < superkeys.count ? superkeys[n] : []
      let valid = { (a: Int) in a != 0 && a != 1 }
      let tap = acts.first.flatMap { valid($0) ? decode($0, layers: layers) : nil }
      let hold = acts.count > 1 && valid(acts[1]) ? decode(acts[1], layers: layers) : nil
      return KeyLabel(main: tap?.main ?? hold?.main ?? "SK", top: "SK \(n + 1)",
                      sub: tap != nil && hold != nil ? "hold " + (hold!.main) : "",
                      kind: .superkey,
                      desc: "Superkey \(n + 1)" + (tap.map { ": \($0.desc) on tap" } ?? "") + (hold.map { ", \($0.desc) on hold" } ?? ""))
    }
    return KeyLabel(main: "#\(c)", kind: .other, desc: "Code \(c)")
  }

  /// superkeys.map: up to 5 actions per superkey, each ended by 0, the list by 0 0.
  static func splitSuperkeys(_ flat: [Int]) -> [[Int]] {
    var groups: [[Int]] = [], cur: [Int] = []
    for v in flat {
      if v == 0 {
        if cur.isEmpty { break }
        groups.append(cur); cur = []
      } else { cur.append(v) }
    }
    return groups
  }

  // MARK: geometry

  struct KeyGeometry {
    var x: Double, y: Double, w: Double, h: Double, rotation: Double  // centre and size in key units, degrees
    var side: String
  }

  /// Width of the drawing in key units; the right half mirrors the left at this width.
  static let width = 16.4
  static let height = 7.35

  /// Position of every Defy key (keymap index → geometry). Main keys: index = row * 16 +
  /// column (left columns 0-6, right 9-15; row 3 has no inner key). Thumbs: 64-71 left,
  /// 72-79 right (72 + k mirrors 71 - k).
  static let geometry: [Int: KeyGeometry] = {
    let stagger: [Int: Double] = [0: 0.6, 1: 0.6, 2: 0.25, 3: 0, 4: 0.25, 5: 0.25, 6: 0.75,
                                  9: 0.75, 10: 0.25, 11: 0.25, 12: 0, 13: 0.25, 14: 0.6, 15: 0.6]
    let thumbs: [Int: (Double, Double, Double, Double, Double)] = [
      64: (3.7, 4.72, 1.2, 0.88, 2), 65: (4.88, 4.76, 0.94, 0.88, 5), 66: (5.92, 4.93, 0.98, 0.9, 14),
      67: (6.74, 5.38, 0.94, 0.9, 38), 71: (3.74, 5.66, 1.16, 0.86, 4), 70: (4.84, 5.72, 0.94, 0.86, 9),
      69: (5.84, 6.02, 0.94, 0.88, 25), 68: (6.74, 6.68, 1.22, 0.9, 45),
    ]
    var g: [Int: KeyGeometry] = [:]
    for row in 0..<4 {
      for col in 0...15 where col != 7 && col != 8 {
        if row == 3 && (col == 6 || col == 9) { continue }
        let x = col <= 6 ? Double(col) : 9.4 + Double(col - 9)
        g[row * 16 + col] = KeyGeometry(x: x + 0.5, y: Double(row) + stagger[col]! + 0.5, w: 0.92, h: 0.92,
                                        rotation: 0, side: col <= 6 ? "left" : "right")
      }
    }
    for (i, t) in thumbs {  // drawn a little smaller than measured, so neighbours don't touch
      let w = t.2 * 0.92, h = t.3 * 0.92
      g[i] = KeyGeometry(x: t.0, y: t.1, w: w, h: h, rotation: t.4, side: "left")
      g[72 + (71 - i)] = KeyGeometry(x: width - t.0, y: t.1, w: w, h: h, rotation: -t.4, side: "right")
    }
    return g
  }()
}
