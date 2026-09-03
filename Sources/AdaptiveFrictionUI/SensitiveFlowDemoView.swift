#if canImport(SwiftUI)
import SwiftUI
import AdaptiveFriction

/// Everything the app decides and the library does not: the policy
/// configuration and the scenario the screen starts in.
public struct SensitiveFlowDemoConfiguration: Sendable {
    public let policy: RiskPolicyConfiguration
    public let initialScenario: QAScenario

    public init(policy: RiskPolicyConfiguration, initialScenario: QAScenario) {
        self.policy = policy
        self.initialScenario = initialScenario
    }
}

/// A payment review screen with the adaptive-friction policy behind its
/// "Review & send" button, and the simulated evaluator's controls exposed so
/// every one of the nine QA states can be driven by hand.
public struct SensitiveFlowDemoView: View {
    @StateObject private var model: FlowModel

    public init(configuration: SensitiveFlowDemoConfiguration) {
        _model = StateObject(wrappedValue: FlowModel(configuration: configuration))
    }

    public var body: some View {
        NavigationStack {
            List {
                paymentSection
                evidenceSection
                signalSection
                decisionSection
                ledgerSection
                auditSection
            }
            .navigationTitle("Adaptive Friction")
        }
    }

    // MARK: Sections

    private var paymentSection: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Transfer to A. Sharma").font(.headline)
                    Text("HDFC ····4417 · new payee").font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                Text("₹48,000").font(.title2.monospacedDigit()).bold()
            }
            Text("The policy never receives the amount, payee or account — only the category and the named risk signals below.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("Payment")
        }
    }

    private var evidenceSection: some View {
        Section {
            ForEach(model.evidence.indices, id: \.self) { index in
                Toggle(isOn: $model.evidence[index].present) {
                    HStack {
                        Text(model.evidence[index].name)
                        Spacer()
                        Text(String(format: "+%.2f", model.evidence[index].weight))
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Text("App risk score")
                Spacer()
                Text(String(format: "%.2f · %@", model.score.value, model.bandName))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("The app's own evidence")
        } footer: {
            Text("Floor on this evidence alone: \(FrictionLevel.name(model.floor)). A coaching signal can raise friction above the floor, never lower it.")
        }
    }

    private var signalSection: some View {
        Section {
            Picker("Signal", selection: $model.signal) {
                ForEach(CoachingSignal.allCases, id: \.self) { Text("\($0)".capitalized).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Availability", selection: $model.availability) {
                ForEach(QAScenario.Availability.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("Prior model present (shadow)", isOn: $model.priorPresent)
            if model.priorPresent {
                Picker("Prior model says", selection: $model.priorSignal) {
                    ForEach(CoachingSignal.allCases, id: \.self) { Text("\($0)".capitalized).tag($0) }
                }
            }
        } header: {
            Text("Platform signal (simulated evaluator)")
        } footer: {
            Text("\"Unknown\" means no evidence was found — not safe. These two pickers are the nine QA states the scheme can also set with -AF_SIGNAL and -AF_AVAILABILITY.")
        }
    }

    private var decisionSection: some View {
        Section {
            Button {
                Task { await model.review() }
            } label: {
                HStack {
                    Spacer()
                    if model.isDeciding {
                        ProgressView().padding(.trailing, 6)
                    }
                    Text(model.isDeciding ? "Evaluating…" : "Review & send")
                        .bold()
                    Spacer()
                }
            }
            .disabled(model.isDeciding)

            if let decision = model.lastDecision {
                FrictionLadderView(floor: decision.floor, level: decision.level)
                LabeledContent("Basis", value: model.describe(decision.basis))
                LabeledContent("Elapsed", value: String(format: "%.0f ms", decision.elapsed.milliseconds))
                if let shadow = decision.shadow {
                    LabeledContent("Shadow",
                                   value: shadow.agrees
                                   ? "prior model agrees"
                                   : "prior model would \(shadow.observerEscalates ? "escalate" : "relax") to \(FrictionLevel.name(shadow.observerLevel))")
                }
                if let report = model.lastReport {
                    LabeledContent("Consumption reported", value: model.describe(report.outcome))
                }
            } else {
                Text("No decision yet.").foregroundStyle(.secondary)
            }
        } header: {
            Text("Decision")
        }
    }

    private var ledgerSection: some View {
        Section {
            LabeledContent("Evaluations reported", value: "\(model.ledger.reported)")
            LabeledContent("Outstanding", value: "\(model.ledger.outstanding)")
            LabeledContent("Discarded unreported", value: "\(model.ledger.discardedUnreported)")
            LabeledContent("Remembered unavailability", value: model.rememberedUnavailability)
            LabeledContent("Shadow comparisons", value: "\(model.shadowLedger.comparisons)")
            LabeledContent("· agree / escalate / relax",
                           value: "\(model.shadowLedger.agreements) / \(model.shadowLedger.escalations) / \(model.shadowLedger.relaxations)")
            LabeledContent("· prior unavailable", value: "\(model.shadowLedger.observerUnavailable)")
            LabeledContent("Promotion verdict", value: model.verdictText)
        } header: {
            Text("Ledgers")
        } footer: {
            Text("The verdict needs \(model.minimumShadowSamples) comparisons before zero disagreements can clear a 5% tolerance (95% Wilson upper bound).")
        }
    }

    private var auditSection: some View {
        Section {
            if model.audit.isEmpty {
                Text("No records yet.").foregroundStyle(.secondary)
            } else {
                ForEach(Array(model.audit.enumerated()), id: \.offset) { _, record in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(record.operationDigest) · \(record.category.rawValue)")
                            .font(.footnote.monospaced())
                        Text("\(model.bandName(record.band)) → \(FrictionLevel.name(record.level)) · \(record.basis.rawValue)\(record.signal.map { " · \($0)" } ?? "")")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Audit (newest last, no PII)")
        }
    }
}

// MARK: - Ladder

struct FrictionLadderView: View {
    let floor: FrictionLevel
    let level: FrictionLevel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(FrictionLevel.allCases.reversed(), id: \.self) { rung in
                HStack(spacing: 10) {
                    Circle()
                        .fill(rung == level ? Color.accentColor : (rung <= level ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.2)))
                        .frame(width: 12, height: 12)
                    Text(FrictionLevel.name(rung))
                        .fontWeight(rung == level ? .bold : .regular)
                    Spacer()
                    if rung == floor && rung == level {
                        Tag("floor · decision")
                    } else if rung == floor {
                        Tag("floor")
                    } else if rung == level {
                        Tag("decision")
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, 4)
    }

    private struct Tag: View {
        let text: String
        init(_ text: String) { self.text = text }
        var body: some View {
            Text(text)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.15), in: Capsule())
        }
    }
}

// MARK: - Model

@MainActor
final class FlowModel: ObservableObject {
    struct Evidence: Identifiable {
        let id: String
        let name: String
        let weight: Double
        var present: Bool
    }

    @Published var evidence: [Evidence] = [
        Evidence(id: "new-payee", name: "New payee", weight: 0.20, present: true),
        Evidence(id: "first-large-transfer", name: "First large transfer", weight: 0.25, present: false),
        Evidence(id: "password-changed-today", name: "Password changed today", weight: 0.30, present: false)
    ]
    @Published var signal: CoachingSignal
    @Published var availability: QAScenario.Availability
    @Published var priorPresent = true
    @Published var priorSignal: CoachingSignal = .unknown
    @Published private(set) var isDeciding = false
    @Published private(set) var lastDecision: FrictionDecision?
    @Published private(set) var lastReport: ConsumptionReport?
    @Published private(set) var ledger = ConsumptionLedger()
    @Published private(set) var shadowLedger = ShadowLedger()
    @Published private(set) var rememberedUnavailability = "none"
    @Published private(set) var audit: [AuditRecord] = []

    private let configuration: RiskPolicyConfiguration
    private let source: SimulatedInsightSource
    private let auditSink: InMemoryAuditSink
    private let policy: RiskPolicy
    private let scorer = WeightedRiskScorer()
    private var operationCounter = 0

    init(configuration: SensitiveFlowDemoConfiguration) {
        self.configuration = configuration.policy
        self.signal = configuration.initialScenario.signal
        self.availability = configuration.initialScenario.availability
        let source = SimulatedInsightSource()
        let auditSink = InMemoryAuditSink(capacity: 12)
        self.source = source
        self.auditSink = auditSink
        self.policy = RiskPolicy(configuration: configuration.policy, source: source,
                                 scorer: scorer, audit: auditSink)
    }

    var signals: [RiskSignal] {
        evidence.compactMap { item in
            // Weights are compile-time constants in [0, 1]; a failure here is
            // unreachable but degrades to "signal absent", never to a trap.
            try? RiskSignal(name: item.id, weight: item.weight, present: item.present)
        }
    }

    var score: RiskScore { scorer.score(signals) }
    var band: RiskBand { configuration.thresholds.band(for: score) }
    var floor: FrictionLevel { configuration.matrix.floor(band: band) }
    var bandName: String { bandName(band) }
    var minimumShadowSamples: Int { configuration.shadow?.minimumSamples ?? 0 }

    func bandName(_ band: RiskBand) -> String {
        switch band {
        case .low: return "low"
        case .elevated: return "elevated"
        case .high: return "high"
        }
    }

    var verdictText: String {
        guard let shadow = configuration.shadow else { return "shadow off" }
        switch shadowLedger.verdict(shadow) {
        case .insufficientSamples(let have, let need):
            return "insufficient (\(have)/\(need))"
        case .promotable(let interval):
            return String(format: "promotable (≤ %.1f%%)", interval.upper * 100)
        case .blocked(let interval):
            return String(format: "blocked (upper %.1f%%)", interval.upper * 100)
        }
    }

    func review() async {
        guard !isDeciding else { return }
        isDeciding = true
        defer { isDeciding = false }

        let scenario = QAScenario(signal: signal, availability: availability)
        await source.set(scenario.behaviour(priorSignal: priorPresent ? priorSignal : nil))
        operationCounter = saturatingAdd(operationCounter, 1)
        let operation = SensitiveOperation(id: "txn-\(operationCounter)", category: .payment, signals: signals)

        let decision = await policy.decide(operation)
        await policy.drainReports()
        lastDecision = decision
        let reports = await source.reports
        lastReport = decision.basis.kind == .fused ? reports.last : nil
        ledger = await policy.ledger
        shadowLedger = await policy.shadowLedger
        let remembered = await policy.rememberedUnavailability
        rememberedUnavailability = remembered.map { describe($0) } ?? "none"
        audit = await auditSink.snapshot()
    }

    func describe(_ basis: DecisionBasis) -> String {
        switch basis {
        case .fused(let signal, let model, let selector):
            return "fused · \(signal) from \(selector.rawValue) model \(model)"
        case .appRiskOnly(let reason, let cached):
            return "app risk only · \(describe(reason))\(cached ? " (remembered)" : "")"
        }
    }

    func describe(_ reason: SignalUnavailableReason) -> String {
        switch reason {
        case .entitlementMissing: return "entitlement missing"
        case .notAuthorized(let cooldown):
            if let cooldown { return "not authorized · cooldown " + String(format: "%.0f s", cooldown.milliseconds / 1000) }
            return "not authorized"
        case .offline: return "offline"
        case .rateLimited: return "rate limited"
        case .timedOut: return "deadline expired"
        case .cancelled: return "cancelled"
        case .localBackpressure: return "local backpressure"
        case .failed(let message): return "failed: \(message)"
        }
    }

    func describe(_ outcome: ConsumptionOutcome) -> String {
        switch outcome {
        case .appliedFriction(let level): return "applied \(FrictionLevel.name(level))"
        case .proceeded: return "proceeded"
        case .usedEvaluationOnly: return "evaluation only"
        case .discardedUnreported: return "DISCARDED UNREPORTED"
        }
    }
}

// MARK: - Presentation helpers

extension FrictionLevel {
    static func name(_ level: FrictionLevel) -> String {
        switch level {
        case .proceed: return "Proceed"
        case .educateAndDelay: return "Educate & delay"
        case .outOfBandVerify: return "Out-of-band verify"
        case .holdForReview: return "Hold for review"
        }
    }
}

extension QAScenario.Availability {
    var label: String {
        switch self {
        case .available: return "Available"
        case .notAuthorized: return "Not authorized"
        case .timeout: return "Timeout"
        }
    }
}

extension Duration {
    /// Milliseconds as a `Double`; `components` never traps.
    var milliseconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) * 1_000 + Double(attoseconds) / 1e15
    }
}
#endif
