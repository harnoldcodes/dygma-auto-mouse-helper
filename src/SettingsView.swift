import SwiftUI

extension ConfigStore {
  func binding<T>(_ kp: WritableKeyPath<AppConfig, T>) -> Binding<T> {
    Binding(get: { self.config[keyPath: kp] }, set: { v in self.edit { $0[keyPath: kp] = v } })
  }
  func intBinding(_ kp: WritableKeyPath<AppConfig, Int>) -> Binding<Double> {
    Binding(get: { Double(self.config[keyPath: kp]) }, set: { v in self.edit { $0[keyPath: kp] = Int(v.rounded()) } })
  }
}

/// The settings window's tabs, in the order setting up goes (the README's quick start):
/// General first, then the trackball and its button, the scroll key, the layer that uses
/// both, and the tuning. ⌘1 to ⌘5 follow this order.
enum SettingsTab: Int, CaseIterable {
  case general, scrollButton, scrollKey, autoMouseLayer, sensitivity

  var title: String {
    switch self {
    case .general: return "General"
    case .scrollButton: return "Scroll Button"
    case .scrollKey: return "Scroll Key"
    case .autoMouseLayer: return "Auto-Mouse Layer"
    case .sensitivity: return "Sensitivity"
    }
  }
}

struct SettingsView: View {
  let app: AppDelegate
  @EnvironmentObject var store: ConfigStore
  @EnvironmentObject var permissions: Permissions
  @EnvironmentObject var model: AppModel
  @EnvironmentObject var keyboard: KeyboardModel
  @EnvironmentObject var devices: Devices
  @State private var tab: SettingsTab

  init(app: AppDelegate, tab: SettingsTab = .general) {
    self.app = app
    _tab = State(initialValue: tab)
  }

  var body: some View {
    VStack(spacing: 0) {
      if let other = model.pausedBy { PausedByBanner(app: other).padding([.horizontal, .top]) }
      if !permissions.allGranted { PermissionBanner().padding([.horizontal, .top]) }
      if devices.openFailure != nil || !devices.held(store.config).isEmpty {
        TrackballProblemBanner().padding([.horizontal, .top])
      }
      if case .notFound = model.focusStatus, model.pausedBy == nil { NoKeyboardBanner().padding([.horizontal, .top]) }
      if !store.warnings.isEmpty { WarningBanner().padding([.horizontal, .top]) }
      if !keyboard.followNotices(store.config).isEmpty || !keyboard.waitingNotices(store.config).isEmpty {
        ScrollKeyWriteBanner().padding([.horizontal, .top])
      }
      TabBar(titles: SettingsTab.allCases.map(\.title),
             selection: Binding(get: { tab.rawValue }, set: { tab = SettingsTab(rawValue: $0) ?? .general }))
        .fixedSize()
        .padding(.top, 14)
        .padding(.bottom, 2)
      Group {
        switch tab {
        case .general: GeneralTab(app: app)
        case .scrollButton: ScrollButtonTab()
        case .scrollKey: ScrollKeyTab(app: app)
        case .autoMouseLayer: LayerTab()
        case .sensitivity: SensitivityTab()
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(tabShortcuts)
    .frame(minWidth: 720, minHeight: 640)
  }

  /// Command-1 to Command-5 pick a tab.
  private var tabShortcuts: some View {
    ZStack {
      ForEach(SettingsTab.allCases, id: \.self) { t in
        Button(t.title) { tab = t }
          .keyboardShortcut(KeyEquivalent(Character(String(t.rawValue + 1))), modifiers: .command)
      }
    }
    .opacity(0)
    .accessibilityHidden(true)
  }
}

/// The tab bar: a segmented control that never takes keyboard focus, so it never draws a
/// focus ring around the selected tab.
struct TabBar: NSViewRepresentable {
  let titles: [String]
  @Binding var selection: Int

  func makeNSView(context: Context) -> NSSegmentedControl {
    let c = NSSegmentedControl(labels: titles, trackingMode: .selectOne, target: context.coordinator,
                               action: #selector(Coordinator.changed(_:)))
    c.refusesFirstResponder = true
    c.focusRingType = .none
    c.segmentStyle = .automatic
    c.setContentHuggingPriority(.required, for: .horizontal)
    return c
  }

  func updateNSView(_ c: NSSegmentedControl, context: Context) {
    context.coordinator.selection = $selection
    if c.selectedSegment != selection { c.selectedSegment = selection }
  }

  func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

  final class Coordinator: NSObject {
    var selection: Binding<Int>
    init(selection: Binding<Int>) { self.selection = selection }
    @objc func changed(_ sender: NSSegmentedControl) { selection.wrappedValue = sender.selectedSegment }
  }
}

// MARK: - Shared pieces

/// A number with a slider and an exact field. Values typed outside the range are clamped.
struct NumberRow: View {
  let title: String
  let help: String
  @Binding var value: Double
  let range: ClosedRange<Double>
  var step: Double = 1
  var unit = ""
  var decimals = 0

  var body: some View {
    let clamped = Binding(get: { value }, set: { value = min(max($0, range.lowerBound), range.upperBound) })
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(title)
        Spacer()
        TextField(title, value: clamped, format: .number.precision(.fractionLength(decimals)))
          .labelsHidden()
          .multilineTextAlignment(.trailing)
          .frame(width: 70)
        Text(unit).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
      }
      // Rounded here rather than with Slider's step, which draws a tick mark per step.
      Slider(value: Binding(get: { value }, set: { clamped.wrappedValue = ($0 / step).rounded() * step }), in: range)
        .labelsHidden()
      Text(help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    .padding(.vertical, 2)
  }
}

struct Help: View {
  let text: String
  init(_ text: String) { self.text = text }
  var body: some View {
    Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
  }
}

struct PermissionBanner: View {
  @EnvironmentObject var permissions: Permissions

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("The helper needs two permissions before it can work", systemImage: "exclamationmark.triangle.fill")
        .font(.headline).foregroundStyle(.orange)
      row("Input Monitoring", "to read the trackball's movement and buttons", permissions.inputMonitoring,
          Permissions.openInputMonitoring)
      row("Accessibility", "to catch the scroll key and scroll for you", permissions.accessibility,
          Permissions.openAccessibility)
      HStack {
        Help("Turn on Dygma Auto-Mouse Helper in both lists. If it isn't listed, add it with the + button "
          + "(it's in your Applications folder). The helper restarts itself once Input Monitoring is on.")
        Spacer()
        Button("Restart Helper") { relaunch(showSettings: true, afterGrant: true) }
      }
    }
    .padding(12)
    .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
  }

  private func row(_ name: String, _ why: String, _ ok: Bool, _ open: @escaping () -> Void) -> some View {
    HStack {
      Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(ok ? .green : .red)
      Text(name).bold()
      Text(why).foregroundStyle(.secondary)
      Spacer()
      if !ok { Button("Open Settings", action: open) }
    }
  }
}

/// Bazecor (or another app from keyboard.pauseWhileRunning) is open, so the helper has let go.
struct PausedByBanner: View {
  let app: String

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "pause.circle.fill").font(.title2)
      VStack(alignment: .leading, spacing: 3) {
        Text("\(app) is open, so Dygma Auto-Mouse Helper is turned off for now").font(.headline)
        Text("\(app) and the helper can't both use the keyboard's connection, so the helper stepped aside when \(app) "
             + "started: the ball only moves the pointer, and the Auto-Mouse Layer, Drag Scroll and Toggle Scroll are off. "
             + "Quit \(app) to give control back to Dygma Auto-Mouse Helper.")
          .font(.callout)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .foregroundStyle(.white)
    .padding(12)
    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .systemRed)))
  }
}

