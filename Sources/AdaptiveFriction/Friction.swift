/// The friction ladder. Ordered: each rung is strictly more friction than the
/// one before it, and every rule in the package is monotone over this order.
public enum FrictionLevel: Int, Sendable, CaseIterable, Codable, Hashable, Comparable {
    /// No added friction; the flow's existing controls apply.
    case proceed = 0
    /// Show scam-education content and impose a short mandatory delay.
    case educateAndDelay = 1
    /// Require verification on a channel the coach cannot be on (callback to a
    /// number on file, in-branch, a second device).
    case outOfBandVerify = 2
    /// Do not complete the operation; queue it for human review.
    case holdForReview = 3

    public static func < (lhs: FrictionLevel, rhs: FrictionLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// The app's own risk score bucketed into bands. Ordered.
public enum RiskBand: Int, Sendable, CaseIterable, Codable, Hashable, Comparable {
    case low = 0
    case elevated = 1
    case high = 2

    public static func < (lhs: RiskBand, rhs: RiskBand) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Where the band boundaries sit on the unit interval.
public struct BandThresholds: Sendable, Hashable, Codable {
    /// Scores at or above this are `.elevated`.
    public let elevatedAt: Double
    /// Scores at or above this are `.high`.
    public let highAt: Double

    /// - Throws: `PolicyError.invalidThresholds` unless `0 < elevatedAt < highAt <= 1`.
    public init(elevatedAt: Double, highAt: Double) throws {
        guard elevatedAt.isFinite, highAt.isFinite,
              elevatedAt > 0, elevatedAt < highAt, highAt <= 1 else {
            throw PolicyError.invalidThresholds(elevatedAt: elevatedAt, highAt: highAt)
        }
        self.elevatedAt = elevatedAt
        self.highAt = highAt
    }

    /// `elevated` from 0.35, `high` from 0.70.
    public static let standard: BandThresholds = {
        // Provably valid: 0 < 0.35 < 0.70 <= 1.
        // swiftlint:disable:next force_try
        try! BandThresholds(elevatedAt: 0.35, highAt: 0.70)
    }()

    public func band(for score: RiskScore) -> RiskBand {
        if score.value >= highAt { return .high }
        if score.value >= elevatedAt { return .elevated }
        return .low
    }
}

/// The fusion rule: (app risk band, coaching signal) → friction.
///
/// Validated at construction so that the one invariant the whole design rests
/// on is enforced by the type rather than by convention:
///
/// > A coaching signal can only ever *raise* friction above what the app's own
/// > risk band would apply. `unknown` — "no evidence" — yields exactly the
/// > band's floor, and `medium`/`high` are monotone non-decreasing from it.
///
/// The matrix is also monotone across bands for a fixed signal, so a higher
/// app risk never gets *less* friction than a lower one.
public struct FrictionMatrix: Sendable, Hashable {
    private let cells: [RiskBand: [CoachingSignal: FrictionLevel]]

    /// - Throws: `PolicyError.matrixIncomplete` if any (band, signal) cell is
    ///   missing; `PolicyError.matrixNotMonotone` if any row or column
    ///   decreases.
    public init(_ cells: [RiskBand: [CoachingSignal: FrictionLevel]]) throws {
        for band in RiskBand.allCases {
            for signal in CoachingSignal.allCases {
                guard cells[band]?[signal] != nil else {
                    throw PolicyError.matrixIncomplete(band: band, signal: signal)
                }
            }
        }
        // Rows: for a fixed band, friction must not decrease as the signal rises.
        for band in RiskBand.allCases {
            var previous: FrictionLevel? = nil
            for signal in CoachingSignal.allCases {
                // Safe: completeness was checked above.
                let level = cells[band]?[signal] ?? .proceed
                if let previous, level < previous {
                    throw PolicyError.matrixNotMonotone(band: band, signal: signal, level: level, previous: previous)
                }
                previous = level
            }
        }
        // Columns: for a fixed signal, friction must not decrease as risk rises.
        for signal in CoachingSignal.allCases {
            var previous: FrictionLevel? = nil
            for band in RiskBand.allCases {
                let level = cells[band]?[signal] ?? .proceed
                if let previous, level < previous {
                    throw PolicyError.matrixNotMonotone(band: band, signal: signal, level: level, previous: previous)
                }
                previous = level
            }
        }
        self.cells = cells
    }

    public func level(band: RiskBand, signal: CoachingSignal) -> FrictionLevel {
        // Safe: `init` guarantees every cell exists; the fallback is unreachable
        // and chosen to be the floor so a hypothetical gap can never *lower*
        // friction below `proceed` — there is nothing below it.
        cells[band]?[signal] ?? .proceed
    }

    /// The friction the app applies on its own evidence alone.
    public func floor(band: RiskBand) -> FrictionLevel {
        level(band: band, signal: .unknown)
    }

    /// A defensible default for a payments flow:
    ///
    /// | band \ signal | unknown          | medium           | high             |
    /// |---------------|------------------|------------------|------------------|
    /// | low           | proceed          | educateAndDelay  | outOfBandVerify  |
    /// | elevated      | educateAndDelay  | outOfBandVerify  | holdForReview    |
    /// | high          | outOfBandVerify  | holdForReview    | holdForReview    |
    public static let standard: FrictionMatrix = {
        // Provably valid: every cell present, every row and column non-decreasing.
        // swiftlint:disable:next force_try
        try! FrictionMatrix([
            .low:      [.unknown: .proceed,         .medium: .educateAndDelay, .high: .outOfBandVerify],
            .elevated: [.unknown: .educateAndDelay, .medium: .outOfBandVerify, .high: .holdForReview],
            .high:     [.unknown: .outOfBandVerify, .medium: .holdForReview,   .high: .holdForReview]
        ])
    }()
}

public enum PolicyError: Error, Sendable, Hashable {
    case invalidThresholds(elevatedAt: Double, highAt: Double)
    case matrixIncomplete(band: RiskBand, signal: CoachingSignal)
    case matrixNotMonotone(band: RiskBand, signal: CoachingSignal, level: FrictionLevel, previous: FrictionLevel)
    case invalidWeight(name: String, weight: Double)
    case invalidConfiguration(String)
    case shadowSelectorsMustDiffer
}
