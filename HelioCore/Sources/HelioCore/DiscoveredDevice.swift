import Foundation

/// A heart-rate peripheral seen during a BLE scan. Pure value type so the
/// selection logic and the UI can share it without importing CoreBluetooth.
public struct DiscoveredDevice: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var rssi: Int        // dBm; 127 means "unknown" per CoreBluetooth
    public var lastSeen: Date

    public init(id: UUID, name: String, rssi: Int, lastSeen: Date) {
        self.id = id
        self.name = name
        self.rssi = rssi
        self.lastSeen = lastSeen
    }

    /// 0–3 signal bars from the RSSI, for the picker UI.
    public var signalBars: Int {
        if rssi >= 0 { return 0 }   // 127 = unknown; positive RSSI is invalid
        if rssi >= -55 { return 3 }
        if rssi >= -70 { return 2 }
        if rssi >= -85 { return 1 }
        return 0
    }

    /// Last 4 characters of the UUID (e.g. "3F1A") to tell identical names apart.
    public var idSuffix: String { String(id.uuidString.suffix(4)) }
}
