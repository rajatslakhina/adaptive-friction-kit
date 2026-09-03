import XCTest
@testable import AdaptiveFriction

/// Signals that land in each band with `BandThresholds.standard`
/// (elevated ≥ 0.35, high ≥ 0.70).
enum Fixtures {
    static func signals(for band: RiskBand) -> [RiskSignal] {
        switch band {
        case .low:      return [try! RiskSignal(name: "new-payee", weight: 0.20, present: true)]
        case .elevated: return [try! RiskSignal(name: "new-payee", weight: 0.20, present: true),
                                try! RiskSignal(name: "first-large-transfer", weight: 0.25, present: true)]
        case .high:     return [try! RiskSignal(name: "new-payee", weight: 0.20, present: true),
                                try! RiskSignal(name: "first-large-transfer", weight: 0.25, present: true),
                                try! RiskSignal(name: "password-changed-today", weight: 0.30, present: true)]
        }
    }

    static func operation(_ id: String = "op-1", band: RiskBand = .low,
                          category: OperationCategory = .payment) -> SensitiveOperation {
        SensitiveOperation(id: id, category: category, signals: signals(for: band))
    }

    static func policy(_ behaviour: SimulatedBehaviour,
                       deadline: Duration = .seconds(2),
                       shadow: ShadowConfiguration? = nil,
                       maxOutstanding: Int = 8,
                       retryAfter: Duration = .seconds(30),
                       audit: InMemoryAuditSink = InMemoryAuditSink()) throws
    -> (RiskPolicy, SimulatedInsightSource) {
        let source = SimulatedInsightSource(behaviour)
        let configuration = try RiskPolicyConfiguration(deadline: deadline, shadow: shadow,
                                                        maxOutstandingEvaluations: maxOutstanding,
                                                        transientRetryAfter: retryAfter)
        return (RiskPolicy(configuration: configuration, source: source, audit: audit), source)
    }
}

final class RecordingReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ConsumptionReport] = []

    var reports: [ConsumptionReport] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func record(_ report: ConsumptionReport) {
        lock.lock(); defer { lock.unlock() }
        storage.append(report)
    }
}
