import AppKit

// The app takes --config <path> to use another settings file. Command-line uses of its binary:
//   --check-config [path]   read a config file, list what's wrong with it, print the settings
//   --print-default-config  print config.json5 with every setting at its default
//   --remove-login-item     stop starting at login (used by uninstall.sh)
//   --check-access          print whether this app may read the mice and trackballs (used by
//                           the app itself, from a new process: see Permissions)
let args = CommandLine.arguments

if args.contains("--print-default-config") {
  print(renderConfig(AppConfig()), terminator: "")
  exit(0)
}

if args.contains("--remove-login-item") {
  LoginItem.apply(false)
  exit(0)
}

if args.contains("--check-access") {
  print(Permissions.inputMonitoringNow() ? "granted" : "denied")
  exit(0)
}

if let i = args.firstIndex(of: "--check-config") {
  let path = i + 1 < args.count ? args[i + 1] : ConfigStore.defaultPath
  guard let data = FileManager.default.contents(atPath: path) else {
    print("\(path): not found (the app writes the defaults there when it starts)")
    exit(1)
  }
  let p = parseConfig(data)
  for w in p.warnings { print("warning: \(w)") }
  if !p.valid { exit(1) }
  for line in describeConfig(p.config) { print(line) }
  exit(p.warnings.isEmpty ? 0 : 2)
}

// One copy at a time. Opening it again shows the running copy's settings instead.
if let id = Bundle.main.bundleIdentifier {
  let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
    .map(\.processIdentifier).filter { $0 != getpid() }
  if !others.isEmpty {
    if args.contains("--relaunched") || args.contains("--show-settings") {
      // The copy that relaunched this one is quitting; wait for it.
      for _ in 0..<50 where others.contains(where: { kill($0, 0) == 0 }) { Thread.sleep(forTimeInterval: 0.1) }
    } else {
      if !args.contains("--login") {
        DistributedNotificationCenter.default().postNotificationName(
          AppDelegate.showNotification, object: nil, userInfo: nil, deliverImmediately: true)
      }
      exit(0)
    }
  }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
