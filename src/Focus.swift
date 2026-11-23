import Foundation
import IOKit
import IOKit.serial

/// The keyboard's Focus serial port (the connection Bazecor uses). All I/O runs on one
/// serial queue, one command at a time: write the command, read until the reply's closing
/// "." line. Layer switches are sent without waiting on the caller; reads of the keymap
/// report back on the main thread.
final class Focus {
  enum Status: Equatable {
    case notFound
    case open(String)
    case paused
  }

  /// Main thread: called when the port opens, closes or pauses.
  var onStatus: ((Status) -> Void)?
  private(set) var status: Status = .notFound  // main-thread copy

  private let q = DispatchQueue(label: "focus")
  private var fd: Int32 = -1          // q only
  private var paused = false          // q only
  private var lastSearch = Date.distantPast
  private var vendorId = 0x35ef
  private var productIds = [0x0010, 0x0012]

  func configure(vendorId: Int, productIds: [Int]) {
    q.async {
      let changed = vendorId != self.vendorId || productIds != self.productIds
      self.vendorId = vendorId; self.productIds = productIds
      if changed { self.closeLocked("keyboard settings changed"); self.lastSearch = .distantPast }
    }
  }

  func setPaused(_ p: Bool, reason: String) {
    q.async {
      guard p != self.paused else { return }
      self.paused = p
      if p { self.closeLocked(reason) } else { self.lastSearch = .distantPast; self.openLocked() }
      self.publish()
    }
  }

  /// At most once a second: look for the keyboard if the port isn't open, and notice when
  /// it has been unplugged if it is (nothing else would until the next command fails).
  func searchIfNeeded() {
    q.async {
      guard Date().timeIntervalSince(self.lastSearch) > 1 else { return }
      if self.fd >= 0 {
        self.lastSearch = Date()
        if !FileManager.default.fileExists(atPath: self.currentPath) { self.closeLocked("unplugged") }
      } else if !self.paused {
        self.openLocked()
      }
    }
  }

  /// Wait until every command sent so far has been answered (on quit).
  func waitForPending() { q.sync {} }

  /// Send a command and don't wait for the result.
  func send(_ cmd: String) {
    q.async { _ = self.transact(cmd, timeout: 1) }
  }

  /// Send a command; `done` gets the reply (nil: no port, or no reply) on the main thread.
  func query(_ cmd: String, timeout: Double = 5, done: @escaping (String?) -> Void) {
    q.async {
      let r = self.transact(cmd, timeout: timeout)
      DispatchQueue.main.async { done(r) }
    }
  }

  // MARK: queue-only

  private func publish() {
    let s: Status = paused ? .paused : (fd >= 0 ? .open(currentPath) : .notFound)
    DispatchQueue.main.async {
      guard s != self.status else { return }
      self.status = s
      self.onStatus?(s)
    }
  }

  private var currentPath = ""

  /// Callout device of the serial interface whose USB device is the keyboard.
  private func findPort() -> String? {
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOSerialBSDServiceValue), &iter) == KERN_SUCCESS else { return nil }
    defer { IOObjectRelease(iter) }
    while case let svc = IOIteratorNext(iter), svc != 0 {
      defer { IOObjectRelease(svc) }
      let opts = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
      let vid = IORegistryEntrySearchCFProperty(svc, kIOServicePlane, "idVendor" as CFString, nil, opts) as? Int
      let pid = IORegistryEntrySearchCFProperty(svc, kIOServicePlane, "idProduct" as CFString, nil, opts) as? Int
      if vid == vendorId, let pid = pid, productIds.contains(pid),
         let path = IORegistryEntryCreateCFProperty(svc, kIOCalloutDeviceKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String {
        return path
      }
    }
    return nil
  }

  private func openLocked() {
    guard fd < 0, !paused else { return }
    lastSearch = Date()
    guard let path = findPort() else { return }
    let f = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
    if f < 0 {
      log("focus: can't open \(path): \(String(cString: strerror(errno)))")
      return
    }
    var t = termios()
    tcgetattr(f, &t)
    cfmakeraw(&t)
    t.c_cflag |= tcflag_t(CLOCAL | CREAD)
    cfsetspeed(&t, speed_t(B115200))
    tcsetattr(f, TCSANOW, &t)
    fd = f
    currentPath = path
    log("focus: opened \(path)")
    publish()
  }

  private func closeLocked(_ reason: String) {
    guard fd >= 0 else { return }
    Darwin.close(fd)
    fd = -1
    log("focus: closed (\(reason))")
    publish()
  }

  private func transact(_ cmd: String, timeout: Double) -> String? {
    if fd < 0 { openLocked() }
    guard fd >= 0 else { return nil }
    drain()
    var bytes = Array((cmd + "\n").utf8)
    let deadline = Date().addingTimeInterval(timeout)
    while !bytes.isEmpty {
      let n = write(fd, bytes, bytes.count)
      if n > 0 { bytes.removeFirst(n); continue }
      if n < 0 && errno != EAGAIN { closeLocked("write error: \(String(cString: strerror(errno)))"); return nil }
      if Date() > deadline { log("focus: '\(cmd.prefix(40))' timed out writing"); return nil }
      var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
      Darwin.poll(&p, 1, 50)
    }
    var out = [UInt8]()
    var buf = [UInt8](repeating: 0, count: 65536)
    while Date() < deadline {
      var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
      let ready = Darwin.poll(&p, 1, 50)
      if ready > 0 {
        let n = read(fd, &buf, buf.count)
        if n > 0 { out.append(contentsOf: buf[0..<n]) }
        else if n == 0 || errno != EAGAIN { closeLocked("read error"); return nil }
      }
      if out.count >= 3 {
        let tail = out.suffix(5)
        if tail.elementsEqual(Array("\r\n.\r\n".utf8)) || out.elementsEqual(Array(".\r\n".utf8)) {
          let s = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
          return String(s.dropLast(s.hasSuffix(".") ? 1 : 0)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
      }
    }
    log("focus: no reply to '\(cmd.prefix(40))'")
    return nil
  }

  /// Throw away anything left over from an earlier command.
  private func drain() {
    var buf = [UInt8](repeating: 0, count: 4096)
    while read(fd, &buf, buf.count) > 0 {}
  }
}
