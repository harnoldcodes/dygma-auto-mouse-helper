import Foundation

// The settings, how config.json5 is read, and how it is written back. config.json5 is the
// only place settings live: the app reads it at start, watches it for edits, and rewrites
// it (with its explanatory comments) whenever a setting is changed in the app.

struct DeviceRef: Hashable {
  var vendorId: Int
  var productId: Int
  var name: String
  /// The button on this device that scrolls with the ball while held.
  var scrollButton: ScrollButton? = nil
  var key: String { DeviceRef.key(vendorId, productId) }
  static func key(_ v: Int, _ p: Int) -> String { String(format: "%04x:%04x", v, p) }
}

struct ScrollButton: Hashable {
  var usagePage: Int
  var usage: Int
  /// An ordinary mouse button (HID page 9): the helper swallows its clicks.
  var isMouseButton: Bool { usagePage == 0x09 }
  var description: String {
    if usagePage == 0x09 {
      switch usage {
      case 3: return "Middle button"
      case 4: return "Button 4 (usually Back)"
      case 5: return "Button 5 (usually Forward)"
      default: return "Button \(usage)"
      }
    }
    if usagePage == 0xff00 && usage == 2 { return "Slimblade top-right button" }
    if usagePage == 0xff00 && usage == 1 { return "Slimblade top-left button" }
    return String(format: "Vendor button (page 0x%04x, usage %d)", usagePage, usage)
  }
}

/// A keyboard shortcut: a key and the modifiers held with it.
struct Shortcut: Hashable {
  struct Modifiers: OptionSet, Hashable {
    let rawValue: Int
    static let control = Modifiers(rawValue: 1), option = Modifiers(rawValue: 2)
    static let shift = Modifiers(rawValue: 4), command = Modifiers(rawValue: 8)
    /// In the order macOS shows them, with their symbols and the names config.json5 uses.
    static let all: [(Modifiers, String, String)] = [
      (.control, "⌃", "Control"), (.option, "⌥", "Option"), (.shift, "⇧", "Shift"), (.command, "⌘", "Command"),
    ]
  }
  var key: Int              // macOS key code
  var modifiers: Modifiers

  /// Like a menu shows it: ⌃⌥P.
  var display: String {
    Modifiers.all.filter { modifiers.contains($0.0) }.map(\.1).joined() + keyName(key)
  }
  var modifierNames: [String] { Modifiers.all.filter { modifiers.contains($0.0) }.map(\.2) }

  /// Why this can't be a shortcut, if it can't.
  func problem(scrollKeys: [Int]) -> String? {
    guard let k = keyInfo(key), k.usable else { return "a modifier key on its own can't be a shortcut" }
    if scrollKeys.contains(key) { return "\(k.name) is a scroll key, so the helper catches it before any shortcut" }
    if modifiers.isEmpty && k.group != .function && k.group != .silent {
      return "use at least one of Control, Option, Shift and Command with \(k.name) (only F-keys work alone)"
    }
    return nil
  }
}

struct AppConfig: Equatable {
  // general
  var showMenuBarIcon = true
  var showInDock = false
  var startAtLogin = true
  var pauseShortcut: Shortcut? = nil            // pauses and resumes the helper from anywhere
  // keyboard
  var keyboardVendorId = 0x35ef                 // Dygma
  var keyboardProductIds = [0x0010, 0x0012]     // Defy wired, Defy wireless
  var autoMouseLayer = 8
  var pauseWhileRunning = ["com.dygmalab.bazecor"]
  // trackballs
  var devices = [DeviceRef(vendorId: 0x047d, productId: 0x2041, name: "Kensington Slimblade",
                           scrollButton: ScrollButton(usagePage: 0xff00, usage: 2))]
  // layer
  var activationThreshold = 10
  var activationWindowMs = 250.0
  var idleTimeoutMs = 400.0
  // scroll
  var scrollKey: Int? = 90                      // macOS key code; 90 = F20. Scrolls both ways.
  var verticalScrollKey: Int? = nil             // scrolls up and down only
  var horizontalScrollKey: Int? = nil           // scrolls sideways only
  var horizontalKeyRolling = SidewaysRolling.sideways
  var gainX = 3.0
  var gainY = 3.0
  var invertX = false
  var invertY = false
  // Toggle Scroll, for the scroll buttons and the scroll keys
  var buttonTap = TapSettings()
  var keyTap = TapSettings()
  var sameTapTiming = true                      // the keys use the buttons' timing
  // log
  var verbose = false

