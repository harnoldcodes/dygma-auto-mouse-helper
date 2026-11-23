import AppKit
import ApplicationServices
import IOKit.hid
import ServiceManagement

/// Input Monitoring and Accessibility. macOS doesn't tell a running process when they are
/// granted, so this checks every 2 seconds while one is missing. Input Monitoring is only
/// seen by a new process, so the check runs this app's own binary with --check-access, and
/// `grantedSinceLaunch` turns true when that one sees a grant this process can't use yet.
final class Permissions: ObservableObject {
  @Published var inputMonitoring = false  // set from outside only by the screenshot harness
  @Published var accessibility = false
  @Published private(set) var grantedSinceLaunch = false
  var allGranted: Bool { inputMonitoring && accessibility }
  var onChange: (() -> Void)?
  private var timer: Timer?
  private var checking = false

  static func inputMonitoringNow() -> Bool {
    IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
  }

  func refresh() {
    let im = Permissions.inputMonitoringNow()
    let ax = AXIsProcessTrusted()
    if im != inputMonitoring || ax != accessibility {
      inputMonitoring = im
      accessibility = ax
      log("permissions: Input Monitoring \(im ? "on" : "off"), Accessibility \(ax ? "on" : "off")")
      onChange?()
    }
    if !im { checkFreshProcess() }
    if allGranted { timer?.invalidate(); timer = nil }
    else if timer == nil {
      let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
      RunLoop.main.add(t, forMode: .common)
      timer = t
    }
  }

  private func checkFreshProcess() {
    guard !checking, !grantedSinceLaunch, let exe = Bundle.main.executablePath else { return }
    checking = true
    DispatchQueue.global().async {
      let p = Process()
      p.executableURL = URL(fileURLWithPath: exe)
      p.arguments = ["--check-access"]
      let out = Pipe()
      p.standardOutput = out
      p.standardError = FileHandle.nullDevice
      var granted = false
      if (try? p.run()) != nil {
        p.waitUntilExit()
        granted = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).hasPrefix("granted")
      }
      DispatchQueue.main.async {
        self.checking = false
        if granted && !self.grantedSinceLaunch {
          log("permissions: Input Monitoring was granted; this process needs a restart to use it")
          self.grantedSinceLaunch = true
          self.onChange?()
        }
      }
    }
  }

  /// Ask macOS to list the app in both places (and show its own prompts).
  func request() {
    if !inputMonitoring { IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }
    if !accessibility {
      _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }
  }

  static func openInputMonitoring() {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
  }

  static func openAccessibility() {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
  }
}

/// Start at login. Uses macOS's login items (SMAppService); if macOS refuses (it may, for an
/// app without an Apple developer signature), falls back to a LaunchAgent that opens the
/// app at login.
enum LoginItem {
  static let agentLabel = "io.github.harnoldcodes.dygma-auto-mouse-helper.login"
  static var agentPath: String { NSString(string: "~/Library/LaunchAgents/\(agentLabel).plist").expandingTildeInPath }

  /// Make macOS match the setting. Returns a short status for the window.
  @discardableResult
  static func apply(_ enabled: Bool) -> String {
    let svc = SMAppService.mainApp
    if enabled {
      if svc.status == .enabled { removeAgent(); return "On (login item)" }
      if svc.status == .requiresApproval {
        return "Waiting for approval in System Settings > General > Login Items"
      }
      do {
        try svc.register()
        removeAgent()
        log("login item: registered (\(statusName(svc.status)))")
        return svc.status == .requiresApproval
          ? "Waiting for approval in System Settings > General > Login Items" : "On (login item)"
      } catch {
        log("login item: register failed (\(error.localizedDescription)); using a LaunchAgent instead")
        return writeAgent() ? "On (LaunchAgent)" : "Couldn't set it up; see the log"
      }
    } else {
      if svc.status == .enabled || svc.status == .requiresApproval {
        do { try svc.unregister(); log("login item: unregistered") } catch {
          log("login item: unregister failed: \(error.localizedDescription)")
        }
      }
      removeAgent()
      return "Off"
    }
  }

  static func statusName(_ s: SMAppService.Status) -> String {
    switch s {
    case .enabled: return "enabled"
    case .notRegistered: return "not registered"
    case .requiresApproval: return "requires approval"
    case .notFound: return "not found"
    @unknown default: return "unknown"
    }
  }

  private static func writeAgent() -> Bool {
    let exe = Bundle.main.executablePath ?? ""
    let plist: [String: Any] = [
      "Label": agentLabel,
      "ProgramArguments": [exe, "--login"],
      "RunAtLoad": true,
      "LimitLoadToSessionType": "Aqua",
      "ProcessType": "Interactive",
    ]
    do {
      try FileManager.default.createDirectory(atPath: (agentPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
      let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
      try data.write(to: URL(fileURLWithPath: agentPath))
      log("login item: wrote \(agentPath)")
      return true
    } catch {
      log("login item: couldn't write \(agentPath): \(error.localizedDescription)")
      return false
    }
  }

  private static func removeAgent() {
    if FileManager.default.fileExists(atPath: agentPath) {
      try? FileManager.default.removeItem(atPath: agentPath)
      log("login item: removed \(agentPath)")
    }
  }
}

/// Quit and open the app again (a new process sees permissions granted since launch).
func relaunch(showSettings: Bool, afterGrant: Bool = false) {
  var args = [showSettings ? "--show-settings" : "--relaunched"]
  if afterGrant { args.append("--after-grant") }
  if let i = CommandLine.arguments.firstIndex(of: "--config"), i + 1 < CommandLine.arguments.count {
    args += ["--config", CommandLine.arguments[i + 1]]
  }
  let p = Process()
  p.executableURL = URL(fileURLWithPath: "/bin/sh")
  p.arguments = ["-c", "sleep 1; exec /usr/bin/open -n \"$0\" --args \"$@\"", Bundle.main.bundlePath] + args
  try? p.run()
  log("relaunching")
  NSApp.terminate(nil)
}
