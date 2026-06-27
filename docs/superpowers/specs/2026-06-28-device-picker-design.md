# Device Picker — Design Spec

> Date: 2026-06-28
> Status: Approved design, pre-implementation
> Scope: Multi-strap selection + remembered-device reconnection. Touches `HeartRateMonitor`, `AppModel`, `SettingsView`, the popover, and adds pure logic + tests to `HelioCore`.

---

## 1. Goal

Today HelioBar connects to the **first** Bluetooth peripheral it sees advertising
the standard Heart Rate service (`180D`), and on every disconnect it re-scans and
again grabs whatever appears first (`HeartRateMonitor.swift`, `didDiscover` lines
47–55 and the disconnect/fail handlers lines 62–74). In a household with two Helio
straps this is a coin flip — the most-upvoted concrete complaint on the launch
threads (u/Material-Garage-4036: *"it sometimes connects to her device"*).

Let the user connect to **their** strap and have HelioBar remember it. Concretely:

- First launch stays **zero-config** for the ~95% with a single strap.
- A household with multiple straps gets to **choose**, and the choice **persists**.
- Reconnection after sleep/disconnect only ever returns to the **remembered** strap
  — never substitutes another one.
- Because the scan targets the generic `180D` service, the resulting picker also
  lists any HR broadcaster (T-Rex 3, Amazfit watches in HR-push mode), which
  quietly satisfies the "does it work with my other device" requests too.

This is primarily a **connection-policy** change. The HR/battery parsing
(`HeartRatePacket`), the `HealthStore`, alert engines, and battery estimate are
**not** modified.

> **UI work MUST use the `swiftui-expert-skill`** (Settings section + popover hint),
> consistent with the UI-redesign spec. Invoke it at the start of the UI tasks;
> follow its state-management, view-composition, and latest-API guidance.

---

## 2. Decisions (locked)

| Decision | Choice | Rationale |
|---|---|---|
| Connection model | **Remember my strap** | User selection. Zero-config single-strap; fixes wrong-strap for couples |
| Picker placement | **Settings "Device" section + subtle popover hint** | User selection. Keeps popover calm; makes a wrong pick noticeable + one-click fixable |
| First-run auto-pick | **Auto-connect only when exactly ONE device is found; prompt when 2+** | Couple-safe from the very first launch — never silently remember the wrong strap |
| Reconnect policy | **Wait, don't substitute** — only reconnect to the remembered UUID | The actual bug fix; a missing strap shows "Looking for…", not a wrong-grab |
| Disambiguation | **Signal bars + last-4 of device UUID** in the list | BLE names can be identical ("Helio Strap"); RSSI + ID suffix distinguish them |
| Decision logic location | **Pure `DeviceSelectionEngine` in `HelioCore` (unit-tested)** | Mirrors existing engine pattern; keeps the CoreBluetooth shell thin/untested |
| Persistence | UserDefaults `selectedDeviceID`, `selectedDeviceName` | Matches existing settings-persistence approach |

---

## 3. Behavior / states

**Launch with a remembered strap (the common case):**
1. On `centralManagerDidUpdateState(.poweredOn)`, if `selectedDeviceID` exists, try
   `central.retrievePeripherals(withIdentifiers:)`. If the system returns it,
   connect directly (no scan). Otherwise scan and connect **only** when a peripheral
   with the remembered UUID is discovered (status meanwhile: *"Looking for <name>…"*).

**First launch / after Forget (no remembered strap):**
2. Scan and collect candidates for a **settle window (3s)**, then:
   - exactly **1** device → connect to it and persist it as remembered (silent, zero-config);
   - **2+** devices → do **not** guess: set `needsDeviceChoice`, surface a
     "Choose your strap" prompt in the popover (and the Settings Device list stays
     live). Remember whichever the user picks.

**Reconnect after disconnect/sleep/failure:**
3. Re-scan but reconnect **only** to the remembered UUID. Never connect to a
   different strap automatically.

**Switch / forget (Settings → Device):**
4. Selecting a device persists it and reconnects to it. "Forget" clears the
   selection and returns to first-run behavior on the next scan.

---

## 4. Architecture

### 4.1 `HelioCore` — new, pure, tested

**`DiscoveredDevice` (new file `Sources/HelioCore/DiscoveredDevice.swift`)**

