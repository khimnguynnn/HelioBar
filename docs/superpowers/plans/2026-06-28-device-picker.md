# Device Picker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let HelioBar connect to a chosen strap and remember it — zero-config for one strap, a picker for households with several, and reconnection that never grabs the wrong device.

**Architecture:** A pure, unit-tested `DeviceSelectionEngine` in `HelioCore` decides which discovered device to connect to. `HeartRateMonitor` (the CoreBluetooth shell) builds a discovered-device registry, acts on the engine's decision, and reconnects only to the remembered UUID. `AppModel` owns persistence (UserDefaults) and feeds device state into the `@Observable` `HealthStore` that the popover and Settings bind to. UI: a Settings "Device" section plus a subtle popover hint.

**Tech Stack:** Swift 6, SwiftUI + AppKit, CoreBluetooth, Swift Package Manager, XCTest.

Reference spec: `docs/superpowers/specs/2026-06-28-device-picker-design.md`.

## Global Constraints

- `HelioCore` package: `swift-tools-version: 6.0`, `platforms: [.macOS(.v14)]`, tests use **XCTest**, and it **must not import CoreBluetooth** (pure logic only).
- App target `HelioBar`: `swift-tools-version: 6.2`, `platforms: [.macOS(.v26)]`, built with `swift build` from the repo root (root `Package.swift`).
- New files under `HelioBarApp/Views/**` and `HelioCore/Sources/HelioCore/**` are auto-compiled — **no `Package.swift` edits needed**.
- Persistence: `UserDefaults.standard` keys **`selectedDeviceID`** (UUID string) and **`selectedDeviceName`** (String). No other storage; all data local.
- No new third-party dependencies.
- Follow existing patterns: closure-based `HeartRateMonitor`, `@Observable` `HealthStore` as the UI's single source of truth, one component per file in `Views/Components/`.
- **UI tasks (3 and 4) MUST use the `swiftui-expert-skill`** — invoke it at the start of each.
- Run commands: HelioCore tests `cd HelioCore && swift test`; app build `swift build`; manual run `./scripts/install-and-run.sh`.

---

### Task 1: Pure device-selection core (HelioCore, TDD)

Creates the value types and the decision engine, fully unit-tested. Nothing here imports CoreBluetooth.

**Files:**
- Create: `HelioCore/Sources/HelioCore/DiscoveredDevice.swift`
- Create: `HelioCore/Sources/HelioCore/DeviceEvent.swift`
- Create: `HelioCore/Sources/HelioCore/DeviceSelectionEngine.swift`
- Test: `HelioCore/Tests/HelioCoreTests/DeviceSelectionEngineTests.swift`

**Interfaces:**
- Produces:
  - `struct DiscoveredDevice: Identifiable, Equatable, Sendable` — `init(id: UUID, name: String, rssi: Int, lastSeen: Date)`, computed `var signalBars: Int` (0–3), `var idSuffix: String` (last 4 of UUID).
  - `enum DeviceEvent: Sendable` — `.devicesChanged([DiscoveredDevice])`, `.connected(DiscoveredDevice?)`, `.needsChoice(Bool)`, `.remembered(DiscoveredDevice?)`.
  - `struct DeviceSelectionEngine: Sendable` — `var rememberedID: UUID?`, `init(rememberedID: UUID? = nil)`, `func decide(candidates: [DiscoveredDevice], scanStarted: Date, now: Date, settleWindow: TimeInterval = 3) -> DeviceDecision`.
  - `enum DeviceDecision: Equatable, Sendable` — `.connect(UUID)`, `.awaitRemembered`, `.needsUserChoice`, `.idle`.

- [ ] **Step 1: Write the failing tests**

Create `HelioCore/Tests/HelioCoreTests/DeviceSelectionEngineTests.swift`:

