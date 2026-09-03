# adaptive-friction-kit

**Face ID passed. The OTP was right. The user is still being talked through the transfer by someone on the phone.**

iOS 27's Trust Insights framework ships an on-device ML signal for exactly that case: *this authenticated user may be being coached by a scammer.* It answers `unknown`, `medium` or `high` — where `unknown` explicitly means **no evidence found**, not *safe* — and then leaves every decision about what to do with it to you. It also arrives with a set of constraints that make the *integration* trivial and the *system design* the whole problem: an entitlement, a user-revocable authorization with a post-disable cooldown, a network dependency, multi-second async latency, a mandatory consumption report for every evaluation (omit it and the platform rate-limits you), and two model versions per call so you can shadow-evaluate before you promote.

This package is the missing middle layer between that signal and a sensitive flow: a `RiskPolicy` actor that fuses the platform's coaching signal with the app's own risk score into a typed friction ladder, fails open to the app's existing controls on every "no signal" state, enforces the consumption contract with the type system, shadow-evaluates the prior model against the current one with a promotion verdict that knows how small its sample is, emits a PII-free audit record for offline fraud labelling, and exposes all nine QA states from an Xcode scheme.

- Demo app: (added after the companion repo is pushed — see below)
- Two modules: `AdaptiveFriction` (the policy; no UI, builds on Linux) and `AdaptiveFrictionUI` (a SwiftUI payment-review screen; compiled by the iOS Simulator CI job only).

## Why this matters

Every fintech, marketplace and account-recovery flow on iOS is about to have this signal available, and the naive integration is one `if` statement: `if insight == .high { block }`. That integration is wrong in five separate ways, and each one is a lead-level design decision rather than a bug fix:

1. **`unknown` is not a class.** It is the absence of evidence. A policy that treats it as "safe" quietly *lowers* friction the day the evaluator is offline, unauthorized or rate-limited — which is exactly when a coached user is least protected. The fusion rule here is validated at construction so that `unknown` yields precisely the friction the app's own risk band would apply, and a signal can only ever raise it.
2. **The signal has a latency and the review screen has a user on it.** A multi-second evaluator cannot hold a "Confirm" button hostage. Every evaluation runs under a hard deadline and a miss fails open to the app's floor — with the basis recorded, so a fail-open decision is never mistaken for a "no evidence" one.
3. **The consumption report is a contract, not a courtesy.** The platform rate-limits apps that forget it. Here the obligation is a noncopyable value: it cannot be duplicated, `report` consumes it, and if a code path drops it, `deinit` sends `.discardedUnreported` so the platform is never left waiting *and* the ledger counts the defect.
4. **A new model version is a change to your policy that you did not make.** Two versions come back per call. Exactly one drives; the other is observed; every decision pair is diffed into a ledger whose promotion verdict uses a Wilson interval — and refuses to call zero disagreements in 30 samples "evidence of ≤ 5%", because it is not (the upper bound is 11.4%).
5. **The audit record is the feedback loop and the privacy surface at once.** Offline fraud labels need a join key; regulators need no PII in the log. The record carries a one-way digest of the operation id and the *names* of the risk signals — never the amount, payee, account or user.

## What's in it

| Type | Role |
|------|------|
| `CoachingSignal` | `unknown < medium < high`. Ordered so monotonicity is a type-level statement. |
| `FrictionLevel` | `proceed < educateAndDelay < outOfBandVerify < holdForReview`. |
| `FrictionMatrix` | (band × signal) → level. `init` throws if any row or column decreases, or any cell is missing. `.standard` is a defensible payments default. |
| `BandThresholds`, `RiskScore`, `RiskSignal`, `WeightedRiskScorer` | The app's own evidence: named, weighted booleans → clamped `[0, 1]` score → band. Scorer is injectable. |
| `InsightSource` | The seam to the platform evaluator. Throws `InsightUnavailable(reason)` for every normal "no signal" state. |
| `SimulatedInsightSource` | Scriptable stand-in: availability, signal, prior-model signal, latency; records every request and report. |
| `InsightEvaluation` | `~Copyable` consumption obligation. `report(_:)` is `consuming`; `deinit` reports `.discardedUnreported`. |
| `withDeadline(_:clock:operation:)` | Two-child task-group race; cancels the loser. |
| `RiskPolicy` | The actor. `decide(_:) → FrictionDecision`. Owns the consumption ledger, the shadow ledger and the remembered unavailability. |
| `FrictionDecision`, `DecisionBasis` | Level, floor, band, score, basis (`fused(signal, model, selector)` or `appRiskOnly(reason, cached:)`), shadow diff, elapsed. |
| `ShadowConfiguration`, `ShadowLedger`, `PromotionVerdict` | Driver/observer selection, diff counts, Wilson-bounded verdict with a floor derived from the tolerance. |
| `AuditRecord`, `AuditSink`, `InMemoryAuditSink`, `operationDigest` | Minimal-PII record; FNV-1a 64 digest; bounded in-memory sink. |
| `QAScenario` | The nine QA states, parsed from `-AF_SIGNAL` / `-AF_AVAILABILITY`. |
| `SensitiveFlowDemoView` (UI module) | Payment review screen with the ladder, the simulated evaluator's controls, the ledgers and the audit log. |

