/// One piece of the app's own evidence about an operation.
///
/// Deliberately not the amount, the payee, or anything that identifies the
/// user: a risk signal is a named, weighted boolean so that the audit record
/// built from it carries no PII by construction.
public struct RiskSignal: Sendable, Hashable, Codable {
    public let name: String
    /// Contribution to the score in `[0, 1]`.
    public let weight: Double
    public let present: Bool

    /// - Throws: `PolicyError.invalidWeight` unless `weight` is finite and in `[0, 1]`.
    public init(name: String, weight: Double, present: Bool) throws {
        guard weight.isFinite, weight >= 0, weight <= 1 else {
            throw PolicyError.invalidWeight(name: name, weight: weight)
        }
        self.name = name
        self.weight = weight
        self.present = present
    }
}

/// A score in `[0, 1]`. The initializer clamps, so a scorer can never hand the
/// bands an out-of-range or non-finite value.
public struct RiskScore: Sendable, Hashable, Codable {
    public let value: Double

    public init(clamping raw: Double) {
        if raw.isNaN {
            value = 0
        } else {
            value = min(max(raw, 0), 1)
        }
    }
}

/// How the app turns its signals into a score. Injected so a product team can
/// swap the arithmetic without touching the fusion rule.
public protocol AppRiskScorer: Sendable {
    func score(_ signals: [RiskSignal]) -> RiskScore
}

/// Sum of the weights of the present signals, clamped to `[0, 1]`.
///
/// Additive on purpose: two independent weak signals should add up, and the
/// clamp — not the weights — is what keeps the result in range. A
/// multiplicative or max-based scorer is a one-line alternative conformance.
public struct WeightedRiskScorer: AppRiskScorer {
    public init() {}

    public func score(_ signals: [RiskSignal]) -> RiskScore {
        var total = 0.0
        for signal in signals where signal.present {
            total += signal.weight
        }
        return RiskScore(clamping: total)
    }
}
