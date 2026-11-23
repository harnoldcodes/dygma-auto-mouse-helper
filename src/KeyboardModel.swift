import Foundation

/// The keyboard's layers as read over Focus, plus the click edits waiting to be written.
final class KeyboardModel: ObservableObject {
  @Published private(set) var keymap: [Int] = []
  @Published private(set) var superkeys: [[Int]] = []
  @Published private(set) var layerNames: [String] = []
  @Published private(set) var busy = false
  @Published private(set) var message = ""
  @Published private(set) var failed = false
  /// Edits not yet written: (layer, key index) → code.
  @Published var pending: [Int: [Int: Int]] = [:]
  /// Scroll keys changed on the Scroll Key tab while the keyboard still sends the old key:
  /// the role → the macOS key the keyboard sends. The keys that send it have pending edits
  /// to the new key. Cleared by a write or a discard.
  @Published private(set) var followedFrom: [ScrollKeyRole: Int] = [:]
  /// Scroll key changes made before the keymap was read, applied once it is.
  @Published private(set) var waitingFollows: [(role: ScrollKeyRole, from: Int, to: Int)] = []
  private var following = true

  private let focus: Focus
  static let backupDir = NSString(string: "~/.local/state/dygma-auto-mouse-helper/backup").expandingTildeInPath

  init(focus: Focus) { self.focus = focus }

  var layers: Int { keymap.count / Keymap.keysPerLayer }
  var loaded: Bool { layers > 0 }

  func layerName(_ n: Int) -> String {
    let name = n < layerNames.count ? layerNames[n] : ""
    return name.isEmpty ? "Layer \(n + 1)" : name
  }

  func codes(layer n: Int) -> [Int] {
    guard n >= 0, (n + 1) * Keymap.keysPerLayer <= keymap.count else { return [] }
    var c = Array(keymap[n * Keymap.keysPerLayer..<(n + 1) * Keymap.keysPerLayer])
    for (i, v) in pending[n] ?? [:] { c[i] = v }
    return c
  }

  func isEmpty(layer n: Int) -> Bool { codes(layer: n).allSatisfy { $0 == Keymap.transparent || $0 == 0 } }

  var pendingCount: Int { pending.values.reduce(0) { $0 + $1.count } }

  func setPending(layer: Int, key: Int, code: Int?) {
    var l = pending[layer] ?? [:]
    let original = keymap[layer * Keymap.keysPerLayer + key]
    if let c = code, c != original { l[key] = c } else { l.removeValue(forKey: key) }
    pending[layer] = l.isEmpty ? nil : l
  }

  // MARK: Scroll keys

  /// The scroll key for `role` changed from `from` to `to`: every key, on any layer, that
  /// sends `from` gets a pending edit to send `to`, so it still scrolls once written.
  func follow(_ role: ScrollKeyRole, from: Int?, to: Int?) {
    // A scroll key turned off (or moved to another role, as when switching to separate
    // keys) leaves the keyboard as it is.
    guard following, let from = from, let to = to, from != to,
          let fromHid = Keymap.hidCode(forMacKey: from), let toHid = Keymap.hidCode(forMacKey: to) else { return }
    guard loaded else {
      waitingFollows.append((role, from, to))
      if !busy { read() }
      return
    }
    // The keys to move: those that send the key the keyboard has for this role (while an
    // earlier change waits to be written, that is the key from before it), and keys set to
    // the scroll key here and not yet written. A key that already sent `from` for some other
    // reason, before a change passed through it, stays as it is.
    let base = followedFrom[role].flatMap { Keymap.hidCode(forMacKey: $0) } ?? fromHid
    var moved = 0
    for layer in 0..<layers {
      for (i, c) in codes(layer: layer).enumerated()
      where c == fromHid && (keymap[layer * Keymap.keysPerLayer + i] == base || pending[layer]?[i] != nil) {
        setPending(layer: layer, key: i, code: toHid)
        moved += 1
      }
    }
    if moved > 0 {
      if followedFrom[role] == nil { followedFrom[role] = from }
      log("keymap: \(moved) key(s) that send \(keyName(from)) set to \(keyName(to)), not yet written")
    }
    if followedFrom[role] == to { followedFrom[role] = nil }
  }

  struct FollowNotice: Equatable {
    let role: ScrollKeyRole
    let was: Int, now: Int        // macOS keys: what the keyboard sends, what the setting says
    let layers: [Int]             // where the keys are, one entry per key
  }

  /// The scroll key changes still to be written, for the banner.
  func followNotices(_ config: AppConfig) -> [FollowNotice] {
    ScrollKeyRole.allCases.compactMap { role in
      guard let was = followedFrom[role], let now = config[keyPath: role.keyPath],
            let wasHid = Keymap.hidCode(forMacKey: was), let nowHid = Keymap.hidCode(forMacKey: now) else { return nil }
      var where_: [Int] = []
      for layer in 0..<layers {
        let current = codes(layer: layer)
        for i in 0..<Keymap.keysPerLayer
        where keymap[layer * Keymap.keysPerLayer + i] == wasHid && current[i] == nowHid { where_.append(layer) }
      }
      return where_.isEmpty ? nil : FollowNotice(role: role, was: was, now: now, layers: where_)
    }
  }