## The design, decision by decision

### A coaching signal can raise friction. It can never lower it.

`FrictionMatrix` is a 3×3 table from (app risk band, coaching signal) to friction level, and its initializer rejects any table where a row or a column decreases. The consequence: `matrix.level(band, .unknown)` — the "floor" — is what the app applies on its own evidence, and `medium`/`high` are non-decreasing from it. Every fail-open path in `RiskPolicy` returns exactly the floor, so an evaluator that is offline, unauthorized, rate-limited or slow produces the *same* friction as one that answered "no evidence". Nothing the evaluator does or fails to do can make the app more permissive than it was before the framework existed.

The `.standard` table:

| band \ signal | unknown | medium | high |
|---|---|---|---|
| low | proceed | educateAndDelay | outOfBandVerify |
| elevated | educateAndDelay | outOfBandVerify | holdForReview |
| high | outOfBandVerify | holdForReview | holdForReview |

*Rejected alternative:* a numeric fusion (`score + weight × signal`). It reads as more "ML", but it hides the invariant inside a formula with tunable weights, and one bad weight lets `high` produce less friction than `unknown`. A table is inspectable by a product owner and its monotonicity is a machine-checked property.

### Every "no signal" state is a normal state, and each is remembered for the right duration

`InsightUnavailable` carries a reason: `entitlementMissing`, `notAuthorized(cooldown:)`, `offline`, `rateLimited`, plus the policy's own `timedOut`, `cancelled` and `localBackpressure`. `RiskPolicy` fails open on all of them and remembers the ones worth remembering: a missing entitlement for the rest of the process, a revoked authorization for the reported cooldown, a transient (`offline`, `rateLimited`) for `transientRetryAfter`. A timeout is *not* remembered — the next call tries again, because a slow answer says nothing about the next one. The basis of a remembered decision is `appRiskOnly(reason, cached: true)`, and the evaluator is not contacted; `forgetUnavailability()` clears it after the app re-requests authorization.

*Rejected alternative:* retrying inside the policy. The review screen is a user waiting on a button; a retry loop doubles the worst-case latency for a signal that, by construction, cannot make the decision safer than the floor.

### The deadline is the review screen's, not the evaluator's

`withDeadline` races the evaluator against a clock in a two-child task group and cancels whichever loses. A cancelled evaluation produced nothing and owes no report (`SimulatedInsightSource` checks cancellation before minting an id, and a test asserts nothing is left unreported after a timeout). Swift 6.0 has no standard deadline primitive, so this is written by hand; when `withDeadline` lands in the standard library the call site is the only thing that changes.

### The consumption report cannot be forgotten

```swift
public struct InsightEvaluation: ~Copyable {
    public consuming func report(_ outcome: ConsumptionOutcome)   // ends the obligation
    deinit { if !reported { reporter(.discardedUnreported) } }     // the safety net
}
```

Inside `RiskPolicy`, fusion is the only function that can see an evaluation, and it takes it by `consuming` ownership. `discard self` would let `report` skip the `deinit` entirely, but Swift 6.0 restricts it to types with trivially-destroyed storage and this one holds a closure, so a `reported` flag is the guard. The test suite includes a deliberately forgetful consumer that returns early on one branch across an `await` — the obligation still fires, once, as `.discardedUnreported`. The policy's `ConsumptionLedger.discardedUnreported` is asserted to be zero across a mixed run of fused and failed-open decisions.

*Why not just call `reportConsumption` at the end of `decide`?* Because the next engineer will add an early return above it. The point of a noncopyable obligation is that the compiler, not code review, owns the invariant.

### Local backpressure before the platform's

The platform rate-limits apps with unreported evaluations. `RiskPolicy` reserves a slot in its ledger *before* awaiting the evaluator and refuses to start a new evaluation once `maxOutstandingEvaluations` are in flight, failing open with `.localBackpressure`. The reservation happens before the suspension point so concurrent callers see it; a test runs five concurrent decisions against a cap of two and gets exactly two evaluator calls and three shed decisions.

### Shadow evaluation with a verdict that knows how small it is

