import Foundation

/// Appends to ~/Library/Logs/dygma-auto-mouse-helper.log. Lines from `vlog` only appear when
/// "log.verbose" is on. The file is moved to .old.log once it passes 2 MB. The tests set
/// DYGMA_AUTO_MOUSE_HELPER_LOG to log somewhere else.
final class Log {
  static let shared = Log()
  static let path = ProcessInfo.processInfo.environment["DYGMA_AUTO_MOUSE_HELPER_LOG"]
    ?? NSString(string: "~/Library/Logs/dygma-auto-mouse-helper.log").expandingTildeInPath

  var verbose = false
  var echo = false  // also print to stdout (command-line use)
  private let queue = DispatchQueue(label: "log")
  private var handle: FileHandle?
  private let stamp: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return f
  }()

  func write(_ s: String) {
    let line = "\(stamp.string(from: Date())) \(s)\n"
    if echo { print(line, terminator: "") }
    queue.async { self.append(line) }
  }

  private func append(_ line: String) {
    let fm = FileManager.default
    if handle == nil {
      try? fm.createDirectory(atPath: (Log.path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
      if !fm.fileExists(atPath: Log.path) { fm.createFile(atPath: Log.path, contents: nil) }
      handle = FileHandle(forWritingAtPath: Log.path)
      handle?.seekToEndOfFile()
    }
    guard let h = handle else { return }
    h.write(Data(line.utf8))
    if h.offsetInFile > 2_000_000 {
      h.closeFile()
      handle = nil
      let old = (Log.path as NSString).deletingPathExtension + ".old.log"
      try? fm.removeItem(atPath: old)
      try? fm.moveItem(atPath: Log.path, toPath: old)
    }
  }
}

func log(_ s: String) { Log.shared.write(s) }
func vlog(_ s: @autoclosure () -> String) { if Log.shared.verbose { Log.shared.write(s()) } }