  /// Scroll key changes waiting for the keymap to be read: (role, the key the keyboard may
  /// still send, the setting now), leaving out any changed back since.
  func waitingNotices(_ config: AppConfig) -> [(role: ScrollKeyRole, was: Int, now: Int?)] {
    ScrollKeyRole.allCases.compactMap { role in
      guard let first = waitingFollows.first(where: { $0.role == role }) else { return nil }
      let now = config[keyPath: role.keyPath]
      return first.from == now ? nil : (role, first.from, now)
    }
  }

  /// Drops every edit not yet written. `revert` is called to put back each scroll key whose
  /// change was waiting to be written, so the setting matches the keyboard again.
  func discard(_ config: AppConfig, revert: (ScrollKeyRole, Int) -> Void) {
    var back = followedFrom
    for w in waitingNotices(config) { back[w.role] = w.was }
    waitingFollows = []
    following = false
    for (role, key) in back { revert(role, key) }
    following = true
    pending = [:]
    followedFrom = [:]
  }

  // MARK: Focus

  func read() {
    guard !busy else { return }
    busy = true; failed = false
    message = "Reading the keyboard…"
    focus.query("keymap.custom") { [weak self] km in
      guard let self = self else { return }
      guard let km = km, case let codes = km.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" }).compactMap({ Int($0) }),
            !codes.isEmpty, codes.count % Keymap.keysPerLayer == 0 else {
        self.finish(failed: true, self.unavailableMessage())
        return
      }
      self.focus.query("superkeys.map") { sk in
        let flat = sk?.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" }).compactMap { Int($0) } ?? []
        self.setData(keymap: codes, superkeys: Keymap.splitSuperkeys(flat), layerNames: KeyboardModel.bazecorLayerNames())
        self.finish(failed: false, "Read \(self.layers) layers at \(KeyboardModel.time()).")
        let waiting = self.waitingFollows
        self.waitingFollows = []
        for f in waiting { self.follow(f.role, from: f.from, to: f.to) }
      }
    }
  }

  /// Write the pending edits: back up the whole keymap, write it with only the edited keys
  /// changed, read it back and check.
  func write() {
    guard !busy, loaded, pendingCount > 0 else { return }
    busy = true; failed = false
    message = "Writing…"
    var next = keymap
    for (layer, keys) in pending {
      for (i, c) in keys { next[layer * Keymap.keysPerLayer + i] = c }
    }
    let backup: String
    do {
      try FileManager.default.createDirectory(atPath: KeyboardModel.backupDir, withIntermediateDirectories: true)
      let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
      backup = KeyboardModel.backupDir + "/keymap-\(f.string(from: Date())).json"
      let data = try JSONSerialization.data(withJSONObject: ["keymap.custom": keymap], options: [])
      try data.write(to: URL(fileURLWithPath: backup))
    } catch {
      finish(failed: true, "Couldn't save a backup first, so nothing was written: \(error.localizedDescription)")
      return
    }
    let edited = pendingCount
    focus.query("keymap.custom " + next.map(String.init).joined(separator: " "), timeout: 10) { [weak self] reply in
      guard let self = self else { return }
      guard reply != nil else { self.finish(failed: true, self.unavailableMessage()); return }
      self.focus.query("keymap.custom") { back in
        let codes = back?.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" }).compactMap { Int($0) } ?? []
        if codes == next {
          self.keymap = codes
          self.pending = [:]
          self.followedFrom = [:]
          log("keymap: wrote \(edited) key(s); backup \(backup)")
          self.finish(failed: false, "Wrote \(edited) key\(edited == 1 ? "" : "s") to the keyboard. Backup: \(backup)")
        } else {
          log("keymap: write didn't read back the same; backup \(backup)")
          if !codes.isEmpty { self.keymap = codes }
          self.finish(failed: true, "The keyboard didn't read back what was written. Your keymap before the write is in \(backup).")
        }
      }
    }
  }

  func setData(keymap: [Int], superkeys: [[Int]], layerNames: [String]) {
    self.keymap = keymap
    self.superkeys = superkeys
    self.layerNames = layerNames
  }

  private func finish(failed: Bool, _ msg: String) {
    busy = false
    self.failed = failed
    message = msg
  }

  private func unavailableMessage() -> String {
    switch focus.status {
    case .paused: return "The helper has let go of the keyboard (paused, or Bazecor is open)."
    case .notFound: return "The keyboard isn't connected by USB."
    case .open: return "The keyboard didn't answer. Try again."
    }
  }

  private static func time() -> String {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
    return f.string(from: Date())
  }

  /// Layer names live only in Bazecor's own settings, not on the keyboard.
  static func bazecorLayerNames() -> [String] {
    let path = NSString(string: "~/Library/Application Support/Bazecor/config.json").expandingTildeInPath
    guard let data = FileManager.default.contents(atPath: path),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let neurons = root["neurons"] as? [[String: Any]], let n = neurons.first,
          let layers = n["layers"] as? [[String: Any]] else { return [] }
    let sorted = layers.sorted { ($0["id"] as? Int ?? 0) < ($1["id"] as? Int ?? 0) }
    return sorted.map { ($0["name"] as? String ?? "").trimmingCharacters(in: .whitespaces) }
  }
}
