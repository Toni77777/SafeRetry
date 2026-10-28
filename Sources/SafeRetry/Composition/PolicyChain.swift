// PolicyChain.swift
// SafeRetry — A composable resilience library for Swift.

// MARK: - PolicyBox

/// Internal protocol for type-erased policy wrappers.
///
/// Each wrapper captures a concrete policy and applies it around
/// the next closure in the chain.
internal protocol PolicyBox: Sendable {

    /// Wraps `next` with this policy's behaviour.
    ///
    /// - Parameter next: The downstream closure to execute inside the policy.
    /// - Returns: The value produced by the downstream closure.
    func wrap<T: Sendable>(
        _ next: @escaping @Sendable () async throws -> T
    ) async throws -> T
}

// MARK: - Concrete Boxes

private struct RetryBox: PolicyBox {
    let policy: RetryPolicy
    let shouldRetry: (@Sendable (_ error: any Error, _ attempt: Int) -> Bool)?
    func wrap<T: Sendable>(
        _ next: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        if let shouldRetry {
            try await policy.execute(shouldRetry: shouldRetry, next)
        } else {
            try await policy.execute(next)
        }
    }
}

private struct CircuitBreakerBox: PolicyBox {
    let breaker: CircuitBreaker
    func wrap<T: Sendable>(
        _ next: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await breaker.execute(next)
    }
}

private struct TimeoutBox: PolicyBox {
    let policy: TimeoutPolicy
    func wrap<T: Sendable>(
        _ next: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await policy.execute(next)
    }
}

// MARK: - PolicyChain

/// Composes multiple resilience policies into a sequential pipeline.
///
/// Policies are applied from outermost (first added) to innermost (last added).
/// For example, `PolicyChain.timeout(...).retry(...).circuitBreaker(...)` produces
/// a pipeline where timeout wraps retry, which wraps circuitBreaker, which wraps
/// the operation.
///
/// ```swift
/// let result = try await PolicyChain
///     .timeout(.seconds(10))
///     .retry(attempts: 3, delay: .exponential(base: .seconds(1)))
///     .circuitBreaker(breaker)
///     .execute {
///         try await api.fetchUser()
///     }
/// ```
public struct PolicyChain: Sendable {

    // MARK: - Properties

    private let boxes: [any PolicyBox]

    // MARK: - Initialisation

    private init(boxes: [any PolicyBox]) {
        self.boxes = boxes
    }

    // MARK: - Static Factory Methods

    /// Creates a chain that retries using the given policy.
    ///
    /// - Parameters:
    ///   - policy: A configured ``RetryPolicy``.
    ///   - shouldRetry: Optional predicate that decides whether a failed attempt
    ///     should be retried. Receives the thrown error and the 1-based attempt index.
    /// - Returns: A new chain containing the retry policy.
    public static func retry(
        _ policy: RetryPolicy,
        shouldRetry: (@Sendable (_ error: any Error, _ attempt: Int) -> Bool)? = nil
    ) -> PolicyChain {
        PolicyChain(boxes: [RetryBox(policy: policy, shouldRetry: shouldRetry)])
    }

    /// Creates a chain that retries with the given parameters.
    ///
    /// The retry policy built here has no `onEvent` callback. To observe retry
    /// events from a chain, build a ``RetryPolicy`` with `onEvent` yourself and
    /// pass it to `retry(_ policy:shouldRetry:)` instead.
    ///
    /// - Parameters:
    ///   - attempts: The maximum number of attempts. Must be at least 1;
    ///     a smaller value traps, matching ``RetryPolicy/init(maxAttempts:delay:jitter:onEvent:)``.
    ///   - delay: The backoff strategy. Defaults to ``DelayStrategy/immediate``.
    ///   - jitter: The jitter strategy. Defaults to ``JitterStrategy/none``.
    ///   - shouldRetry: Optional predicate that decides whether a failed attempt
    ///     should be retried. Receives the thrown error and the 1-based attempt index.
    /// - Returns: A new chain containing a retry policy.
    public static func retry(
        attempts: Int,
        delay: DelayStrategy = .immediate,
        jitter: JitterStrategy = .none,
        shouldRetry: (@Sendable (_ error: any Error, _ attempt: Int) -> Bool)? = nil
    ) -> PolicyChain {
        PolicyChain(boxes: [RetryBox(policy: RetryPolicy(
            maxAttempts: attempts,
            delay: delay,
            jitter: jitter
        ), shouldRetry: shouldRetry)])
    }

    /// Creates a chain that applies a circuit breaker.
    ///
    /// - Parameter breaker: A configured ``CircuitBreaker`` actor.
    /// - Returns: A new chain containing the circuit breaker.
    public static func circuitBreaker(_ breaker: CircuitBreaker) -> PolicyChain {
        PolicyChain(boxes: [CircuitBreakerBox(breaker: breaker)])
    }