```swift
import XCTest
@testable import HelioCore

final class DeviceSelectionEngineTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 0)
    private let a = UUID()
    private let b = UUID()
    private func dev(_ id: UUID, rssi: Int = -50) -> DiscoveredDevice {
        DiscoveredDevice(id: id, name: "Helio Strap", rssi: rssi, lastSeen: t0)
    }

    func test_rememberedPresent_connectsToIt() {
        let e = DeviceSelectionEngine(rememberedID: a)
        XCTAssertEqual(e.decide(candidates: [dev(a), dev(b)], scanStarted: t0, now: t0), .connect(a))
    }

    func test_rememberedAbsent_waits_neverSubstitutes() {
        let e = DeviceSelectionEngine(rememberedID: a)
        // Only b is visible; must NOT connect to b.
        XCTAssertEqual(e.decide(candidates: [dev(b)], scanStarted: t0, now: t0.addingTimeInterval(60)),
                       .awaitRemembered)
    }

    func test_noRemembered_empty_isIdle() {
        let e = DeviceSelectionEngine()
        XCTAssertEqual(e.decide(candidates: [], scanStarted: t0, now: t0.addingTimeInterval(60)), .idle)
    }

    func test_noRemembered_singleDevice_idleDuringSettle_thenConnects() {
        let e = DeviceSelectionEngine()
        XCTAssertEqual(e.decide(candidates: [dev(a)], scanStarted: t0, now: t0.addingTimeInterval(1)), .idle)
        XCTAssertEqual(e.decide(candidates: [dev(a)], scanStarted: t0, now: t0.addingTimeInterval(3)), .connect(a))
    }

    func test_noRemembered_multipleDevices_promptsAfterSettle() {
        let e = DeviceSelectionEngine()
        XCTAssertEqual(e.decide(candidates: [dev(a), dev(b)], scanStarted: t0, now: t0.addingTimeInterval(1)), .idle)
        XCTAssertEqual(e.decide(candidates: [dev(a), dev(b)], scanStarted: t0, now: t0.addingTimeInterval(3)),
                       .needsUserChoice)
    }

    func test_discoveredDevice_signalBars_and_idSuffix() {
        XCTAssertEqual(dev(a, rssi: -40).signalBars, 3)
        XCTAssertEqual(dev(a, rssi: -65).signalBars, 2)
        XCTAssertEqual(dev(a, rssi: -80).signalBars, 1)
        XCTAssertEqual(dev(a, rssi: -95).signalBars, 0)
        XCTAssertEqual(dev(a, rssi: 127).signalBars, 0)   // CoreBluetooth "unknown RSSI" sentinel
        XCTAssertEqual(dev(a).idSuffix.count, 4)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail (do not compile)**

Run: `cd HelioCore && swift test`
Expected: FAIL — `cannot find 'DiscoveredDevice' in scope` / `cannot find 'DeviceSelectionEngine' in scope`.

- [ ] **Step 3: Create `DiscoveredDevice.swift`**

```swift
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
```

- [ ] **Step 4: Create `DeviceEvent.swift`**

```swift
import Foundation

/// Device-related events the BLE monitor reports up to the app layer.
public enum DeviceEvent: Sendable {
    case devicesChanged([DiscoveredDevice])   // fresh scan list, sorted by signal
    case connected(DiscoveredDevice?)          // now-connected device, or nil on disconnect
    case needsChoice(Bool)                     // first run, 2+ devices — prompt the user
    case remembered(DiscoveredDevice?)         // selection changed; persist (nil = forgotten)
}
```

- [ ] **Step 5: Create `DeviceSelectionEngine.swift`**

```swift
import Foundation

/// The outcome of a selection pass. The CoreBluetooth shell acts on this.
public enum DeviceDecision: Equatable, Sendable {
    case connect(UUID)      // connect now (shell persists if this was a first-run auto-pick)
    case awaitRemembered    // remembered device known but not visible — keep scanning
    case needsUserChoice    // first run, 2+ candidates — prompt
    case idle               // nothing actionable yet
}

/// Decides which discovered device to connect to. Pure and testable; the
/// CoreBluetooth shell (`HeartRateMonitor`) holds the peripherals and acts.
public struct DeviceSelectionEngine: Sendable {
    public var rememberedID: UUID?

    public init(rememberedID: UUID? = nil) {
        self.rememberedID = rememberedID
    }

