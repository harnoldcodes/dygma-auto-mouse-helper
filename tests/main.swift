import Foundation

// Checks for the parts that don't need hardware. Build and run with tests/run.sh:
//   tests/run.sh [focus dump .json]
// The dump (an object with "keymap.custom" and "superkeys.map" as Focus returns them) adds
// checks that every code on a real Defy decodes.
var failures = 0
func check(_ ok: Bool, _ what: String, file: String = #file, line: Int = #line) {
  if ok { print("  ok   \(what)") } else { print("  FAIL \(what) (line \(line))"); failures += 1 }
}
let args = CommandLine.arguments

print("config: defaults survive a write and a read")
let d = AppConfig()
let p0 = parseConfig(Data(renderConfig(d).utf8))
check(p0.valid && p0.warnings.isEmpty, "no warnings: \(p0.warnings)")
check(p0.config == d, "same settings")

print("config: every setting survives a write and a read")
var c = AppConfig()
c.showMenuBarIcon = false; c.showInDock = true; c.startAtLogin = false
c.pauseShortcut = Shortcut(key: 35, modifiers: [.control, .option, .command])
c.keyboardVendorId = 0x1234; c.keyboardProductIds = [1, 2, 3]; c.autoMouseLayer = 3; c.pauseWhileRunning = ["a.b", "c \"quoted\" ü"]
c.devices = [DeviceRef(vendorId: 1, productId: 2, name: "Ball \"X\" // not a comment", scrollButton: ScrollButton(usagePage: 9, usage: 4)),
             DeviceRef(vendorId: 3, productId: 4, name: ""),
             DeviceRef(vendorId: 5, productId: 6, name: "Odd", scrollButton: ScrollButton(usagePage: 0xff07, usage: 9))]
c.activationThreshold = 25; c.activationWindowMs = 300.5; c.idleTimeoutMs = 1200
c.scrollKey = 0; c.verticalScrollKey = 39; c.horizontalScrollKey = 52; c.horizontalKeyRolling = .upMovesRight
c.gainX = 2.75; c.gainY = 0.5; c.invertX = true; c.invertY = true
c.buttonTap = TapSettings(toggleScroll: false, maxMs: 180, maxMotion: 4); c.keyTap = TapSettings(toggleScroll: true, maxMs: 320.5, maxMotion: 7)
c.sameTapTiming = false; c.verbose = true
let p1 = parseConfig(Data(renderConfig(c).utf8))
check(p1.valid && p1.warnings.isEmpty, "no warnings: \(p1.warnings)")
check(p1.config == c, "same settings")
c.scrollKey = nil; c.verticalScrollKey = nil; c.horizontalScrollKey = nil; c.devices = []; c.pauseWhileRunning = []; c.pauseShortcut = nil
let p2 = parseConfig(Data(renderConfig(c).utf8))
check(p2.config == c && p2.warnings.isEmpty, "nulls and empty lists: \(p2.warnings)")
for (name, code) in silentKeys {
  c.scrollKey = code
  let r = renderConfig(c)
  if !r.contains("\"key\": \"\(name)\"") || parseConfig(Data(r.utf8)).config.scrollKey != code { check(false, "scroll key \(name)") }
}
check(true, "F13-F20 written by name and read back")
for k in allKeys where k.usable {
  c.scrollKey = k.code
  let r = renderConfig(c)
  let back = parseConfig(Data(r.utf8))
  if back.config.scrollKey != k.code || !back.warnings.isEmpty { check(false, "scroll key \(k.name) (\(k.code)): \(back.warnings)") }
}
check(true, "every usable key is written and read back")

print("keys")
check(allKeys.map(\.code).sorted() == Array(0...127), "every macOS key code 0-127, once each")
let allNames = allKeys.flatMap { [$0.name] + $0.aliases }.map { $0.lowercased() }
check(Set(allNames).count == allNames.count, "names and other names are unique: \(Dictionary(grouping: allNames, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted())")
let hids = allKeys.compactMap(\.hid)
check(Set(hids).count == hids.count && hids.allSatisfy { (4...255).contains($0) }, "keymap codes unique and plain")
check(keyInfo(named: "page down")?.code == 121 && keyInfo(named: "ESC")?.code == 53 && keyInfo(named: "`")?.code == 50,
      "names ignore case; other names and symbols work")