/// A scroll key changed, and keys on the Defy still send the old one: write the change to
/// the keyboard, or discard it (which puts the scroll key back).
struct ScrollKeyWriteBanner: View {
  @EnvironmentObject var store: ConfigStore
  @EnvironmentObject var keyboard: KeyboardModel
  @EnvironmentObject var model: AppModel

  var body: some View {
    let notices = keyboard.followNotices(store.config)
    let waiting = keyboard.waitingNotices(store.config)
    let connected: Bool = { if case .open = model.focusStatus { return true } else { return false } }()
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(.orange)
      VStack(alignment: .leading, spacing: 4) {
        if !notices.isEmpty {
          Text(notices.count == 1 ? title(notices[0]) : "The scroll keys changed, but your Defy still sends the old ones")
            .font(.headline)
          if notices.count > 1 {
            ForEach(notices, id: \.role) { n in Text("• \(n.role.title): \(keyName(n.was)) → \(keyName(n.now)), \(where_(n))") }
          } else {
            Text("Your Defy sends \(keyName(notices[0].was)) from \(where_(notices[0])), so "
                 + (notices[0].layers.count == 1 ? "that key" : "those keys") + " won't scroll until you write the change.")
          }
          Text(footer(notices)).foregroundStyle(.secondary)
        } else if let w = waiting.first {
          // (SwiftUI can draw the banner once more after a discard empties both lists.)
          Text("Check your Defy for \(keyName(w.was))").font(.headline)
          Text(keyboard.busy ? "Reading the keyboard to find the keys that send \(keyName(w.was))…"
               : "\(w.role.title) is now \(keyName(w.now)), but the helper couldn't read the keyboard to move keys that "
                 + "send \(keyName(w.was)) to it (\(reason)). It reads it as soon as it can.")
        }
        if keyboard.failed && !keyboard.message.isEmpty { Text(keyboard.message).foregroundStyle(.red) }
      }
      .font(.callout)
      .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
      VStack(alignment: .trailing, spacing: 6) {
        if notices.isEmpty {
          Button { keyboard.read() } label: { Text("Read Keyboard").frame(maxWidth: .infinity) }
            .disabled(keyboard.busy || !connected)
        } else {
          Button { keyboard.write() } label: { Text("Write to Keyboard").frame(maxWidth: .infinity) }
            .disabled(keyboard.busy || !connected)
        }
        Button {
          keyboard.discard(store.config) { role, key in store.edit { $0[keyPath: role.keyPath] = key } }
        } label: { Text("Discard").frame(maxWidth: .infinity) }
        .disabled(keyboard.busy)
        .help("Put the scroll key back to the key your Defy sends, and drop the changes not yet written")
      }
      .fixedSize()
    }
    .padding(12)
    .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.45)))
  }

  private func title(_ n: KeyboardModel.FollowNotice) -> String {
    let role = n.role.title.prefix(1).lowercased() + n.role.title.dropFirst()
    return "The \(role) is now \(keyName(n.now)), but your Defy still sends \(keyName(n.was))"
  }

  /// "the Auto-Mouse Layer", "2 keys on the Auto-Mouse Layer and Layer 1".
  private func where_(_ n: KeyboardModel.FollowNotice) -> String {
    var names: [String] = []
    for l in n.layers where !names.contains(name(l)) { names.append(name(l)) }
    let list = ListFormatter.localizedString(byJoining: names)
    return n.layers.count == 1 ? "a key on \(list)" : "\(n.layers.count) keys on \(list)"
  }

  private func name(_ layer: Int) -> String {
    layer == store.config.autoMouseLayer ? "the Auto-Mouse Layer" : keyboard.layerName(layer)
  }

  private func footer(_ notices: [KeyboardModel.FollowNotice]) -> String {
    let followed = notices.reduce(0) { $0 + $1.layers.count }
    let others = keyboard.pendingCount - followed
    var s = "Write to Keyboard saves it on the Defy. Discard puts "
      + (notices.count == 1 ? "the key back to \(keyName(notices[0].was))" : "the keys back") + "."
    if others > 0 {
      s += " Both include the \(others) other key\(others == 1 ? "" : "s") changed on the Auto-Mouse Layer tab."
    }
    return s
  }

  private var reason: String {
    switch model.focusStatus {
    case .paused: return model.pausedBy.map { "\($0) is open" } ?? "the helper is paused"
    case .notFound: return "it isn't connected by USB"
    case .open: return "it didn't answer"
    }
  }
}

