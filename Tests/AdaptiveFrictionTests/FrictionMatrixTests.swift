import XCTest
@testable import AdaptiveFriction

final class FrictionMatrixTests: XCTestCase {

    func testStandardMatrixCellsAreTheDocumentedTable() {
        let m = FrictionMatrix.standard
        XCTAssertEqual(m.level(band: .low, signal: .unknown), .proceed)
        XCTAssertEqual(m.level(band: .low, signal: .medium), .educateAndDelay)
        XCTAssertEqual(m.level(band: .low, signal: .high), .outOfBandVerify)
        XCTAssertEqual(m.level(band: .elevated, signal: .unknown), .educateAndDelay)
        XCTAssertEqual(m.level(band: .elevated, signal: .medium), .outOfBandVerify)
        XCTAssertEqual(m.level(band: .elevated, signal: .high), .holdForReview)
        XCTAssertEqual(m.level(band: .high, signal: .unknown), .outOfBandVerify)
        XCTAssertEqual(m.level(band: .high, signal: .medium), .holdForReview)
        XCTAssertEqual(m.level(band: .high, signal: .high), .holdForReview)
    }

    /// The load-bearing invariant: a matrix in which `high` coaching yields
    /// *less* friction than "no evidence" must be impossible to construct.
    func testRowThatLetsASignalLowerFrictionIsRejected() {
        var cells = Self.standardCells
        cells[.low] = [.unknown: .educateAndDelay, .medium: .educateAndDelay, .high: .proceed]
        XCTAssertThrowsError(try FrictionMatrix(cells)) { error in
            guard case PolicyError.matrixNotMonotone(let band, let signal, let level, let previous) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(band, .low)
            XCTAssertEqual(signal, .high)
            XCTAssertEqual(level, .proceed)
            XCTAssertEqual(previous, .educateAndDelay)
        }
    }

    func testColumnThatGivesHigherRiskLessFrictionIsRejected() {
        var cells = Self.standardCells
        cells[.high] = [.unknown: .proceed, .medium: .holdForReview, .high: .holdForReview]
        XCTAssertThrowsError(try FrictionMatrix(cells)) { error in
            guard case PolicyError.matrixNotMonotone(let band, let signal, _, _) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(band, .high)
            XCTAssertEqual(signal, .unknown)
        }
    }

    func testMissingCellIsRejected() {
        var cells = Self.standardCells
        cells[.elevated]?[.medium] = nil
        XCTAssertThrowsError(try FrictionMatrix(cells)) { error in
            guard case PolicyError.matrixIncomplete(let band, let signal) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(band, .elevated)
            XCTAssertEqual(signal, .medium)
        }
    }

    func testAFlatMatrixIsLegalBecauseMonotoneIsNonStrict() throws {
        var cells: [RiskBand: [CoachingSignal: FrictionLevel]] = [:]
        for band in RiskBand.allCases {
            cells[band] = [.unknown: .educateAndDelay, .medium: .educateAndDelay, .high: .educateAndDelay]
        }
        let matrix = try FrictionMatrix(cells)
        XCTAssertEqual(matrix.level(band: .high, signal: .high), .educateAndDelay)
    }

    func testThresholdValidation() {
        XCTAssertThrowsError(try BandThresholds(elevatedAt: 0.70, highAt: 0.35))
        XCTAssertThrowsError(try BandThresholds(elevatedAt: 0, highAt: 0.5))
        XCTAssertThrowsError(try BandThresholds(elevatedAt: 0.5, highAt: 1.5))
        XCTAssertThrowsError(try BandThresholds(elevatedAt: .nan, highAt: 0.5))
        XCTAssertThrowsError(try BandThresholds(elevatedAt: 0.5, highAt: 0.5))
        XCTAssertNoThrow(try BandThresholds(elevatedAt: 0.01, highAt: 1.0))
    }

    func testBandBoundariesAreInclusiveAtTheLowEnd() {
        let t = BandThresholds.standard
        XCTAssertEqual(t.band(for: RiskScore(clamping: 0.3499)), .low)
        XCTAssertEqual(t.band(for: RiskScore(clamping: 0.35)), .elevated)
        XCTAssertEqual(t.band(for: RiskScore(clamping: 0.6999)), .elevated)
        XCTAssertEqual(t.band(for: RiskScore(clamping: 0.70)), .high)
        XCTAssertEqual(t.band(for: RiskScore(clamping: 1.0)), .high)
    }

    static var standardCells: [RiskBand: [CoachingSignal: FrictionLevel]] {
        [
            .low:      [.unknown: .proceed,         .medium: .educateAndDelay, .high: .outOfBandVerify],
            .elevated: [.unknown: .educateAndDelay, .medium: .outOfBandVerify, .high: .holdForReview],
            .high:     [.unknown: .outOfBandVerify, .medium: .holdForReview,   .high: .holdForReview]
        ]
    }
}

final class RiskScoreTests: XCTestCase {

    func testScoreClampsEveryPathologicalInput() {
        XCTAssertEqual(RiskScore(clamping: .nan).value, 0)
        XCTAssertEqual(RiskScore(clamping: .infinity).value, 1)
        XCTAssertEqual(RiskScore(clamping: -.infinity).value, 0)
        XCTAssertEqual(RiskScore(clamping: -0.2).value, 0)
        XCTAssertEqual(RiskScore(clamping: 1.7).value, 1)
        XCTAssertEqual(RiskScore(clamping: 0.42).value, 0.42)
    }

    func testWeightedScorerSumsPresentSignalsAndClampsToOne() throws {
        let signals = [
            try RiskSignal(name: "a", weight: 0.6, present: true),
            try RiskSignal(name: "b", weight: 0.7, present: true),
            try RiskSignal(name: "c", weight: 0.9, present: false)
        ]
        XCTAssertEqual(WeightedRiskScorer().score(signals).value, 1.0)
        XCTAssertEqual(WeightedRiskScorer().score([signals[0]]).value, 0.6, accuracy: 1e-12)
        XCTAssertEqual(WeightedRiskScorer().score([]).value, 0)
    }

    func testInvalidWeightsAreRejected() {
        XCTAssertThrowsError(try RiskSignal(name: "x", weight: 1.2, present: true))
        XCTAssertThrowsError(try RiskSignal(name: "x", weight: -0.1, present: true))
        XCTAssertThrowsError(try RiskSignal(name: "x", weight: .nan, present: true))
        XCTAssertThrowsError(try RiskSignal(name: "x", weight: .infinity, present: true))
    }
}