check(searchKeys("90").first?.name == "F20", "a key code finds its key: \(searchKeys("90").first?.name ?? "-")")
check(searchKeys("0x5a").first?.name == "F20", "so does hex")
check(searchKeys("1").prefix(2).map(\.name) == ["1", "S"], "a name beats a key code: \(searchKeys("1").prefix(2).map(\.name))")
check(Set(searchKeys("pag").prefix(2).map(\.name)) == ["Page Up", "Page Down"], "a prefix finds Page Up and Down")
check(searchKeys("arrow").count == 4 && searchKeys("keypad").count == 19, "words match (4 arrows; 18 keypad keys and the JIS keypad comma)")
check(searchKeys("zzz").isEmpty && searchKeys("").count == 128, "no match; empty search lists every key")
let mod = parseConfig(Data(#"{"scroll": {"key": "Right Option"}}"#.utf8))
check(mod.config.scrollKey == 90 && mod.warnings.count == 1, "a modifier is refused: \(mod.warnings)")
let dup = parseConfig(Data(#"{"scroll": {"key": "F20", "verticalKey": "F20", "horizontalKey": "f19"}}"#.utf8))
check(dup.config.scrollKey == 90 && dup.config.verticalScrollKey == nil && dup.config.horizontalScrollKey == 80 && dup.warnings.count == 1,
      "a key used twice is refused: \(dup.warnings)")
let moved = parseConfig(Data(#"{"scroll": {"verticalKey": "F20"}}"#.utf8))
check(moved.config.scrollKey == nil && moved.config.verticalScrollKey == 90 && moved.warnings.isEmpty, "a key given another job leaves the default")
var sk = AppConfig()
sk.setScrollKey(.horizontal, 90)
check(sk.scrollKey == nil && sk.horizontalScrollKey == 90 && sk.scrollKeyRole(for: 90) == .horizontal, "setting a key takes it off the others")
let roll = parseConfig(Data(#"{"scroll": {"horizontalKeyRolling": "diagonal"}}"#.utf8))
check(roll.config.horizontalKeyRolling == .sideways && roll.warnings.count == 1, "bad horizontalKeyRolling")

print("config: pause shortcut")
let ps = Shortcut(key: 35, modifiers: [.command, .control, .option])
check(ps.display == "⌃⌥⌘P" && ps.modifierNames == ["Control", "Option", "Command"], "shown and written in macOS's order: \(ps.display)")
check(renderConfig(AppConfig()).contains("\"pauseShortcut\": null,") && AppConfig().pauseShortcut == nil, "none by default")
let psr = parseConfig(Data(#"{"general": {"pauseShortcut": {"key": "page down", "modifiers": ["ctrl", "Shift"]}}}"#.utf8))
check(psr.warnings.isEmpty && psr.config.pauseShortcut == Shortcut(key: 121, modifiers: [.control, .shift]), "names and short modifier names read")
let f19 = parseConfig(Data(#"{"general": {"pauseShortcut": {"key": "F19"}}}"#.utf8))
check(f19.warnings.isEmpty && f19.config.pauseShortcut == Shortcut(key: 80, modifiers: []), "an F-key works alone")
let psBad = parseConfig(Data(#"{"general": {"pauseShortcut": {"key": "P"}}, "scroll": {"key": "F18"}}"#.utf8))
let psScroll = parseConfig(Data(#"{"general": {"pauseShortcut": {"key": "F18", "modifiers": ["Option"]}}, "scroll": {"key": "F18"}}"#.utf8))
let psJunk = parseConfig(Data(#"{"general": {"pauseShortcut": {"key": "P", "modifiers": ["Hyper"]}}}"#.utf8))
check([psBad, psScroll, psJunk].allSatisfy { $0.config.pauseShortcut == nil && $0.warnings.count == 1 },
      "refused: a letter alone, a scroll key, an unknown modifier: \([psBad, psScroll, psJunk].map(\.warnings))")

print("keymap: keys follow a scroll key change")
do {
  // macOS F20 = 90, F19 = 80, F18 = 79; Defy codes F20 = 111, F19 = 110, F18 = 109.
  var km = Array(repeating: Keymap.transparent, count: Keymap.keysPerLayer * 10)
  km[8 * 80 + 5] = 111; km[0 * 80 + 70] = 111   // F20 on the Auto-Mouse Layer and on a base layer
  km[1 * 80 + 3] = 109                           // F18, already on the keyboard for something else
  let kb = KeyboardModel(focus: Focus())
  kb.setData(keymap: km, superkeys: [], layerNames: [])
  var c = AppConfig(); c.scrollKey = 79
  kb.follow(.both, from: 90, to: 79)
  check(kb.pending == [8: [5: 109], 0: [70: 109]], "every key that sent the old key sends the new one: \(kb.pending)")
  check(kb.followNotices(c) == [.init(role: .both, was: 90, now: 79, layers: [0, 8])], "the banner names both layers: \(kb.followNotices(c))")
  c.scrollKey = 80
  kb.follow(.both, from: 79, to: 80)
  check(kb.pending == [8: [5: 110], 0: [70: 110]] && kb.pending[1] == nil, "a second change moves them on, not the key that was F18 already")
  check(kb.followNotices(c).first?.was == 90, "the banner still names what the keyboard sends")
  c.scrollKey = 90
  kb.follow(.both, from: 80, to: 90)
  check(kb.pending.isEmpty && kb.followNotices(c).isEmpty && kb.followedFrom.isEmpty, "changing back leaves nothing to write")
  kb.follow(.both, from: 90, to: nil)
  check(kb.pending.isEmpty, "turning a scroll key off leaves the keyboard alone")
  c.scrollKey = 79
  kb.follow(.both, from: 90, to: 79)
  kb.setPending(layer: 2, key: 1, code: Keymap.leftClick)
  var reverted: [(ScrollKeyRole, Int)] = []
  kb.discard(c) { r, k in reverted.append((r, k)); kb.follow(r, from: 79, to: k) }
  check(reverted.count == 1 && reverted[0].0 == .both && reverted[0].1 == 90, "discard puts the scroll key back: \(reverted)")
  check(kb.pending.isEmpty && kb.followedFrom.isEmpty, "discard drops every edit not yet written")

  // Not read yet: the change waits for the keymap.
  let f = Focus()
  f.setPaused(true, reason: "test")  // so the read fails without opening a real keyboard
  let kb2 = KeyboardModel(focus: f)
  kb2.follow(.both, from: 90, to: 79)
  check(kb2.waitingFollows.count == 1 && kb2.busy, "a change before the keymap is read reads it")
  RunLoop.main.run(until: Date().addingTimeInterval(0.3))
  check(!kb2.busy && kb2.failed && kb2.waitingNotices(c).count == 1, "a failed read keeps the change waiting")
  var reverted2: [(ScrollKeyRole, Int)] = []
  kb2.discard(c) { reverted2.append(($0, $1)) }
  check(reverted2.count == 1 && reverted2[0].1 == 90 && kb2.waitingFollows.isEmpty, "discard puts back a waiting change too")
}

print("config: Toggle Scroll")
var tl = AppConfig()
tl.setTapTiming(.key, \.maxMs, 400)
check(tl.keyTap.maxMs == 400 && tl.buttonTap.maxMs == 400, "shared timing: setting the keys' sets the buttons' too")
tl.sameTapTiming = false
tl.setTapTiming(.button, \.maxMotion, 3)
check(tl.buttonTap.maxMotion == 3 && tl.keyTap.maxMotion == 10, "separate timing: only the one set")
tl.setSameTapTiming(true, from: .button)
check(tl.keyTap.maxMotion == 3 && tl.keyTap.maxMs == 400, "sharing again: the other one takes this one's timing")
tl.buttonTap.toggleScroll = false
check(tl.keyTap.toggleScroll, "the Toggle Scroll switches stay separate")
let shared = parseConfig(Data(#"{"trackballs": {"tapMaxMs": 300}, "scroll": {"tapMaxMs": 200, "tapToToggleScroll": false}}"#.utf8))
check(shared.config.keyTap == TapSettings(toggleScroll: false, maxMs: 300, maxMotion: 10) && shared.config.buttonTap.maxMs == 300 && shared.config.buttonTap.toggleScroll,
      "sameTapTiming (default on): the keys take the buttons' timing, but not their switch")
let apart = parseConfig(Data(#"{"trackballs": {"tapMaxMs": 300}, "scroll": {"tapMaxMs": 200, "sameTapTiming": false}}"#.utf8))
check(apart.config.keyTap.maxMs == 200 && apart.config.buttonTap.maxMs == 300 && apart.warnings.isEmpty, "sameTapTiming off: each its own")

print("config: scroll buttons")
let badButton = parseConfig(Data(#"{"trackballs": {"devices": [{"vendorId": 1, "productId": 2, "scrollButton": {"usagePage": 9, "usage": 2}}]}}"#.utf8))
check(badButton.config.devices.first?.scrollButton == nil && badButton.warnings.count == 1, "a device's bad scroll button: none, one warning")

print("config: bad files and values")
let bad = parseConfig(Data("{ \"scroll\": { \"gainX\": } }".utf8))
check(!bad.valid, "broken JSON is refused: \(bad.warnings.first ?? "")")
check(!parseConfig(Data("[1]".utf8)).valid, "a list instead of an object is refused")
let vals = parseConfig(Data("""
{ "scroll": { "gainX": "fast", "key": "F21", "tapMaxMs": -1, "invertX": 1 },
  "layer": { "activationThreshold": 2.5 }, "keyboard": { "autoMouseLayer": 40, "productIds": [] },
  "trackballs": { "scrollButton": { "usagePage": 9, "usage": 1 }, "devices": [ { "vendorId": 1 } ] },
  "general": { "showInDock": "yes" }, "extra": {}, "log": { "verbos": true } }
""".utf8))
check(vals.valid, "readable")
check(vals.config == AppConfig(), "every bad value keeps its default")
check(vals.warnings.count == 12, "one warning each (\(vals.warnings.count)): \(vals.warnings.joined(separator: " | "))")
let hex = parseConfig(Data("{ // comment\n \"keyboard\": { \"vendorId\": 0x35ef, /* c */ }, }".utf8))
check(hex.valid && hex.warnings.isEmpty && hex.config.keyboardVendorId == 0x35ef, "comments, trailing commas and hex")

print("keymap: decoding")
check(Keymap.decode(111).main == "F20" && Keymap.decode(Keymap.leftClick).desc == "Left click", "F20, left click")
check(Keymap.decode(542).desc == "Option+1" && Keymap.decode(8 << 8 | 30).main == "!", "Option+1, shifted 1")
check(Keymap.splitSuperkeys([4, 0, 5, 225, 0, 0, 9, 0]) == [[4], [5, 225]], "superkeys.map ends at 0 0")
check(Keymap.decode(53980 + 1, superkeys: [[4], [5, 225]]).desc == "Superkey 2: B on tap, Left Shift on hold", "superkey")
var km: [Int] = []
if args.count > 1, let dumpData = FileManager.default.contents(atPath: args[1]),
   let dump = try? JSONSerialization.jsonObject(with: dumpData) as? [String: Any] {
  print("keymap: decoding \(args[1])")
  func nums(_ s: Any?) -> [Int] { (s as? String ?? "").split(separator: " ").compactMap { Int($0) } }
  km = nums(dump["keymap.custom"])
  let sk = Keymap.splitSuperkeys(nums(dump["superkeys.map"]))
  check(km.count % 80 == 0 && !km.isEmpty, "\(km.count / 80) layers")
  var unknown = Set<Int>()
  for code in km where Keymap.decode(code, superkeys: sk).main.hasPrefix("#") { unknown.insert(code) }
  check(unknown.isEmpty, "every code decodes: unknown \(unknown.sorted())")
} else {
  print("keymap: no dump given, skipping the checks against a real keymap")
}
check(Keymap.decode(65535).kind == .transparent && Keymap.decode(0).kind == .none, "transparent and none")
check(Keymap.decode(51218 + 256 * 2 + 44).desc == "Space on tap, layer 3 on hold", "layer-tap")
check(Keymap.decode(49937 + 4).desc == "A on tap, Command on hold", "dual-function")
check(Keymap.decode(2530).main == "Meh" && Keymap.decode(17451).desc == "Layer 2 while held", "Meh, layer hold")
check(Keymap.hidCode(forMacKey: 90) == 111 && Keymap.decode(111).main == "F20", "F20 maps to HID 111")

print("keymap: geometry")
check(Keymap.geometry.count == 70, "70 keys, 35 a side (\(Keymap.geometry.count)); the other 10 of 80 slots aren't keys")
check(Keymap.geometry.keys.allSatisfy { $0 < 80 }, "indices below 80")
let g = Keymap.geometry.values
check(g.allSatisfy { $0.x - $0.w / 2 >= -0.1 && $0.x + $0.w / 2 <= Keymap.width + 0.1 && $0.y + $0.h / 2 <= Keymap.height + 0.1 }, "inside the drawing")

print("config file: kept in step with the app")
func wait(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
let dir = NSTemporaryDirectory() + "auto-mouse-test-\(getpid())"
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
let path = dir + "/config.json5"
try! Data(#"{"scroll": {"key": "F20"}}"#.utf8).write(to: URL(fileURLWithPath: path))  // a partial file
let store = ConfigStore(path: path)
var changes = 0
store.onChange = { _, _ in changes += 1 }
store.load()
store.startWatching()
func file() -> String { String(decoding: FileManager.default.contents(atPath: path) ?? Data(), as: UTF8.self) }
check(file() == renderConfig(store.config), "a partial file is rewritten in the current form at start")
check(store.config.devices.count == 1 && store.config.scrollKey == 90, "with its settings")
wait(0.5)
store.edit { $0.gainY = 4.5 }
check(!file().contains("\"gainY\": 4.5"), "an edit isn't written at once")
wait(0.8)
check(file().contains("\"gainY\": 4.5"), "it is written half a second later")
check(changes == 1, "one change reported (\(changes))")
// Edit by hand, as an editor would: write a new file and move it into place.
var hand = file().replacingOccurrences(of: "\"gainX\": 3.0", with: "\"gainX\": 7.25")
try! hand.write(toFile: path + ".edit", atomically: false, encoding: .utf8)
rename(path + ".edit", path)
wait(0.6)
check(store.config.gainX == 7.25, "a hand edit is picked up (\(store.config.gainX))")
check(file() == hand, "and the file is left as the user wrote it")
let fh = FileHandle(forWritingAtPath: path)!  // edit in place, as VS Code and nano do
fh.truncateFile(atOffset: 0)
fh.write(Data(hand.replacingOccurrences(of: "\"gainX\": 7.25", with: "\"gainX\": 6.5").utf8))
fh.closeFile()
wait(0.6)
check(store.config.gainX == 6.5, "an edit written into the file is picked up (\(store.config.gainX))")
rename(path, path + ".x"); rename(path + ".x", path)
hand = file().replacingOccurrences(of: "\"gainX\": 6.5", with: "\"gainX\": 7.25")
try! hand.write(toFile: path, atomically: true, encoding: .utf8)
wait(0.6)
hand += "oops"
try! hand.write(toFile: path, atomically: true, encoding: .utf8)
wait(0.6)
check(store.fileBroken && store.config.gainX == 7.25, "a broken file keeps the previous settings")
check(file() == hand, "and is not overwritten")
store.edit { $0.gainX = 2 }
wait(0.8)
check(!store.fileBroken && parseConfig(Data(file().utf8)).config.gainX == 2, "a change in the app writes a good file again")
try! FileManager.default.removeItem(atPath: path)
wait(0.6)
check(parseConfig(Data(file().utf8)).config == store.config, "a deleted file is written back")
try? FileManager.default.removeItem(atPath: dir)

print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
