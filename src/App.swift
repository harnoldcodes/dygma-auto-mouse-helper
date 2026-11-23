import AppKit
import Combine
import SwiftUI

/// App-wide state the window shows that doesn't belong to one part.
final class AppModel: ObservableObject {
  @Published var focusStatus: Focus.Status = .notFound
  @Published var loginStatus = ""
  @Published var pausedBy: String?  // the app from keyboard.pauseWhileRunning that is open
  @Published var shortcutProblem: String?  // why macOS refused the pause shortcut
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
  static let showNotification = Notification.Name("io.github.harnoldcodes.dygma-auto-mouse-helper.show")

  let store: ConfigStore = {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: "--config"), i + 1 < a.count {
      return ConfigStore(path: NSString(string: a[i + 1]).expandingTildeInPath)
    }
    return ConfigStore()
  }()
  let focus = Focus()
  let model = AppModel()
  let permissions = Permissions()
  lazy var engine = Engine(focus: focus, store: store)
  lazy var devices = Devices(engine: engine, store: store)
  lazy var tap = EventTap(engine: engine, store: store)
  lazy var keyboard = KeyboardModel(focus: focus)
  let hotKey = HotKey()

  private var statusItem: NSStatusItem?
  private var window: NSWindow?
  private var subs = Set<AnyCancellable>()
  private var firstRun = false
  private var launchedAtLogin = false

  func applicationDidFinishLaunching(_ note: Notification) {
    let args = CommandLine.arguments
    launchedAtLogin = args.contains("--login") || AppDelegate.launchedAsLoginItem()
    log("Dygma Auto-Mouse Helper \(AppDelegate.version) starting (pid \(getpid())\(launchedAtLogin ? ", at login" : ""))")

    firstRun = !FileManager.default.fileExists(atPath: store.path)
    store.load()
    store.startWatching()
    for line in describeConfig(store.config) { log("  \(line)") }
    store.onChange = { [weak self] old, new in self?.configChanged(old, new) }

    focus.configure(vendorId: store.config.keyboardVendorId, productIds: store.config.keyboardProductIds)
    focus.onStatus = { [weak self] s in
      guard let self = self else { return }
      self.model.focusStatus = s
      if case .open = s {
        // A scroll key changed while the keymap couldn't be read: look now.
        if !self.keyboard.waitingFollows.isEmpty && !self.keyboard.busy { self.keyboard.read() }
      } else {
        self.engine.portClosed()
      }
    }
    engine.start()
    devices.onLearned = { [weak self] button, device in
      self?.store.edit { $0.setScrollButton(device, button) }
    }

    permissions.onChange = { [weak self] in self?.permissionsChanged() }
    permissions.refresh()
    if !permissions.allGranted {
      log("permissions: asking macOS (Input Monitoring \(permissions.inputMonitoring), Accessibility \(permissions.accessibility))")
      permissions.request()
    }
    startInput()

    watchPauseApps()
    hotKey.onPress = { [weak self] in
      guard let self = self else { return }
      log("pause shortcut pressed")
      self.engine.setUserPaused(!self.engine.userPaused)
    }
    applyShortcut()
    applyAppearance()
    model.loginStatus = LoginItem.apply(store.config.startAtLogin)

    Publishers.CombineLatest4(engine.$layerActive, engine.$scroll, engine.$userPaused, model.$focusStatus)
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in self?.updateIcon() }
      .store(in: &subs)
    Publishers.CombineLatest3(permissions.$inputMonitoring, permissions.$accessibility, model.$pausedBy)
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in self?.updateIcon() }
      .store(in: &subs)

    DistributedNotificationCenter.default().addObserver(forName: AppDelegate.showNotification, object: nil, queue: .main) {
      [weak self] _ in self?.showSettings()
    }

    let bothHidden = !store.config.showMenuBarIcon && !store.config.showInDock
    if args.contains("--show-settings") || firstRun || store.fileBroken || !permissions.allGranted
        || (bothHidden && !launchedAtLogin) {
      showSettings()
    }
  }

  func applicationWillTerminate(_ note: Notification) {
    engine.stopAll("quit")
    store.flush()
    focus.waitForPending()  // the layer switch reaches the keyboard before the app exits
    log("quit")
  }

  /// Opening the app again while it runs (Finder, Spotlight, Dock) shows the settings.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    showSettings()
    return false
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  /// An app opened by the Login Items list gets this in its open event.
  static func launchedAsLoginItem() -> Bool {
    guard let e = NSAppleEventManager.shared().currentAppleEvent else { return false }
    return e.eventID == kAEOpenApplication
      && e.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
  }

  // MARK: input

  private func startInput() {
    if permissions.inputMonitoring { devices.start() }
    if permissions.accessibility { tap.start() }
  }

  private func permissionsChanged() {
    startInput()
    if permissions.grantedSinceLaunch && !permissions.inputMonitoring && !devices.opened {
      // Granted in System Settings while running: only a new process can use it. Once only:
      // if the new process still can't, the window's Restart button is left to the user.
      if CommandLine.arguments.contains("--after-grant") {
        log("permissions: still no Input Monitoring after restarting; not restarting again")
      } else {
        relaunch(showSettings: window?.isVisible ?? false, afterGrant: true)
      }
    }
  }

  // MARK: config

  private func configChanged(_ old: AppConfig, _ new: AppConfig) {
    engine.configChanged(old: old, new: new)
    if old.showMenuBarIcon != new.showMenuBarIcon || old.showInDock != new.showInDock { applyAppearance() }
    if old.startAtLogin != new.startAtLogin { model.loginStatus = LoginItem.apply(new.startAtLogin) }
    if old.pauseWhileRunning != new.pauseWhileRunning { checkPauseApps() }
    if old.pauseShortcut != new.pauseShortcut { applyShortcut() }
    // Keys on the Defy that send a scroll key follow it to its new key (written on request).
    for r in ScrollKeyRole.allCases where old[keyPath: r.keyPath] != new[keyPath: r.keyPath] {
      keyboard.follow(r, from: old[keyPath: r.keyPath], to: new[keyPath: r.keyPath])
    }
  }

  /// Registers the pause shortcut from the settings (or none).
  func applyShortcut() {
    model.shortcutProblem = hotKey.set(store.config.pauseShortcut)
  }

  // MARK: apps that need the keyboard

  private func watchPauseApps() {
    let nc = NSWorkspace.shared.notificationCenter
    for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
      nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.checkPauseApps() }
    }
    checkPauseApps()
  }

  private func checkPauseApps() {
    let ids = Set(store.config.pauseWhileRunning)
    let app = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier.map(ids.contains) ?? false }
    let name = app.map { $0.localizedName ?? $0.bundleIdentifier ?? "an app" }
    if name != model.pausedBy {
      model.pausedBy = name
      if let n = name { log("\(n) is open; letting go of the keyboard") } else { log("resuming") }
    }
    engine.setExternalPause(name != nil, app: name ?? "")
  }

  // MARK: appearance

  private func applyAppearance() {
    let c = store.config
    NSApp.setActivationPolicy(c.showInDock ? .regular : .accessory)
    if NSApp.mainMenu == nil || NSApp.mainMenu?.items.isEmpty == true {
      NSApp.mainMenu = AppDelegate.makeMainMenu(target: self)  // for Cmd+C/V/W in the window
    }
    if c.showMenuBarIcon {
      if statusItem == nil {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
      }
      updateIcon()
    } else if let item = statusItem {
      NSStatusBar.system.removeStatusItem(item)
      statusItem = nil
    }
    if window?.isVisible == true {
      // Switching to .accessory hides the app's windows; bring the settings back.
      DispatchQueue.main.async { self.showSettings() }
    }
  }

  /// The version; a dev build's names its commit (0.1.0-dev+e8a0d29), see install.sh.
  static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
  static var isDevBuild: Bool { version.contains("-dev+") }

  private enum IconState { case needsPermission, pausedBy, paused, noKeyboard, idle, autoMouseLayer, dragScroll, toggleScroll }

  private var iconState: IconState {
    if !permissions.allGranted { return .needsPermission }
    if model.pausedBy != nil { return .pausedBy }
    if engine.userPaused { return .paused }
    if case .open = model.focusStatus {} else { return .noKeyboard }
    switch engine.scroll {
    case .drag: return .dragScroll
    case .toggle: return .toggleScroll
    case .off: return engine.layerActive ? .autoMouseLayer : .idle
    }
  }

  private var statusText: String {
    switch iconState {
    case .needsPermission: return "Needs permissions (open Settings)"
    case .pausedBy:
      let app = model.pausedBy ?? "Bazecor"
      return "Turned off while \(app) is open. Quit \(app) to give control back."
    case .paused: return "Paused"
    case .noKeyboard: return "No Dygma keyboard connected by USB"
    case .idle: return "Ready"
    case .autoMouseLayer: return "Auto-Mouse Layer on"
    case .dragScroll: return "Drag Scroll"
    case .toggleScroll: return "Toggle Scroll (press a scroll button or key to stop)"
    }
  }

  private func updateIcon() {
    guard let button = statusItem?.button else { return }
    let text = statusText
    button.image = {
      switch iconState {
      case .needsPermission: return StatusIcon.image(active: false, dimmed: true, badge: .warning, description: text)
      case .pausedBy: return StatusIcon.image(active: false, dimmed: true, badge: .pausedBy, description: text)
      case .paused: return StatusIcon.image(active: false, dimmed: true, badge: .paused, description: text)
      case .noKeyboard: return StatusIcon.image(active: false, dimmed: true, badge: .noKeyboard, description: text)
      case .idle: return StatusIcon.image(active: false, description: text)
      case .autoMouseLayer, .dragScroll, .toggleScroll: return StatusIcon.image(active: true, description: text)
      }
    }()
    button.toolTip = "Dygma Auto-Mouse Helper: \(text)"
  }

  // MARK: menu

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    let header = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
    header.isEnabled = false
    menu.addItem(header)
    menu.addItem(.separator())
    let pause = NSMenuItem(title: "Pause", action: #selector(togglePause), keyEquivalent: "")
    pause.target = self
    pause.state = engine.userPaused ? .on : .off
    menu.addItem(pause)
    menu.addItem(.separator())
    for (title, sel, key) in [("Settings…", #selector(showSettingsAction), ","),
                              ("Open config.json5", #selector(openConfig), ""),
                              ("Show Log", #selector(openLog), "")] {
      let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
      i.target = self
      menu.addItem(i)
    }
    menu.addItem(.separator())
    let version = NSMenuItem(title: "Version \(AppDelegate.version)\(AppDelegate.isDevBuild ? " (dev build)" : "")",
                             action: nil, keyEquivalent: "")
    version.isEnabled = false
    menu.addItem(version)
    let quit = NSMenuItem(title: "Quit Dygma Auto-Mouse Helper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    menu.addItem(quit)
  }

  @objc func togglePause() { engine.setUserPaused(!engine.userPaused) }
  @objc func showSettingsAction() { showSettings() }

  @objc func openConfig() {
    store.flush()
    let url = URL(fileURLWithPath: store.path)
    // Few Macs have an app for .json5, so without one it opens in TextEdit.
    if NSWorkspace.shared.urlForApplication(toOpen: url) != nil, NSWorkspace.shared.open(url) { return }
    NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                            configuration: NSWorkspace.OpenConfiguration()) { _, error in
      if error != nil { DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
    }
  }

  @objc func openLog() {
    NSWorkspace.shared.open([URL(fileURLWithPath: Log.path)], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"),
                            configuration: NSWorkspace.OpenConfiguration())
  }

  static func makeMainMenu(target: AppDelegate) -> NSMenu {
    let main = NSMenu()
    let appItem = NSMenuItem()
    main.addItem(appItem)
    let app = NSMenu()
    let settings = NSMenuItem(title: "Settings…", action: #selector(showSettingsAction), keyEquivalent: ",")
    settings.target = target
    app.addItem(settings)
    app.addItem(.separator())
    app.addItem(NSMenuItem(title: "Hide Dygma Auto-Mouse Helper", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
    app.addItem(.separator())
    app.addItem(NSMenuItem(title: "Quit Dygma Auto-Mouse Helper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    appItem.submenu = app
    let editItem = NSMenuItem()
    main.addItem(editItem)
    let edit = NSMenu(title: "Edit")
    edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
    edit.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
    edit.addItem(.separator())
    edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
    edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
    edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
    edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
    editItem.submenu = edit
    let windowItem = NSMenuItem()
    main.addItem(windowItem)
    let win = NSMenu(title: "Window")
    win.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
    win.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
    windowItem.submenu = win
    return main
  }

  // MARK: window

  func showSettings() {
    if window == nil {
      let root = SettingsView(app: self)
        .environmentObject(store).environmentObject(engine).environmentObject(devices)
        .environmentObject(keyboard).environmentObject(permissions).environmentObject(model)
      let w = NSWindow(contentViewController: NSHostingController(rootView: root))
      w.title = "Dygma Auto-Mouse Helper"
      w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
      w.setContentSize(NSSize(width: 820, height: 760))
      w.contentMinSize = NSSize(width: 720, height: 640)
      w.isReleasedWhenClosed = false
      w.delegate = self
      w.center()
      w.setFrameAutosaveName("Settings")
      window = w
    }
    NSApp.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
  }

  func windowWillClose(_ notification: Notification) {
    devices.stopLearning()
    tap.recordKey = nil
    store.flush()
  }
}