/// No Dygma keyboard on USB: the helper can't switch layers until there is one.
struct NoKeyboardBanner: View {
  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "cable.connector").font(.title2).foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 3) {
        Text("No Dygma keyboard connected").font(.headline)
        Text("Connect your Defy by USB (a wireless Defy through its Neuron). Until then the helper can't switch "
             + "the keyboard to the Auto-Mouse Layer; Drag Scroll and Toggle Scroll with a trackball button still work. A Defy on "
             + "Bluetooth only can't be told to switch layers.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .padding(12)
    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.3)))
  }
}

/// A ticked trackball that another app has to itself (a key remapper such as kanata), or mice
/// and trackballs macOS won't open: either way the helper can't see the ball move.
struct TrackballProblemBanner: View {
  @EnvironmentObject var store: ConfigStore
  @EnvironmentObject var devices: Devices

  var body: some View {
    let held = devices.held(store.config)
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(.orange)
      VStack(alignment: .leading, spacing: 3) {
        if let failure = devices.openFailure {
          Text("Can't read the mice and trackballs").font(.headline)
          Text("\(failure), so the helper can't see the ball move. Quit and reopen the helper; if it keeps "
               + "happening, Show Log (General tab) says more.")
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        ForEach(held, id: \.key) { d in
          Text("\(d.holder ?? "Another app") has \(d.name) to itself").font(.headline)
        }
        if !held.isEmpty {
          Text("While it does, the helper can't see the ball move or its scroll button, so nothing switches "
               + "the Auto-Mouse Layer. Key remappers such as kanata (used by Mantle) and Karabiner-Elements "
               + "take over every device they're set to remap: set yours to leave the trackball alone, or quit "
               + "it. The helper picks the trackball up as soon as it's let go.")
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(12)
    .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.4)))
  }
}

struct WarningBanner: View {
  @EnvironmentObject var store: ConfigStore

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Label(store.fileBroken ? "config.json5 can't be read" : "Some settings in config.json5 were ignored",
            systemImage: "doc.badge.ellipsis").font(.headline)
      ForEach(store.warnings, id: \.self) { Text("• " + $0).font(.callout) }
      Help(store.displayPath)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(RoundedRectangle(cornerRadius: 8).fill(Color.yellow.opacity(0.15)))
  }
}

// MARK: - General

struct GeneralTab: View {
  let app: AppDelegate
  @EnvironmentObject var store: ConfigStore
  @EnvironmentObject var engine: Engine
  @EnvironmentObject var model: AppModel
  @EnvironmentObject var devices: Devices

  var body: some View {
    Form {
      Section("Status") {
        LabeledContent("Keyboard") { Text(keyboardText).foregroundStyle(keyboardOK ? .primary : .secondary) }
        LabeledContent("Trackballs") {
          Text(trackballText).foregroundStyle(devices.held(store.config).isEmpty && devices.openFailure == nil ? Color.secondary : .orange)
        }
        LabeledContent("Auto-Mouse Layer") {
          Text(engine.scroll == .toggle ? "on, Toggle Scroll" : engine.scroll == .drag ? "on, Drag Scroll"
               : engine.layerActive ? "on" : "off")
        }
        Toggle("Pause the helper", isOn: Binding(get: { engine.userPaused }, set: { engine.setUserPaused($0) }))
        Help("While paused, the ball only moves the pointer and the helper lets go of the keyboard's connection.")
        PauseShortcutRow(app: app)
      }
      Section("Appearance") {
        Toggle("Show the icon in the menu bar", isOn: store.binding(\.showMenuBarIcon))
        Help("The ring in the middle of the icon fills with green while the Auto-Mouse Layer is on.")
        Toggle("Show in the Dock and the app switcher", isOn: store.binding(\.showInDock))
        if !store.config.showMenuBarIcon && !store.config.showInDock {
          Help("With both off, open Dygma Auto-Mouse Helper again (from Finder or Spotlight) to get back to this window.")
        }
      }
      Section("Startup") {
        Toggle("Start at login", isOn: store.binding(\.startAtLogin))
        if !model.loginStatus.isEmpty { Help(model.loginStatus) }
      }
      Section("Settings file and log") {
        Toggle("Detailed log", isOn: store.binding(\.verbose))
        Help("Logs every layer change, scroll change and trackball button press.")
        HStack {
          Button("Open config.json5") { app.openConfig() }
          Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: store.path)])
          }
          Button("Show Log") { app.openLog() }
        }
        Help("All settings live in \(store.displayPath). Changes made here are saved there, and edits made there show up here.")
      }
      Section {
        HStack {
          if AppDelegate.isDevBuild {
            Text("Version \(AppDelegate.version)").foregroundStyle(.secondary)
              .help("A dev build, from this commit of the source. ./install.sh --release puts the release back.")
            Text("dev build").font(.caption.weight(.semibold)).foregroundStyle(.white)
              .padding(.horizontal, 6).padding(.vertical, 1)
              .background(Capsule().fill(Color.orange))
          } else {
            Text("Version \(AppDelegate.version)").foregroundStyle(.secondary)
          }
          Spacer()
          Button("Quit Dygma Auto-Mouse Helper") { NSApp.terminate(nil) }
        }
      }
    }
    .formStyle(.grouped)
  }

  private var keyboardOK: Bool { if case .open = model.focusStatus { return true } else { return false } }

  private var keyboardText: String {
    if let app = model.pausedBy { return "let go while \(app) is open (quit it to give control back)" }
    switch model.focusStatus {
    case .open(let path): return "connected (\(path))"
    case .paused: return "let go (paused)"
    case .notFound: return "not connected by USB"
    }
  }

  private var trackballText: String {
    let chosen = store.config.devices
    if chosen.isEmpty { return "none chosen (see Scroll Button)" }
    let on = chosen.filter { d in devices.connected.contains { $0.vendorId == d.vendorId && $0.productId == d.productId } }
    if devices.openFailure != nil { return "\(chosen.count) chosen; macOS won't open them" }
    if !devices.opened { return "\(chosen.count) chosen; waiting for Input Monitoring" }
    let held = devices.held(store.config)
    if !held.isEmpty { return "\(on.count) of \(chosen.count) chosen connected; \(held.count) held by another app" }
    return "\(on.count) of \(chosen.count) chosen connected"
  }
}

