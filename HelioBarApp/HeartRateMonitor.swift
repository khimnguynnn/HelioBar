import Foundation
import CoreBluetooth
import HelioCore

/// Connects to a chosen strap's standard BLE Heart Rate broadcast and reports BPM.
/// Remembers the selected device and only ever reconnects to it; on first run it
/// auto-connects to a lone strap or asks the user to choose among several.
///
/// All state is touched on the main thread: CoreBluetooth is created with
/// `queue: nil` (main queue) and the settle Timer fires on the main run loop.
// INVARIANT: every stored property is touched on the main thread only (CoreBluetooth queue: nil + main-run-loop Timer). Do not call into this type off-main.
final class HeartRateMonitor: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?

    private let onSample: @Sendable (HeartRateSample) -> Void
    private let onBattery: @Sendable (Int) -> Void
    private let onConnected: @Sendable (Bool) -> Void
    private let onUnavailable: @Sendable (String) -> Void
    private let onDeviceEvent: @Sendable (DeviceEvent) -> Void

    private let hrService = CBUUID(string: "180D")
    private let hrMeasurement = CBUUID(string: "2A37")
    private let batteryService = CBUUID(string: "180F")
    private let batteryLevel = CBUUID(string: "2A19")

    // Selection state
    private var engine: DeviceSelectionEngine
    private var discovered: [UUID: DiscoveredDevice] = [:]
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var scanStartedAt = Date()
    private var settleTimer: Timer?
    private let settleWindow: TimeInterval = 3
    private let staleAfter: TimeInterval = 10

    init(rememberedID: UUID?,
         onSample: @escaping @Sendable (HeartRateSample) -> Void,
         onBattery: @escaping @Sendable (Int) -> Void,
         onConnected: @escaping @Sendable (Bool) -> Void,
         onUnavailable: @escaping @Sendable (String) -> Void,
         onDeviceEvent: @escaping @Sendable (DeviceEvent) -> Void) {
        self.engine = DeviceSelectionEngine(rememberedID: rememberedID)
        self.onSample = onSample
        self.onBattery = onBattery
        self.onConnected = onConnected
        self.onUnavailable = onUnavailable
        self.onDeviceEvent = onDeviceEvent
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - Public control (called from AppModel on the main thread)

    /// User picked a device in Settings.
    func select(deviceID: UUID) {
        engine.rememberedID = deviceID
        onDeviceEvent(.remembered(discovered[deviceID]))
        onDeviceEvent(.needsChoice(false))
        if peripheral?.identifier == deviceID { return }   // already on it; selection persisted above
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
            peripheral = nil
            onDeviceEvent(.connected(nil))
        }
        connectToRemembered()
    }

    /// User cleared the selection — revert to auto-pick on the next scan.
    func forget() {
        engine.rememberedID = nil
        onDeviceEvent(.remembered(nil))
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        onDeviceEvent(.connected(nil))
        startScan()
    }

    /// Refresh the discovered list (Settings Device section opened).
    func rescan() {
        guard central.state == .poweredOn else { return }
        startScan()
    }

    /// Stop the picker scan (Settings closed) — but keep hunting if we still
    /// need to (re)connect to the remembered device.
    func stopDeviceScan() {
        if peripheral != nil { central.stopScan(); settleTimer?.invalidate() }
    }

    // MARK: - Scanning / selection

    private func startScan() {
        discovered.removeAll()
        peripherals.removeAll()
        scanStartedAt = Date()
        onDeviceEvent(.devicesChanged([]))
        central.scanForPeripherals(withServices: [hrService])
        settleTimer?.invalidate()
        settleTimer = Timer.scheduledTimer(withTimeInterval: settleWindow, repeats: false) { [weak self] _ in
            self?.evaluate()
        }
    }

    private func connectToRemembered() {
        guard let id = engine.rememberedID else { startScan(); return }
        // Fast path: the system may already know this peripheral across launches.
        if let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            peripherals[id] = known
            connect(known)
            return
        }
        if let p = peripherals[id] { connect(p); return }
        startScan()   // wait until it advertises
    }

    private func connect(_ p: CBPeripheral) {
        central.stopScan()
        settleTimer?.invalidate()
        peripheral = p
        p.delegate = self
        central.connect(p)
    }

    /// Run the decision engine against the current candidates and act.
    private func evaluate() {
        pruneStale()
        let candidates = sortedDevices()
        switch engine.decide(candidates: candidates, scanStarted: scanStartedAt,
                             now: Date(), settleWindow: settleWindow) {
        case .connect(let id):
            if peripheral?.identifier == id { return }   // already on it
            if engine.rememberedID == nil {              // first-run auto-pick: remember it
                engine.rememberedID = id
                onDeviceEvent(.remembered(discovered[id]))
            }
            if let p = peripherals[id] { connect(p) }
        case .needsUserChoice:
            onDeviceEvent(.needsChoice(true))
        case .awaitRemembered, .idle:
            break
        }
    }

    private func pruneStale() {
        let cutoff = Date().addingTimeInterval(-staleAfter)
        var removed = false
        for (id, dev) in discovered where dev.lastSeen < cutoff {
            discovered[id] = nil
            peripherals[id] = nil
            removed = true
        }
        if removed { onDeviceEvent(.devicesChanged(sortedDevices())) }
    }

    private func sortedDevices() -> [DiscoveredDevice] {
        discovered.values.sorted { $0.rssi > $1.rssi }
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if engine.rememberedID != nil { connectToRemembered() } else { startScan() }
        case .unauthorized: onUnavailable("Bluetooth permission denied")
        case .poweredOff:   onUnavailable("Bluetooth is off")
        case .unsupported:  onUnavailable("Bluetooth unavailable")
        default: break
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let id = peripheral.identifier
        let name = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? "Unknown HR device"
        discovered[id] = DiscoveredDevice(id: id, name: name, rssi: RSSI.intValue, lastSeen: Date())
        peripherals[id] = peripheral
        onDeviceEvent(.devicesChanged(sortedDevices()))
        evaluate()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        onConnected(true)
        onDeviceEvent(.needsChoice(false))
        let dev = discovered[peripheral.identifier]
            ?? DiscoveredDevice(id: peripheral.identifier,
                                name: peripheral.name ?? "Helio Strap",
                                rssi: 127, lastSeen: Date())
        onDeviceEvent(.connected(dev))
        peripheral.discoverServices([hrService, batteryService])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }   // ignore a failure for a device we've moved off of
        self.peripheral = nil
        onConnected(false)
        connectToRemembered()
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }   // ignore stale (e.g. just-switched-away) device
        self.peripheral = nil
        onConnected(false)
        onDeviceEvent(.connected(nil))
        connectToRemembered()
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] {
            switch service.uuid {
            case hrService:
                peripheral.discoverCharacteristics([hrMeasurement], for: service)
            case batteryService:
                peripheral.discoverCharacteristics([batteryLevel], for: service)
            default:
                break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        for char in service.characteristics ?? [] {
            switch char.uuid {
            case hrMeasurement:
                peripheral.setNotifyValue(true, for: char)
            case batteryLevel:
                if char.properties.contains(.read) {
                    peripheral.readValue(for: char)
                }
                if char.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: char)
                }
            default:
                break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard let data = characteristic.value else { return }
        switch characteristic.uuid {
        case hrMeasurement:
            guard let sample = HeartRatePacket.parse(data) else { return }
            onSample(sample)
        case batteryLevel:
            guard let percent = data.first else { return }
            onBattery(Int(percent))
        default:
            break
        }
    }
}