```swift
public struct DiscoveredDevice: Identifiable, Equatable, Sendable {
    public let id: UUID        // CBPeripheral.identifier (stable per-Mac across launches)
    public var name: String    // peripheral.name ?? "Unknown HR device"
    public var rssi: Int       // dBm; used only for display sorting + signal bars
    public var lastSeen: Date

    public init(id: UUID, name: String, rssi: Int, lastSeen: Date)

    /// 0–3 bars from dBm, for the picker. Pure, testable.
    public var signalBars: Int { /* ≥ -55:3, ≥ -70:2, ≥ -85:1, else 0 */ }
    /// Last 4 chars of the UUID, e.g. "…3F1A", to disambiguate identical names.
    public var idSuffix: String { String(id.uuidString.suffix(4)) }
}
```

**`DeviceSelectionEngine` (new file `Sources/HelioCore/DeviceSelectionEngine.swift`)**

```swift
public enum DeviceDecision: Equatable, Sendable {
    case connect(UUID)     // connect now (shell persists if this was a first-run auto-pick)
    case awaitRemembered   // remembered device known but not visible — keep scanning, do nothing else
    case needsUserChoice   // first run, 2+ candidates — prompt the user
    case idle              // nothing actionable yet
}

public struct DeviceSelectionEngine {
    public var rememberedID: UUID?
    public init(rememberedID: UUID?)

    public func decide(candidates: [DiscoveredDevice],
                       scanStarted: Date,
                       now: Date,
                       settleWindow: TimeInterval = 3) -> DeviceDecision
}
```

**Decision rules** (the whole point of isolating this):
- `rememberedID != nil`: candidate with that id present → `.connect(rememberedID)`; else `.awaitRemembered`.
- `rememberedID == nil`: empty candidates → `.idle`; within settle window → `.idle`;
  after settle → exactly 1 → `.connect(that)`, 2+ → `.needsUserChoice`.

The engine never uses RSSI to *choose* (we prompt instead of auto-picking among
many); RSSI only drives display ordering and `signalBars`.

### 4.2 `HeartRateMonitor.swift` (app target) — rewrite the policy

- Maintain a registry while scanning: `candidates: [UUID: (DiscoveredDevice, CBPeripheral)]`,
  updated in `didDiscover` (name, rssi, lastSeen). Prune entries not seen for ~10s so
  the picker reflects reality.
- Track `scanStartedAt`. On scan start, schedule a one-shot timer at `settleWindow`
  that calls `evaluate()`; also call `evaluate()` on each `didDiscover` (fast path for
  an immediately-visible remembered device).
- `evaluate()` runs `DeviceSelectionEngine.decide(...)` and acts:
  - `.connect(id)` → keep a strong ref to that `CBPeripheral`, `stopScan()`, `connect()`;
    if it was a first-run single-device pick, persist remembered + update `engine.rememberedID`.
  - `.awaitRemembered` / `.idle` → keep scanning; ensure not connected to anything else.
  - `.needsUserChoice` → stop auto-connecting, fire `onNeedsChoice(true)`, keep scanning.
- Launch fast-path: at `.poweredOn`, if `rememberedID` set, try
  `retrievePeripherals(withIdentifiers:)` → connect directly if present, else scan + await.
- New public API:
  - `func select(deviceID: UUID)` — set+persist remembered, disconnect any current, connect chosen.
  - `func forget()` — clear remembered + persisted keys, disconnect, restart first-run scan.
  - `func rescan()` / `func stopDeviceScan()` — refresh/stop the picker list (used by Settings open/close).
  - callbacks: `onDevicesChanged: ([DiscoveredDevice]) -> Void` (sorted by rssi desc),
    `onConnectedDevice: (DiscoveredDevice?) -> Void`, `onNeedsChoice: (Bool) -> Void`.
  - Existing `onConnected(Bool)` is retained (drives `HealthStore` live/stale status).
- Threading: `CBCentralManager(delegate:queue:nil)` already delivers callbacks on the
  main queue; timers scheduled on main. No new concurrency surface.

### 4.3 `AppModel.swift`

- New `@Observable` state: `discoveredDevices: [DiscoveredDevice]`,
  `connectedDevice: DiscoveredDevice?`, `needsDeviceChoice: Bool`.
- In `start()`: read `selectedDeviceID` from UserDefaults and pass into the monitor
  (`rememberedID`); wire the three new callbacks to update state on the main actor.
- New methods for the views: `selectDevice(_ id: UUID)`, `forgetDevice()`,
  `rescanDevices()`, `stopDeviceScan()`. `selectDevice`/`forgetDevice` write/clear the
  UserDefaults keys (`selectedDeviceID`, `selectedDeviceName`).

### 4.4 `SettingsView.swift`

- Inject `AppModel` (today the view only uses `@AppStorage`). The Settings window is
  built in `HelioBarApp.swift`, so pass the existing model into the hosting view.
