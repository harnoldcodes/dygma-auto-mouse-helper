import Combine
import Foundation

/// Holds the settings and keeps them in step with config.json5, the only place they live.
/// Edits made in the app are written to the file (half a second after the last change);
/// edits made to the file are picked up within a moment. A file that isn't valid JSON5 is
/// never overwritten by the app on its own, and the previous settings stay in use.
final class ConfigStore: ObservableObject {
  static let defaultPath = NSString(string: "~/.config/dygma-auto-mouse-helper/config.json5").expandingTildeInPath

  let path: String
  /// The path as the window shows it, with ~ for the home folder ($HOME, so the README's
  /// screenshots can stand in a home folder of their own).
  var displayPath: String {
    let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : (path as NSString).abbreviatingWithTildeInPath
  }
  @Published private(set) var config = AppConfig()
  /// Problems found in the file the last time it was read.
  @Published private(set) var warnings: [String] = []
  /// The file couldn't be read as JSON5; the app is using the settings it had before.
  @Published private(set) var fileBroken = false

  /// Called on the main thread with (old, new) whenever the settings change.
  var onChange: ((AppConfig, AppConfig) -> Void)?

  private var lastData: Data?          // what the file held when last read or written
  private var saveWork: DispatchWorkItem?
  private var reloadWork: DispatchWorkItem?
  private var watcher: DispatchSourceFileSystemObject?
  private var fileWatcher: DispatchSourceFileSystemObject?
  private var dirFD: Int32 = -1

  init(path: String = ConfigStore.defaultPath) {
    self.path = path
  }

  /// Reads the file, or writes the defaults if there is none.
  func load() {
    let fm = FileManager.default
    try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    if let data = fm.contents(atPath: path) {
      apply(data, initial: true)
      // Bring an older or partial file into the current form (every setting, with its
      // comment), unless something in it needs the user's attention first.
      if !fileBroken && warnings.isEmpty && data != Data(renderConfig(config).utf8) {
        log("config: rewriting \(path) in the current form")
        writeNow()
      }
    } else {
      log("config: \(path) not found; writing the defaults")
      config = AppConfig()
      writeNow()
    }
    Log.shared.verbose = config.verbose
  }

  /// Change settings from the app. Saved to the file shortly after the last change.
  func edit(_ change: (inout AppConfig) -> Void) {
    var c = config
    change(&c)
    guard c != config else { return }
    let old = config
    config = c
    Log.shared.verbose = c.verbose
    onChange?(old, c)
    scheduleSave()
  }

  /// Write pending changes now (on quit).
  func flush() {
    if saveWork != nil { saveWork?.cancel(); saveWork = nil; writeNow() }
  }

  // MARK: file

  private func scheduleSave() {
    saveWork?.cancel()
    let w = DispatchWorkItem { [weak self] in self?.saveWork = nil; self?.writeNow() }
    saveWork = w
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
  }

  private func writeNow() {
    let data = Data(renderConfig(config).utf8)
    let tmp = path + ".tmp"
    do {
      try data.write(to: URL(fileURLWithPath: tmp))
      if rename(tmp, path) != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
      lastData = data
      warnings = []
      fileBroken = false
      vlog("config: saved")
      if watcher != nil { watchFile() }  // the file was replaced
    } catch {
      try? FileManager.default.removeItem(atPath: tmp)
      log("config: couldn't write \(path): \(error.localizedDescription)")
      warnings = ["couldn't save: \(error.localizedDescription)"]
    }
  }

  private func apply(_ data: Data, initial: Bool) {
    lastData = data
    let p = parseConfig(data)
    if !p.valid {
      fileBroken = true
      warnings = p.warnings + [initial ? "using the default settings until the file is fixed"
                                       : "still using the previous settings until the file is fixed"]
      log("config: \(p.warnings.joined(separator: "; "))")
      return
    }
    fileBroken = false
    warnings = p.warnings
    for w in p.warnings { log("config warning: \(w)") }
    if p.config != config || initial {
      let old = config
      config = p.config
      Log.shared.verbose = p.config.verbose
      if !initial {
        log("config: reloaded \(path)")
        onChange?(old, p.config)
      }
    }
  }

  /// Watch the folder, for editors (and this app) that save by replacing the file, and the
  /// file, for editors that write into it.
  func startWatching() {
    let dir = (path as NSString).deletingLastPathComponent
    dirFD = open(dir, O_EVTONLY)
    guard dirFD >= 0 else { log("config: can't watch \(dir)"); return }
    let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: dirFD, eventMask: [.write, .rename, .delete], queue: .main)
    src.setEventHandler { [weak self] in self?.scheduleReload() }
    src.setCancelHandler { [dirFD] in close(dirFD) }
    src.resume()
    watcher = src
    watchFile()
  }

  private func watchFile() {
    fileWatcher?.cancel()
    fileWatcher = nil
    let fd = open(path, O_EVTONLY)
    guard fd >= 0 else { return }
    let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
    src.setEventHandler { [weak self] in self?.scheduleReload() }
    src.setCancelHandler { close(fd) }
    src.resume()
    fileWatcher = src
  }

  private func scheduleReload() {
    reloadWork?.cancel()
    let w = DispatchWorkItem { [weak self] in self?.reloadFromDisk() }
    reloadWork = w
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: w)
  }

  private func reloadFromDisk() {
    watchFile()  // the file may have been replaced
    guard saveWork == nil else { return }  // our own change is about to be written
    guard let data = FileManager.default.contents(atPath: path) else {
      if lastData != nil {
        log("config: \(path) was removed; writing the current settings back")
        writeNow()
      }
      return
    }
    if data == lastData { return }
    apply(data, initial: false)
  }
}
