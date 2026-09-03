/// The thing being decided on. Carries no amount, payee or account: the
/// policy needs the category and the app's *risk signals*, nothing else.
public struct SensitiveOperation: Sendable, Hashable {
    public let id: String
    public let category: OperationCategory
    public let signals: [RiskSignal]

    public init(id: String, category: OperationCategory, signals: [RiskSignal]) {
        self.id = id
        self.category = category
        self.signals = signals
    }
}

public enum DecisionBasis: Sendable, Hashable {
    /// The coaching signal from `selector`'s model was fused with the app's risk band.
    case fused(signal: CoachingSignal, model: ModelVersion, selector: ModelSelector)
    /// No signal was available for `reason`; the app's own band decided.
    /// `cached` is true when the unavailability was remembered from an earlier
    /// call and the evaluator was not contacted at all.
    case appRiskOnly(SignalUnavailableReason, cached: Bool)

    public var kind: DecisionBasisKind {
        switch self {
        case .fused: return .fused
        case .appRiskOnly: return .appRiskOnly
        }
    }
}

public struct FrictionDecision: Sendable, Hashable {
    public let operationID: String
    public let category: OperationCategory
    public let score: RiskScore
    public let band: RiskBand
    /// What the app would have applied on its own evidence alone.
    public let floor: FrictionLevel
    /// What to apply.
    public let level: FrictionLevel
    public let basis: DecisionBasis
    public let shadow: ShadowComparison?
    public let elapsed: Duration
}

public struct RiskPolicyConfiguration: Sendable {
    public let matrix: FrictionMatrix
    public let thresholds: BandThresholds
    /// Hard budget for one evaluator call. The review screen is waiting.
    public let deadline: Duration
    /// `nil` disables shadow evaluation (only `.current` is requested).
    public let shadow: ShadowConfiguration?
    /// Evaluations that have returned but not yet been reported as consumed.
    /// Above this the policy stops calling the evaluator and fails open, which
    /// is the local, earlier version of the platform's own rate limit.
    public let maxOutstandingEvaluations: Int
    /// How long an `offline` or `rateLimited` answer is remembered before the
    /// evaluator is asked again.
    public let transientRetryAfter: Duration

    /// - Throws: `PolicyError.invalidConfiguration` for a non-positive
    ///   deadline, a sub-1 outstanding cap, or a negative retry interval.
    public init(matrix: FrictionMatrix = .standard,
                thresholds: BandThresholds = .standard,
                deadline: Duration = .seconds(3),
                shadow: ShadowConfiguration? = nil,
                maxOutstandingEvaluations: Int = 8,
                transientRetryAfter: Duration = .seconds(30)) throws {
        guard deadline > .zero else {
            throw PolicyError.invalidConfiguration("deadline must be positive, got \(deadline)")
        }
        guard maxOutstandingEvaluations >= 1 else {
            throw PolicyError.invalidConfiguration("maxOutstandingEvaluations must be >= 1, got \(maxOutstandingEvaluations)")
        }
        guard transientRetryAfter >= .zero else {
            throw PolicyError.invalidConfiguration("transientRetryAfter must be >= 0, got \(transientRetryAfter)")
        }
        self.matrix = matrix
        self.thresholds = thresholds
        self.deadline = deadline
        self.shadow = shadow
        self.maxOutstandingEvaluations = maxOutstandingEvaluations
        self.transientRetryAfter = transientRetryAfter
    }
}

/// Counts of what happened to evaluations. `discardedUnreported` is the
/// number of times the safety net in `InsightEvaluation.deinit` fired; in a
/// correct build it is zero and a test asserts that.
public struct ConsumptionLedger: Sendable, Hashable {
    public private(set) var outstanding = 0
    public private(set) var reported = 0
    public private(set) var discardedUnreported = 0

    public init() {}

    mutating func reserve() { outstanding = saturatingAdd(outstanding, 1) }
    mutating func release() { outstanding = max(0, outstanding - 1) }

    mutating func settle(_ outcome: ConsumptionOutcome) {
        release()
        reported = saturatingAdd(reported, 1)
        if outcome == .discardedUnreported {
            discardedUnreported = saturatingAdd(discardedUnreported, 1)
        }
    }
}