    /// Creates a chain that applies a timeout.
    ///
    /// The timeout policy built here has no `onEvent` callback. To observe
    /// ``PolicyEvent/timeoutExceeded(duration:)`` from a chain, build a
    /// ``TimeoutPolicy`` with `onEvent` yourself and pass it to
    /// `timeout(_ policy:)` instead.
    ///
    /// - Parameter duration: The maximum duration allowed. Must be greater than
    ///   zero; a smaller value traps, matching ``TimeoutPolicy/init(duration:onEvent:)``.
    /// - Returns: A new chain containing a timeout policy.
    public static func timeout(_ duration: Duration) -> PolicyChain {
        PolicyChain(boxes: [TimeoutBox(policy: TimeoutPolicy(duration: duration))])
    }

    /// Creates a chain that applies the given timeout policy.
    ///
    /// Use this overload when the policy needs an `onEvent` callback, which the
    /// `timeout(_ duration:)` shorthand cannot supply.
    ///
    /// - Parameter policy: A configured ``TimeoutPolicy``.
    /// - Returns: A new chain containing the timeout policy.
    public static func timeout(_ policy: TimeoutPolicy) -> PolicyChain {
        PolicyChain(boxes: [TimeoutBox(policy: policy)])
    }

    // MARK: - Chaining Methods

    /// Appends a retry policy to the chain.
    ///
    /// - Parameters:
    ///   - policy: A configured ``RetryPolicy``.
    ///   - shouldRetry: Optional predicate that decides whether a failed attempt
    ///     should be retried. Receives the thrown error and the 1-based attempt index.
    /// - Returns: A new chain with the retry policy added as the next inner layer.
    public func retry(
        _ policy: RetryPolicy,
        shouldRetry: (@Sendable (_ error: any Error, _ attempt: Int) -> Bool)? = nil
    ) -> PolicyChain {
        PolicyChain(boxes: boxes + [RetryBox(policy: policy, shouldRetry: shouldRetry)])
    }

    /// Appends a retry policy with the given parameters to the chain.
    ///
    /// The retry policy built here has no `onEvent` callback. To observe retry
    /// events, build a ``RetryPolicy`` with `onEvent` yourself and pass it to
    /// `retry(_ policy:shouldRetry:)` instead.
    ///
    /// - Parameters:
    ///   - attempts: The maximum number of attempts. Must be at least 1;
    ///     a smaller value traps.
    ///   - delay: The backoff strategy. Defaults to ``DelayStrategy/immediate``.
    ///   - jitter: The jitter strategy. Defaults to ``JitterStrategy/none``.
    ///   - shouldRetry: Optional predicate that decides whether a failed attempt
    ///     should be retried. Receives the thrown error and the 1-based attempt index.
    /// - Returns: A new chain with the retry policy added as the next inner layer.
    public func retry(
        attempts: Int,
        delay: DelayStrategy = .immediate,
        jitter: JitterStrategy = .none,
        shouldRetry: (@Sendable (_ error: any Error, _ attempt: Int) -> Bool)? = nil
    ) -> PolicyChain {
        PolicyChain(boxes: boxes + [RetryBox(policy: RetryPolicy(
            maxAttempts: attempts,
            delay: delay,
            jitter: jitter
        ), shouldRetry: shouldRetry)])
    }

    /// Appends a circuit breaker to the chain.
    ///
    /// - Parameter breaker: A configured ``CircuitBreaker`` actor.
    /// - Returns: A new chain with the circuit breaker added as the next inner layer.
    public func circuitBreaker(_ breaker: CircuitBreaker) -> PolicyChain {
        PolicyChain(boxes: boxes + [CircuitBreakerBox(breaker: breaker)])
    }

    /// Appends a timeout to the chain.
    ///
    /// The timeout policy built here has no `onEvent` callback. To observe
    /// ``PolicyEvent/timeoutExceeded(duration:)``, build a ``TimeoutPolicy``
    /// with `onEvent` yourself and pass it to `timeout(_ policy:)`
    /// instead.
    ///
    /// - Parameter duration: The maximum duration allowed. Must be greater than
    ///   zero; a smaller value traps.
    /// - Returns: A new chain with the timeout added as the next inner layer.
    public func timeout(_ duration: Duration) -> PolicyChain {
        PolicyChain(boxes: boxes + [TimeoutBox(policy: TimeoutPolicy(duration: duration))])
    }

    /// Appends the given timeout policy to the chain.
    ///
    /// Use this overload when the policy needs an `onEvent` callback, which the
    /// `timeout(_ duration:)` shorthand cannot supply.
    ///
    /// - Parameter policy: A configured ``TimeoutPolicy``.
    /// - Returns: A new chain with the timeout added as the next inner layer.
    public func timeout(_ policy: TimeoutPolicy) -> PolicyChain {
        PolicyChain(boxes: boxes + [TimeoutBox(policy: policy)])
    }