- Add a **"Device"** `Section` (e.g. `Label("Device", systemImage: "dot.radiowaves.left.and.right")`):
  - If `connectedDevice != nil`: a "connected" row (name · signal · ✓).
  - The `discoveredDevices` list — each row: signal bars · name · `…idSuffix` · ✓ when
    connected; tapping calls `model.selectDevice(id)`.
  - A "Forget / auto-pick" button → `model.forgetDevice()`.
  - `.onAppear { model.rescanDevices() }`, `.onDisappear { model.stopDeviceScan() }`,
    plus an optional Refresh button.
- Bump the window height (~330×480) to fit the new section; `Form` scrolls regardless.

### 4.5 Popover — `MenuContentView.swift` + new `Views/Components/DeviceHint.swift`

- A subtle hint near the existing `StatusBadge`: `connectedDevice?.name ?? "No strap"`
  with a chevron; action opens Settings (reuse the existing Settings-open path; scroll
  to the Device section if feasible, otherwise just open Settings).
- When `needsDeviceChoice == true`, show a prominent **"Choose your strap →"** prompt
  in place of the hint, opening Settings → Device.

### 4.6 `HelioBarApp.swift`

- Pass the `AppModel` into `SettingsView` when constructing the Settings `NSWindow`
  hosting view. Optionally support opening Settings focused on the Device section
  (nice-to-have; a simple "open Settings" is acceptable).

---

## 5. Data flow

- scan → registry → `onDevicesChanged` → `AppModel.discoveredDevices` → Settings list
- user taps → `AppModel.selectDevice` → `monitor.select` (persist + reconnect) →
  `onConnectedDevice` → popover hint + Settings ✓
- disconnect → re-scan → reconnect **only** to remembered
- first run, 2+ devices → `onNeedsChoice(true)` → `AppModel.needsDeviceChoice` →
  popover "Choose your strap" prompt

---

## 6. Persistence (UserDefaults.standard)

| Key | Type | Meaning |
|---|---|---|
| `selectedDeviceID` | `String` (UUID) | Remembered peripheral identifier; empty/absent = auto-pick mode |
| `selectedDeviceName` | `String` | Last known name, shown before a connection exists |

---

## 7. Edge cases

- **Remembered strap dead / out of range** → status *"Looking for <name>…"*; never grabs another.
- **Single strap (~95%)** → first run auto-connects + remembers silently; behaves like today.
- **Identical BLE names** → signal bars + `…idSuffix` disambiguate in the list.
- **Bluetooth off / unauthorized** → existing `onUnavailable` handling unchanged.
- **Stale list** → prune candidates not seen for ~10s so departed straps disappear.
- **Forget while connected** → disconnect, then re-enter first-run logic.
- **Identifier stability** → CB `identifier` is stable per-Mac across launches, so the
  remembered UUID survives restarts (it is *not* the BLE MAC; that's fine here).
- **Power** → scan only while (a) hunting the remembered device pre-connect, or (b) the
  Settings Device section is open; stop scanning once connected.

---

## 8. Testing

`HelioCore/Tests/HelioCoreTests/DeviceSelectionEngineTests.swift` (TDD, pure):

- remembered present in candidates → `.connect(remembered)`
- remembered absent (even with other devices present) → `.awaitRemembered` (never substitute)
- no remembered, empty → `.idle`
- no remembered, 1 candidate, within settle window → `.idle`; after settle → `.connect(that)`
- no remembered, 2+ candidates within settle → `.idle`; after settle → `.needsUserChoice`
- `DiscoveredDevice.signalBars` thresholds and `idSuffix` formatting

The CoreBluetooth `HeartRateMonitor` shell stays thin and is verified **manually with
real straps** (single-strap silent connect; two-strap prompt + switch; sleep/wake
reconnect to the remembered one) — matching the repo's current "no tests on the BLE
layer" strategy.

---

## 9. Out of scope (YAGNI)

- Simultaneous connection to more than one strap.
- Device nicknames / renaming.
- Background scanning beyond reconnecting to the remembered device.
- Battery % in the pre-connect list (battery is only readable once connected).

---

## 10. Implementation sequence

1. `HelioCore`: `DiscoveredDevice` + `DeviceSelectionEngine` + tests (TDD).
2. `HeartRateMonitor`: registry + engine-driven policy + new API/callbacks + retrieve-on-launch.
3. `AppModel`: state, persistence, `select`/`forget`/`rescan`/`stopDeviceScan`, callback wiring.
4. `SettingsView`: inject `AppModel`; add the Device section (`swiftui-expert-skill`).
5. Popover `DeviceHint` + `needsDeviceChoice` prompt (`swiftui-expert-skill`).
6. `HelioBarApp` wiring (inject model; optional open-to-Device).
7. Manual real-strap verification per §8.