/// The policy layer between the platform's coaching-risk signal and the app's
/// sensitive flows.
///
/// An actor because it owns three pieces of mutable state that must be read
/// and written consistently across suspension points: the consumption ledger
/// (reserved *before* the evaluator is awaited, so concurrent callers see the
/// reservation), the shadow ledger, and the remembered unavailability. The
/// evaluator call itself is the only `await` inside `decide`, and every
/// ledger read that feeds a decision happens either before it or after it —
/// never across it.
public actor RiskPolicy {
    public let configuration: RiskPolicyConfiguration
    private let source: any InsightSource
    private let scorer: any AppRiskScorer
    private let audit: any AuditSink
    private let clock = ContinuousClock()

    public private(set) var ledger = ConsumptionLedger()
    public private(set) var shadowLedger = ShadowLedger()
    private var remembered: RememberedUnavailability?

    public init(configuration: RiskPolicyConfiguration,
                source: any InsightSource,
                scorer: any AppRiskScorer = WeightedRiskScorer(),
                audit: any AuditSink = InMemoryAuditSink()) {
        self.configuration = configuration
        self.source = source
        self.scorer = scorer
        self.audit = audit
    }

    // MARK: Decide

    public func decide(_ operation: SensitiveOperation) async -> FrictionDecision {
        let started = clock.now
        let score = scorer.score(operation.signals)
        let band = configuration.thresholds.band(for: score)
        let floor = configuration.matrix.floor(band: band)

        if let remembered, remembered.isInForce(at: clock.now) {
            return await finish(operation, score: score, band: band, floor: floor,
                                level: floor,
                                basis: .appRiskOnly(remembered.reason, cached: true),
                                shadow: nil, started: started)
        }
        remembered = nil

        guard ledger.outstanding < configuration.maxOutstandingEvaluations else {
            return await finish(operation, score: score, band: band, floor: floor,
                                level: floor,
                                basis: .appRiskOnly(.localBackpressure, cached: false),
                                shadow: nil, started: started)
        }

        var versions: Set<ModelSelector> = [.current]
        if let shadow = configuration.shadow {
            versions.insert(shadow.driver)
            versions.insert(shadow.observer)
        }
        let request = InsightRequest(category: operation.category, versions: versions)
        let source = self.source
        let deadline = configuration.deadline

        // Reserve before the await so a concurrent caller counts this call.
        ledger.reserve()
        let response: InsightResponse
        do {
            response = try await withDeadline(deadline, clock: clock) {
                try await source.evaluate(request)
            }
        } catch {
            // Nothing was produced: release the reservation, fail open.
            ledger.release()
            let reason = Self.reason(for: error)
            remember(reason)
            return await finish(operation, score: score, band: band, floor: floor,
                                level: floor,
                                basis: .appRiskOnly(reason, cached: false),
                                shadow: nil, started: started)
        }

        // From here on an evaluation exists and *must* be reported exactly once.
        let evaluation = InsightEvaluation(id: response.id, reporter: { [weak self] report in
            self?.enqueueReport(report)
        })
        let (level, basis, shadow) = fuse(response, band: band, evaluation: evaluation)
        return await finish(operation, score: score, band: band, floor: floor,
                            level: level, basis: basis, shadow: shadow, started: started)
    }

    /// Fusion is the only function that can see an `InsightEvaluation`, and
    /// it takes it by `consuming` ownership: every path out of here either
    /// reports it or lets `deinit` report `.discardedUnreported`, which the
    /// ledger counts and a test asserts is zero.
    private func fuse(_ response: InsightResponse, band: RiskBand,
                      evaluation: consuming InsightEvaluation)
    -> (FrictionLevel, DecisionBasis, ShadowComparison?) {
        let matrix = configuration.matrix

        // Resolve which model drives. Default: current. With shadow enabled,
        // the configured driver — falling back to the other model if the
        // driver was unavailable, and recording that in the basis.
        var driverSelector: ModelSelector = .current
        var driverSignal = response.signal
        var driverModel = response.modelVersion
        var comparison: ShadowComparison? = nil

        if let shadow = configuration.shadow {
            let priorSignal: (CoachingSignal, ModelVersion)?
            if case .evaluated(let signal, let model)? = response.prior {
                priorSignal = (signal, model)
            } else {
                priorSignal = nil
            }

            if shadow.driver == .prior, case let (signal, model)? = priorSignal {
                driverSelector = .prior
                driverSignal = signal
                driverModel = model
            }

            if case let (priorValue, _)? = priorSignal {
                let currentLevel = matrix.level(band: band, signal: response.signal)
                let priorLevel = matrix.level(band: band, signal: priorValue)
                let observed = shadow.observer == .prior
                    ? ShadowComparison(band: band, driverSignal: response.signal, observerSignal: priorValue,
                                       driverLevel: currentLevel, observerLevel: priorLevel)
                    : ShadowComparison(band: band, driverSignal: priorValue, observerSignal: response.signal,
                                       driverLevel: priorLevel, observerLevel: currentLevel)
                shadowLedger.record(observed)
                comparison = observed
            } else if shadow.observer == .prior {
                shadowLedger.recordObserverUnavailable()
            } else {
                // The prior model was the *driver* and is missing; the current
                // model drove instead (see above). That says nothing about the
                // observer, which was present.
                shadowLedger.recordDriverUnavailable()
            }
        }

        let level = matrix.level(band: band, signal: driverSignal)
        evaluation.report(level == .proceed ? .proceeded : .appliedFriction(level))
        return (level, .fused(signal: driverSignal, model: driverModel, selector: driverSelector), comparison)
    }

    private func finish(_ operation: SensitiveOperation, score: RiskScore, band: RiskBand,
                        floor: FrictionLevel, level: FrictionLevel, basis: DecisionBasis,
                        shadow: ShadowComparison?, started: ContinuousClock.Instant) async -> FrictionDecision {
        var signal: CoachingSignal? = nil
        var model: ModelVersion? = nil
        if case .fused(let fusedSignal, let fusedModel, _) = basis {
            signal = fusedSignal
            model = fusedModel
        }
        await audit.record(AuditRecord(operationDigest: operationDigest(operation.id),
                                       category: operation.category,
                                       band: band, level: level, basis: basis.kind,
                                       signal: signal, modelVersion: model,
                                       shadowAgreed: shadow?.agrees,
                                       recordedAt: .init()))
        return FrictionDecision(operationID: operation.id, category: operation.category,
                                score: score, band: band, floor: floor, level: level,
                                basis: basis, shadow: shadow, elapsed: clock.now - started)
    }

    // MARK: Consumption reporting

    private nonisolated func enqueueReport(_ report: ConsumptionReport) {
        // `deinit` of a noncopyable value is synchronous; the report itself
        // is async. Hop onto the actor to record and forward it.
        Task { await self.deliver(report) }
    }

    private func deliver(_ report: ConsumptionReport) async {
        // The source hears first; the ledger settles second. `drainReports`
        // waits on the ledger, so when it returns the source has been told.
        await source.reportConsumption(report)
        ledger.settle(report.outcome)
    }

    /// Test seam: creates an obligation wired to this policy's ledger and
    /// source exactly as `decide` wires them (reservation included) and then
    /// drops it without reporting — the one thing `decide` never does. The
    /// drop must show up as `ledger.discardedUnreported == 1` and as a
    /// `.discardedUnreported` report at the source; that is the test which
    /// proves the safety net is *connected*, not merely that
    /// `InsightEvaluation.deinit` runs. Noncopyable values cannot leave the
    /// actor, which is why the drop happens here rather than in the test.
    func dropObligationForTesting(id: EvaluationID) {
        ledger.reserve()
        _ = InsightEvaluation(id: id, reporter: { [weak self] report in
            self?.enqueueReport(report)
        })
    }

    /// Waits for every report that has been enqueued so far to reach the
    /// source. Tests and the demo call this before reading ledgers; production
    /// code never needs to.
    public func drainReports() async {
        // Reports are enqueued as detached-style tasks; yielding a few times
        // lets them run. Bounded so a broken source cannot hang the caller.
        for _ in 0..<32 {
            if ledger.outstanding == 0 { return }
            await Task.yield()
            try? await clock.sleep(for: .milliseconds(5))
        }
    }

    // MARK: Unavailability memory

    private struct RememberedUnavailability {
        let reason: SignalUnavailableReason
        /// `nil` means "for the rest of this process".
        let until: ContinuousClock.Instant?

        func isInForce(at now: ContinuousClock.Instant) -> Bool {
            guard let until else { return true }
            return now < until
        }
    }

    private func remember(_ reason: SignalUnavailableReason) {
        let now = clock.now
        switch reason {
        case .entitlementMissing:
            remembered = RememberedUnavailability(reason: reason, until: nil)
        case .notAuthorized(let cooldown):
            if let cooldown, cooldown > .zero {
                remembered = RememberedUnavailability(reason: reason, until: now + cooldown)
            }
        case .offline, .rateLimited:
            if configuration.transientRetryAfter > .zero {
                remembered = RememberedUnavailability(reason: reason, until: now + configuration.transientRetryAfter)
            }
        case .timedOut, .cancelled, .localBackpressure, .failed:
            break
        }
    }

    /// Forget a remembered unavailability — call after the user has
    /// re-authorized the evaluator or reachability has returned.
    public func forgetUnavailability() {
        remembered = nil
    }

    public var rememberedUnavailability: SignalUnavailableReason? {
        guard let remembered, remembered.isInForce(at: clock.now) else { return nil }
        return remembered.reason
    }

    private static func reason(for error: any Error) -> SignalUnavailableReason {
        if let unavailable = error as? InsightUnavailable { return unavailable.reason }
        if error is DeadlineExceeded { return .timedOut }
        if error is CancellationError { return .cancelled }
        return .failed(String(describing: error))
    }
}