  func usesDevice(_ vendorId: Int, _ productId: Int) -> Bool { device(vendorId, productId) != nil }

  /// The chosen device with these IDs, if it is chosen.
  func device(_ vendorId: Int, _ productId: Int) -> DeviceRef? {
    devices.first { $0.vendorId == vendorId && $0.productId == productId }
  }

  /// Sets the scroll button of a chosen device.
  mutating func setScrollButton(_ key: String, _ button: ScrollButton?) {
    if let i = devices.firstIndex(where: { $0.key == key }) { devices[i].scrollButton = button }
  }

  /// Sets a tap timing; while the two share their timing, the other one's too.
  mutating func setTapTiming<T>(_ source: TapSource, _ kp: WritableKeyPath<TapSettings, T>, _ value: T) {
    self[keyPath: source.keyPath][keyPath: kp] = value
    if sameTapTiming { self[keyPath: source.other.keyPath][keyPath: kp] = value }
  }

  /// Turns shared timing on or off. Turned on, the other one takes this one's timing.
  mutating func setSameTapTiming(_ on: Bool, from source: TapSource) {
    sameTapTiming = on
    if on {
      self[keyPath: source.other.keyPath].maxMs = self[keyPath: source.keyPath].maxMs
      self[keyPath: source.other.keyPath].maxMotion = self[keyPath: source.keyPath].maxMotion
    }
  }

  /// The Defy keymap code of each scroll key that has one.
  var scrollKeyHids: [Int: ScrollKeyRole] {
    var m: [Int: ScrollKeyRole] = [:]
    for r in ScrollKeyRole.allCases {
      if let k = self[keyPath: r.keyPath], let hid = keyInfo(k)?.hid { m[hid] = r }
    }
    return m
  }

  /// The scroll keys' key codes.
  var scrollKeyCodes: [Int] { ScrollKeyRole.allCases.compactMap { self[keyPath: $0.keyPath] } }

  /// Which scroll key this macOS key code is, if any.
  func scrollKeyRole(for code: Int) -> ScrollKeyRole? {
    ScrollKeyRole.allCases.first { self[keyPath: $0.keyPath] == code }
  }

  /// Sets one scroll key. A key is only ever one of them, so it is taken off the others.
  mutating func setScrollKey(_ role: ScrollKeyRole, _ code: Int?) {
    if let code = code {
      for r in ScrollKeyRole.allCases where r != role && self[keyPath: r.keyPath] == code { self[keyPath: r.keyPath] = nil }
    }
    self[keyPath: role.keyPath] = code
  }

  /// Separate keys for up and down and for sideways, rather than one key for both.
  var separateScrollKeys: Bool { verticalScrollKey != nil || horizontalScrollKey != nil }
}

/// Toggle Scroll: a tap (a short press with little ball movement) keeps Scroll Mode on.
struct TapSettings: Equatable {
  var toggleScroll = true
  var maxMs = 250.0       // a press shorter than this...
  var maxMotion = 10      // ...with at most this much ball movement is a tap
}

/// What was pressed to scroll: a trackball's scroll button or a keyboard scroll key.
enum TapSource: Equatable {
  case button, key
  var keyPath: WritableKeyPath<AppConfig, TapSettings> { self == .button ? \.buttonTap : \.keyTap }
  var other: TapSource { self == .button ? .key : .button }
}

/// Which way of rolling the ball the sideways scroll key turns into sideways scrolling.
enum SidewaysRolling: String, CaseIterable {
  case sideways          // rolling the ball sideways
  case upMovesLeft       // rolling it up moves the page left, down moves it right
  case upMovesRight      // rolling it up moves the page right, down moves it left
}

