import Foundation

/// The minimal record needed to label an evaluation offline as fraud / not
/// fraud and to reconstruct *why* the app applied the friction it did.
///
/// What is deliberately **not** here: the amount, the payee, the account, the
/// user, the device. The operation identifier is stored as a one-way digest
/// so that the record can be joined to the app's own transaction log by
/// whoever holds that log, and by nobody else.
public struct AuditRecord: Sendable, Hashable, Codable {
    public let operationDigest: String
    public let category: OperationCategory
    public let band: RiskBand
    public let level: FrictionLevel
    public let basis: DecisionBasisKind
    public let signal: CoachingSignal?
    public let modelVersion: ModelVersion?
    public let shadowAgreed: Bool?
    public let recordedAt: Date
}

/// The basis of a decision, flattened for the audit record.
public enum DecisionBasisKind: String, Sendable, Hashable, Codable {
    case fused
    case appRiskOnly
}

public protocol AuditSink: Sendable {
    func record(_ record: AuditRecord) async
}

/// Keeps the newest `capacity` records. Bounded so a long session cannot grow
/// without limit; the eviction is FIFO because audit is a stream, not a cache.
public actor InMemoryAuditSink: AuditSink {
    public private(set) var records: [AuditRecord] = []
    public let capacity: Int

    /// - Parameter capacity: clamped to at least 1.
    public init(capacity: Int = 200) {
        self.capacity = max(1, capacity)
    }

    public func record(_ record: AuditRecord) {
        records.append(record)
        if records.count > capacity {
            records.removeFirst(records.count - capacity)
        }
    }

    public func snapshot() -> [AuditRecord] { records }
}

/// FNV-1a, 64-bit. Stable across processes and platforms, unlike `Hasher`,
/// which is seeded per process and would make the digest useless as a join
/// key. Not a cryptographic hash: it hides the identifier from a casual reader
/// of the audit log, and the README is explicit that a keyed hash belongs here
/// in production.
public func operationDigest(_ identifier: String) -> String {
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in identifier.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x100000001b3
    }
    return String(hash, radix: 16)
}
