import Foundation

// Every macOS virtual key code (0-127), with a name, a group for the key picker and the
// Defy keymap code (a HID usage) that sends it.

enum KeyGroup: Int, CaseIterable, Identifiable {
  case silent, function, letters, digits, punctuation, editing, keypad, media, international, modifiers, other
  var id: Int { rawValue }
  var title: String {
    switch self {
    case .silent: return "Keys that type nothing on a Mac (best)"
    case .function: return "Function keys"
    case .letters: return "Letters"
    case .digits: return "Numbers"
    case .punctuation: return "Punctuation"
    case .editing: return "Editing and navigation"
    case .keypad: return "Keypad"
    case .media: return "Media"
    case .international: return "Japanese keyboards"
    case .modifiers: return "Modifiers (can't be used)"
    case .other: return "Other key codes"
    }
  }
}

struct KeyInfo: Identifiable, Equatable {
  let code: Int          // macOS virtual key code
  let name: String
  let group: KeyGroup
  var aliases: [String] = []
  var hid: Int? = nil    // the Defy keymap code that sends this key, if it has a plain one
  var id: Int { code }

  /// Modifier keys reach the app as flag changes, not presses, so they can't scroll.
  var usable: Bool { group != .modifiers }
  var silent: Bool { group == .silent }
  var note: String? {
    switch group {
    case .silent: return "types nothing"
    case .modifiers: return "can't be used"
    case .media: return "often sent as a media key"
    case .other: return "no standard key"
    default: return nil
    }
  }
}

let allKeys: [KeyInfo] = {
  var k: [KeyInfo] = []
  func add(_ g: KeyGroup, _ list: [(String, Int, Int?, [String])]) {
    for (name, code, hid, aliases) in list { k.append(KeyInfo(code: code, name: name, group: g, aliases: aliases, hid: hid)) }
  }
  add(.silent, [("F13", 105, 104, []), ("F14", 107, 105, []), ("F15", 113, 106, []), ("F16", 106, 107, []),
                ("F17", 64, 108, []), ("F18", 79, 109, []), ("F19", 80, 110, []), ("F20", 90, 111, [])])
  add(.function, [("F1", 122, 58, []), ("F2", 120, 59, []), ("F3", 99, 60, []), ("F4", 118, 61, []),
                  ("F5", 96, 62, []), ("F6", 97, 63, []), ("F7", 98, 64, []), ("F8", 100, 65, []),
                  ("F9", 101, 66, []), ("F10", 109, 67, []), ("F11", 103, 68, []), ("F12", 111, 69, [])])
  let letters: [Character: Int] = ["A": 0, "S": 1, "D": 2, "F": 3, "H": 4, "G": 5, "Z": 6, "X": 7, "C": 8, "V": 9,
    "B": 11, "Q": 12, "W": 13, "E": 14, "R": 15, "Y": 16, "T": 17, "O": 31, "U": 32, "I": 34, "P": 35, "L": 37,
    "J": 38, "K": 40, "N": 45, "M": 46]
  add(.letters, letters.keys.sorted().map { c in
    (String(c), letters[c]!, 4 + Int(c.asciiValue! - 65), [])
  })
  add(.digits, [("1", 18, 30, []), ("2", 19, 31, []), ("3", 20, 32, []), ("4", 21, 33, []), ("5", 23, 34, []),
                ("6", 22, 35, []), ("7", 26, 36, []), ("8", 28, 37, []), ("9", 25, 38, []), ("0", 29, 39, [])])
  add(.punctuation, [
    ("Grave (`)", 50, 53, ["`", "Grave", "Backtick", "Tilde"]), ("Minus (-)", 27, 45, ["-", "Minus", "Hyphen"]),
    ("Equals (=)", 24, 46, ["=", "Equals"]), ("Left Bracket ([)", 33, 47, ["[", "Left Bracket"]),
    ("Right Bracket (])", 30, 48, ["]", "Right Bracket"]), ("Backslash (\\)", 42, 49, ["\\", "Backslash"]),
    ("Semicolon (;)", 41, 51, [";", "Semicolon"]), ("Quote (')", 39, 52, ["'", "Quote", "Apostrophe"]),
    ("Comma (,)", 43, 54, [",", "Comma"]), ("Period (.)", 47, 55, [".", "Period", "Dot"]),
    ("Slash (/)", 44, 56, ["/", "Slash"]), ("Section (§)", 10, 100, ["§", "Section", "ISO Section"]),
  ])
  add(.editing, [
    ("Return", 36, 40, ["Enter"]), ("Tab", 48, 43, []), ("Space", 49, 44, ["Spacebar"]),
    ("Delete", 51, 42, ["Backspace"]), ("Forward Delete", 117, 76, []), ("Escape", 53, 41, ["Esc"]),
    ("Help", 114, 73, ["Insert"]), ("Home", 115, 74, []), ("End", 119, 77, []),
    ("Page Up", 116, 75, ["PgUp"]), ("Page Down", 121, 78, ["PgDn"]),
    ("Left Arrow", 123, 80, ["Left"]), ("Right Arrow", 124, 79, ["Right"]),
    ("Up Arrow", 126, 82, ["Up"]), ("Down Arrow", 125, 81, ["Down"]),
    ("Context Menu", 110, 101, ["Menu", "Application"]),
  ])
  add(.keypad, [
    ("Keypad 0", 82, 98, ["KP0"]), ("Keypad 1", 83, 89, ["KP1"]), ("Keypad 2", 84, 90, ["KP2"]),
    ("Keypad 3", 85, 91, ["KP3"]), ("Keypad 4", 86, 92, ["KP4"]), ("Keypad 5", 87, 93, ["KP5"]),
    ("Keypad 6", 88, 94, ["KP6"]), ("Keypad 7", 89, 95, ["KP7"]), ("Keypad 8", 91, 96, ["KP8"]),
    ("Keypad 9", 92, 97, ["KP9"]), ("Keypad .", 65, 99, ["KP."]), ("Keypad *", 67, 85, ["KP*"]),
    ("Keypad +", 69, 87, ["KP+"]), ("Keypad -", 78, 86, ["KP-"]), ("Keypad /", 75, 84, ["KP/"]),
    ("Keypad =", 81, 103, ["KP="]), ("Keypad Enter", 76, 88, ["KP Enter"]), ("Keypad Clear", 71, 83, ["Num Lock"]),
  ])
  add(.media, [("Volume Up", 72, nil, []), ("Volume Down", 73, nil, []), ("Mute", 74, nil, [])])
  add(.international, [
    ("JIS Yen (¥)", 93, 137, ["Yen"]), ("JIS Underscore (_)", 94, 135, ["Ro"]),
    ("JIS Keypad Comma", 95, 133, []), ("JIS Eisu", 102, 145, ["Eisu"]), ("JIS Kana", 104, 144, ["Kana"]),
  ])
  add(.modifiers, [
    ("Command", 55, nil, ["Left Command", "Cmd"]), ("Right Command", 54, nil, ["Right Cmd"]),
    ("Shift", 56, nil, ["Left Shift"]), ("Right Shift", 60, nil, []),
    ("Option", 58, nil, ["Left Option", "Alt"]), ("Right Option", 61, nil, ["Right Alt"]),
    ("Control", 59, nil, ["Left Control", "Ctrl"]), ("Right Control", 62, nil, ["Right Ctrl"]),
    ("Fn", 63, nil, ["Function", "Globe"]), ("Caps Lock", 57, nil, []),
  ])
  add(.other, [52, 66, 68, 70, 77, 108, 112, 127].map { ("Key code \($0)", $0, nil, []) })
  return k
}()