/// The keyboard shortcut that pauses and resumes the helper: Learn (press it) or None.
struct PauseShortcutRow: View {
  let app: AppDelegate
  @EnvironmentObject var store: ConfigStore
  @EnvironmentObject var model: AppModel
  @State private var learning = false
  @State private var message = ""
  @State private var monitor: Any?

  var body: some View {
    let current = store.config.pauseShortcut
    VStack(alignment: .leading, spacing: 4) {
      LabeledContent("Pause shortcut") {
        HStack(spacing: 8) {
          if learning {
            Text("Press the shortcut… (Esc cancels)").foregroundStyle(Color.accentColor)
            Button("Cancel") { stop() }
          } else {
            Text(current?.display ?? "None")
              .fontWeight(current == nil ? .regular : .medium)
              .foregroundStyle(current == nil ? .secondary : .primary)
            Button("Learn…") { start() }
            Button("None") { message = ""; store.edit { $0.pauseShortcut = nil } }.disabled(current == nil)
          }
        }
      }
      if !message.isEmpty {
        Label(message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
      } else if current != nil, let problem = model.shortcutProblem {
        Label("It doesn't work: \(problem). Learn another.", systemImage: "exclamationmark.triangle")
          .font(.caption).foregroundStyle(.orange)
      } else {
        Help("Press it anywhere to pause or resume the helper. Use Control, Option, Shift or Command with a key; "
          + "F-keys also work alone.")
      }
    }
    .onDisappear { stop() }
  }

  private func start() {
    message = ""
    learning = true
    app.hotKey.set(nil)  // so pressing the current shortcut is learned, not acted on
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
      learned(e)
      return nil
    }
  }

  private func learned(_ e: NSEvent) {
    let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
    var mods = Shortcut.Modifiers()
    if flags.contains(.control) { mods.insert(.control) }
    if flags.contains(.option) { mods.insert(.option) }
    if flags.contains(.shift) { mods.insert(.shift) }
    if flags.contains(.command) { mods.insert(.command) }
    let code = Int(e.keyCode)
    if code == 53 && mods.isEmpty { stop(); return }  // Escape
    let s = Shortcut(key: code, modifiers: mods)
    if let why = s.problem(scrollKeys: store.config.scrollKeyCodes) {
      message = "\(s.display) can't be used: \(why). Press another."
      return
    }
    message = ""
    stop()
    store.edit { $0.pauseShortcut = s }
  }

  private func stop() {
    if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    if learning {
      learning = false
      app.applyShortcut()
    }
  }
}

// MARK: - Scroll Button

/// The mice and trackballs, each one's scroll button, and Toggle Scroll for the buttons.
struct ScrollButtonTab: View {
  @EnvironmentObject var store: ConfigStore
  @EnvironmentObject var devices: Devices

  private struct Row: Identifiable {
    var id: String { ref.key }
    var ref: DeviceRef
    var detail: String
    var connected: Bool
    var held = false
    var holder: String?
  }

  private var rows: [Row] {
    var r = devices.connected.map {
      Row(ref: DeviceRef(vendorId: $0.vendorId, productId: $0.productId, name: $0.name),
          detail: [$0.manufacturer, $0.key, $0.transport].filter { !$0.isEmpty }.joined(separator: " · "), connected: true,
          held: $0.held, holder: $0.holder)
    }
    for d in store.config.devices where !r.contains(where: { $0.ref.key == d.key }) {
      r.append(Row(ref: d, detail: "\(d.key) · not connected", connected: false))
    }
    return r
  }