/// The keyboard keys that scroll with the ball while held: one for both directions, or one
/// for up and down and one for sideways (or all three).
enum ScrollKeyRole: CaseIterable {
  case both, vertical, horizontal
  var keyPath: WritableKeyPath<AppConfig, Int?> {
    switch self {
    case .both: return \.scrollKey
    case .vertical: return \.verticalScrollKey
    case .horizontal: return \.horizontalScrollKey
    }
  }
  var configName: String {
    switch self {
    case .both: return "key"
    case .vertical: return "verticalKey"
    case .horizontal: return "horizontalKey"
    }
  }
  /// Above the key's name in the keyboard drawing.
  var tag: String {
    switch self {
    case .both: return "scroll"
    case .vertical: return "scroll ↕"
    case .horizontal: return "scroll ↔"
    }
  }
  var title: String {
    switch self {
    case .both: return "Scroll key"
    case .vertical: return "Up and down key"
    case .horizontal: return "Sideways key"
    }
  }
}

// MARK: - Reading

struct ConfigParse {
  var config: AppConfig
  var warnings: [String]
  var valid: Bool  // false: the file isn't usable JSON5 at all
}

/// Parses config.json5: JSON5, so `//` and `/* */` comments, trailing commas, unquoted keys,
/// single quotes and hex numbers are allowed. Every setting is optional; a setting that can't be used keeps its default and
/// gets a warning.
func parseConfig(_ data: Data) -> ConfigParse {
  var c = AppConfig()
  var warnings: [String] = []
  let root: [String: Any]
  do {
    guard let obj = try JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? [String: Any] else {
      return ConfigParse(config: c, warnings: ["the file must hold one { } object"], valid: false)
    }
    root = obj
  } catch {
    let detail = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription
    return ConfigParse(config: c, warnings: ["not valid JSON5: \(detail)"], valid: false)
  }

  func isBool(_ v: Any) -> Bool { CFGetTypeID(v as CFTypeRef) == CFBooleanGetTypeID() }
  func isNull(_ v: Any) -> Bool { v is NSNull }
  func number(_ v: Any) -> Double? {
    guard let n = v as? NSNumber, !isBool(v) else { return nil }
    return n.doubleValue
  }
  func whole(_ v: Any, _ r: ClosedRange<Int>) -> Int? {
    guard let x = number(v), x == x.rounded(), Double(r.lowerBound) <= x, x <= Double(r.upperBound) else { return nil }
    return Int(x)
  }
  func g(_ d: Double) -> String { String(format: "%g", d) }

  let sections: [String: [String]] = [
    "general": ["showMenuBarIcon", "showInDock", "startAtLogin", "pauseShortcut"],
    "keyboard": ["vendorId", "productIds", "autoMouseLayer", "pauseWhileRunning"],
    "trackballs": ["devices", "tapToToggleScroll", "tapMaxMs", "tapMaxMotion"],
    "layer": ["activationThreshold", "activationWindowMs", "idleTimeoutMs", "dropWhenScrollEnds"],
    "scroll": ["key", "verticalKey", "horizontalKey", "horizontalKeyRolling", "gainX", "gainY", "invertX", "invertY", "tapToToggleScroll", "sameTapTiming",
               "tapMaxMs", "tapMaxMotion"],
    "log": ["verbose"],
  ]
  var values: [String: Any] = [:]
  for (name, value) in root {
    guard let keys = sections[name] else { warnings.append("\(name): unknown section, ignored"); continue }
    guard let d = value as? [String: Any] else { warnings.append("\(name): expected { }, ignored"); continue }
    for (k, v) in d {
      if keys.contains(k) { values["\(name).\(k)"] = v } else { warnings.append("\(name).\(k): unknown setting, ignored") }
    }
  }

  func int(_ key: String, _ r: ClosedRange<Int>) -> Int? {
    guard let v = values[key] else { return nil }
    if let x = whole(v, r) { return x }
    warnings.append("\(key): expected a whole number from \(r.lowerBound) to \(r.upperBound), using the default")
    return nil
  }
  func double(_ key: String, _ r: ClosedRange<Double>) -> Double? {
    guard let v = values[key] else { return nil }
    if let x = number(v), r.contains(x) { return x }
    warnings.append("\(key): expected a number from \(g(r.lowerBound)) to \(g(r.upperBound)), using the default")
    return nil
  }
  func bool(_ key: String) -> Bool? {
    guard let v = values[key] else { return nil }
    if isBool(v), let b = v as? Bool { return b }
    warnings.append("\(key): expected true or false, using the default")
    return nil
  }
  /// nil: can't be used (with a warning); .some(nil): null, no button.
  func button(_ v: Any, _ key: String, _ fallback: String) -> ScrollButton?? {
    if isNull(v) { return .some(nil) }
    if let d = v as? [String: Any], d.count == 2,
       let p = d["usagePage"].flatMap({ whole($0, 1...0xffff) }), let u = d["usage"].flatMap({ whole($0, 1...0xffff) }) {
      if p == 0x09 && u <= 2 {
        warnings.append("\(key): the left and right buttons can't be the scroll button, \(fallback)")
        return nil
      }
      return .some(ScrollButton(usagePage: p, usage: u))
    }
    warnings.append("\(key): expected { \"usagePage\": N, \"usage\": N } or null, \(fallback)")
    return nil
  }

  let id16 = 0...0xffff
  if let v = bool("general.showMenuBarIcon") { c.showMenuBarIcon = v }
  if let v = bool("general.showInDock") { c.showInDock = v }
  if let v = bool("general.startAtLogin") { c.startAtLogin = v }

  if let v = int("keyboard.vendorId", id16) { c.keyboardVendorId = v }
  if let v = values["keyboard.productIds"] {
    if let a = v as? [Any], !a.isEmpty, case let xs = a.compactMap({ whole($0, id16) }), xs.count == a.count {
      c.keyboardProductIds = xs
    } else {
      warnings.append("keyboard.productIds: expected a list of whole numbers from 0 to 65535, using the default")
    }
  }
  if let v = int("keyboard.autoMouseLayer", 0...31) { c.autoMouseLayer = v }
  if let v = values["keyboard.pauseWhileRunning"] {
    if let a = v as? [Any], let s = a as? [String] { c.pauseWhileRunning = s } else {
      warnings.append("keyboard.pauseWhileRunning: expected a list of strings, using the default")
    }
  }

  if let v = values["trackballs.devices"] {
    var list: [DeviceRef] = []
    var ok = v is [Any]
    for (i, item) in ((v as? [Any]) ?? []).enumerated() {
      if let d = item as? [String: Any], let vid = d["vendorId"].flatMap({ whole($0, id16) }),
         let pid = d["productId"].flatMap({ whole($0, id16) }) {
        var ref = DeviceRef(vendorId: vid, productId: pid, name: d["name"] as? String ?? "")
        if let b = d["scrollButton"] {
          ref.scrollButton = button(b, "trackballs.devices[\(i)].scrollButton", "so it has none") ?? nil
        }
        list.append(ref)
      } else { ok = false }
    }
    if ok { c.devices = list } else {
      warnings.append("trackballs.devices: expected a list of { \"vendorId\": N, \"productId\": N, \"name\": \"…\", "
        + "\"scrollButton\": … }, using the default")
    }
  }

  if let v = int("layer.activationThreshold", 1...10000) { c.activationThreshold = v }
  if let v = double("layer.activationWindowMs", 1...10000) { c.activationWindowMs = v }
  if let v = double("layer.idleTimeoutMs", 50...60000) { c.idleTimeoutMs = v }

  for role in ScrollKeyRole.allCases {
    let path = "scroll.\(role.configName)"
    guard let v = values[path] else { continue }
    if isNull(v) { c[keyPath: role.keyPath] = nil }
    else if let k = (v as? String).flatMap({ keyInfo(named: $0) }) ?? whole(v, 0...127).flatMap({ keyInfo($0) }) {
      if !k.usable {
        warnings.append("\(path): \(k.name) is a modifier key, which can't scroll; using the default")
      } else if let other = c.scrollKeyRole(for: k.code), other != role, values["scroll.\(other.configName)"] != nil {
        warnings.append("\(path): \(k.name) is already scroll.\(other.configName); ignored")
      } else {
        c.setScrollKey(role, k.code)
      }
    }
    else { warnings.append("\(path): expected a key name such as \"F20\", a macOS key code (0-127) or null, using the default") }
  }
  if let v = values["scroll.horizontalKeyRolling"] {
    if let r = (v as? String).flatMap(SidewaysRolling.init(rawValue:)) { c.horizontalKeyRolling = r }
    else { warnings.append("scroll.horizontalKeyRolling: expected \"sideways\", \"upMovesLeft\" or \"upMovesRight\", using the default") }
  }
  if let v = double("scroll.gainX", 0...100) { c.gainX = v }
  if let v = double("scroll.gainY", 0...100) { c.gainY = v }
  if let v = bool("scroll.invertX") { c.invertX = v }
  if let v = bool("scroll.invertY") { c.invertY = v }
  func tap(_ section: String) -> TapSettings {
    var t = TapSettings()
    if let v = bool("\(section).tapToToggleScroll") { t.toggleScroll = v }
    if let v = double("\(section).tapMaxMs", 1...2000) { t.maxMs = v }
    if let v = int("\(section).tapMaxMotion", 0...10000) { t.maxMotion = v }
    return t
  }
  c.keyTap = tap("scroll")
  c.buttonTap = tap("trackballs")
  if let v = bool("scroll.sameTapTiming") { c.sameTapTiming = v }
  if c.sameTapTiming {
    c.keyTap.maxMs = c.buttonTap.maxMs
    c.keyTap.maxMotion = c.buttonTap.maxMotion
  }
  // After the scroll keys: the shortcut can't use one.
  if let v = values["general.pauseShortcut"], !isNull(v) {
    let names = Dictionary(uniqueKeysWithValues: Shortcut.Modifiers.all.map { ($0.2.lowercased(), $0.0) })
      .merging(["ctrl": .control, "alt": .option, "opt": .option, "cmd": .command]) { a, _ in a }
    let expected = "expected { \"key\": \"P\", \"modifiers\": [\"Control\", \"Option\"] } or null"
    if let d = v as? [String: Any], let rawKey = d["key"],
       let k = (rawKey as? String).flatMap({ keyInfo(named: $0) }) ?? whole(rawKey, 0...127).flatMap({ keyInfo($0) }),
       let mods = (d["modifiers"] ?? [String]()) as? [String],
       case let flags = mods.compactMap({ names[$0.lowercased()] }), flags.count == mods.count {
      let s = Shortcut(key: k.code, modifiers: Shortcut.Modifiers(flags))
      if let why = s.problem(scrollKeys: c.scrollKeyCodes) {
        warnings.append("general.pauseShortcut: \(why); ignored")
      } else {
        c.pauseShortcut = s
      }
    } else {
      warnings.append("general.pauseShortcut: \(expected); ignored")
    }
  }
  if let v = bool("log.verbose") { c.verbose = v }
  // 0.1 settings that are now always on: accepted silently and dropped on the next save.
  return ConfigParse(config: c, warnings: warnings.sorted(), valid: true)
}

