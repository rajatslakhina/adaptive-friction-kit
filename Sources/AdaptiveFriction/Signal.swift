/// The kind of sensitive operation being evaluated.
///
/// Mirrors the categories the platform's coaching-risk evaluator accepts
/// (`payment`, `account`, `resourceUse`, `communication`, `other`) so that a
/// policy can be written once per category and the adapter is a straight map.
public enum OperationCategory: String, Sendable, CaseIterable, Codable, Hashable {
    case payment
    case account
    case resourceUse
    case communication
    case other
}

/// The platform's answer to "is this authenticated user likely being coached?"
///
/// The ordering matters and is load-bearing for `FrictionMatrix`: `unknown`
/// is the *floor*, not a class label. It means "no evidence was found", never
/// "safe". Every rule in this package that consumes a signal is written so that
/// `unknown` produces exactly the friction the app would apply on its own risk
/// score alone, and `medium`/`high` can only add to it.
public enum CoachingSignal: Int, Sendable, CaseIterable, Codable, Hashable, Comparable {
    /// No evidence found. Not "safe".
    case unknown = 0
    case medium = 1
    case high = 2

    public static func < (lhs: CoachingSignal, rhs: CoachingSignal) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// An opaque identifier for the on-device model that produced a signal.
///
/// Two versions can be requested for one evaluation (the current model and the
/// one before it) so that a policy tuned against the prior model can be
/// shadow-evaluated against the current one before it is promoted.
public struct ModelVersion: Sendable, Hashable, Codable, CustomStringConvertible {
    public let identifier: String

    public init(_ identifier: String) {
        self.identifier = identifier
    }

    public var description: String { identifier }
}

/// Which of the two evaluator-supplied models a policy component refers to.
public enum ModelSelector: String, Sendable, CaseIterable, Codable, Hashable {
    case current
    case prior
}

/// Why a signal could not be obtained.
///
/// Every case here is a *normal* operating state, not an error. A production
/// sensitive flow sees all of them regularly, which is why `RiskPolicy` never
/// throws on them and instead records them as the basis of a fail-open
/// decision.
public enum SignalUnavailableReason: Sendable, Hashable, Codable {
    /// The app is not entitled to the evaluator. Permanent for this install.
    case entitlementMissing
    /// The user revoked authorization; the platform enforces a cooldown before
    /// it will accept a new authorization request.
    case notAuthorized(cooldown: Duration?)
    /// The evaluator needs network reachability and had none.
    case offline
    /// The platform rate-limited the app (typically because evaluations were
    /// not being reported as consumed).
    case rateLimited
    /// The policy's own deadline elapsed before the evaluator answered.
    case timedOut
    /// The surrounding task was cancelled.
    case cancelled
    /// The policy refused to start an evaluation because too many earlier
    /// evaluations are still unreported. See `RiskPolicyConfiguration`.
    case localBackpressure
    /// Any other evaluator failure, described.
    case failed(String)
}

/// The outcome of asking one model version for a signal.
public enum SignalOutcome: Sendable, Hashable, Codable {
    case evaluated(CoachingSignal, ModelVersion)
    case unavailable(SignalUnavailableReason)

    /// The signal, if one was produced.
    public var signal: CoachingSignal? {
        if case .evaluated(let signal, _) = self { return signal }
        return nil
    }
}
