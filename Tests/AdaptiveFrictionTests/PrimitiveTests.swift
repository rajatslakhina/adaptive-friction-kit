import XCTest
@testable import AdaptiveFriction

final class EvaluationTests: XCTestCase {

    func testReportingSendsExactlyOneReportWithTheGivenOutcome() {
        let reporter = RecordingReporter()
        do {
            let evaluation = InsightEvaluation(id: EvaluationID("e1"), reporter: { reporter.record($0) })
            evaluation.report(.appliedFriction(.outOfBandVerify))
        }
        XCTAssertEqual(reporter.reports, [ConsumptionReport(id: EvaluationID("e1"),
                                                            outcome: .appliedFriction(.outOfBandVerify))])
    }

    /// The safety net: a code path that forgets to report still produces a
    /// report, and it is the one that names the defect.
    func testDroppingAnEvaluationReportsItAsDiscarded() {
        let reporter = RecordingReporter()
        do {
            _ = InsightEvaluation(id: EvaluationID("e2"), reporter: { reporter.record($0) })
        }
        XCTAssertEqual(reporter.reports, [ConsumptionReport(id: EvaluationID("e2"), outcome: .discardedUnreported)])
    }

    /// A deliberately broken consumer: it takes the evaluation, awaits
    /// something, and returns early on a branch without reporting. The
    /// obligation still fires — once, and as `.discardedUnreported`, not as a
    /// silent nothing.
    func testForgetfulConsumerIsCaughtEvenAcrossAnAwait() async {
        let reporter = RecordingReporter()
        func forgetful(_ evaluation: consuming InsightEvaluation, remember: Bool) async {
            await Task.yield()
            if remember {
                evaluation.report(.proceeded)
            }
            // The `false` branch drops `evaluation` here.
        }
        await forgetful(InsightEvaluation(id: EvaluationID("e3"), reporter: { reporter.record($0) }), remember: false)
        await forgetful(InsightEvaluation(id: EvaluationID("e4"), reporter: { reporter.record($0) }), remember: true)
        XCTAssertEqual(reporter.reports, [
            ConsumptionReport(id: EvaluationID("e3"), outcome: .discardedUnreported),
            ConsumptionReport(id: EvaluationID("e4"), outcome: .proceeded)
        ])
    }
}

final class DeadlineTests: XCTestCase {

    func testFastOperationReturnsItsValue() async throws {
        let value = try await withDeadline(.seconds(1), clock: ContinuousClock()) { 42 }
        XCTAssertEqual(value, 42)
    }