    /// - candidates: HR devices seen so far this scan.
    /// - scanStarted: when the current scan began (drives the first-run settle window).
    /// - now: current time.
    /// - settleWindow: how long to wait for more devices before auto-picking on first run.
    public func decide(candidates: [DiscoveredDevice],
                       scanStarted: Date,
                       now: Date,
                       settleWindow: TimeInterval = 3) -> DeviceDecision {
        if let remembered = rememberedID {
            return candidates.contains(where: { $0.id == remembered })
                ? .connect(remembered)
                : .awaitRemembered
        }
        if candidates.isEmpty { return .idle }
        if now.timeIntervalSince(scanStarted) < settleWindow { return .idle }
        if candidates.count == 1 { return .connect(candidates[0].id) }
        return .needsUserChoice
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd HelioCore && swift test`
Expected: PASS — all `DeviceSelectionEngineTests` green, existing tests still green.

- [ ] **Step 7: Commit**

```bash
git add HelioCore/Sources/HelioCore/DiscoveredDevice.swift \
        HelioCore/Sources/HelioCore/DeviceEvent.swift \
        HelioCore/Sources/HelioCore/DeviceSelectionEngine.swift \
        HelioCore/Tests/HelioCoreTests/DeviceSelectionEngineTests.swift
git commit -m "feat(core): device selection engine + DiscoveredDevice/DeviceEvent"
```

---

### Task 2: Remembered-device connection policy (HeartRateMonitor + AppModel + HealthStore)

Replaces "connect to first" with the engine-driven policy and wires persistence. End-to-end compiles and runs; UI comes in Tasks 3–4. No unit tests (CoreBluetooth shell), verified by build + the manual checklist in Task 5.

**Files:**
- Modify: `HelioCore/Sources/HelioCore/HealthStore.swift` (add device display state)
- Modify: `HelioBarApp/HeartRateMonitor.swift` (rewrite policy + new API)
- Modify: `HelioBarApp/AppModel.swift` (new monitor wiring, persistence, actions)

**Interfaces:**
- Consumes (Task 1): `DiscoveredDevice`, `DeviceEvent`, `DeviceSelectionEngine`, `DeviceDecision`.
- Produces:
  - `HealthStore` new properties: `var discoveredDevices: [DiscoveredDevice]`, `var connectedDevice: DiscoveredDevice?`, `var rememberedDeviceName: String?`, `var needsDeviceChoice: Bool`.
  - `HeartRateMonitor.init(rememberedID: UUID?, onSample:..., onBattery:..., onConnected:..., onUnavailable:..., onDeviceEvent: @escaping @Sendable (DeviceEvent) -> Void)` and methods `select(deviceID: UUID)`, `forget()`, `rescan()`, `stopDeviceScan()`.
  - `AppModel` methods: `selectDevice(_ id: UUID)`, `forgetDevice()`, `rescanDevices()`, `stopDeviceScan()`.

- [ ] **Step 1: Add device display state to `HealthStore`**

In `HelioCore/Sources/HelioCore/HealthStore.swift`, add these properties immediately after the `maxHR` line (`public var maxHR: Int = 190`):

```swift
    // Device selection (fed by AppModel from the BLE monitor)
    public var discoveredDevices: [DiscoveredDevice] = []
    public var connectedDevice: DiscoveredDevice?
    public var rememberedDeviceName: String?
    public var needsDeviceChoice: Bool = false
```

(No import needed — `DiscoveredDevice` is in the same module.)

- [ ] **Step 2: Rewrite `HeartRateMonitor.swift`**

Replace the **entire** contents of `HelioBarApp/HeartRateMonitor.swift` with:

```swift
import Foundation
import CoreBluetooth
import HelioCore

/// Connects to a chosen strap's standard BLE Heart Rate broadcast and reports BPM.
/// Remembers the selected device and only ever reconnects to it; on first run it
/// auto-connects to a lone strap or asks the user to choose among several.
///
/// All state is touched on the main thread: CoreBluetooth is created with
/// `queue: nil` (main queue) and the settle Timer fires on the main run loop.
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
        if let p = peripheral, p.identifier != deviceID {
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
        for (id, dev) in discovered where dev.lastSeen < cutoff {
            discovered[id] = nil
            peripherals[id] = nil
        }
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
        let dev = discovered[peripheral.identifier]
            ?? DiscoveredDevice(id: peripheral.identifier,
                                name: peripheral.name ?? "Helio Strap",
                                rssi: 127, lastSeen: Date())
        onDeviceEvent(.connected(dev))
        peripheral.discoverServices([hrService, batteryService])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral, error: Error?) {
        onConnected(false)
        connectToRemembered()
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
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
```

- [ ] **Step 3: Rewrite `AppModel.swift`**

Replace the **entire** contents of `HelioBarApp/AppModel.swift` with (adds device wiring; HR/battery/alert logic unchanged):

```swift
import Foundation
import UserNotifications
import HelioCore

/// Owns the BLE monitor, applies user prefs, fires alerts, and mediates
/// device selection between the monitor and the UI-facing HealthStore.
@MainActor
@Observable
final class AppModel {
    let store = HealthStore()
    private var monitor: HeartRateMonitor?
    private let alertEngine = ElevatedHRAlertEngine()
    private let batteryAlertEngine = BatteryAlertEngine()
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        let d = UserDefaults.standard
        let rememberedID = d.string(forKey: "selectedDeviceID").flatMap(UUID.init(uuidString:))
        store.rememberedDeviceName = d.string(forKey: "selectedDeviceName")

        monitor = HeartRateMonitor(
            rememberedID: rememberedID,
            onSample: { [weak self] sample in
                Task { @MainActor in self?.handle(bpm: sample.bpm) }
            },
            onBattery: { [weak self] percent in
                Task { @MainActor in self?.handleBattery(percent: percent) }
            },
            onConnected: { [weak self] connected in
                Task { @MainActor in if !connected { self?.store.hrDisconnected() } }
            },
            onUnavailable: { [weak self] message in
                Task { @MainActor in self?.store.hrFailed(message) }
            },
            onDeviceEvent: { [weak self] event in
                Task { @MainActor in self?.handleDeviceEvent(event) }
            })
    }

    // MARK: - Device actions (called from SettingsView)

    func selectDevice(_ id: UUID) { monitor?.select(deviceID: id) }
    func forgetDevice() { monitor?.forget() }
    func rescanDevices() { monitor?.rescan() }
    func stopDeviceScan() { monitor?.stopDeviceScan() }

    // MARK: - Event handling

    private func handleDeviceEvent(_ event: DeviceEvent) {
        switch event {
        case .devicesChanged(let list):
            store.discoveredDevices = list
        case .connected(let dev):
            store.connectedDevice = dev
        case .needsChoice(let needs):
            store.needsDeviceChoice = needs
        case .remembered(let dev):
            store.rememberedDeviceName = dev?.name
            let d = UserDefaults.standard
            if let dev {
                d.set(dev.id.uuidString, forKey: "selectedDeviceID")
                d.set(dev.name, forKey: "selectedDeviceName")
            } else {
                d.removeObject(forKey: "selectedDeviceID")
                d.removeObject(forKey: "selectedDeviceName")
            }
        }
    }

    private func handle(bpm: Int) {
        applyPrefs()
        store.updateHR(bpm)
        if alertEngine.evaluate(bpm: bpm, now: Date()) { fireAlert(bpm) }
    }

    private func handleBattery(percent: Int) {
        applyPrefs()
        store.updateBattery(percent: percent)
        if batteryAlertEngine.evaluate(percent: percent) { fireBatteryAlert(percent) }
    }

    private func applyPrefs() {
        let d = UserDefaults.standard
        let age = (d.object(forKey: "age") as? Int) ?? 30
        store.maxHR = Swift.max(120, 220 - age)
        alertEngine.config = ElevatedHRConfig(
            enabled: d.bool(forKey: "alertEnabled"),
            threshold: (d.object(forKey: "alertThreshold") as? Int) ?? 100,
            duration: TimeInterval(((d.object(forKey: "alertDurationMin") as? Int) ?? 3) * 60))
        batteryAlertEngine.config = BatteryAlertConfig(
            enabled: (d.object(forKey: "batteryAlertEnabled") as? Bool) ?? true,
            threshold: (d.object(forKey: "batteryAlertThreshold") as? Int) ?? 20)
    }

    private func fireAlert(_ bpm: Int) {
        let c = UNMutableNotificationContent()
        c.title = "Heart rate elevated"
        c.body = "\(bpm) bpm for a while — take a breath."
        c.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    private func fireBatteryAlert(_ percent: Int) {
        let c = UNMutableNotificationContent()
        c.title = "Strap battery low"
        c.body = "Helio Strap battery is at \(percent)%."
        c.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "strap-battery-low", content: c, trigger: nil))
    }
}
```

- [ ] **Step 4: Build and verify it compiles**

Run: `swift build`
Expected: `Build complete!` with no errors.

- [ ] **Step 5: Verify HelioCore tests still pass**

Run: `cd HelioCore && swift test`
Expected: PASS (no regressions).

- [ ] **Step 6: Commit**

```bash
git add HelioCore/Sources/HelioCore/HealthStore.swift \
        HelioBarApp/HeartRateMonitor.swift \
        HelioBarApp/AppModel.swift
git commit -m "feat: remember selected strap; reconnect only to it (no UI yet)"
```

---

### Task 3: Settings "Device" section (UI)

**Invoke the `swiftui-expert-skill` first.**

Adds the picker UI and injects `AppModel` into Settings.

**Files:**
- Create: `HelioBarApp/Views/Components/SignalBars.swift`
- Modify: `HelioBarApp/Views/SettingsView.swift`
- Modify: `HelioBarApp/HelioBarApp.swift` (pass `model` into `SettingsView`, bump window height)

**Interfaces:**
- Consumes: `AppModel.selectDevice/forgetDevice/rescanDevices/stopDeviceScan`, `store.discoveredDevices`, `store.connectedDevice`, `DiscoveredDevice.signalBars/idSuffix`.
- Produces: `SettingsView(model: AppModel)`, `SignalBars(level: Int)`.

- [ ] **Step 1: Create `SignalBars.swift`**

```swift
import SwiftUI

/// Three little bars showing 0–3 signal strength.
struct SignalBars: View {
    let level: Int   // 0...3

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i <= level ? Color.secondary : Color.secondary.opacity(0.25))
                    .frame(width: 3, height: CGFloat(3 + i * 3))
            }
        }
        .frame(width: 14, height: 12, alignment: .bottom)
        .accessibilityLabel("Signal \(level) of 3")
    }
}

