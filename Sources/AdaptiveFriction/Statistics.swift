/// A closed interval on the unit line.
public struct ProportionInterval: Sendable, Hashable, Codable {
    public let lower: Double
    public let upper: Double
    public let point: Double
}

/// Wilson score interval for a binomial proportion.
///
/// Chosen over the normal approximation because shadow ledgers are small
/// (tens of samples) and disagreement rates are near zero, which is exactly
/// where the normal interval collapses to a width of zero and lies. `z` is
/// 1.96 for the 95% interval.
///
/// Returns `nil` when there are no samples: a rate over nothing is not a
/// number, and callers must decide, not divide.
public func wilsonInterval(successes: Int, trials: Int, z: Double = 1.96) -> ProportionInterval? {
    guard trials > 0, successes >= 0, successes <= trials, z.isFinite, z > 0 else { return nil }
    let n = Double(trials)
    let p = Double(successes) / n
    let z2 = z * z
    let denominator = 1 + z2 / n
    let centre = (p + z2 / (2 * n)) / denominator
    let spread = (z / denominator) * (p * (1 - p) / n + z2 / (4 * n * n)).squareRoot()
    let lower = max(0, centre - spread)
    let upper = min(1, centre + spread)
    return ProportionInterval(lower: lower, upper: upper, point: p)
}

/// Integer addition that saturates at `Int.max` instead of trapping.
///
/// Counters in long-lived ledgers are the one place an overflow trap is both
/// plausible and unrecoverable, so they go through this rather than `+`.
@inlinable
public func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
    let (sum, overflow) = lhs.addingReportingOverflow(rhs)
    if overflow {
        return rhs > 0 ? Int.max : Int.min
    }
    return sum
}
