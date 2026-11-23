import SwiftUI

/// One layer of the Defy, drawn to scale. Keys with unsaved edits are outlined in orange.
struct KeyboardView: View {
  let codes: [Int]
  let superkeys: [[Int]]
  let layers: Int
  let pending: Set<Int>
  @Binding var selected: Int?
  let editable: Bool
  var scrollKeys: [Int: ScrollKeyRole] = [:]   // keymap code → the scroll key it sends

  var body: some View {
    GeometryReader { geo in
      let s = geo.size.width / Keymap.width
      ZStack(alignment: .topLeading) {
        ForEach(Keymap.geometry.keys.sorted(), id: \.self) { i in
          let g = Keymap.geometry[i]!
          let label = i < codes.count ? Keymap.label(codes[i], superkeys: superkeys, layers: layers, scrollKeys: scrollKeys)
                                      : KeyLabel(main: "", kind: .none, desc: "")
          KeyCap(label: label, scale: s, pending: pending.contains(i), selected: editable && selected == i)
            .frame(width: g.w * s, height: g.h * s)
            .rotationEffect(.degrees(g.rotation))
            .position(x: g.x * s, y: g.y * s)
            .help("Key \(i): \(label.desc)")
            .onTapGesture { if editable { selected = (selected == i ? nil : i) } }
        }
      }
    }
    .aspectRatio(Keymap.width / Keymap.height, contentMode: .fit)
  }
}

struct KeyCap: View {
  let label: KeyLabel
  let scale: Double
  let pending: Bool
  let selected: Bool

  private var fill: Color {
    switch label.kind {
    case .none: return Color.secondary.opacity(0.05)
    case .transparent: return Color.secondary.opacity(0.08)
    case .mouse: return Color.accentColor.opacity(0.28)
    case .layer: return Color.purple.opacity(0.22)
    case .superkey: return Color.teal.opacity(0.22)
    case .dual: return Color.indigo.opacity(0.2)
    case .mod: return Color.secondary.opacity(0.22)
    case .plain, .other: return Color.secondary.opacity(0.16)
    }
  }

  var body: some View {
    let r = RoundedRectangle(cornerRadius: scale * 0.14, style: .continuous)
    ZStack {
      r.fill(fill)
      r.strokeBorder(selected ? Color.accentColor : pending ? Color.orange : Color.secondary.opacity(0.3),
                     lineWidth: selected || pending ? max(2, scale * 0.06) : 1)
      VStack(spacing: 0) {
        if !label.top.isEmpty {
          Text(label.top).font(.system(size: scale * 0.15)).foregroundStyle(.secondary)
        }
        Text(label.main)
          .font(.system(size: scale * (label.main.count > 4 ? 0.2 : 0.28), weight: .medium))
          .foregroundStyle(label.kind == .transparent || label.kind == .none ? .secondary : .primary)
        if !label.sub.isEmpty {
          Text(label.sub).font(.system(size: scale * 0.15)).foregroundStyle(.secondary)
        }
      }
      .lineLimit(1)
      .minimumScaleFactor(0.5)
      .padding(.horizontal, scale * 0.04)
    }
    .contentShape(r)
  }
}
