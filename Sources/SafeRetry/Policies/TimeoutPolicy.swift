// TimeoutPolicy.swift
// SafeRetry — A composable resilience library for Swift.

// MARK: - TimeoutPolicy

/// Cancels an operation that exceeds a specified duration.
///
/// Uses structured concurrency to race the operation against an internal
/// timer. If the timer fires first, the operation's child task is
/// cancelled and ``TimeoutError`` is thrown.
///
/// ## The operation must be cancellable
///
/// The timeout is enforced by *cancelling* the operation, not by abandoning
/// it. Because the operation runs as a child task, ``execute(_:)`` cannot
/// return until that child actually finishes — structured concurrency awaits
/// it. An operation that never checks for cancellation (a blocking
/// synchronous call, a `Task.sleep` whose error is swallowed, a third-party
/// API with no cancellation support) therefore delays ``TimeoutError`` past
/// the deadline by however long it keeps running.
///
/// Every cancellation-aware API — `URLSession`'s async methods,
/// `Task.sleep(for:)`, anything that calls `Task.checkCancellation()` —
/// returns at the deadline as expected.
///
/// ## Cost
///
/// Each call creates a task group with two child tasks — the operation and
/// the timer. That is negligible next to a network request, which is the
/// intended use, but it costs far more than an in-memory read; keep timeouts
/// off hot in-process paths.
///
/// ```swift
/// let policy = TimeoutPolicy(duration: .seconds(5))
/// let data = try await policy.execute {
///     try await urlSession.data(from: url)
/// }
/// ```
public struct TimeoutPolicy: Sendable {

    // MARK: - Configuration

    /// The maximum duration the operation is allowed to run.
    public let duration: Duration

    /// Optional callback invoked when the timeout is exceeded.
    private let onEvent: (@Sendable (PolicyEvent) -> Void)?

    // MARK: - Initialisation

    /// Creates a timeout policy with the given duration.
    ///
    /// - Parameters:
    ///   - duration: The maximum time allowed for the operation.
    ///     Must be greater than zero.
    ///   - onEvent: Optional synchronous callback invoked on policy events.
    ///     Runs inline with execution, so it must not block. Spawn a `Task`
    ///     inside the closure if async work is required.
    public init(
        duration: Duration,
        onEvent: (@Sendable (PolicyEvent) -> Void)? = nil
    ) {
        precondition(duration > .zero, "duration must be greater than zero")
        self.duration = duration
        self.onEvent = onEvent
    }

    // MARK: - Execute

    /// Executes `operation`, cancelling it if it exceeds ``duration``.
    ///
    /// - Parameter operation: The async throwing closure to run with a timeout.
    /// - Returns: The value produced by `operation` if it completes in time.
    /// - Throws: ``TimeoutError`` if the operation exceeds the timeout,
    ///   the original error if the operation fails before the timeout, or
    ///   `CancellationError` if the task is cancelled — including when it is
    ///   already cancelled on entry, in which case the operation does not run.
    public func execute<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        // Without this, an already-cancelled caller still spawns both children:
        // the timer's sleep fails at once, but the group must then wait out an
        // operation that ignores cancellation, only to discard its result.
        try Task.checkCancellation()

        return try await withThrowingTaskGroup(of: Outcome<T>.self) { group in
            group.addTask {
                do {
                    return .success(try await operation())
                } catch {
                    return .failure(error)
                }
            }

            group.addTask {
                do {
                    try await Task.sleep(for: self.duration)
                    return .timeout
                } catch {
                    // Timer was cancelled — operation finished first or outer
                    // task was cancelled. Return a sentinel that will either be
                    // discarded (operation won) or handled below.
                    return .cancelled
                }
            }

            defer { group.cancelAll() }

            // The first child to complete determines the outcome.
            // Force-unwrap is safe: we added exactly two children.
            switch try await group.next()! {
            case .success(let value):
                return value
            case .failure(let error):
                throw error
            case .timeout:
                emitEvent(.timeoutExceeded(duration: self.duration))
                throw TimeoutError(duration: self.duration)
            case .cancelled:
                // Timer was cancelled before the operation produced a result.
                // This only happens when the outer task itself is cancelled,
                // propagating CancellationError to both children simultaneously.
                throw CancellationError()
            }
        }
    }

    // MARK: - Event Emission

    private func emitEvent(_ event: PolicyEvent) {
        onEvent?(event)
    }
}

// MARK: - Private Helpers

/// Internal result type for the race between operation and timer.
///
/// Both child tasks catch their own errors and return an ``Outcome``
/// instead of throwing, so the task group never has unconsumed child
/// errors when the body returns.
private enum Outcome<T: Sendable>: Sendable {
    /// The operation completed successfully.
    case success(T)
    /// The operation threw an error (including `CancellationError`).
    case failure(any Error)
    /// The timer expired — the operation took too long.
    case timeout
    /// The timer was cancelled before it could fire.
    case cancelled
}