  var body: some View {
    Form {
      Section {
        if !devices.opened {
          Help("The list appears once the helper has Input Monitoring permission.")
        } else if rows.isEmpty {
          Help("No mice or trackballs found.")
        }
        ForEach(rows) { row in
          VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: chosen(row.ref)) {
              HStack(spacing: 8) {
                Circle()
                  .fill(devices.recentlyMoved.contains(row.ref.key) ? Color.green : Color.secondary.opacity(0.25))
                  .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                  Text(row.ref.name.isEmpty ? "Unnamed device" : row.ref.name)
                    .foregroundStyle(row.connected ? .primary : .secondary)
                  Text(row.detail).font(.caption).foregroundStyle(.secondary)
                  if row.held {
                    Label("\(row.holder ?? "Another app") has it to itself, so the helper can't read it",
                          systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                  }
                }
              }
            }
            .toggleStyle(.checkbox)
            if let ref = store.config.device(row.ref.vendorId, row.ref.productId) {
              ScrollButtonRow(device: ref, connected: row.connected && !row.held).padding(.leading, 38)
            }
          }
        }
      } header: {
        Text("Mice and trackballs")
      } footer: {
        Help("Tick the ones whose movement turns on the Auto-Mouse Layer, and that can scroll. The dot lights "
          + "up while a device moves, to tell them apart. Each ticked one can have its own scroll button: hold it "
          + "for Drag Scroll, tap it for Toggle Scroll. Click Learn, then press the button. Buttons that macOS doesn't use (like "
          + "the Slimblade's top-right one) work best; an ordinary button (middle, back, forward) stops clicking, "
          + "on every mouse.")
      }

      ToggleScrollSection(source: .button)
    }
    .formStyle(.grouped)
  }

  private func chosen(_ ref: DeviceRef) -> Binding<Bool> {
    Binding(get: { store.config.usesDevice(ref.vendorId, ref.productId) }, set: { on in
      store.edit { c in
        c.devices.removeAll { $0.vendorId == ref.vendorId && $0.productId == ref.productId }
        if on { c.devices.append(ref) }
      }
    })
  }
}

/// A ticked device's scroll button: what it is, Learn and None.
struct ScrollButtonRow: View {
  let device: DeviceRef
  let connected: Bool
  @EnvironmentObject var store: ConfigStore
  @EnvironmentObject var devices: Devices

  var body: some View {
    let learning = devices.learning == device.key
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 8) {
        Text("Scroll button").foregroundStyle(.secondary)
        if learning {
          ProgressView().controlSize(.small)
          Text(devices.learnMessage).foregroundStyle(Color.accentColor)
          Spacer()
          Button("Cancel") { devices.stopLearning() }
        } else {
          Text(device.scrollButton?.description ?? "None")
            .foregroundStyle(device.scrollButton == nil ? .secondary : .primary)
          Spacer()
          Button("Learn…") { devices.startLearning(device.key) }
            .disabled(!devices.opened || !connected || devices.learning != nil)
          Button("None") { store.edit { $0.setScrollButton(device.key, nil) } }
            .disabled(device.scrollButton == nil)
        }
      }
      if !learning, devices.learnMessageFor == device.key, !devices.learnMessage.isEmpty {
        Help(devices.learnMessage)
      }
    }
    .font(.callout)
  }
}

/// Toggle Scroll for the scroll buttons or the scroll keys: on or off, the timing (which the
/// two can share), and a live read-out to try it with.
struct ToggleScrollSection: View {
  let source: TapSource
  @EnvironmentObject var store: ConfigStore
  @EnvironmentObject var engine: Engine

  private var settings: TapSettings { store.config[keyPath: source.keyPath] }
  private var what: String { source == .button ? "scroll button" : "scroll key" }

  var body: some View {
    Section {
      Toggle("Tap a \(what) for Toggle Scroll", isOn: store.binding(source.keyPath.appending(path: \.toggleScroll)))
      Toggle("Use the same timing for the scroll buttons and the scroll keys", isOn: Binding(
        get: { store.config.sameTapTiming },
        set: { on in store.edit { $0.setSameTapTiming(on, from: source) } }))
      Group {
        NumberRow(title: "Longest tap", help: "A press shorter than this counts as a tap.",
                  value: timing(\.maxMs), range: 50...1000, step: 10, unit: "ms")
        NumberRow(title: "Most movement in a tap", help: "A press that moves the ball more than this is a hold.",
                  value: Binding(get: { Double(settings.maxMotion) },
                                 set: { v in store.edit { $0.setTapTiming(source, \.maxMotion, Int(v.rounded())) } }),
                  range: 0...100, unit: "counts")
      }
      .disabled(!settings.toggleScroll)
      LabeledContent("Right now") { LayerIndicator() }
      LabeledContent("Last press") {
        if let p = engine.lastPress, p.source == source {
          Text("\(p.ms) ms, ball moved \(p.motion): \(p.outcome)").multilineTextAlignment(.trailing)
        } else {
          Text("Press a \(what) to try it").foregroundStyle(.secondary)
        }
      }
    } header: {
      Text("Toggle Scroll")
    } footer: {
      Help("A tap keeps Scroll Mode, and the Auto-Mouse Layer, on until the next press of a scroll button or a scroll "
        + "key. A hold is Drag Scroll, which ends when you let go. "
        + (source == .key ? "A tap of a one-direction key scrolls in that direction only. " : "")
        + "Tap and hold here to see how each press is counted. "
        + (store.config.sameTapTiming ? "The timing is shared with the \(source == .button ? "Scroll Key" : "Scroll Button") tab." : ""))
    }
  }

  private func timing(_ kp: WritableKeyPath<TapSettings, Double>) -> Binding<Double> {
    Binding(get: { settings[keyPath: kp] }, set: { v in store.edit { $0.setTapTiming(source, kp, v) } })
  }
}

// MARK: - Live state

/// What the helper is doing right now. Lights up while the Auto-Mouse Layer is on, so the
/// switching settings can be tried out as they are changed.
struct LayerIndicator: View {
  @EnvironmentObject var engine: Engine
  @EnvironmentObject var model: AppModel