#if !SWIFT_PACKAGE
#Preview {
    HStack(spacing: 16) { SignalBars(level: 0); SignalBars(level: 1); SignalBars(level: 2); SignalBars(level: 3) }
        .padding().background(.black)
}
#endif
```

- [ ] **Step 2: Update `SettingsView.swift` — accept the model and add the Device section**

Replace the **entire** contents of `HelioBarApp/Views/SettingsView.swift` with:

```swift
import SwiftUI
import ServiceManagement
import HelioCore

struct SettingsView: View {
    let model: AppModel

    @AppStorage("age") private var age = 30
    @AppStorage("alertEnabled") private var alertEnabled = false
    @AppStorage("alertThreshold") private var alertThreshold = 100
    @AppStorage("alertDurationMin") private var alertDurationMin = 3
    @AppStorage("batteryAlertEnabled") private var batteryAlertEnabled = true
    @AppStorage("batteryAlertThreshold") private var batteryAlertThreshold = 20
    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)
    @State private var launchAtLoginError: String?

    var body: some View {
        Form {
            Section {
                Stepper("Age: \(age)", value: $age, in: 10...100)
                Text("Max HR ≈ \(220 - age) bpm · zones scale to this")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Label("You", systemImage: "person.fill")
            }
            deviceSection
            Section {
                Toggle("Notify when HR stays high", isOn: $alertEnabled)
                Stepper("Above \(alertThreshold) bpm", value: $alertThreshold, in: 80...200, step: 5)
                Stepper("For \(alertDurationMin) min", value: $alertDurationMin, in: 1...30)
            } header: {
                Label("Elevated-HR alert", systemImage: "heart.text.square.fill")
            }
            Section {
                Toggle("Notify when strap battery is low", isOn: $batteryAlertEnabled)
                Stepper("At or below \(batteryAlertThreshold)%", value: $batteryAlertThreshold, in: 5...50, step: 5)
            } header: {
                Label("Strap battery alert", systemImage: "battery.25percent")
            }
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in setLaunch(on) }
                if let launchAtLoginError {
                    Text(launchAtLoginError).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Label("System", systemImage: "power")
            }
        }
        .formStyle(.grouped)
        .frame(width: 330, height: 480)
        .onAppear { model.rescanDevices() }
        .onDisappear { model.stopDeviceScan() }
    }

    @ViewBuilder
    private var deviceSection: some View {
        Section {
            if let connected = model.store.connectedDevice {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(connected.name)
                    Spacer()
                    Text("Connected").font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(model.store.discoveredDevices) { dev in
                Button {
                    model.selectDevice(dev.id)
                } label: {
                    HStack(spacing: 8) {
                        SignalBars(level: dev.signalBars)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(dev.name)
                            Text("…\(dev.idSuffix)").font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        if dev.id == model.store.connectedDevice?.id {
                            Image(systemName: "checkmark").foregroundStyle(.green)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            if model.store.discoveredDevices.isEmpty {
                Text("Searching for straps…").font(.caption).foregroundStyle(.secondary)
            }
            Button("Forget / auto-pick", role: .destructive) { model.forgetDevice() }
        } header: {
            Label("Device", systemImage: "dot.radiowaves.left.and.right")
        } footer: {
            Text("HelioBar remembers this strap and reconnects only to it. Signal bars and the ID suffix help tell identical straps apart.")
                .font(.caption2)
        }
    }

    private func setLaunch(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else  { try SMAppService.mainApp.unregister() }
            launchAtLoginError = nil
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        } catch {
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
            launchAtLoginError = error.localizedDescription
        }
    }
}
```

- [ ] **Step 3: Update `HelioBarApp.swift` — pass the model and grow the window**

In `HelioBarApp/HelioBarApp.swift`, change the Settings window construction. Replace this line:

```swift
                contentRect: NSRect(x: 0, y: 0, width: 330, height: 400),
```

with:

```swift
                contentRect: NSRect(x: 0, y: 0, width: 330, height: 480),
```

And replace this line:

```swift
            window.contentViewController = NSHostingController(rootView: SettingsView())
```

with:

```swift
            window.contentViewController = NSHostingController(rootView: SettingsView(model: model))
```

- [ ] **Step 4: Build and verify**

Run: `swift build`
Expected: `Build complete!` with no errors.

- [ ] **Step 5: Commit**

```bash
git add HelioBarApp/Views/Components/SignalBars.swift \
        HelioBarApp/Views/SettingsView.swift \
        HelioBarApp/HelioBarApp.swift
git commit -m "feat(ui): Settings Device section with strap picker"
```

---

### Task 4: Popover device hint (UI)

**Invoke the `swiftui-expert-skill` first.**

Adds the subtle connected-strap line / "Choose your strap" prompt under the status badge.

**Files:**
- Create: `HelioBarApp/Views/Components/DeviceHint.swift`
- Modify: `HelioBarApp/Views/MenuContentView.swift`

**Interfaces:**
- Consumes: `store.connectedDevice`, `store.rememberedDeviceName`, `store.needsDeviceChoice`, the existing `onSettings` closure, `Theme`.
- Produces: `DeviceHint(connectedName: String?, rememberedName: String?, needsChoice: Bool, onTap: () -> Void)`.

- [ ] **Step 1: Create `DeviceHint.swift`**

```swift
import SwiftUI

/// A small line under the status badge: the connected strap (tap to switch),
/// a "looking for…" note, or a "choose your strap" prompt on first run.
struct DeviceHint: View {
    let connectedName: String?
    let rememberedName: String?
    let needsChoice: Bool
    var onTap: () -> Void

    var body: some View {
        if needsChoice {
            row(text: "Choose your strap", icon: "exclamationmark.circle.fill", tint: Theme.elevated)
        } else if let name = connectedName {
            row(text: name, icon: "dot.radiowaves.left.and.right", tint: .secondary)
        } else if let name = rememberedName {
            row(text: "Looking for \(name)…", icon: "dot.radiowaves.left.and.right", tint: .secondary)
        }
    }

    private func row(text: String, icon: String, tint: Color) -> some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10))
                Text(text).font(.system(size: 11, weight: .medium, design: .rounded)).lineLimit(1)
                Image(systemName: "chevron.right").font(.system(size: 8)).opacity(0.6)
            }
            .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
    }
}

