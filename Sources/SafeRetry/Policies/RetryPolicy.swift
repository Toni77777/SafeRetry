// RetryPolicy.swift
// SafeRetry — A composable resilience library for Swift.

// MARK: - RetryPolicy

/// Retries a failable operation according to a configurable strategy.
///
/// The policy re-executes the given closure up to ``maxAttempts`` times,
/// pausing between retries according to the chosen ``DelayStrategy`` and
/// ``JitterStrategy``.  Cancellation is respected immediately — a cancelled
/// task will not start another attempt.
///
/// `RetryPolicy` is a value type with no mutable state. Multiple callers
/// can share the same instance and execute concurrently without serialization.
///
/// ```swift
/// let policy = RetryPolicy(maxAttempts: 3, delay: .exponential(base: .seconds(1)))
/// let data = try await policy.execute {
///     try await urlSession.data(from: url)
/// }
/// ```
public struct RetryPolicy: Sendable {

    // MARK: - Configuration

    /// The maximum number of times the operation will be attempted.
    public let maxAttempts: Int

    /// The backoff strategy used to compute inter-retry delays.
    public let delay: DelayStrategy

    /// The jitter strategy applied on top of the computed delay.
    public let jitter: JitterStrategy

    /// Optional callback invoked on every policy event.
    private let onEvent: (@Sendable (PolicyEvent) -> Void)?

    /// The sleep implementation used to wait out inter-retry delays.
    ///
    /// Defaults to `Task.sleep(for:)`. Overridden internally by tests to
    /// verify computed delays without waiting in real time.
    private let sleep: @Sendable (Duration) async throws -> Void

    // MARK: - Initialisation

    /// Creates a retry policy with the given configuration.
    ///
    /// - Parameters:
    ///   - maxAttempts: Total number of attempts (including the first). Must be ≥ 1.
    ///   - delay: The backoff strategy between retries. Defaults to ``DelayStrategy/immediate``.
    ///   - jitter: The jitter strategy applied to each delay. Defaults to ``JitterStrategy/none``.
    ///   - onEvent: Optional synchronous callback invoked on every policy event.
    ///     The callback runs inline with retry execution, so it must not block.
    ///     Spawn a `Task` inside the closure if async work is required — but
    ///     tasks spawned per event can finish out of order. When order matters,
    ///     forward events into an ``EventStream`` and consume it from a single task.
    public init(
        maxAttempts: Int = 3,
        delay: DelayStrategy = .immediate,
        jitter: JitterStrategy = .none,
        onEvent: (@Sendable (PolicyEvent) -> Void)? = nil
    ) {
        self.init(
            maxAttempts: maxAttempts,
            delay: delay,
            jitter: jitter,
            onEvent: onEvent,
            sleep: { try await Task.sleep(for: $0) }
        )
    }

    /// Internal initialiser with injectable sleep for testing.
    init(
        maxAttempts: Int = 3,
        delay: DelayStrategy = .immediate,
        jitter: JitterStrategy = .none,
        onEvent: (@Sendable (PolicyEvent) -> Void)? = nil,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) {
        precondition(maxAttempts >= 1, "maxAttempts must be at least 1")
        self.maxAttempts = maxAttempts
        self.delay = delay
        self.jitter = jitter
        self.onEvent = onEvent
        self.sleep = sleep
    }

    // MARK: - Execute

    /// Executes `operation`, retrying on failure up to ``maxAttempts`` times.
    ///
    /// - Parameter operation: The async throwing closure to attempt.
    /// - Returns: The value produced by `operation` on the first successful attempt.
    /// - Throws: The last error if all attempts are exhausted, or the
    ///   cancellation error if the task is cancelled. A cancelled attempt does
    ///   not consume the retry budget; both `CancellationError` and
    ///   `URLError(.cancelled)` count as cancellation.
    ///
    /// - Note: A cancelled attempt emits no terminal event — see the
    ///   `shouldRetry` overload for the full event contract.
    public func execute<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await execute(shouldRetry: { _, _ in true }, operation)
    }

    /// Executes `operation`, retrying only when `shouldRetry` returns `true`.
    ///
    /// Use this overload to stop retrying for non-transient failures while still
    /// using the policy's attempt count and delay configuration.
    ///
    /// - Parameters:
    ///   - shouldRetry: Predicate that decides whether a failed attempt should be retried.
    ///     Receives the thrown error and the 1-based attempt index that failed.
    ///   - operation: The async throwing closure to attempt.
    /// - Returns: The value produced by `operation` on the first successful attempt.
    /// - Throws: The thrown error when retries are exhausted or disallowed, or
    ///   the cancellation error if the task is cancelled. A cancelled attempt
    ///   does not consume the retry budget; both `CancellationError` and
    ///   `URLError(.cancelled)` count as cancellation.
    ///
    /// - Note: `shouldRetry` is not consulted on the final attempt — there is
    ///   no retry left to authorise. A veto throws the error directly without
    ///   emitting ``PolicyEvent/retryExhausted(totalAttempts:lastError:)``,
    ///   which is reserved for an actually-exhausted attempt budget. If the
    ///   task is cancelled during the backoff delay, the cancellation error is
    ///   thrown and the operation's own error is not preserved.
    ///
    /// - Note: A cancelled attempt is rethrown before any event is emitted, so
    ///   its ``PolicyEvent/attemptStarted(attempt:)`` has no matching
    ///   ``PolicyEvent/attemptSucceeded(attempt:duration:)``,
    ///   ``PolicyEvent/attemptFailed(attempt:error:nextDelay:)``, or
    ///   ``PolicyEvent/retryExhausted(totalAttempts:lastError:)``. Cancellation
    ///   is not a policy outcome, so the policy reports none. An observer that
    ///   pairs starts with terminal events — an in-flight gauge, a latency
    ///   histogram — has to treat an unmatched start as a cancelled attempt
    ///   rather than a leak.
    public func execute<T: Sendable>(
        shouldRetry: @Sendable (_ error: any Error, _ attempt: Int) -> Bool,
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        var lastError: (any Error)?
        let clock = ContinuousClock()

        for attempt in 1...maxAttempts {
            try Task.checkCancellation()
            emitEvent(.attemptStarted(attempt: attempt))

            let start = clock.now
            do {
                let result = try await operation()
                emitEvent(.attemptSucceeded(attempt: attempt, duration: clock.now - start))
                return result
            } catch where isCancellation(error) {
                throw error
            } catch {
                lastError = error
                guard attempt < maxAttempts else {
                    emitEvent(.attemptFailed(attempt: attempt, error: error, nextDelay: nil))
                    break
                }
                guard shouldRetry(error, attempt) else {
                    emitEvent(.attemptFailed(attempt: attempt, error: error, nextDelay: nil))
                    throw error
                }

                let baseDelay = delay.delay(forAttempt: attempt)
                let jitteredDelay = jitter.apply(to: baseDelay)
                emitEvent(.attemptFailed(attempt: attempt, error: error, nextDelay: jitteredDelay))
                emitEvent(.retryScheduled(attempt: attempt + 1, delay: jitteredDelay))
                if jitteredDelay > .zero {
                    try await sleep(jitteredDelay)
                }
            }
        }

        guard let lastError else {
            preconditionFailure("RetryPolicy exhausted without a terminal result or error.")
        }
        emitEvent(.retryExhausted(totalAttempts: maxAttempts, lastError: lastError))
        throw lastError
    }

    // MARK: - Event Emission

    private func emitEvent(_ event: PolicyEvent) {
        onEvent?(event)
    }
}
