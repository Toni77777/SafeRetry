// PolicyEvent.swift
// SafeRetry — A composable resilience library for Swift.

// MARK: - PolicyEvent

/// Describes lifecycle events for resilience policies.
///
/// Every built-in policy emits its own subset through the `onEvent` callback
/// taken at initialisation:
///
/// | Case | Emitted by |
/// |---|---|
/// | ``attemptStarted(attempt:)`` | ``RetryPolicy`` |
/// | ``attemptSucceeded(attempt:duration:)`` | ``RetryPolicy`` |
/// | ``attemptFailed(attempt:error:nextDelay:)`` | ``RetryPolicy`` |
/// | ``retryExhausted(totalAttempts:lastError:)`` | ``RetryPolicy`` |
/// | ``retryScheduled(attempt:delay:)`` | ``RetryPolicy`` |
/// | ``circuitStateChanged(from:to:)`` | ``CircuitBreaker`` |
/// | ``circuitCallRejected(state:)`` | ``CircuitBreaker`` |
/// | ``timeoutExceeded(duration:)`` | ``TimeoutPolicy`` |
/// | ``fallbackUsed`` | ``FallbackPolicy``, ``FallbackChain`` (when given `onEvent`) |
///
/// Any case can also be emitted manually through ``EventStream`` to build a
/// custom instrumentation pipeline. See <doc:Observability>.
///
/// Policies created by the ``PolicyChain`` shorthand factories
/// (`.retry(attempts:…)`, `.timeout(_ duration:)`) carry no callback — pass a
/// pre-built policy to the chain to observe their events.
public enum PolicyEvent: Sendable {

    // MARK: - Retry Events

    /// A new execution attempt has started.
    ///
    /// - Parameter attempt: The 1-based attempt index.
    case attemptStarted(attempt: Int)

    /// An attempt completed successfully.
    ///
    /// - Parameters:
    ///   - attempt: The 1-based attempt index.
    ///   - duration: Wall-clock time the attempt took.
    case attemptSucceeded(attempt: Int, duration: Duration)

    /// An attempt failed with the given error.
    ///
    /// - Parameters:
    ///   - attempt: The 1-based attempt index.
    ///   - error: The error that caused the failure.
    ///   - nextDelay: The delay before the next retry, or `nil` if no retry is scheduled.
    case attemptFailed(attempt: Int, error: any Error, nextDelay: Duration?)

    /// All retry attempts have been exhausted.
    ///
    /// - Parameters:
    ///   - totalAttempts: The total number of attempts made.
    ///   - lastError: The error from the final attempt.
    case retryExhausted(totalAttempts: Int, lastError: any Error)

    /// A retry has been scheduled after a delay.
    ///
    /// - Parameters:
    ///   - attempt: The 1-based index of the upcoming attempt.
    ///   - delay: The duration to wait before the next attempt.
    case retryScheduled(attempt: Int, delay: Duration)

    // MARK: - Circuit Breaker Events

    /// The circuit breaker transitioned between states.
    ///
    /// - Parameters:
    ///   - from: The previous state.
    ///   - to: The new state.
    case circuitStateChanged(from: CircuitState, to: CircuitState)

    /// A call was rejected because the circuit is not closed.
    ///
    /// - Parameter state: The current circuit state at the time of rejection.
    case circuitCallRejected(state: CircuitState)

    // MARK: - Timeout Events

    /// An operation exceeded its allowed duration.
    ///
    /// - Parameter duration: The timeout threshold that was exceeded.
    case timeoutExceeded(duration: Duration)

    // MARK: - Fallback Events

    /// A fallback value was used in place of the failed operation.
    case fallbackUsed
}