// MARK: - Writing

/// config.json5 as the app writes it: every setting, each with a comment saying what it does.
func renderConfig(_ c: AppConfig) -> String {
  func js(_ s: String) -> String {
    let d = try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed, .withoutEscapingSlashes])
    return d.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
  }
  func ms(_ d: Double) -> String { d == d.rounded() ? String(Int(d)) : String(format: "%g", d) }
  func gain(_ d: Double) -> String { d == d.rounded() ? String(format: "%.1f", d) : String(format: "%g", d) }
  func hex(_ v: Int) -> String { String(format: "0x%04x", v) }

  let products = c.keyboardProductIds.map(String.init).joined(separator: ", ")
  let productsHex = c.keyboardProductIds.map(hex).joined(separator: ", ")
  func button(_ b: ScrollButton?) -> String {
    guard let b = b else { return "null," }
    return "{ \"usagePage\": \(b.usagePage), \"usage\": \(b.usage) },  // \(b.description)"
  }
  let devices = c.devices.isEmpty ? "[]" : "[\n" + c.devices.map {
    """
          {
            "vendorId": \($0.vendorId), "productId": \($0.productId),  // \($0.key)
            "name": \(js($0.name)),
            "scrollButton": \(button($0.scrollButton))
          },
    """
  }.joined(separator: "\n") + "\n    ]"
  func shortcut(_ s: Shortcut?) -> String {
    guard let s = s else { return "null," }
    let k = keyInfo(s.key).flatMap { $0.group == .other ? nil : js($0.name) } ?? String(s.key)
    return "{ \"key\": \(k), \"modifiers\": [\(s.modifierNames.map(js).joined(separator: ", "))] },  // \(s.display)"
  }
  func key(_ code: Int?) -> String {
    guard let k = code else { return "null," }
    if let info = keyInfo(k), info.group != .other { return js(info.name) + "," }
    return "\(k),  // \(keyName(k))"
  }

  return """
  // Dygma Auto-Mouse Helper settings. The app keeps this file up to date when you change a
  // setting in its window, and picks up edits made here within a moment. Comments you add
  // are not kept: the app rewrites the file in this form.
  //
  // JSON5: JSON with comments and trailing commas allowed. Every setting is optional; one
  // that is missing or can't be used keeps its default, and the app's window lists why.
  {
    "general": {
      // Show the helper's icon in the menu bar. The ring in its middle fills with green while the
      // Auto-Mouse Layer is on.
      "showMenuBarIcon": \(c.showMenuBarIcon),
      // Show the helper in the Dock and the app switcher while it runs.
      "showInDock": \(c.showInDock),
      // Start the helper when you log in.
      "startAtLogin": \(c.startAtLogin),
      // A keyboard shortcut that pauses and resumes the helper from anywhere (null: none).
      // "key" is a key name or macOS key code; "modifiers" any of "Control", "Option",
      // "Shift" and "Command". F-keys work without modifiers.
      "pauseShortcut": \(shortcut(c.pauseShortcut))
    },

    "keyboard": {
      // USB vendor ID of the keyboard (\(hex(c.keyboardVendorId))). Dygma's is 13807 (0x35ef).
      "vendorId": \(c.keyboardVendorId),
      // USB product IDs to look for (\(productsHex)). The Defy's are 16 (wired) and 18 (wireless).
      "productIds": [\(products)],
      // The Auto-Mouse Layer, counted from 0 as the keyboard does (Bazecor counts from 1, so
      // this is Bazecor's layer \(c.autoMouseLayer + 1)).
      "autoMouseLayer": \(c.autoMouseLayer),
      // Apps that need the keyboard's connection; the helper lets go while one runs.
      "pauseWhileRunning": [\(c.pauseWhileRunning.map(js).joined(separator: ", "))],
    },

    "trackballs": {
      // The mice and trackballs whose movement turns on the Auto-Mouse Layer, and that can
      // scroll. Each one's scrollButton (null: none) is for Drag Scroll while held and Toggle
      // Scroll when tapped. An ordinary mouse button (usagePage 9) stops clicking; the left
      // and right buttons can't be used.
      "devices": \(devices),
      // Toggle Scroll: tap a scroll button to stay in Scroll Mode until the next press of a
      // scroll button or a scroll key.
      "tapToToggleScroll": \(c.buttonTap.toggleScroll),
      // A press shorter than this many milliseconds...
      "tapMaxMs": \(ms(c.buttonTap.maxMs)),
      // ...with at most this much ball movement counts as a tap.
      "tapMaxMotion": \(c.buttonTap.maxMotion),
    },

    "layer": {
      // Ball movement (|x| + |y|, in device counts) that switches to the layer...
      "activationThreshold": \(c.activationThreshold),
      // ...within this many milliseconds. Smaller bumps of the ball are ignored.
      "activationWindowMs": \(ms(c.activationWindowMs)),
      // The idle timeout: leave the layer after this many milliseconds without ball
      // movement or clicks.
      "idleTimeoutMs": \(ms(c.idleTimeoutMs)),
    },

    "scroll": {
      // The scroll key: Drag Scroll while held, Toggle Scroll when tapped. A key name such
      // as "F20" or "Page Down", a macOS key code (0-127), or null for none. F13 to F20 type
      // nothing on a Mac. The helper swallows the key, so apps never see it.
      "key": \(key(c.scrollKey))
      // Keys that scroll in one direction only, instead of or as well as "key" (null: none).
      "verticalKey": \(key(c.verticalScrollKey))
      "horizontalKey": \(key(c.horizontalScrollKey))
      // What horizontalKey scrolls with: "sideways" (rolling the ball sideways),
      // "upMovesLeft" (rolling it up moves the page left, down moves it right) or
      // "upMovesRight". With either of the last two, invertX doesn't apply to it.
      "horizontalKeyRolling": \(js(c.horizontalKeyRolling.rawValue)),
      // Up and down: pixels scrolled per count of ball movement, and whether to reverse
      // (false: the content follows the ball, as on a trackpad).
      "gainY": \(gain(c.gainY)),
      "invertY": \(c.invertY),
      // Sideways, the same.
      "gainX": \(gain(c.gainX)),
      "invertX": \(c.invertX),
      // Toggle Scroll: tap a scroll key to stay in Scroll Mode until the next press of a
      // scroll key or a scroll button.
      "tapToToggleScroll": \(c.keyTap.toggleScroll),
      // true: the keys use the scroll buttons' tapMaxMs and tapMaxMotion (in "trackballs"),
      // and the two below are kept the same as those.
      "sameTapTiming": \(c.sameTapTiming),
      // A press shorter than this many milliseconds...
      "tapMaxMs": \(ms(c.keyTap.maxMs)),
      // ...with at most this much ball movement counts as a tap.
      "tapMaxMotion": \(c.keyTap.maxMotion),
    },

    "log": {
      // Log every layer change, scroll change and trackball button press to
      // ~/Library/Logs/dygma-auto-mouse-helper.log.
      "verbose": \(c.verbose),
    },
  }

  """
}

