// CircuitBreaker.swift
// SafeRetry — A composable resilience library for Swift.

// MARK: - CircuitBreaker

/// A circuit breaker that prevents repeated calls to a failing dependency.
///
/// The breaker tracks failures within a rolling time window and transitions
/// through three states:
///
/// - **Closed** — Calls flow through normally. Failures are counted.
/// - **Open** — Calls are immediately rejected with ``CircuitBreakerError/open(retryAfter:)``.
/// - **Half-open** — A limited number of trial calls are allowed to probe recovery.
///
/// ```swift
/// let breaker = CircuitBreaker(failureThreshold: 5, timeout: .seconds(30))
/// let result = try await breaker.execute {
///     try await api.fetchData()
/// }
/// ```
///
/// ## Give the breaker a bounded operation
///
/// Only the **open** state has a deadline (`timeout`). Half-open has none: it
/// ends when a trial call completes, one way or the other. An operation that
/// never returns therefore holds its trial slot indefinitely, and with the
/// default `halfOpenMaxCalls: 1` every later call is rejected with
/// ``CircuitBreakerError/halfOpenRejected`` — which, having no deadline to
/// report, carries a `nil` ``CircuitBreakerError/retryAfter``. Short of
/// ``reset()``, the breaker never leaves that state.
///
/// Bound the operation to keep that from happening. The timeout has to sit
/// *inside* the breaker, so the breaker sees ``TimeoutError`` rather than the
/// cancellation it deliberately ignores:
///
/// ```swift
/// // Breaker outermost, timeout inside it: a hung call becomes a counted failure.
/// let chain = PolicyChain
///     .circuitBreaker(breaker)
///     .timeout(.seconds(5))
/// ```
///
/// Ordering the two the other way round (`.timeout(…).circuitBreaker(breaker)`)
/// cancels the breaker's in-flight call when the timer fires, and cancellation
/// is exempt from failure counting — so a dependency that only ever hangs would
/// never trip the breaker at all.
public actor CircuitBreaker {

    // MARK: - Configuration

    private let failureThreshold: Int
    private let successThreshold: Int
    private let halfOpenMaxCalls: Int
    private let timeout: Duration
    private let rollingWindow: Duration
    private let isFailure: (@Sendable (any Error) -> Bool)?
    private let onEvent: (@Sendable (PolicyEvent) -> Void)?
    private let now: @Sendable () -> ContinuousClock.Instant

    // MARK: - Mutable State

    private var currentState: CircuitState = .closed
    private var failureTimestamps: [ContinuousClock.Instant] = []
    private var halfOpenInFlight: Int = 0
    private var halfOpenSuccesses: Int = 0

    /// Identifies the current counter epoch.
    ///
    /// Bumped by every ``transition(to:)``, which is the only place the
    /// counters above are reset. A call captures this on the way in and
    /// compares it on the way out: equal generations mean "the counters I
    /// started with are still the live ones". Comparing ``currentState``
    /// instead cannot distinguish "nothing changed" from "changed and cycled
    /// back", and the latter has already wiped the counters.
    private var generation: UInt64 = 0

    // MARK: - Public State

    /// The current state of the circuit breaker.
    ///
    /// The `open → halfOpen` transition is driven by ``execute(_:)``, so a
    /// breaker whose open window has elapsed is still *stored* as
    /// ``CircuitState/open(until:)`` until the next call arrives. This getter
    /// reports such a breaker as ``CircuitState/halfOpen``, which is what the
    /// next call will actually encounter — otherwise a status view polling
    /// `state` would show a dependency as hard-rejecting indefinitely after it
    /// had become probe-eligible.
    ///
    /// Reading this property never mutates the breaker and never emits
    /// ``PolicyEvent/circuitStateChanged(from:to:)``; the event is emitted when
    /// a call performs the transition.
    public var state: CircuitState {
        if case .open(let until) = currentState, now() >= until {
            return .halfOpen
        }
        return currentState
    }

    // MARK: - Initialisation

    /// Creates a circuit breaker with the given configuration.
    ///
    /// - Parameters:
    ///   - failureThreshold: Failures within `rollingWindow` required to open the circuit. Must be at least 1.
    ///   - successThreshold: Successes in half-open needed to close the circuit. Must be at least 1.
    ///     A probe that ends in cancellation — or in an error `isFailure` rejects — frees its
    ///     trial slot without resetting the tally, so the successes that close the circuit need
    ///     not be strictly back-to-back. Only a genuine failure (which reopens the circuit) or
    ///     ``reset()`` clears the count.
    ///   - halfOpenMaxCalls: Maximum concurrent trial calls while half-open. Must be at least 1.
    ///   - timeout: Duration the circuit stays open before transitioning to half-open. Must be greater than zero.
    ///   - rollingWindow: Time window for counting closed-state failures. Must be greater than zero.
    ///     The window is inclusive at both ends — a failure exactly `rollingWindow` old still
    ///     counts — so two failures exactly 60 s apart trip a `failureThreshold: 2` breaker
    ///     whose window is 60 s.
    ///   - isFailure: Optional predicate deciding whether a thrown error counts as
    ///     evidence that the dependency is unhealthy. Return `false` for errors that
    ///     are the *caller's* problem rather than the dependency's — a validation
    ///     rejection, a decoded `404`, a business-rule error — so they propagate to
    ///     the caller without moving the breaker toward `.open`. Defaults to `nil`,
    ///     which counts every error. Cancellation is always exempt, whatever this
    ///     predicate returns.
    ///     Like `onEvent`, the predicate runs synchronously on the breaker's actor
    ///     executor, so it must not block — keep it to type checks and cheap
    ///     property reads rather than I/O or heavy formatting.
    ///   - onEvent: Optional synchronous callback invoked on every policy event.
    ///     The callback runs on the breaker's actor executor, so it must not block
    ///     or perform long-running work. Spawn a `Task` inside the closure if async
    ///     work is required — but tasks spawned per event run concurrently and can
    ///     finish out of order, so a `closed → open` change may be recorded after
    ///     the `open → halfOpen` that followed it. When order matters, forward
    ///     events into an ``EventStream`` and consume it from a single task.
    public init(
        failureThreshold: Int,
        successThreshold: Int = 1,
        halfOpenMaxCalls: Int = 1,
        timeout: Duration = .seconds(30),
        rollingWindow: Duration = .seconds(60),
        isFailure: (@Sendable (any Error) -> Bool)? = nil,
        onEvent: (@Sendable (PolicyEvent) -> Void)? = nil
    ) {
        self.init(
            failureThreshold: failureThreshold,
            successThreshold: successThreshold,
            halfOpenMaxCalls: halfOpenMaxCalls,
            timeout: timeout,
            rollingWindow: rollingWindow,
            isFailure: isFailure,
            onEvent: onEvent,
            now: { ContinuousClock().now }
        )
    }

    /// Internal initialiser with injectable clock for testing.
    init(
        failureThreshold: Int,
        successThreshold: Int = 1,
        halfOpenMaxCalls: Int = 1,
        timeout: Duration = .seconds(30),
        rollingWindow: Duration = .seconds(60),
        isFailure: (@Sendable (any Error) -> Bool)? = nil,
        onEvent: (@Sendable (PolicyEvent) -> Void)? = nil,
        now: @escaping @Sendable () -> ContinuousClock.Instant
    ) {
        precondition(failureThreshold >= 1, "failureThreshold must be at least 1")
        precondition(successThreshold >= 1, "successThreshold must be at least 1")
        precondition(halfOpenMaxCalls >= 1, "halfOpenMaxCalls must be at least 1")
        precondition(timeout > .zero, "timeout must be greater than zero")
        precondition(rollingWindow > .zero, "rollingWindow must be greater than zero")

        self.failureThreshold = failureThreshold
        self.successThreshold = successThreshold
        self.halfOpenMaxCalls = halfOpenMaxCalls
        self.timeout = timeout
        self.rollingWindow = rollingWindow
        self.isFailure = isFailure
        self.onEvent = onEvent
        self.now = now
    }

    // MARK: - Execute

    /// Executes an operation subject to the circuit breaker's state machine.
    ///
    /// - In **closed** state the operation runs normally; failures are tracked.
    /// - In **open** state the call is immediately rejected.
    /// - In **half-open** state a limited number of trial calls are permitted.
    /// - A call from an already-cancelled task throws `CancellationError`
    ///   before the state machine is consulted: the operation does not run,
    ///   no trial slot is taken, and no event is emitted.
    /// - Cancellation — `CancellationError` or `URLError(.cancelled)`, which is
    ///   how `URLSession` reports a cancelled task — is propagated without
    ///   being counted as a dependency failure.
    /// - An error rejected by the `isFailure` predicate is propagated without
    ///   being counted either.
    /// - A result from a call that was in flight across a state change belongs
    ///   to the generation it started in and is discarded, so it cannot extend
    ///   an open window, free a trial slot owned by a live probe, satisfy a
    ///   later `successThreshold`, or count against a recovered circuit.
    ///
    /// - Parameter operation: The async throwing closure to protect.
    /// - Returns: The value produced by `operation`.
    /// - Throws: `CancellationError` if the task is already cancelled,
    ///   ``CircuitBreakerError`` if the circuit rejects the call,
    ///   or the original error from `operation`.
    public func execute<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        // Callers queued behind the actor hop may arrive after their task was
        // cancelled (a dismissed screen's request, say). Sending that request
        // to the dependency anyway is wasted work — and in half-open it would
        // occupy a trial slot on behalf of a caller who is already gone.
        try Task.checkCancellation()

        switch currentState {
        case .closed:
            return try await executeClosed(operation)

        case .open(let until):
            let currentNow = now()
            if currentNow >= until {
                transition(to: .halfOpen)
                return try await executeHalfOpen(operation)
            } else {
                emitEvent(.circuitCallRejected(state: currentState))
                throw CircuitBreakerError.open(
                    retryAfter: until - currentNow
                )
            }

        case .halfOpen:
            return try await executeHalfOpen(operation)
        }
    }

    // MARK: - Reset

    /// Forces the circuit back to the closed state, clearing all counters.
    ///
    /// Emits ``PolicyEvent/circuitStateChanged(from:to:)`` if the state
    /// was not already closed.
    public func reset() {
        transition(to: .closed)
    }

    // MARK: - Closed-State Execution

    private func executeClosed<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        let entered = generation

        do {
            return try await operation()
        } catch {
            // The actor was released for the duration of the operation, so the
            // state may have moved on while this call was in flight. A failure
            // that lands after the circuit already tripped belongs to the
            // generation that tripped it: counting it again would re-open an
            // open circuit — pushing its deadline out by a further `timeout`
            // under sustained concurrency — and report an `open → open`
            // transition that never happened.
            //
            // The generation check also covers the circuit cycling all the way
            // back to closed (open → half-open → closed, or `reset()`) while
            // this call was in flight: `currentState` alone would look
            // unchanged even though the counters were wiped twice, letting a
            // failure that predates the recovery count against the recovered
            // circuit.
            guard entered == generation else {
                throw error
            }
            guard !isCancellation(error), isFailure?(error) ?? true else {
                throw error
            }

            let currentNow = now()
            failureTimestamps.append(currentNow)
            pruneOldFailures(at: currentNow)

            if failureTimestamps.count >= failureThreshold {
                transition(to: .open(until: currentNow.advanced(by: timeout)))
            }

            throw error
        }
    }

    // MARK: - Half-Open Execution

    private func executeHalfOpen<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        guard case .halfOpen = currentState,
              halfOpenInFlight < halfOpenMaxCalls else {
            emitEvent(.circuitCallRejected(state: currentState))
            throw CircuitBreakerError.halfOpenRejected
        }

        halfOpenInFlight += 1
        let entered = generation

        do {
            let result = try await operation()

            // The actor was released during the operation, so this call may
            // belong to a half-open generation that has since ended. Its slot
            // and its success belong to that dead generation: releasing the
            // slot would free one owned by a live probe (admitting more
            // concurrent probes than `halfOpenMaxCalls` allows), and counting
            // the success would close the circuit on fewer genuine probes than
            // `successThreshold` requires.
            guard entered == generation else {
                return result
            }

            releaseHalfOpenCallSlot()
            halfOpenSuccesses += 1

            if halfOpenSuccesses >= successThreshold {
                transition(to: .closed)
            }

            return result
        } catch {
            guard entered == generation else {
                throw error
            }
            // Cancellation and caller-side errors say nothing about the
            // dependency's health, so they must not end the trial period —
            // but they do free the trial slot, or a cancelled probe would
            // block recovery until the breaker's next transition.
            guard !isCancellation(error), isFailure?(error) ?? true else {
                releaseHalfOpenCallSlot()
                throw error
            }

            let currentNow = now()
            transition(to: .open(until: currentNow.advanced(by: timeout)))
            throw error
        }
    }

    // MARK: - State Transitions

    /// Moves to `newState`, clearing every counter, starting a new generation,
    /// and emitting ``PolicyEvent/circuitStateChanged(from:to:)`` if the state
    /// actually changed.
    ///
    /// Every entry point that mutates `currentState` goes through here, so
    /// this is the single place counters are reset and the single place
    /// ``generation`` advances. All three counters are cleared for every
    /// target state rather than only the ones the entered state "owns": the
    /// narrower version was correct only because the paths into `.halfOpen`
    /// happened to come from `.open`, which had already cleared
    /// `failureTimestamps`. A future `closed → halfOpen` edge would have
    /// silently carried stale failures across.
    private func transition(to newState: CircuitState) {
        let previous = currentState
        currentState = newState

        failureTimestamps.removeAll()
        halfOpenInFlight = 0
        halfOpenSuccesses = 0

        // Unconditional, including a same-state transition such as `reset()`
        // on an already-closed breaker: the counters were still cleared, so
        // calls in flight must not be allowed to write into the new epoch.
        generation &+= 1

        if previous != newState {
            emitEvent(.circuitStateChanged(from: previous, to: newState))
        }
    }

    // MARK: - Event Emission

    private func emitEvent(_ event: PolicyEvent) {
        onEvent?(event)
    }

    /// Frees one half-open trial slot.
    ///
    /// Only ever called after the caller has confirmed its generation is still
    /// current. Within one generation nothing else decrements the counter — a
    /// transition resets it and starts a new generation — so the caller's own
    /// increment is still accounted for and the counter is necessarily
    /// positive. `max` keeps a release build from underflowing should that
    /// invariant ever be broken.
    private func releaseHalfOpenCallSlot() {
        assert(halfOpenInFlight > 0, "a current-generation call must still own its trial slot")
        halfOpenInFlight = max(0, halfOpenInFlight - 1)
    }

    // MARK: - Rolling Window

    private func pruneOldFailures(at now: ContinuousClock.Instant) {
        failureTimestamps.removeAll { (now - $0) > rollingWindow }
    }
}
