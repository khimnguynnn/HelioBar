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
