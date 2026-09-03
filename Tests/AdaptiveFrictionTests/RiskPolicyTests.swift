import XCTest
@testable import AdaptiveFriction

final class RiskPolicyTests: XCTestCase {

    // MARK: Fusion

    /// "unknown" is the floor: with no evidence the policy applies exactly
    /// what the app's own band would, in every band — and the basis says the
    /// evaluator *was* consulted, so this is not the fail-open path in disguise.
    func testUnknownSignalYieldsExactlyTheBandFloor() async throws {
        let (policy, _) = try Fixtures.policy(SimulatedBehaviour(signal: .unknown))
        for band in RiskBand.allCases {
            let decision = await policy.decide(Fixtures.operation(band: band))
            XCTAssertEqual(decision.band, band)
            XCTAssertEqual(decision.level, decision.floor)
            XCTAssertEqual(decision.floor, FrictionMatrix.standard.floor(band: band))
            guard case .fused(let signal, _, let selector) = decision.basis else {
                return XCTFail("expected fused basis, got \(decision.basis)")
            }
            XCTAssertEqual(signal, .unknown)
            XCTAssertEqual(selector, .current)
        }
    }

    func testHighSignalRaisesFrictionAboveTheFloor() async throws {
        let (policy, _) = try Fixtures.policy(SimulatedBehaviour(signal: .high))
        let low = await policy.decide(Fixtures.operation(band: .low))
        XCTAssertEqual(low.floor, .proceed)
        XCTAssertEqual(low.level, .outOfBandVerify)
        let elevated = await policy.decide(Fixtures.operation(band: .elevated))
        XCTAssertEqual(elevated.level, .holdForReview)
        XCTAssertGreaterThan(elevated.level, elevated.floor)
    }

    /// Property over the whole (band × signal) space: the decision is exactly
    /// the matrix cell, and therefore never below the floor. Equality, not
    /// `>=`, so a fusion gutted to "return the floor" fails on six cells.
    func testEveryBandSignalPairDecidesExactlyTheMatrixCell() async throws {
        for signal in CoachingSignal.allCases {
            let (policy, _) = try Fixtures.policy(SimulatedBehaviour(signal: signal))
            for band in RiskBand.allCases {
                let decision = await policy.decide(Fixtures.operation(band: band))
                XCTAssertEqual(decision.level, FrictionMatrix.standard.level(band: band, signal: signal), "\(signal)/\(band)")
                XCTAssertGreaterThanOrEqual(decision.level, decision.floor, "\(signal)/\(band)")
            }
        }
    }

    // MARK: Fail-open

    func testNotAuthorizedFailsOpenAndIsRememberedForTheCooldown() async throws {
        let behaviour = SimulatedBehaviour(availability: .unavailable(.notAuthorized(cooldown: .milliseconds(120))),
                                           signal: .high)
        let (policy, source) = try Fixtures.policy(behaviour)

        let first = await policy.decide(Fixtures.operation("a", band: .elevated))
        XCTAssertEqual(first.level, first.floor)
        XCTAssertEqual(first.basis, .appRiskOnly(.notAuthorized(cooldown: .milliseconds(120)), cached: false))

        let second = await policy.decide(Fixtures.operation("b", band: .elevated))
        XCTAssertEqual(second.basis, .appRiskOnly(.notAuthorized(cooldown: .milliseconds(120)), cached: true))
        let requestsDuringCooldown = await source.requests.count
        XCTAssertEqual(requestsDuringCooldown, 1, "the evaluator must not be hammered during a cooldown")

        try await Task.sleep(for: .milliseconds(160))
        await source.set(SimulatedBehaviour(signal: .high))
        let third = await policy.decide(Fixtures.operation("c", band: .elevated))
        guard case .fused = third.basis else { return XCTFail("cooldown should have expired") }
        let requestsAfter = await source.requests.count
        XCTAssertEqual(requestsAfter, 2)
    }

    func testMissingEntitlementIsRememberedForTheProcess() async throws {
        let (policy, source) = try Fixtures.policy(SimulatedBehaviour(availability: .unavailable(.entitlementMissing)))
        _ = await policy.decide(Fixtures.operation("a"))
        _ = await policy.decide(Fixtures.operation("b"))
        _ = await policy.decide(Fixtures.operation("c"))
        let requests = await source.requests.count
        XCTAssertEqual(requests, 1)
        let remembered = await policy.rememberedUnavailability
        XCTAssertEqual(remembered, .entitlementMissing)
        await policy.forgetUnavailability()
        _ = await policy.decide(Fixtures.operation("d"))
        let afterForget = await source.requests.count
        XCTAssertEqual(afterForget, 2)
    }

