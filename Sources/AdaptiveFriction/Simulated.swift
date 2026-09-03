/// What `SimulatedInsightSource` does on the next `evaluate`.
public struct SimulatedBehaviour: Sendable, Hashable {
    public enum Availability: Sendable, Hashable {
        case available
        case unavailable(SignalUnavailableReason)
    }

    public var availability: Availability
    public var signal: CoachingSignal
    /// What the prior model answers when asked. `nil` means the prior model
    /// is unavailable on this device (the platform keeps only one previous
    /// version, and not always).
    public var priorSignal: CoachingSignal?
    public var latency: Duration
    public var currentVersion: ModelVersion
    public var priorVersion: ModelVersion

    public init(availability: Availability = .available,
                signal: CoachingSignal = .unknown,
                priorSignal: CoachingSignal? = nil,
                latency: Duration = .milliseconds(20),
                currentVersion: ModelVersion = ModelVersion("sim-2026.09"),
                priorVersion: ModelVersion = ModelVersion("sim-2026.06")) {
        self.availability = availability
        self.signal = signal
        self.priorSignal = priorSignal
        self.latency = max(.zero, latency)
        self.currentVersion = currentVersion
        self.priorVersion = priorVersion
    }
}

/// A scriptable stand-in for the platform evaluator.
///
/// Exists so that the policy, the tests and the demo can exercise every
/// availability state, both model versions, arbitrary latency, and the
/// consumption-reporting contract without an entitlement, a network, or a
/// device. It records every request and every report so tests can assert on
/// the exact sequence.
public actor SimulatedInsightSource: InsightSource {
    public private(set) var behaviour: SimulatedBehaviour
    public private(set) var requests: [InsightRequest] = []
    public private(set) var reports: [ConsumptionReport] = []
    private var nextID = 0

    public init(_ behaviour: SimulatedBehaviour = SimulatedBehaviour()) {
        self.behaviour = behaviour
    }

    public func set(_ behaviour: SimulatedBehaviour) {
        self.behaviour = behaviour
    }

    public func evaluate(_ request: InsightRequest) async throws -> InsightResponse {
        requests.append(request)
        let behaviour = self.behaviour
        if behaviour.latency > .zero {
            // Honour the contract: a cancelled evaluation produces nothing.
            try await Task.sleep(for: behaviour.latency)
        }
        try Task.checkCancellation()
        if case .unavailable(let reason) = behaviour.availability {
            throw InsightUnavailable(reason)
        }
        nextID = saturatingAdd(nextID, 1)
        let prior: SignalOutcome?
        if request.versions.contains(.prior) {
            if let priorSignal = behaviour.priorSignal {
                prior = .evaluated(priorSignal, behaviour.priorVersion)
            } else {
                prior = .unavailable(.failed("prior model not present on this device"))
            }
        } else {
            prior = nil
        }
        return InsightResponse(id: EvaluationID("sim-\(nextID)"),
                               signal: behaviour.signal,
                               modelVersion: behaviour.currentVersion,
                               prior: prior)
    }

    public func reportConsumption(_ report: ConsumptionReport) {
        reports.append(report)
    }

    /// Evaluations that returned but have no report yet — the thing the
    /// platform rate-limits on.
    public var unreportedIDs: [EvaluationID] {
        let reported = Set(reports.map(\.id))
        return (0..<nextID).compactMap { index -> EvaluationID? in
            let id = EvaluationID("sim-\(index + 1)")
            return reported.contains(id) ? nil : id
        }
    }
}
