import Foundation

/// The app that has a device to itself, from the `IOUserClientCreator` strings of the device's
/// clients in the I/O Registry ("pid 1304, kanata_macos_arm"). The registry lists every app
/// that has the device open and doesn't mark the one that took it over, so only apps known to
/// take devices over count. nil: none of those, or none that isn't this app.
func knownHolder(_ creators: [String], ownPid: Int32) -> String? {
  let known: [(match: String, name: String)] = [
    ("kanata", "kanata (Mantle)"),
    ("karabiner", "Karabiner-Elements"),
    ("kensington", "KensingtonWorks"),
    ("overdrive", "USB Overdrive"),
  ]
  for creator in creators {
    let parts = creator.split(separator: ",", maxSplits: 1)
    guard parts.count == 2, parts[0].hasPrefix("pid "), let pid = Int32(parts[0].dropFirst(4)) else { continue }
    if pid == ownPid { continue }
    let process = parts[1].trimmingCharacters(in: .whitespaces).lowercased()
    if let k = known.first(where: { process.contains($0.match) }) { return k.name }
  }
  return nil
}