    func testOfflineIsRememberedOnlyForTheTransientInterval() async throws {
        let (policy, source) = try Fixtures.policy(SimulatedBehaviour(availability: .unavailable(.offline)),
                                                   retryAfter: .milliseconds(60))
        _ = await policy.decide(Fixtures.operation("a"))
        _ = await policy.decide(Fixtures.operation("b"))
        var requests = await source.requests.count
        XCTAssertEqual(requests, 1)
        try await Task.sleep(for: .milliseconds(90))
        _ = await policy.decide(Fixtures.operation("c"))
        requests = await source.requests.count
        XCTAssertEqual(requests, 2)
    }

    func testDeadlineExpiryFailsOpenFastAndLeavesNothingToReport() async throws {
        let (policy, source) = try Fixtures.policy(SimulatedBehaviour(signal: .high, latency: .seconds(10)),
                                                   deadline: .milliseconds(50))
        let decision = await policy.decide(Fixtures.operation(band: .high))
        XCTAssertEqual(decision.basis, .appRiskOnly(.timedOut, cached: false))
        XCTAssertEqual(decision.level, .outOfBandVerify) // the high-band floor
        XCTAssertLessThan(decision.elapsed, .seconds(2))
        await policy.drainReports()
        let unreported = await source.unreportedIDs
        XCTAssertTrue(unreported.isEmpty, "a cancelled evaluation produced nothing, so nothing is owed")
        let ledger = await policy.ledger
        XCTAssertEqual(ledger.outstanding, 0)
        // A timeout is not remembered: the next call tries the evaluator again.
        await source.set(SimulatedBehaviour(signal: .high))
        let next = await policy.decide(Fixtures.operation("n", band: .high))
        guard case .fused = next.basis else { return XCTFail("timeouts must not be cached") }
    }

    // MARK: Consumption contract

    func testEveryProducedEvaluationIsReportedExactlyOnce() async throws {
        let (policy, source) = try Fixtures.policy(SimulatedBehaviour(signal: .medium))
        var fused = 0
        for index in 0..<12 {
            let band = RiskBand.allCases[index % RiskBand.allCases.count]
            if index % 4 == 3 {
                await source.set(SimulatedBehaviour(availability: .unavailable(.rateLimited)))
            } else {
                await source.set(SimulatedBehaviour(signal: .medium))
                await policy.forgetUnavailability()
            }
            let decision = await policy.decide(Fixtures.operation("op-\(index)", band: band))
            if case .fused = decision.basis { fused += 1 }
        }
        await policy.drainReports()
        let ledger = await policy.ledger
        let reports = await source.reports
        let unreported = await source.unreportedIDs
        XCTAssertEqual(fused, 9)
        XCTAssertEqual(reports.count, 9)
        XCTAssertEqual(Set(reports.map(\.id)).count, 9, "no evaluation may be reported twice")
        XCTAssertTrue(unreported.isEmpty)
        XCTAssertEqual(ledger.reported, 9)
        XCTAssertEqual(ledger.outstanding, 0)
        XCTAssertEqual(ledger.discardedUnreported, 0, "the deinit safety net must never have to fire")
        // Outcome fidelity: friction above `proceed` reports the level; `proceed` reports `.proceeded`.
        for report in reports {
            switch report.outcome {
            case .appliedFriction, .proceeded: break
            default: XCTFail("unexpected outcome \(report.outcome)")
            }
        }
        XCTAssertTrue(reports.contains { $0.outcome == .appliedFriction(.educateAndDelay) })
        XCTAssertTrue(reports.contains { $0.outcome == .appliedFriction(.holdForReview) })
    }

    /// Positive control for the safety net: an obligation wired exactly as
    /// `decide` wires it, then dropped. The ledger must count it *and* the
    /// source must hear `.discardedUnreported`. Delete the increment in
    /// `ConsumptionLedger.settle` or the reporter wiring and this fails.
    func testADroppedObligationReachesTheLedgerAndTheSource() async throws {
        let (policy, source) = try Fixtures.policy(SimulatedBehaviour(signal: .medium))
        await policy.dropObligationForTesting(id: EvaluationID("dropped-1"))
        await policy.drainReports()
        let ledger = await policy.ledger
        let reports = await source.reports
        XCTAssertEqual(ledger.discardedUnreported, 1)
        XCTAssertEqual(ledger.reported, 1)
        XCTAssertEqual(ledger.outstanding, 0)
        XCTAssertEqual(reports, [ConsumptionReport(id: EvaluationID("dropped-1"), outcome: .discardedUnreported)])
    }