  private var state: (text: String, icon: String, color: Color, lit: Bool) {
    if let app = model.pausedBy { return ("Turned off while \(app) is open", "pause.circle.fill", .red, true) }
    if engine.userPaused { return ("Paused", "pause.circle", .secondary, false) }
    guard case .open = model.focusStatus else { return ("Keyboard not connected", "keyboard", .secondary, false) }
    let way = engine.scrollAxes == .y ? " up and down" : engine.scrollAxes == .x ? " sideways" : ""
    switch engine.scroll {
    case .toggle: return ("Auto-Mouse Layer on · Toggle Scroll\(way)", "lock.circle.fill", .orange, true)
    case .drag: return ("Auto-Mouse Layer on · Drag Scroll\(way)", "arrow.up.and.down.circle.fill", .accentColor, true)
    case .off:
      return engine.layerActive ? ("Auto-Mouse Layer on", "computermouse.fill", .accentColor, true)
                                : ("Auto-Mouse Layer off", "computermouse", .secondary, false)
    }
  }

  var body: some View {
    let s = state
    Label(s.text, systemImage: s.icon)
      .font(.callout.weight(.medium))
      .foregroundStyle(s.lit ? Color.white : Color.secondary)
      .padding(.horizontal, 10).padding(.vertical, 4)
      .background(Capsule().fill(s.lit ? s.color : Color.secondary.opacity(0.12)))
      .fixedSize()
      .animation(.easeOut(duration: 0.12), value: s.text)
  }
}

// MARK: - Scroll Key

struct ScrollKeyTab: View {
  let app: AppDelegate
  @EnvironmentObject var store: ConfigStore
  @State private var recording: ScrollKeyRole?
  @State private var separateChosen = false

  private var separate: Bool { store.config.separateScrollKeys || separateChosen }

  var body: some View {
    Form {
      Section {
        Picker("Scroll with", selection: Binding(get: { separate }, set: setSeparate)) {
          Text("One key for both directions").tag(false)
          Text("Separate keys for up and down and for sideways").tag(true)
        }
        .pickerStyle(.radioGroup)
        if separate {
          ScrollKeyRow(app: app, role: .vertical, recording: $recording)
          ScrollKeyRow(app: app, role: .horizontal, recording: $recording)
          Picker("The sideways key scrolls with", selection: store.binding(\.horizontalKeyRolling)) {
            Text("Rolling the ball sideways").tag(SidewaysRolling.sideways)
            Text("Rolling it up and down: up moves the page left").tag(SidewaysRolling.upMovesLeft)
            Text("Rolling it up and down: up moves the page right").tag(SidewaysRolling.upMovesRight)
          }
          .pickerStyle(.radioGroup)
          if store.config.scrollKey != nil { ScrollKeyRow(app: app, role: .both, recording: $recording) }
        } else {
          ScrollKeyRow(app: app, role: .both, recording: $recording)
        }
      } header: {
        Text("Scroll keys")
      } footer: {
        Help("Put the scroll key on a base layer to reach it straight away, or on a key of the Auto-Mouse Layer "
          + "(the Auto-Mouse Layer tab can do that): moving the ball turns that layer on, so the key is right under "
          + "your fingers. Either way, hold it for Drag Scroll, or tap it for Toggle Scroll (below). Choose a key "
          + "from the list or press "
          + "Record and then the key. F13 to F20 type nothing on a Mac, so they make the best scroll keys. "
          + "With separate keys, each one scrolls in its own direction only.")
      }

      ToggleScrollSection(source: .key)
    }
    .formStyle(.grouped)
    .onDisappear { app.tap.recordKey = nil; recording = nil }
  }

  private func setSeparate(_ on: Bool) {
    separateChosen = on
    store.edit { c in
      if on, !c.separateScrollKeys {
        // The one key becomes the up and down key; the sideways key is chosen next.
        c.verticalScrollKey = c.scrollKey
        c.scrollKey = nil
      } else if !on {
        if c.scrollKey == nil { c.scrollKey = c.verticalScrollKey ?? c.horizontalScrollKey }
        c.verticalScrollKey = nil
        c.horizontalScrollKey = nil
      }
    }
  }
}

/// One scroll key: what it is, and Choose (from the list), Record (press it) or None.
struct ScrollKeyRow: View {
  let app: AppDelegate
  let role: ScrollKeyRole
  @Binding var recording: ScrollKeyRole?
  @EnvironmentObject var store: ConfigStore
  @State private var choosing = false

  var body: some View {
    let code = store.config[keyPath: role.keyPath]
    VStack(alignment: .leading, spacing: 4) {
      LabeledContent(role.title) {
        HStack(spacing: 8) {
          if recording == role {
            Text("Press a key… (Esc cancels)").foregroundStyle(Color.accentColor)
          } else if let k = code {
            Text(keyName(k)).fontWeight(.medium)
            Text("key code \(k)").font(.caption).foregroundStyle(.secondary)
          } else {
            Text("None").foregroundStyle(.secondary)
          }
          Button("Choose…") { choosing = true }
            .popover(isPresented: $choosing, arrowEdge: .bottom) {
              KeyPicker(current: code, others: others, pick: { k in
                store.edit { $0.setScrollKey(role, k) }
                choosing = false
              }, cancel: { choosing = false })
            }
          Button(recording == role ? "Cancel" : "Record…") { record() }
            .disabled(!app.tap.running)
          Button("None") { store.edit { $0.setScrollKey(role, nil) } }.disabled(code == nil)
        }
      }
      if let k = code, let info = keyInfo(k), !info.silent {
        Label("\(info.name) can't be typed while the helper runs: it is caught and never reaches apps."
              + (info.group == .media ? " Most keyboards send it as a media key, which the helper can't catch." : ""),
              systemImage: "exclamationmark.triangle")
          .font(.caption).foregroundStyle(.orange)
      }
    }
  }