`ShadowConfiguration` names a *driver* and an *observer* (`.current`/`.prior`, must differ). Both are pushed through the same matrix and the same band, so any difference is attributable to the model, not the policy. `ShadowLedger` counts agreements, escalations (observer would apply more friction) and relaxations (less), plus evaluations where the observer was requested but missing — a model that is absent 30% of the time is not promotable however well it agrees when present.

The verdict is `promotable` only when the 95% Wilson upper bound on the disagreement rate is within tolerance. The default minimum sample count is *derived* from the tolerance — `ceil(z²(1−t)/t)`, which is 73 at 5% — because a round number like 30 sits in a band where zero disagreements can only ever be `blocked` (0/30 has an upper bound of 11.4%). A test pins both facts.

If the configured driver is unavailable on a given call, the other model drives and the basis says so (`selector`): a policy tuned against the prior model does not silently start driving on the current one without the decision record showing it.

*Rejected alternative:* the normal-approximation interval. At n = 30 and p̂ = 0 it has width zero and would call the model promotable after one afternoon of QA.

### Audit records carry a digest and the names of signals — nothing else

`AuditRecord` has nine fields and a test enumerates all of them by `Mirror`, so adding an `amount` is a visible test change. The operation id is an FNV-1a 64 digest (stable across processes, unlike `Hasher`; not cryptographic — the README says a keyed hash belongs here in production). `InMemoryAuditSink` is bounded FIFO; a real app supplies its own `AuditSink`.

### Nine QA states from one scheme

`QAScenario` is `CoachingSignal × {available, notAuthorized, timeout}`, parsed from `-AF_SIGNAL high -AF_AVAILABILITY timeout` or the environment; a typo falls back to the key's default rather than crashing a launch. A test drives all nine through the real policy and asserts the expected basis and level for each.

## Wiring the real evaluator

The package deliberately has no dependency on the Trust Insights framework: the CI toolchain (Xcode 16 on `macos-15`) has no iOS 27 SDK, and a policy layer should be testable without an entitlement. The adapter is a conformance to `InsightSource`, sketched here against the API surface described in the WWDC26 session *Meet Trust Insights* and the iOS 27 beta release notes. **This snippet is not compiled in this repository**; treat the names as the shape to verify against the SDK you have:

```swift
// import TrustInsights
final class TrustInsightsSource: InsightSource {
    func evaluate(_ request: InsightRequest) async throws -> InsightResponse {
        // let evaluator = InsightEvaluator()
        // guard await evaluator.authorizationStatus == .authorized else {
        //     throw InsightUnavailable(.notAuthorized(cooldown: evaluator.cooldownRemaining))
        // }
        // let versions: [InsightEvaluator.ModelVersionRequest] = request.versions.contains(.prior) ? [.current, .prior] : [.current]
        // let result = try await evaluator.evaluate(.isLikelyBeingCoached, category: map(request.category), modelVersions: versions)
        // return InsightResponse(id: EvaluationID(result.identifier),
        //                        signal: map(result.current.outcome), modelVersion: ModelVersion(result.current.modelVersion),
        //                        prior: result.prior.map { .evaluated(map($0.outcome), ModelVersion($0.modelVersion)) })
        fatalError("wire against the iOS 27 SDK; see README")
    }
    func reportConsumption(_ report: ConsumptionReport) async {
        // await evaluator.reportConsumption(id: report.id.rawValue, outcome: map(report.outcome))
    }
}
```

Map `ConsumptionOutcome.usedEvaluationOnly` to the framework's `.usedEvaluationOnly`, `appliedFriction`/`proceeded` to its "used" outcomes, and `discardedUnreported` to whatever "not used" outcome it offers — the point is that the platform always hears back.

## How to run it

```swift
.package(url: "https://github.com/rajatslakhina/adaptive-friction-kit.git", from: "1.0.0")
```

```swift
import AdaptiveFriction

let configuration = try RiskPolicyConfiguration(
    deadline: .seconds(3),
    shadow: try ShadowConfiguration(driver: .current, observer: .prior),
    maxOutstandingEvaluations: 8)
let policy = RiskPolicy(configuration: configuration, source: SimulatedInsightSource(SimulatedBehaviour(signal: .high)))

let decision = await policy.decide(SensitiveOperation(
    id: "txn-9f2",
    category: .payment,
    signals: [try RiskSignal(name: "new-payee", weight: 0.20, present: true)]))

decision.floor   // .proceed         — the app's own evidence
decision.level   // .outOfBandVerify — raised by the `high` signal
decision.basis   // .fused(signal: .high, model: "sim-2026.09", selector: .current)
```

Library checks, from a clean tree:

```
swift build -Xswiftc -warnings-as-errors
swift build --build-tests -Xswiftc -warnings-as-errors
swift test
```

## Verification

(filled in after CI has reported — see the companion demo repo for the Simulator run status)