    /// Positive control for `unreportedIDs`: bypass the policy, evaluate
    /// directly, and the source must show the debt until it is paid. A stub
    /// that always answers `[]` fails here.
    func testUnreportedIDsShowsTheDebtUntilItIsReported() async throws {
        let source = SimulatedInsightSource(SimulatedBehaviour(signal: .high, latency: .zero))
        let first = try await source.evaluate(InsightRequest(category: .payment, versions: [.current]))
        let second = try await source.evaluate(InsightRequest(category: .account, versions: [.current]))
        var owed = await source.unreportedIDs
        XCTAssertEqual(owed, [EvaluationID("sim-1"), EvaluationID("sim-2")])
        XCTAssertEqual(first.id, EvaluationID("sim-1"))
        await source.reportConsumption(ConsumptionReport(id: first.id, outcome: .proceeded))
        owed = await source.unreportedIDs
        XCTAssertEqual(owed, [second.id])
        await source.reportConsumption(ConsumptionReport(id: second.id, outcome: .appliedFriction(.holdForReview)))
        owed = await source.unreportedIDs
        XCTAssertTrue(owed.isEmpty)
    }

    func testSimulatedSourceHistoryIsBoundedButDebtIsNot() async throws {
        let source = SimulatedInsightSource(SimulatedBehaviour(latency: .zero), historyCapacity: 2)
        for _ in 0..<5 {
            _ = try await source.evaluate(InsightRequest(category: .other, versions: [.current]))
        }
        let requests = await source.requests
        let owed = await source.unreportedIDs
        XCTAssertEqual(requests.count, 2, "history is FIFO-bounded")
        XCTAssertEqual(owed.count, 5, "every unreported evaluation is still owed")
    }

    func testLocalBackpressureRefusesToStartEvaluationsBeyondTheCap() async throws {
        let (policy, source) = try Fixtures.policy(SimulatedBehaviour(signal: .high, latency: .milliseconds(150)),
                                                   maxOutstanding: 2)
        let decisions = await withTaskGroup(of: FrictionDecision.self, returning: [FrictionDecision].self) { group in
            for index in 0..<5 {
                group.addTask { await policy.decide(Fixtures.operation("c-\(index)", band: .low)) }
            }
            var collected: [FrictionDecision] = []
            for await decision in group { collected.append(decision) }
            return collected
        }
        let shed = decisions.filter { $0.basis == .appRiskOnly(.localBackpressure, cached: false) }
        let fused = decisions.filter { if case .fused = $0.basis { return true } else { return false } }
        XCTAssertEqual(shed.count, 3)
        XCTAssertEqual(fused.count, 2)
        XCTAssertTrue(shed.allSatisfy { $0.level == .proceed }, "shed calls fail open to the floor")
        XCTAssertTrue(fused.allSatisfy { $0.level == .outOfBandVerify })
        let requests = await source.requests.count
        XCTAssertEqual(requests, 2, "only the admitted calls reach the evaluator")
        await policy.drainReports()
        let ledger = await policy.ledger
        XCTAssertEqual(ledger.outstanding, 0)
        XCTAssertEqual(ledger.reported, 2)
    }