#if !SWIFT_PACKAGE
#Preview {
    VStack(spacing: 10) {
        DeviceHint(connectedName: "Helio Strap", rememberedName: nil, needsChoice: false, onTap: {})
        DeviceHint(connectedName: nil, rememberedName: "Helio Strap", needsChoice: false, onTap: {})
        DeviceHint(connectedName: nil, rememberedName: nil, needsChoice: true, onTap: {})
    }
    .padding().background(.black)
}
#endif
```

- [ ] **Step 2: Add `DeviceHint` to the popover**

In `HelioBarApp/Views/MenuContentView.swift`, find this line inside `main`:

```swift
            StatusBadge(status: store.hrStatus)
```

and replace it with:

```swift
            StatusBadge(status: store.hrStatus)
            DeviceHint(connectedName: store.connectedDevice?.name,
                       rememberedName: store.rememberedDeviceName,
                       needsChoice: store.needsDeviceChoice,
                       onTap: onSettings)
```

- [ ] **Step 3: Build and verify**

Run: `swift build`
Expected: `Build complete!` (the existing `#Preview`s in `MenuContentView` still compile — the new `HealthStore` fields default to empty/nil, so `DeviceHint` renders nothing there).

- [ ] **Step 4: Commit**

```bash
git add HelioBarApp/Views/Components/DeviceHint.swift \
        HelioBarApp/Views/MenuContentView.swift
git commit -m "feat(ui): popover device hint + choose-your-strap prompt"
```

