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
