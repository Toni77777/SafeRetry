// SafeRetry.swift
// SafeRetry — A composable resilience library for Swift.

// MARK: - Public Namespace

/// Top-level namespace for the SafeRetry library.
///
/// Provides convenience static methods for one-off resilient operations
/// and access to the shared ``PolicyRegistry``.
///
/// ```swift
/// let user = try await SafeRetry.retry(attempts: 3) {
///     try await api.fetchUser()
/// }
/// ```
public enum SafeRetry: Sendable {

    // MARK: - Registry

    /// Convenience accessor for the shared ``PolicyRegistry``.
    public static var registry: PolicyRegistry { PolicyRegistry.shared }

    // MARK: - Convenience Methods

    /// Retries an operation with the given parameters.
    ///
    /// A shorthand for creating a ``RetryPolicy`` and calling its
    /// ``RetryPolicy/execute(_:)`` method.
    ///
    /// - Parameters:
    ///   - attempts: The maximum number of attempts, including the first. Must be
    ///     at least 1; a smaller value traps, matching
    ///     ``RetryPolicy/init(maxAttempts:delay:jitter:onEvent:)``.
    ///   - delay: The backoff strategy. Defaults to exponential with a 1 s base.
    ///   - operation: The async throwing closure to retry.
    /// - Returns: The value produced by `operation` on the first successful attempt.
    /// - Throws: The last error after all attempts are exhausted, or the
    ///   cancellation error if the task is cancelled.
    public static func retry<T: Sendable>(
        attempts: Int,
        delay: DelayStrategy = .exponential(base: .seconds(1)),
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        let policy = RetryPolicy(maxAttempts: attempts, delay: delay)
        return try await policy.execute(operation)
    }

    /// Executes an operation through the given circuit breaker.
    ///
    /// A shorthand for calling ``CircuitBreaker/execute(_:)`` directly.
    ///
    /// - Parameters:
    ///   - breaker: The ``CircuitBreaker`` actor to guard the call.
    ///   - operation: The async throwing closure to execute.
    /// - Returns: The value produced by `operation`.
    /// - Throws: ``CircuitBreakerError`` if the circuit is open, or any
    ///   error thrown by the operation.
    public static func withCircuitBreaker<T: Sendable>(
        _ breaker: CircuitBreaker,
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await breaker.execute(operation)
    }
}