private let keysByCode: [Int: KeyInfo] = Dictionary(uniqueKeysWithValues: allKeys.map { ($0.code, $0) })
private let keysByName: [String: KeyInfo] = {
  var m: [String: KeyInfo] = [:]
  for k in allKeys { for n in [k.name] + k.aliases { m[n.lowercased()] = k } }
  return m
}()

func keyInfo(_ code: Int) -> KeyInfo? { keysByCode[code] }

/// A key by its name or one of its other names, ignoring case ("F20", "page down", "Esc").
func keyInfo(named name: String) -> KeyInfo? { keysByName[name.trimmingCharacters(in: .whitespaces).lowercased()] }

func keyName(_ code: Int?) -> String {
  guard let code = code else { return "None" }
  return keyInfo(code)?.name ?? "Key code \(code)"
}

/// F13-F20 type nothing on a Mac, so they make good scroll keys. Name → macOS key code.
let silentKeys: [String: Int] = Dictionary(uniqueKeysWithValues: allKeys.filter(\.silent).map { ($0.name, $0.code) })

/// The keys matching a search, best first: the exact name, then the key code ("90" or
/// "0x5a"), then names that start with it, words that start with it, names containing it,
/// and last the group's title. An empty search gives every key, in group order.
func searchKeys(_ query: String) -> [KeyInfo] {
  let q = query.trimmingCharacters(in: .whitespaces).lowercased()
  if q.isEmpty { return allKeys }
  let number = Int(q) ?? (q.hasPrefix("0x") ? Int(q.dropFirst(2), radix: 16) : nil)
  var scored: [(score: Int, order: Int, key: KeyInfo)] = []
  for (i, k) in allKeys.enumerated() {
    var best = Int.max
    if number == k.code { best = 1 }
    for n in ([k.name] + k.aliases).map({ $0.lowercased() }) {
      if n == q { best = min(best, 0) }
      else if n.hasPrefix(q) { best = min(best, 2) }
      else if n.split(whereSeparator: { " ()".contains($0) }).contains(where: { $0.hasPrefix(q) }) { best = min(best, 3) }
      else if n.contains(q) { best = min(best, 4) }
    }
    if best == .max && k.group.title.lowercased().contains(q) { best = 5 }
    if best != .max { scored.append((best, i, k)) }
  }
  return scored.sorted { ($0.score, $0.order) < ($1.score, $1.order) }.map(\.key)
}
