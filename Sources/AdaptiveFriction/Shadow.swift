/// How shadow evaluation is wired.
///
/// The evaluator can return two model versions for one call. Exactly one of
/// them *drives* the decision; the other is *observed*, and the two decisions
/// are diffed. A product team that tuned `FrictionMatrix` against the prior
/// model keeps driving on `.prior` and observes `.current` until the ledger
/// says the two agree closely enough to promote; a team that trusts the
/// platform's newest model drives on `.current` and observes `.prior` to see
/// what changed.
public struct ShadowConfiguration: Sendable, Hashable {
    public let driver: ModelSelector
    public let observer: ModelSelector
    /// Disagreements above this rate (upper bound of the 95% Wilson interval)
    /// block promotion.
    public let disagreementTolerance: Double
    /// Below this many comparable samples the verdict is `insufficientSamples`.
    ///
    /// Defaults to the smallest sample count at which *zero* disagreements
    /// would clear the tolerance — 73 at 5%. Below that, a perfect record is
    /// not evidence: the 95% Wilson upper bound for 0/30 is 11.4%, so a floor
    /// of 30 would sit in a band where the verdict can only ever be `blocked`.
    public let minimumSamples: Int

    /// - Throws: `PolicyError.shadowSelectorsMustDiffer` if `driver == observer`;
    ///   `PolicyError.invalidConfiguration` for a tolerance outside `(0, 1]` or
    ///   a non-positive sample floor.
    public init(driver: ModelSelector, observer: ModelSelector,
                disagreementTolerance: Double = 0.05, minimumSamples: Int? = nil) throws {
        guard driver != observer else { throw PolicyError.shadowSelectorsMustDiffer }
        guard disagreementTolerance.isFinite, disagreementTolerance > 0, disagreementTolerance <= 1 else {
            throw PolicyError.invalidConfiguration("disagreementTolerance must be in (0, 1], got \(disagreementTolerance)")
        }
        let floor = minimumSamples ?? Self.samplesToClear(tolerance: disagreementTolerance)
        guard floor > 0 else {
            throw PolicyError.invalidConfiguration("minimumSamples must be > 0, got \(floor)")
        }
        self.driver = driver
        self.observer = observer
        self.disagreementTolerance = disagreementTolerance
        self.minimumSamples = floor
    }

    /// The smallest `n` for which the Wilson upper bound of `0/n` is within
    /// `tolerance`: `ceil(z² · (1 − t) / t)`. Returns 1 for a tolerance that
    /// is not in `(0, 1]` so a caller can never receive a non-positive floor.
    public static func samplesToClear(tolerance: Double, z: Double = 1.96) -> Int {
        guard tolerance.isFinite, tolerance > 0, tolerance <= 1, z.isFinite, z > 0 else { return 1 }
        let raw = (z * z * (1 - tolerance) / tolerance).rounded(.up)
        // `raw` is finite and non-negative here; cap before converting so an
        // absurd tolerance cannot make `Int(_:)` trap.
        let capped = min(raw, Double(Int32.max))
        return max(1, Int(capped))
    }
}

/// One side-by-side result. Both levels are computed through the *same*
/// matrix and the *same* band, so a difference here is attributable to the
/// model, not to the policy.
public struct ShadowComparison: Sendable, Hashable, Codable {
    public let band: RiskBand
    public let driverSignal: CoachingSignal
    public let observerSignal: CoachingSignal
    public let driverLevel: FrictionLevel
    public let observerLevel: FrictionLevel

    public var agrees: Bool { driverLevel == observerLevel }
    /// The observed model would have applied *more* friction than the driver.
    public var observerEscalates: Bool { observerLevel > driverLevel }
    /// The observed model would have applied *less* friction than the driver.
    public var observerRelaxes: Bool { observerLevel < driverLevel }
}

public enum PromotionVerdict: Sendable, Hashable {
    case insufficientSamples(have: Int, need: Int)
    /// The observed model can replace the driver: the disagreement rate's
    /// upper bound is within tolerance.
    case promotable(disagreement: ProportionInterval)
    /// Not yet: the upper bound exceeds tolerance.
    case blocked(disagreement: ProportionInterval)
}

/// Aggregates shadow comparisons and answers "can the observed model drive?".
///
/// Also counts evaluations where the observer was requested but unavailable,
/// because a model that is missing 30% of the time is not promotable however
/// well it agrees when present.
public struct ShadowLedger: Sendable, Hashable {
    public private(set) var comparisons = 0
    public private(set) var agreements = 0
    public private(set) var escalations = 0
    public private(set) var relaxations = 0
    public private(set) var observerUnavailable = 0

    public init() {}

    public mutating func record(_ comparison: ShadowComparison) {
        comparisons = saturatingAdd(comparisons, 1)
        if comparison.agrees {
            agreements = saturatingAdd(agreements, 1)
        } else if comparison.observerEscalates {
            escalations = saturatingAdd(escalations, 1)
        } else {
            relaxations = saturatingAdd(relaxations, 1)
        }
    }

    public mutating func recordObserverUnavailable() {
        observerUnavailable = saturatingAdd(observerUnavailable, 1)
    }

    public var disagreements: Int { escalations + relaxations }

    public func verdict(_ configuration: ShadowConfiguration) -> PromotionVerdict {
        guard comparisons >= configuration.minimumSamples,
              let interval = wilsonInterval(successes: disagreements, trials: comparisons) else {
            return .insufficientSamples(have: comparisons, need: configuration.minimumSamples)
        }
        if interval.upper <= configuration.disagreementTolerance {
            return .promotable(disagreement: interval)
        }
        return .blocked(disagreement: interval)
    }
}