  private var others: [Int: String] {
    var m: [Int: String] = [:]
    for r in ScrollKeyRole.allCases where r != role {
      if let k = store.config[keyPath: r.keyPath] { m[k] = r.title }
    }
    return m
  }

  private func record() {
    if recording == role { app.tap.recordKey = nil; recording = nil; return }
    recording = role
    app.tap.recordKey = { code in
      recording = nil
      if let c = code { store.edit { $0.setScrollKey(role, c) } }
    }
  }
}

// MARK: - Sensitivity

/// How readily the ball turns the Auto-Mouse Layer on, and how fast it scrolls.
struct SensitivityTab: View {
  @EnvironmentObject var store: ConfigStore

  private var sidewaysKeyRolls: Bool { store.config.horizontalScrollKey != nil && store.config.horizontalKeyRolling != .sideways }

  var body: some View {
    Form {
      Section {
        LabeledContent("Right now") { LayerIndicator() }
        NumberRow(title: "Movement to turn on",
                  help: "Ball movement (sideways plus up and down, in counts) that turns on the Auto-Mouse Layer.",
                  value: store.intBinding(\.activationThreshold), range: 1...200, unit: "counts")
        NumberRow(title: "Within", help: "The movement has to come within this time. Smaller bumps are ignored.",
                  value: store.binding(\.activationWindowMs), range: 20...1000, step: 10, unit: "ms")
        NumberRow(title: "Idle timeout", help: "Turn the layer off after this long without ball movement or clicks.",
                  value: store.binding(\.idleTimeoutMs), range: 100...3000, step: 50, unit: "ms")
      } header: {
        Text("Auto-Mouse Layer")
      } footer: {
        Help("Moving the ball this much within this time turns on the Auto-Mouse Layer, and the idle timeout turns it "
          + "off again (at once when Scroll Mode ends). Changes apply straight away: roll the ball and "
          + "watch the light.")
      }

      Section("Scrolling up and down") {
        NumberRow(title: "Speed", help: "Pixels scrolled per count of ball movement.",
                  value: store.binding(\.gainY), range: 0.25...15, step: 0.25, unit: "px", decimals: 2)
        Toggle("Reverse", isOn: store.binding(\.invertY))
      }

      Section {
        NumberRow(title: "Speed", help: "Pixels scrolled per count of ball movement.",
                  value: store.binding(\.gainX), range: 0.25...15, step: 0.25, unit: "px", decimals: 2)
        Toggle("Reverse", isOn: store.binding(\.invertX))
      } header: {
        Text("Scrolling sideways")
      } footer: {
        Help("Reverse off: the content follows the ball, as on a trackpad."
          + (sidewaysKeyRolls
             ? " The sideways key scrolls with the ball's up and down movement, in the direction set on the Scroll Key "
               + "tab; Reverse doesn't change it." : ""))
      }
    }
    .formStyle(.grouped)
  }
}

// MARK: - Auto-Mouse Layer

struct LayerTab: View {
  @EnvironmentObject var store: ConfigStore
  @EnvironmentObject var keyboard: KeyboardModel
  @EnvironmentObject var model: AppModel
  @EnvironmentObject var engine: Engine
  @State private var viewLayer: Int?
  @State private var selectedKey: Int?

