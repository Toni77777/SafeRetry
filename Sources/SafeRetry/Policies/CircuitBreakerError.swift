// CircuitBreakerError.swift
// SafeRetry — A composable resilience library for Swift.

// MARK: - CircuitBreakerError

/// Errors thrown by ``CircuitBreaker`` when a call cannot proceed.
public enum CircuitBreakerError: Error, Sendable, Equatable, CustomStringConvertible {

    /// The circuit is open and rejecting all calls.
    ///
    /// - Parameter retryAfter: The remaining duration before the circuit
    ///   transitions to half-open.
    case open(retryAfter: Duration)

    /// The circuit is half-open but has reached its concurrent call limit.
    case halfOpenRejected

    // MARK: - Backoff Guidance

    /// How long to wait before retrying, when the breaker can say.
    ///
    /// Lets a caller back off without switching on the case:
    ///
    /// ```swift
    /// } catch let error as CircuitBreakerError {
    ///     try await Task.sleep(for: error.retryAfter ?? .seconds(1))
    /// }
    /// ```
    ///
    /// `nil` for ``halfOpenRejected``: a trial slot frees when the in-flight
    /// probe completes, and that has no deadline to report.
    public var retryAfter: Duration? {
        switch self {
        case .open(let retryAfter):
            retryAfter
        case .halfOpenRejected:
            nil
        }
    }

    /// A human-readable description including the rejection reason.
    public var description: String {
        switch self {
        case .open(let retryAfter):
            "Circuit breaker is open; retry after \(retryAfter)"
        case .halfOpenRejected:
            "Circuit breaker is half-open and at capacity"
        }
    }
}
