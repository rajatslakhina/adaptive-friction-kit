/// A consumption obligation that cannot be forgotten.
///
/// The platform requires every evaluation to be reported as consumed, and
/// rate-limits apps that do not. Rather than trusting every call site to
/// remember, the obligation is a noncopyable value:
///
/// - it cannot be duplicated, so it cannot be reported twice;
/// - `report(_:)` is `consuming`, so after reporting it no longer exists;
/// - if it goes out of scope any other way, `deinit` sends
///   `.discardedUnreported` so the platform is never left waiting *and* the
///   ledger records a defect a test can assert on.
///
/// `discard self` would let `report` skip the `deinit` entirely, but Swift 6.0
/// only allows it for types with trivially-destroyed storage, and this one
/// holds a closure. The `reported` flag is the equivalent guard.
public struct InsightEvaluation: ~Copyable {
    public let id: EvaluationID
    private var reported = false
    private let reporter: @Sendable (ConsumptionReport) -> Void

    public init(id: EvaluationID, reporter: @escaping @Sendable (ConsumptionReport) -> Void) {
        self.id = id
        self.reporter = reporter
    }

    /// Reports the outcome and ends the obligation.
    public consuming func report(_ outcome: ConsumptionOutcome) {
        reported = true
        reporter(ConsumptionReport(id: id, outcome: outcome))
    }

    deinit {
        if !reported {
            reporter(ConsumptionReport(id: id, outcome: .discardedUnreported))
        }
    }
}