  private var shown: Int { viewLayer ?? store.config.autoMouseLayer }
  private var editable: Bool { shown == store.config.autoMouseLayer }
  /// The drawing lights up while the Auto-Mouse Layer is on (orange during Toggle Scroll).
  private var glow: Color? {
    guard editable, engine.layerActive else { return nil }
    return engine.scroll == .toggle ? .orange : .accentColor
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      intro
      toolbar
      if keyboard.loaded {
        drawing
        editor
      } else {
        notRead
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
    .onAppear {
      if !keyboard.loaded && !keyboard.busy, case .open = model.focusStatus { keyboard.read() }
    }
  }

  private var intro: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("**The Auto-Mouse Layer is the layer your Defy switches to while you use the trackball:** when you move the ball, or while you hold a scroll key. Put your mouse clicks on it, so they're under your fingers whenever the ball is in use: left, right and middle click, back (mouse 4) and forward (mouse 5). Give the layer its own LED colours in Bazecor, and the keyboard's lights show at a glance when it's on.")
      Text("What you see here is your Defy's keymap as it is now, read straight from its Neuron. The helper reads and writes it with Focus, the same connection Bazecor uses, so what you write here is saved on the keyboard itself and shows in Bazecor too. Keep Bazecor closed while you use this tab: only one app can use the connection at a time.")
        .foregroundStyle(.secondary)
    }
    .font(.callout)
    .fixedSize(horizontal: false, vertical: true)
  }

  private var toolbar: some View {
    HStack(spacing: 10) {
      if keyboard.loaded {
        Picker("Layer", selection: Binding(get: { shown }, set: { viewLayer = $0; selectedKey = nil })) {
          ForEach(0..<keyboard.layers, id: \.self) { n in
            Text(layerTitle(n)).tag(n)
          }
        }
        .frame(maxWidth: 320)
        if editable {
          Label("The Auto-Mouse Layer", systemImage: "computermouse.fill").foregroundStyle(Color.accentColor)
        } else {
          Button("Use as the Auto-Mouse Layer") {
            store.edit { $0.autoMouseLayer = shown }
            viewLayer = nil
          }
        }
      }
      Spacer()
      if keyboard.loaded && !keyboard.message.isEmpty {
        Text(keyboard.message).font(.caption).foregroundStyle(keyboard.failed ? .red : .secondary)
          .lineLimit(2).truncationMode(.middle)
      }
      Button(keyboard.loaded ? "Read Again" : "Read Keyboard") { keyboard.read() }
        .disabled(keyboard.busy || keyboard.pendingCount > 0)
    }
  }

  private var drawing: some View {
    let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
    return KeyboardView(codes: keyboard.codes(layer: shown), superkeys: keyboard.superkeys, layers: keyboard.layers,
                        pending: Set((keyboard.pending[shown] ?? [:]).keys), selected: $selectedKey, editable: editable,
                        scrollKeys: store.config.scrollKeyHids)
      .padding(12)
      .background(shape.fill((glow ?? .clear).opacity(0.12)))
      .overlay(shape.strokeBorder(glow ?? Color.secondary.opacity(0.2), lineWidth: glow == nil ? 1 : 2.5))
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .animation(.easeOut(duration: 0.12), value: glow)
  }

  private var editor: some View {
    VStack(alignment: .leading, spacing: 8) {
      if editable, let k = selectedKey {
        KeyEditor(layer: shown, key: k, selected: $selectedKey)
      } else if editable {
        Help("Click a key to put a mouse click or a scroll key on it, then Write to Keyboard. Build the rest of the "
          + "layer in Bazecor, and leave keys you don't need transparent so they keep typing what the layer below types.")
      } else {
        Help("Only the Auto-Mouse Layer can be edited here. Use as the Auto-Mouse Layer makes this one the Auto-Mouse Layer.")
      }
      if keyboard.pendingCount > 0 {
        HStack {
          Text("\(keyboard.pendingCount) key\(keyboard.pendingCount == 1 ? "" : "s") changed, not yet on the keyboard")
            .foregroundStyle(.orange)
          Spacer()
          Button("Discard") {
            keyboard.discard(store.config) { role, key in store.edit { $0[keyPath: role.keyPath] = key } }
            selectedKey = nil
          }
          Button("Write to Keyboard") { keyboard.write() }.keyboardShortcut(.defaultAction).disabled(keyboard.busy)
        }
      }
    }
  }

  private var notRead: some View {
    VStack(spacing: 12) {
      Image(systemName: "keyboard").font(.system(size: 44, weight: .light)).foregroundStyle(.secondary)
      if keyboard.busy { ProgressView().controlSize(.small) }
      if !keyboard.message.isEmpty {
        Text(keyboard.message).foregroundStyle(keyboard.failed ? .red : .secondary).multilineTextAlignment(.center)
      }
      Text("Read Keyboard shows the keyboard's layers here. The Defy has to be connected by USB, with Bazecor closed.")
        .foregroundStyle(.secondary).multilineTextAlignment(.center)
      Stepper("Auto-Mouse Layer: Bazecor layer \(store.config.autoMouseLayer + 1)",
              value: Binding(get: { store.config.autoMouseLayer }, set: { v in store.edit { $0.autoMouseLayer = v } }), in: 0...31)
        .fixedSize()
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.secondary.opacity(0.2)))
  }

  private func layerTitle(_ n: Int) -> String {
    let name = keyboard.layerName(n)
    let base = name == "Layer \(n + 1)" ? name : "\(n + 1) · \(name)"
    var tags: [String] = []
    if n == store.config.autoMouseLayer { tags.append("Auto-Mouse Layer") }
    if keyboard.isEmpty(layer: n) { tags.append("empty") }
    return tags.isEmpty ? base : "\(base) (\(tags.joined(separator: ", ")))"
  }
}

struct KeyEditor: View {
  let layer: Int
  let key: Int
  @Binding var selected: Int?
  @EnvironmentObject var keyboard: KeyboardModel
  @EnvironmentObject var store: ConfigStore

  var body: some View {
    let codes = keyboard.codes(layer: layer)
    let current = key < codes.count ? codes[key] : 0
    let original = keyboard.keymap.count > layer * Keymap.keysPerLayer + key ? keyboard.keymap[layer * Keymap.keysPerLayer + key] : current
    let label = Keymap.label(current, superkeys: keyboard.superkeys, layers: keyboard.layers, scrollKeys: store.config.scrollKeyHids)
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("Key \(key):").bold()
        Text(label.desc)
        if current != original {
          Text("(was: \(Keymap.label(original, superkeys: keyboard.superkeys, layers: keyboard.layers, scrollKeys: store.config.scrollKeyHids).desc))")
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button { selected = nil } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
      }
      HStack(spacing: 6) {
        ForEach(Keymap.clicks, id: \.code) { c in
          choice(c.name, c.code, current)
        }
      }
      HStack(spacing: 6) {
        ForEach(ScrollKeyRole.allCases, id: \.self) { r in
          if let k = store.config[keyPath: r.keyPath], let hid = Keymap.hidCode(forMacKey: k) {
            choice("\(r.title) (\(keyName(k)))", hid, current)
          }
        }
        choice("Transparent", Keymap.transparent, current)
        choice("No key", 0, current)
        if current != original {
          Button("Undo") { keyboard.setPending(layer: layer, key: key, code: nil) }
        }
      }
    }
    .padding(10)
    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
  }

  private func choice(_ title: String, _ code: Int, _ current: Int) -> some View {
    Button(title) { keyboard.setPending(layer: layer, key: key, code: code) }
      .buttonStyle(.bordered)
      .tint(code == current ? .accentColor : nil)
      .disabled(code == current)
  }
}
