// CircuitState.swift
// SafeRetry — A composable resilience library for Swift.

// MARK: - CircuitState

/// Represents the current state of a circuit breaker.
///
/// A circuit breaker transitions between these states to protect
/// downstream dependencies from repeated failures.
public enum CircuitState: Sendable, Equatable, CustomStringConvertible {

    /// The circuit is closed; requests flow through normally.
    case closed

    /// The circuit is open; requests are rejected until the given instant.
    case open(until: ContinuousClock.Instant)

    /// The circuit is half-open; a limited number of trial requests are allowed
    /// to test recovery.
    ///
    /// The limit is the breaker's `halfOpenMaxCalls` (default `1`). Trial calls
    /// beyond it are rejected with ``CircuitBreakerError/halfOpenRejected``.
    case halfOpen

    // MARK: - CustomStringConvertible

    /// A human-readable name for this state ("closed", "open", "halfOpen").
    public var description: String {
        switch self {
        case .closed:
            "closed"
        case .open:
            "open"
        case .halfOpen:
            "halfOpen"
        }
    }
}