---

### Task 5: Manual real-strap verification

The CoreBluetooth shell isn't unit-tested, so verify behavior on hardware. This task has no code; it's an acceptance checklist (spec §8).

- [ ] **Step 1: Build, install, and launch**

Run: `./scripts/install-and-run.sh`
Expected: builds release, installs to `~/Applications/HelioBar.app`, codesigns, launches. The menu-bar pill appears.

- [ ] **Step 2: Single-strap silent connect (zero-config)**

With one strap broadcasting (Heart Rate Push enabled in Zepp) and no prior selection (run `defaults delete com.helio.HelioBar selectedDeviceID` first to simulate first run):
- Expected: within a few seconds the pill shows live BPM; the popover hint shows the strap name; Settings → Device shows it connected with a ✓.

- [ ] **Step 3: Two-strap prompt + pick + persistence**

With two straps broadcasting:
- Expected: the popover shows **"Choose your strap"** instead of silently connecting. Open Settings → Device, confirm both appear with signal bars + distinct ID suffixes, pick yours. The pill goes live. Quit and relaunch — it reconnects to the same strap with no prompt.

- [ ] **Step 4: Reconnect only to remembered (the bug fix)**

While connected to your strap, sleep/wake the Mac (or toggle Bluetooth off/on):
- Expected: it reconnects to **your** strap. With the other strap also present, it must not switch to it. If your strap is powered off, the hint shows **"Looking for <name>…"** and it does **not** connect to the other strap.

