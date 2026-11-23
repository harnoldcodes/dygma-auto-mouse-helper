import AppKit
import SwiftUI

/// Every key, in a list that can be searched. The search narrows the list a moment after
/// typing stops, best match first; Up and Down move through it, Return picks, and Escape
/// clears the search (or closes the list when the search is empty).
struct KeyPicker: View {
  let current: Int?
  /// Keys that are already another scroll key, with that key's title.
  var others: [Int: String] = [:]
  let pick: (Int) -> Void
  let cancel: () -> Void

  @State private var query = ""
  @State private var shownQuery = ""  // the search the list shows
  @State private var results: [KeyInfo] = allKeys
  @State private var highlighted: Int?
  @State private var hovered: Int?

  static let debounce: UInt64 = 180_000_000  // ns

  var body: some View {
    VStack(spacing: 0) {
      KeySearchField(text: $query, placeholder: "Search by name or key code", onMove: move, onSubmit: submit,
                     onCancel: cancel)
        .frame(height: 24)
        .padding(10)
      Divider()
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
            if results.isEmpty {
              Text("No key matches “\(shownQuery)”").foregroundStyle(.secondary).padding()
            } else if shownQuery.trimmingCharacters(in: .whitespaces).isEmpty {
              ForEach(KeyGroup.allCases) { g in
                Section {
                  ForEach(results.filter { $0.group == g }) { row($0) }
                } header: {
                  header(g.title)
                }
              }
            } else {
              ForEach(results) { row($0) }
            }
          }
        }
        .onChange(of: highlighted) { h in
          if let h = h { proxy.scrollTo(h) }
        }
      }
      Divider()
      Text(footer)
        .font(.caption).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
    }
    .frame(width: 400, height: 470)
    .task(id: query) {
      if query != shownQuery {  // wait for typing to stop
        try? await Task.sleep(nanoseconds: KeyPicker.debounce)
        if Task.isCancelled { return }
      }
      apply(query)
    }
  }

  private var browsing: Bool { shownQuery.trimmingCharacters(in: .whitespaces).isEmpty }

  private var footer: String {
    if shownQuery.trimmingCharacters(in: .whitespaces).isEmpty {
      return "All \(allKeys.count) macOS key codes. Type to search; ↑ ↓ and Return choose one."
    }
    return "\(results.count) matching. ↑ ↓ and Return choose one; Esc clears the search."
  }

  private func header(_ title: String) -> some View {
    Text(title)
      .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 10).padding(.vertical, 4)
      .background(.bar)
  }

  private func row(_ k: KeyInfo) -> some View {
    let lit = highlighted == k.code
    let secondary: Color = lit ? .white.opacity(0.85) : .secondary
    return HStack(spacing: 8) {
      Image(systemName: "checkmark").font(.caption.weight(.bold))
        .opacity(k.code == current ? 1 : 0).frame(width: 12)
      Text(k.name).foregroundStyle(lit ? .white : (k.usable ? .primary : .secondary))
      if let o = others[k.code] { Text("now the \(o.lowercased())").font(.caption).foregroundStyle(secondary) }
      Spacer(minLength: 8)
      if let n = k.note, !(k.silent && browsing) {  // when browsing, the group's title says it
        Text(n).font(.caption).foregroundStyle(lit ? .white : (k.silent ? Color.green : .secondary))
      }
      Text(String(format: "%3d · 0x%02X", k.code, k.code))
        .font(.caption.monospacedDigit()).foregroundStyle(secondary)
    }
    .padding(.horizontal, 10).padding(.vertical, 4)
    .background(lit ? Color.accentColor : (hovered == k.code && k.usable ? Color.secondary.opacity(0.12) : .clear))
    .contentShape(Rectangle())
    .onHover { inside in
      if inside { hovered = k.code } else if hovered == k.code { hovered = nil }
    }
    .onTapGesture { if k.usable { pick(k.code) } }
    .help(k.usable ? "Key code \(k.code)" : "Modifier keys reach apps as changes of the modifier state, not as key presses, so they can't scroll.")
    .id(k.code)
  }

  private func apply(_ q: String) {
    shownQuery = q
    results = searchKeys(q)
    highlighted = q.trimmingCharacters(in: .whitespaces).isEmpty ? current : results.first(where: \.usable)?.code
  }

  private func move(_ by: Int) {
    if query != shownQuery { apply(query) }
    let usable = results.filter(\.usable)
    guard !usable.isEmpty else { return }
    if let h = highlighted, let i = usable.firstIndex(where: { $0.code == h }) {
      highlighted = usable[max(0, min(usable.count - 1, i + by))].code
    } else {
      highlighted = (by > 0 ? usable.first : usable.last)?.code
    }
  }

  private func submit() {
    if query != shownQuery { apply(query) }  // Return before the list caught up
    if let h = highlighted, keyInfo(h)?.usable == true { pick(h) }
  }
}

/// A search field that passes Up, Down, Return and Escape to the list below it, and takes
/// the keyboard focus when it appears.
struct KeySearchField: NSViewRepresentable {
  @Binding var text: String
  let placeholder: String
  let onMove: (Int) -> Void
  let onSubmit: () -> Void
  let onCancel: () -> Void

  final class Field: NSSearchField {
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      DispatchQueue.main.async { [weak self] in
        guard let self = self, let w = self.window else { return }
        w.makeFirstResponder(self)
      }
    }
  }

  func makeNSView(context: Context) -> NSSearchField {
    let f = Field()
    f.placeholderString = placeholder
    f.delegate = context.coordinator
    f.target = context.coordinator
    f.action = #selector(Coordinator.changed(_:))  // also the clear button
    f.sendsSearchStringImmediately = true
    return f
  }

  func updateNSView(_ f: NSSearchField, context: Context) {
    context.coordinator.parent = self
    if f.stringValue != text { f.stringValue = text }
  }

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  final class Coordinator: NSObject, NSSearchFieldDelegate {
    var parent: KeySearchField
    init(_ parent: KeySearchField) { self.parent = parent }

    @objc func changed(_ sender: NSSearchField) {
      if parent.text != sender.stringValue { parent.text = sender.stringValue }
    }

    func controlTextDidChange(_ n: Notification) {
      if let f = n.object as? NSTextField, parent.text != f.stringValue { parent.text = f.stringValue }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
      switch sel {
      case #selector(NSResponder.moveUp(_:)): parent.onMove(-1)
      case #selector(NSResponder.moveDown(_:)): parent.onMove(1)
      case #selector(NSResponder.insertNewline(_:)): parent.onSubmit()
      case #selector(NSResponder.cancelOperation(_:)):
        if parent.text.isEmpty { parent.onCancel() } else { parent.text = ""; control.stringValue = "" }
      default: return false
      }
      return true
    }
  }
}