    func testSlowOperationIsCancelledAndDeadlineExceededIsThrown() async {
        let observed = CancellationObserver()
        let started = ContinuousClock().now
        do {
            _ = try await withDeadline(.milliseconds(40), clock: ContinuousClock()) {
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    await observed.mark()
                    throw error
                }
                return 1
            }
            XCTFail("expected DeadlineExceeded")
        } catch let error as DeadlineExceeded {
            XCTAssertEqual(error.budget, .milliseconds(40))
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertLessThan(ContinuousClock().now - started, .seconds(2))
        // Give the cancelled child a moment to observe its cancellation.
        for _ in 0..<20 where await !observed.wasCancelled {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let wasCancelled = await observed.wasCancelled
        XCTAssertTrue(wasCancelled, "the losing child must actually be cancelled, not left running")
    }

    func testNonPositiveBudgetNeverStartsTheOperation() async {
        let observed = CancellationObserver()
        do {
            _ = try await withDeadline(.zero, clock: ContinuousClock()) {
                await observed.mark()
                return 1
            }
            XCTFail("expected DeadlineExceeded")
        } catch is DeadlineExceeded {
            // expected
        } catch {
            XCTFail("unexpected \(error)")
        }
        let ran = await observed.wasCancelled
        XCTAssertFalse(ran)
    }

    func testOperationErrorPropagatesWhenItFailsFirst() async {
        struct Boom: Error {}
        do {
            _ = try await withDeadline(.seconds(1), clock: ContinuousClock()) { () -> Int in throw Boom() }
            XCTFail("expected Boom")
        } catch is Boom {
            // expected
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    actor CancellationObserver {
        private(set) var wasCancelled = false
        func mark() { wasCancelled = true }
    }
}

final class StatisticsTests: XCTestCase {

    func testWilsonKnownValues() throws {
        // 0/30 at 95%: upper = z² / (n + z²) = 3.8416 / 33.8416 = 0.11352.
        let zeroOfThirty = try XCTUnwrap(wilsonInterval(successes: 0, trials: 30))
        XCTAssertEqual(zeroOfThirty.lower, 0, accuracy: 1e-12)
        XCTAssertEqual(zeroOfThirty.upper, 0.11352, accuracy: 1e-4)
        XCTAssertEqual(zeroOfThirty.point, 0)

        // 3/30: point 0.1, interval must strictly bracket it.
        let threeOfThirty = try XCTUnwrap(wilsonInterval(successes: 3, trials: 30))
        XCTAssertEqual(threeOfThirty.point, 0.1, accuracy: 1e-12)
        XCTAssertLessThan(threeOfThirty.lower, 0.1)
        XCTAssertGreaterThan(threeOfThirty.upper, 0.1)
        XCTAssertEqual(threeOfThirty.lower, 0.0346, accuracy: 1e-3)
        XCTAssertEqual(threeOfThirty.upper, 0.2562, accuracy: 1e-3)

        // 30/30 is the mirror image of 0/30.
        let all = try XCTUnwrap(wilsonInterval(successes: 30, trials: 30))
        XCTAssertEqual(all.lower, 1 - zeroOfThirty.upper, accuracy: 1e-12)
        XCTAssertEqual(all.upper, 1, accuracy: 1e-12)
    }

    func testWilsonRefusesNonsense() {
        XCTAssertNil(wilsonInterval(successes: 0, trials: 0))
        XCTAssertNil(wilsonInterval(successes: 5, trials: 3))
        XCTAssertNil(wilsonInterval(successes: -1, trials: 3))
        XCTAssertNil(wilsonInterval(successes: 1, trials: 3, z: .nan))
    }

    func testSamplesToClearToleranceMatchesTheWilsonBound() throws {
        let n = ShadowConfiguration.samplesToClear(tolerance: 0.05)
        XCTAssertEqual(n, 73)
        let atFloor = try XCTUnwrap(wilsonInterval(successes: 0, trials: n))
        let belowFloor = try XCTUnwrap(wilsonInterval(successes: 0, trials: n - 1))
        XCTAssertLessThanOrEqual(atFloor.upper, 0.05)
        XCTAssertGreaterThan(belowFloor.upper, 0.05)
        XCTAssertEqual(ShadowConfiguration.samplesToClear(tolerance: 1), 1)
        XCTAssertEqual(ShadowConfiguration.samplesToClear(tolerance: 0), 1)
        XCTAssertEqual(ShadowConfiguration.samplesToClear(tolerance: .nan), 1)
        XCTAssertEqual(ShadowConfiguration.samplesToClear(tolerance: 1e-12), Int(Int32.max))
    }

    func testSaturatingAdd() {
        XCTAssertEqual(saturatingAdd(Int.max, 1), Int.max)
        XCTAssertEqual(saturatingAdd(Int.min, -1), Int.min)
        XCTAssertEqual(saturatingAdd(40, 2), 42)
    }

    func testOperationDigestIsFNV1a64AndNotTheIdentifier() {
        // Standard FNV-1a 64-bit test vectors.
        XCTAssertEqual(operationDigest(""), "cbf29ce484222325")
        XCTAssertEqual(operationDigest("a"), "af63dc4c8601ec8c")
        XCTAssertEqual(operationDigest("foobar"), "85944171f73967e8")
        XCTAssertNotEqual(operationDigest("txn-1234"), "txn-1234")
    }
}

final class ShadowLedgerTests: XCTestCase {

    func testVerdictNeedsTheDerivedFloorAndThenUsesTheUpperBound() throws {
        let configuration = try ShadowConfiguration(driver: .prior, observer: .current, disagreementTolerance: 0.05)
        XCTAssertEqual(configuration.minimumSamples, 73)
        var ledger = ShadowLedger()
        let agree = ShadowComparison(band: .low, driverSignal: .unknown, observerSignal: .unknown,
                                     driverLevel: .proceed, observerLevel: .proceed)
        let escalate = ShadowComparison(band: .low, driverSignal: .unknown, observerSignal: .high,
                                        driverLevel: .proceed, observerLevel: .outOfBandVerify)

        for _ in 0..<72 { ledger.record(agree) }
        guard case .insufficientSamples(let have, let need) = ledger.verdict(configuration) else {
            return XCTFail("expected insufficientSamples")
        }
        XCTAssertEqual(have, 72)
        XCTAssertEqual(need, 73)

        ledger.record(agree)
        guard case .promotable(let interval) = ledger.verdict(configuration) else {
            return XCTFail("expected promotable at 0/73")
        }
        XCTAssertLessThanOrEqual(interval.upper, 0.05)

        // One escalation in 74 pushes the upper bound to ~7.3%: blocked.
        ledger.record(escalate)
        guard case .blocked(let blocked) = ledger.verdict(configuration) else {
            return XCTFail("expected blocked at 1/74")
        }
        XCTAssertGreaterThan(blocked.upper, 0.05)
        XCTAssertEqual(ledger.escalations, 1)
        XCTAssertEqual(ledger.relaxations, 0)
        XCTAssertEqual(ledger.agreements, 73)
    }

    func testAZeroDisagreementRecordAtThirtySamplesIsNotEvidenceOfFivePercent() throws {
        // The reason the default floor is derived rather than a round number.
        let configuration = try ShadowConfiguration(driver: .prior, observer: .current,
                                                    disagreementTolerance: 0.05, minimumSamples: 30)
        var ledger = ShadowLedger()
        let agree = ShadowComparison(band: .low, driverSignal: .unknown, observerSignal: .unknown,
                                     driverLevel: .proceed, observerLevel: .proceed)
        for _ in 0..<30 { ledger.record(agree) }
        guard case .blocked(let interval) = ledger.verdict(configuration) else {
            return XCTFail("0/30 must be blocked, its upper bound is 11.4%")
        }
        XCTAssertEqual(interval.point, 0)
        XCTAssertGreaterThan(interval.upper, 0.11)
    }

    func testConfigurationValidation() {
        XCTAssertThrowsError(try ShadowConfiguration(driver: .current, observer: .current))
        XCTAssertThrowsError(try ShadowConfiguration(driver: .current, observer: .prior, disagreementTolerance: 0))
        XCTAssertThrowsError(try ShadowConfiguration(driver: .current, observer: .prior, disagreementTolerance: 1.5))
        XCTAssertThrowsError(try ShadowConfiguration(driver: .current, observer: .prior, minimumSamples: 0))
        XCTAssertNoThrow(try ShadowConfiguration(driver: .current, observer: .prior, disagreementTolerance: 1))
    }

    func testRelaxationsAndEscalationsAreCountedSeparately() {
        var ledger = ShadowLedger()
        ledger.record(ShadowComparison(band: .high, driverSignal: .high, observerSignal: .unknown,
                                       driverLevel: .holdForReview, observerLevel: .outOfBandVerify))
        ledger.record(ShadowComparison(band: .low, driverSignal: .unknown, observerSignal: .medium,
                                       driverLevel: .proceed, observerLevel: .educateAndDelay))
        ledger.recordObserverUnavailable()
        XCTAssertEqual(ledger.relaxations, 1)
        XCTAssertEqual(ledger.escalations, 1)
        XCTAssertEqual(ledger.disagreements, 2)
        XCTAssertEqual(ledger.observerUnavailable, 1)
        XCTAssertEqual(ledger.comparisons, 2)
    }
}