/// One line per setting, for `--check-config` and the log.
func describeConfig(_ c: AppConfig) -> [String] {
  [
    "general: menu bar icon \(c.showMenuBarIcon), Dock \(c.showInDock), start at login \(c.startAtLogin), pause shortcut \(c.pauseShortcut?.display ?? "none")",
    String(format: "keyboard: %04x:", c.keyboardVendorId) + c.keyboardProductIds.map { String(format: "%04x", $0) }.joined(separator: "/")
      + ", layer \(c.autoMouseLayer), pause while running \(c.pauseWhileRunning)",
    "trackballs: " + (c.devices.isEmpty ? "none" : c.devices.map {
      "\($0.name.isEmpty ? "?" : $0.name) (\($0.key), scroll button: \($0.scrollButton?.description ?? "none"))"
    }.joined(separator: ", ")) + ", " + tapText(c.buttonTap),
    "layer: threshold \(c.activationThreshold), window \(Int(c.activationWindowMs)) ms, idle \(Int(c.idleTimeoutMs)) ms",
    "scroll: key \(keyName(c.scrollKey)), up/down key \(keyName(c.verticalScrollKey)), "
      + "sideways key \(keyName(c.horizontalScrollKey)) (\(c.horizontalKeyRolling.rawValue)), gain \(c.gainX)/\(c.gainY), invert \(c.invertX)/\(c.invertY), "
      + tapText(c.keyTap) + (c.sameTapTiming ? " (same timing)" : ""),
    "log: verbose \(c.verbose)",
  ]
}

private func tapText(_ t: TapSettings) -> String {
  "Toggle Scroll \(t.toggleScroll) (< \(Int(t.maxMs)) ms, motion <= \(t.maxMotion))"
}
