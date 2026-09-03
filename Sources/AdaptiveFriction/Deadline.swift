public struct DeadlineExceeded: Error, Sendable, Hashable {
    public let budget: Duration

    public init(budget: Duration) {
        self.budget = budget
    }
}

/// Runs `operation` and gives up after `budget`, cancelling it.
///
/// A sensitive flow pins the evaluator call to the review screen with a hard
/// budget: the user is looking at a "Confirm" button and a multi-second
/// evaluator must not be allowed to hold it hostage. When the budget elapses
/// the operation is cancelled — a cancelled evaluation produced nothing and
/// needs no consumption report — and `DeadlineExceeded` is thrown so the
/// caller can fail open to its own controls.
///
/// Implemented as a two-child task-group race because Swift 6.0 has no
/// standard-library deadline primitive; the first child to finish wins and
/// the group cancels the other on exit.
///
/// - Throws: `DeadlineExceeded` when the budget elapses first, whatever
///   `operation` throws when it fails first, or `CancellationError` if the
///   surrounding task is cancelled.
public func withDeadline<T: Sendable, C: Clock>(
    _ budget: Duration,
    clock: C,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T where C.Duration == Duration {
    // A non-positive budget is a request for "do not even start".
    guard budget > .zero else { throw DeadlineExceeded(budget: budget) }

    return try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await clock.sleep(for: budget)
            return nil
        }
        // The first child to complete decides the outcome. `next()` returns
        // `nil` only when the group is empty, which cannot happen here because
        // two children were just added; the fallback treats that impossible
        // case as a timeout rather than trapping.
        let first = try await group.next()
        group.cancelAll()
        guard let value = first, let unwrapped = value else {
            throw DeadlineExceeded(budget: budget)
        }
        return unwrapped
    }
}
