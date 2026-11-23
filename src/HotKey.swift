import Carbon
import Foundation

/// A global keyboard shortcut, registered as a Carbon hot key. macOS matches hot keys after
/// every event tap, so modifiers that a tap adds (home-row mods from TapLayer or kanata)
/// count, and it needs no permission.
final class HotKey {
  var onPress: (() -> Void)?
  private var ref: EventHotKeyRef?
  private var handler: EventHandlerRef?

  /// Registers the shortcut in place of the previous one (nil: none). Returns why macOS
  /// refused it, if it did.
  @discardableResult
  func set(_ shortcut: Shortcut?) -> String? {
    if let r = ref { UnregisterEventHotKey(r); ref = nil }
    guard let s = shortcut else { return nil }
    installHandler()
    var mods: UInt32 = 0
    if s.modifiers.contains(.control) { mods |= UInt32(controlKey) }
    if s.modifiers.contains(.option) { mods |= UInt32(optionKey) }
    if s.modifiers.contains(.shift) { mods |= UInt32(shiftKey) }
    if s.modifiers.contains(.command) { mods |= UInt32(cmdKey) }
    let id = EventHotKeyID(signature: OSType(0x4e_56_42_48), id: 1)  // "NVBH"
    let err = RegisterEventHotKey(UInt32(s.key), mods, id, GetApplicationEventTarget(), 0, &ref)
    if err == noErr { return nil }
    ref = nil
    let why = err == eventHotKeyExistsErr ? "another app already uses \(s.display)" : "macOS refused \(s.display) (error \(err))"
    log("pause shortcut: \(why)")
    return why
  }

  private func installHandler() {
    guard handler == nil else { return }
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let ctx = Unmanaged.passUnretained(self).toOpaque()
    InstallEventHandler(GetApplicationEventTarget(), { _, _, ctx in
      guard let ctx = ctx else { return noErr }
      let me = Unmanaged<HotKey>.fromOpaque(ctx).takeUnretainedValue()
      DispatchQueue.main.async { me.onPress?() }
      return noErr
    }, 1, &spec, ctx, &handler)
  }
}