    func testConcurrentDecisionsKeepTheLedgerConsistent() async throws {
        let (policy, source) = try Fixtures.policy(SimulatedBehaviour(signal: .medium, latency: .milliseconds(5)),
                                                   maxOutstanding: 100)
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<50 {
                group.addTask { _ = await policy.decide(Fixtures.operation("p-\(index)", band: .low)) }
            }
        }
        await policy.drainReports()
        let ledger = await policy.ledger
        let reports = await source.reports
        XCTAssertEqual(ledger.outstanding, 0)
        XCTAssertEqual(ledger.reported, 50)
        XCTAssertEqual(ledger.discardedUnreported, 0)
        XCTAssertEqual(Set(reports.map(\.id)).count, 50)
    }

    // MARK: Shadow evaluation

    func testObservingThePriorModelRecordsADiffWithoutChangingTheDecision() async throws {
        let shadow = try ShadowConfiguration(driver: .current, observer: .prior)
        let (policy, source) = try Fixtures.policy(SimulatedBehaviour(signal: .high, priorSignal: .unknown),
                                                   shadow: shadow)
        let decision = await policy.decide(Fixtures.operation(band: .low))
        XCTAssertEqual(decision.level, .outOfBandVerify)
        guard case .fused(_, _, let selector) = decision.basis else { return XCTFail() }
        XCTAssertEqual(selector, .current)
        let comparison = try XCTUnwrap(decision.shadow)
        XCTAssertEqual(comparison.driverLevel, .outOfBandVerify)
        XCTAssertEqual(comparison.observerLevel, .proceed)
        XCTAssertTrue(comparison.observerRelaxes)
        let ledger = await policy.shadowLedger
        XCTAssertEqual(ledger.relaxations, 1)
        let requests = await source.requests
        XCTAssertEqual(requests.first?.versions, [.current, .prior])
    }

    func testDrivingOnThePriorModelUsesItsSignalAndObservesTheCurrentOne() async throws {
        let shadow = try ShadowConfiguration(driver: .prior, observer: .current)
        let (policy, _) = try Fixtures.policy(SimulatedBehaviour(signal: .high, priorSignal: .medium),
                                              shadow: shadow)
        let decision = await policy.decide(Fixtures.operation(band: .low))
        XCTAssertEqual(decision.level, .educateAndDelay, "the prior model's `medium` drives")
        guard case .fused(let signal, let model, let selector) = decision.basis else { return XCTFail() }
        XCTAssertEqual(signal, .medium)
        XCTAssertEqual(selector, .prior)
        XCTAssertEqual(model, ModelVersion("sim-2026.06"))
        let comparison = try XCTUnwrap(decision.shadow)
        XCTAssertTrue(comparison.observerEscalates)
        XCTAssertEqual(comparison.observerLevel, .outOfBandVerify)
    }

    func testDriverFallsBackToTheCurrentModelWhenThePriorIsMissing() async throws {
        let shadow = try ShadowConfiguration(driver: .prior, observer: .current)
        let (policy, _) = try Fixtures.policy(SimulatedBehaviour(signal: .high, priorSignal: nil), shadow: shadow)
        let decision = await policy.decide(Fixtures.operation(band: .low))
        XCTAssertEqual(decision.level, .outOfBandVerify)
        guard case .fused(_, _, let selector) = decision.basis else { return XCTFail() }
        XCTAssertEqual(selector, .current, "the basis must say which model actually drove")
        XCTAssertNil(decision.shadow)
        let ledger = await policy.shadowLedger
        XCTAssertEqual(ledger.driverUnavailable, 1, "the missing model was the driver, not the observer")
        XCTAssertEqual(ledger.observerUnavailable, 0)
        XCTAssertEqual(ledger.comparisons, 0)
    }

    func testMissingPriorCountsAsObserverUnavailableWhenThePriorIsTheObserver() async throws {
        let shadow = try ShadowConfiguration(driver: .current, observer: .prior)
        let (policy, _) = try Fixtures.policy(SimulatedBehaviour(signal: .high, priorSignal: nil), shadow: shadow)
        let decision = await policy.decide(Fixtures.operation(band: .low))
        XCTAssertEqual(decision.level, .outOfBandVerify)
        XCTAssertNil(decision.shadow)
        let ledger = await policy.shadowLedger
        XCTAssertEqual(ledger.observerUnavailable, 1)
        XCTAssertEqual(ledger.driverUnavailable, 0)
    }

    func testWithoutShadowOnlyTheCurrentModelIsRequested() async throws {
        let (policy, source) = try Fixtures.policy(SimulatedBehaviour(signal: .medium, priorSignal: .high))
        let decision = await policy.decide(Fixtures.operation())
        XCTAssertNil(decision.shadow)
        let requests = await source.requests
        XCTAssertEqual(requests.first?.versions, [.current])
    }

    // MARK: Audit

    func testAuditRecordCarriesTheDigestNotTheIdentifierAndNoAmountField() async throws {
        let audit = InMemoryAuditSink(capacity: 3)
        let (policy, _) = try Fixtures.policy(SimulatedBehaviour(signal: .medium), audit: audit)
        for index in 0..<5 {
            _ = await policy.decide(Fixtures.operation("txn-\(index)", band: .elevated))
        }
        let records = await audit.snapshot()
        XCTAssertEqual(records.count, 3, "bounded: only the newest `capacity` records survive")
        XCTAssertEqual(records.map(\.operationDigest), ["txn-2", "txn-3", "txn-4"].map(operationDigest))
        for record in records {
            XCTAssertFalse(record.operationDigest.hasPrefix("txn-"))
            XCTAssertEqual(record.band, .elevated)
            XCTAssertEqual(record.level, .outOfBandVerify)
            XCTAssertEqual(record.basis, .fused)
            XCTAssertEqual(record.signal, .medium)
        }
        // The record type has no field that could hold an amount, payee or
        // account: the whole schema is enumerated here so adding one is a
        // visible test change, not a silent one.
        let mirror = Mirror(reflecting: try XCTUnwrap(records.first))
        XCTAssertEqual(Set(mirror.children.compactMap(\.label)),
                       ["operationDigest", "category", "band", "level", "basis",
                        "signal", "modelVersion", "shadowAgreed", "recordedAt"])
    }

    func testFailOpenDecisionsAreAuditedWithoutASignal() async throws {
        let audit = InMemoryAuditSink()
        let (policy, _) = try Fixtures.policy(SimulatedBehaviour(availability: .unavailable(.offline)), audit: audit)
        _ = await policy.decide(Fixtures.operation("x", band: .high))
        let records = await audit.snapshot()
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.basis, .appRiskOnly)
        XCTAssertNil(record.signal)
        XCTAssertNil(record.modelVersion)
        XCTAssertEqual(record.level, .outOfBandVerify)
    }

    // MARK: Configuration

    func testConfigurationValidation() {
        XCTAssertThrowsError(try RiskPolicyConfiguration(deadline: .zero))
        XCTAssertThrowsError(try RiskPolicyConfiguration(deadline: .seconds(-1)))
        XCTAssertThrowsError(try RiskPolicyConfiguration(maxOutstandingEvaluations: 0))
        XCTAssertThrowsError(try RiskPolicyConfiguration(transientRetryAfter: .seconds(-1)))
        XCTAssertNoThrow(try RiskPolicyConfiguration(transientRetryAfter: .zero))
    }
}