- [ ] **Step 5: Forget / re-pick**

Settings → Device → "Forget / auto-pick":
- Expected: selection clears; with one strap it auto-reconnects + re-remembers; with two it prompts again.

- [ ] **Step 6: Record results**

Note any deviations. If all pass, the feature is complete. No commit (no code change in this task).

---

## Self-Review

- **Spec coverage:** remembered model (T1 engine + T2) ✓; first-run 1-vs-2+ (T1 tests + T2 `evaluate`) ✓; reconnect-only-to-remembered (T2 `connectToRemembered` on disconnect/fail) ✓; `retrievePeripherals` fast path (T2) ✓; Settings Device section w/ signal bars + idSuffix + Forget + scan on appear/stop on disappear (T3) ✓; popover hint + needsChoice + "Looking for…" (T4) ✓; persistence keys `selectedDeviceID`/`selectedDeviceName` (T2 `handleDeviceEvent`) ✓; edges: stale prune, BT-off unchanged, identical-name disambiguation, power-aware scanning (T2/T3) ✓; tests (T1) ✓; out-of-scope respected ✓; swiftui-expert-skill on UI tasks ✓.
- **Type consistency:** `DiscoveredDevice`, `DeviceEvent`, `DeviceSelectionEngine.decide`, the `HeartRateMonitor` init/methods, `AppModel` methods, `HealthStore` fields, `DeviceHint`/`SignalBars`/`SettingsView(model:)` signatures match across all tasks.
- **Placeholders:** none — every step has full code and exact commands.