    /// Terminates the chain with a constant fallback value.
    ///
    /// The returned ``FallbackChain`` catches non-cancellation errors from the chain
    /// and returns `value` instead.
    ///
    /// - Parameters:
    ///   - value: The value to return on failure.
    ///   - onEvent: Optional synchronous callback invoked with
    ///     ``PolicyEvent/fallbackUsed`` when the fallback is used. Runs inline
    ///     with execution, so it must not block. Spawn a `Task` inside the
    ///     closure if async work is required.
    /// - Returns: A ``FallbackChain`` whose `execute` throws only on task cancellation.
    public func fallback<T: Sendable>(
        _ value: T,
        onEvent: (@Sendable (PolicyEvent) -> Void)? = nil
    ) -> FallbackChain<T> {
        FallbackChain(chain: self, onEvent: onEvent, handler: { _ in value })
    }

    /// Terminates the chain with a fallback handler.
    ///
    /// The returned ``FallbackChain`` catches non-cancellation errors from the chain
    /// and invokes `handler` with the error to produce an alternative result.
    ///
    /// - Parameters:
    ///   - onEvent: Optional synchronous callback invoked with
    ///     ``PolicyEvent/fallbackUsed`` when the fallback is used. Runs inline
    ///     with execution, so it must not block. Spawn a `Task` inside the
    ///     closure if async work is required.
    ///   - handler: A closure that receives the error and returns a fallback
    ///     value, or throws a different error.
    /// - Returns: A ``FallbackChain`` whose `execute` throws only on task
    ///   cancellation or an error thrown by `handler`.
    public func fallback<T: Sendable>(
        onEvent: (@Sendable (PolicyEvent) -> Void)? = nil,
        _ handler: @escaping @Sendable (any Error) async throws -> T
    ) -> FallbackChain<T> {
        FallbackChain(chain: self, onEvent: onEvent, handler: handler)
    }

    // MARK: - Execute

    /// Runs the operation through every policy in the chain.
    ///
    /// Policies are applied outermost-first: the first policy added to the
    /// chain wraps all subsequent policies, which in turn wrap the operation.
    ///
    /// - Parameter operation: The async throwing closure to execute.
    /// - Returns: The value produced by the operation.
    /// - Throws: Any error that escapes through the policy layers.
    public func execute<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        // Build the nested closure from innermost to outermost.
        // boxes[0] is outermost, boxes.last is innermost.
        var current: @Sendable () async throws -> T = operation
        for box in boxes.reversed() {
            let next = current
            current = { try await box.wrap(next) }
        }
        return try await current()
    }
}

// MARK: - Presets

extension PolicyChain {

    /// Ready-made policy chains for common use cases.
    ///
    /// Presets do **not** include a ``CircuitBreaker`` because a breaker must
    /// be a long-lived, shared instance to accumulate failure history.
    /// Append your own breaker to a preset when needed:
    ///
    /// ```swift
    /// let breaker = CircuitBreaker(failureThreshold: 5)
    /// let chain = PolicyChain.Preset.default.circuitBreaker(breaker)
    /// ```
    ///
    /// Appending adds the *innermost* layer, so appending a breaker to
    /// ``conservative`` lands it inside that preset's ``TimeoutPolicy`` — the
    /// ordering that hides timed-out calls from the breaker's failure count,
    /// because the timeout cancels them and the breaker ignores cancellation.
    /// Build the chain by hand when you want a breaker *and* a timeout:
    ///
    /// ```swift
    /// let chain = PolicyChain
    ///     .retry(attempts: 2, delay: .fixed(.seconds(2)))
    ///     .circuitBreaker(breaker)
    ///     .timeout(.seconds(5))
    /// ```
    public enum Preset: Sendable {

        /// A balanced default: 3 attempts (the first call plus up to 2
        /// retries) with exponential backoff (1 s base).
        public static var `default`: PolicyChain {
            PolicyChain
                .retry(
                    attempts: 3,
                    delay: .exponential(base: .seconds(1))
                )
        }

        /// An aggressive preset for high-availability paths: 10 attempts (the
        /// first call plus up to 9 retries) with exponential backoff (0.5 s
        /// base).
        ///
        /// Without a predicate this retries every error, including
        /// ``CircuitBreakerError``: appended to an open breaker, it waits out
        /// roughly three minutes of backoff while every attempt is rejected.
        /// Pass a `shouldRetry` that excludes the rejection when you build such
        /// a chain yourself.
        public static var aggressive: PolicyChain {
            PolicyChain
                .retry(
                    attempts: 10,
                    delay: .exponential(base: .milliseconds(500))
                )
        }

        /// A conservative preset for latency-sensitive paths: 2 attempts (the
        /// first call plus 1 retry) with a fixed 2 s delay, each attempt
        /// individually bounded by a 5 s timeout.
        ///
        /// The timeout wraps each attempt rather than the whole retry sequence
        /// (`.retry(...).timeout(...)`, retry outermost) — otherwise a slow
        /// first attempt could consume the whole budget before a retry gets
        /// a chance to run.
        public static var conservative: PolicyChain {
            PolicyChain
                .retry(
                    attempts: 2,
                    delay: .fixed(.seconds(2))
                )
                .timeout(.seconds(5))
        }
    }
}