final class QAScenarioTests: XCTestCase {

    func testThereAreExactlyNineDistinctScenarios() {
        XCTAssertEqual(QAScenario.allCases.count, 9)
        XCTAssertEqual(Set(QAScenario.allCases).count, 9)
    }

    func testParsingFromEnvironmentAndArguments() {
        XCTAssertNil(QAScenario.parse([:]))
        XCTAssertEqual(QAScenario.parse(["AF_SIGNAL": "high", "AF_AVAILABILITY": "timeout"]),
                       QAScenario(signal: .high, availability: .timeout))
        XCTAssertEqual(QAScenario.parse(["AF_SIGNAL": "MEDIUM"]),
                       QAScenario(signal: .medium, availability: .available))
        // A typo must not crash a launch: it falls back to the key's default.
        XCTAssertEqual(QAScenario.parse(["AF_SIGNAL": "hgih", "AF_AVAILABILITY": "notauthorized"]),
                       QAScenario(signal: .unknown, availability: .notAuthorized))
        XCTAssertEqual(QAScenario.parse(arguments: ["Demo", "-AF_SIGNAL", "medium", "-AF_AVAILABILITY", "timeout"]),
                       QAScenario(signal: .medium, availability: .timeout))
        XCTAssertEqual(QAScenario.parse(arguments: ["Demo", "-AF_SIGNAL"]), nil)
        XCTAssertEqual(QAScenario.parse(arguments: ["-Other", "x", "-AF_AVAILABILITY", "notAuthorized"]),
                       QAScenario(signal: .unknown, availability: .notAuthorized))
    }

    /// Every cell of the matrix, driven through the real policy, lands on the
    /// basis QA expects — the point of the matrix is that all nine are
    /// reachable from a scheme.
    func testEveryScenarioReachesItsExpectedBasis() async throws {
        for scenario in QAScenario.allCases {
            let (policy, _) = try Fixtures.policy(scenario.behaviour(), deadline: .milliseconds(60))
            let decision = await policy.decide(Fixtures.operation("\(scenario)", band: .elevated))
            switch scenario.availability {
            case .available:
                guard case .fused(let signal, _, _) = decision.basis else {
                    return XCTFail("\(scenario): expected fused, got \(decision.basis)")
                }
                XCTAssertEqual(signal, scenario.signal)
                XCTAssertEqual(decision.level, FrictionMatrix.standard.level(band: .elevated, signal: scenario.signal))
            case .notAuthorized:
                XCTAssertEqual(decision.basis, .appRiskOnly(.notAuthorized(cooldown: .seconds(60)), cached: false), "\(scenario)")
                XCTAssertEqual(decision.level, .educateAndDelay)
            case .timeout:
                XCTAssertEqual(decision.basis, .appRiskOnly(.timedOut, cached: false), "\(scenario)")
                XCTAssertEqual(decision.level, .educateAndDelay)
            }
        }
    }
}
