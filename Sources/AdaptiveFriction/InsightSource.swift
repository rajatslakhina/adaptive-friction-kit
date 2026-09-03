/// An opaque handle the source hands back so a consumption report can be tied
/// to the evaluation it consumes.
public struct EvaluationID: Sendable, Hashable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

/// What the policy asks a source for.
public struct InsightRequest: Sendable, Hashable {
    public let category: OperationCategory
    /// Which model versions to evaluate. Always contains `.current`; contains
    /// `.prior` as well when shadow evaluation is enabled.
    public let versions: Set<ModelSelector>

    public init(category: OperationCategory, versions: Set<ModelSelector>) {
        self.category = category
        self.versions = versions.union([.current])
    }
}

/// What a source answers with when the current model produced a signal.
///
/// `prior` is `nil` when it was not requested. When it *was* requested and the
/// source could not evaluate it, the source answers `.unavailable` for it
/// rather than dropping it, so "not asked" and "asked, failed" stay distinct
/// in the shadow ledger.
public struct InsightResponse: Sendable, Hashable {
    public let id: EvaluationID
    public let signal: CoachingSignal
    public let modelVersion: ModelVersion
    public let prior: SignalOutcome?

    public init(id: EvaluationID, signal: CoachingSignal, modelVersion: ModelVersion, prior: SignalOutcome? = nil) {
        self.id = id
        self.signal = signal
        self.modelVersion = modelVersion
        self.prior = prior
    }
}

/// Thrown by a source when the current model cannot be evaluated at all. No
/// evaluation was produced, so nothing needs to be reported.
public struct InsightUnavailable: Error, Sendable, Hashable {
    public let reason: SignalUnavailableReason

    public init(_ reason: SignalUnavailableReason) {
        self.reason = reason
    }
}

/// What the app did with an evaluation. The platform requires one of these for
/// every evaluation it produced; the policy guarantees exactly one is sent.
public enum ConsumptionOutcome: Sendable, Hashable, Codable {
    /// The decision was driven by the signal and friction was applied.
    case appliedFriction(FrictionLevel)
    /// The decision was driven by the signal and the operation proceeded
    /// without added friction.
    case proceeded
    /// The evaluation was requested only to observe (shadow) and did not drive
    /// the decision.
    case usedEvaluationOnly
    /// The evaluation went out of scope without the app reporting what it did.
    /// `InsightEvaluation.deinit` sends this so the platform is never left
    /// waiting, and the ledger counts it as a defect.
    case discardedUnreported
}

public struct ConsumptionReport: Sendable, Hashable, Codable {
    public let id: EvaluationID
    public let outcome: ConsumptionOutcome

    public init(id: EvaluationID, outcome: ConsumptionOutcome) {
        self.id = id
        self.outcome = outcome
    }
}

/// The seam between this package and the platform evaluator.
///
/// The real adapter wraps the platform's evaluator (see the README for the
/// shape); the package ships `SimulatedInsightSource` so the policy, the tests
/// and the demo can exercise all nine QA states without an entitlement, a
/// network, or an iOS 27 device.
///
/// Contract:
/// - `evaluate` must honour task cancellation promptly; a cancelled call has
///   produced nothing and needs no consumption report.
/// - `evaluate` throws `InsightUnavailable` for every normal "no signal"
///   state (no entitlement, not authorized, offline, rate-limited). Those are
///   not failures of the policy and `RiskPolicy` fails open on them.
/// - Every non-cancelled `evaluate` that returns must eventually be followed by
///   exactly one `reportConsumption` for its `id`. `RiskPolicy` enforces this
///   with `InsightEvaluation`.
public protocol InsightSource: Sendable {
    func evaluate(_ request: InsightRequest) async throws -> InsightResponse
    func reportConsumption(_ report: ConsumptionReport) async
}
