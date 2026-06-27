import Foundation

/// Device-related events the BLE monitor reports up to the app layer.
public enum DeviceEvent: Sendable {
    case devicesChanged([DiscoveredDevice])   // fresh scan list, sorted by signal
    case connected(DiscoveredDevice?)          // now-connected device, or nil on disconnect
    case needsChoice(Bool)                     // first run, 2+ devices — prompt the user
    case remembered(DiscoveredDevice?)         // selection changed; persist (nil = forgotten)
}
