// CancellationSemanticsTests.swift
// SafeRetry — A composable resilience library for Swift.

import Foundation
import os
import Testing
@testable import SafeRetry

// MARK: - Test Helpers

private struct TestError: Error, Equatable {}
private struct BusinessError: Error, Equatable {}

/// Reduces ``CircuitState`` to its case label for comparisons that ignore associated values.
private enum StateKind: Equatable, CustomStringConvertible {
    case closed, open, halfOpen

    init(_ state: CircuitState) {
        switch state {
        case .closed: self = .closed
        case .open: self = .open
        case .halfOpen: self = .halfOpen
        }
    }

    var description: String {
        switch self {
        case .closed: "closed"
        case .open: "open"
        case .halfOpen: "halfOpen"
        }
    }
}

/// A controllable clock backed by `OSAllocatedUnfairLock` for strict `Sendable` compliance.
private struct TestClock: Sendable {
    private let storage: OSAllocatedUnfairLock<ContinuousClock.Instant>

    init(_ instant: ContinuousClock.Instant = ContinuousClock().now) {
        self.storage = OSAllocatedUnfairLock(initialState: instant)
    }

    var now: ContinuousClock.Instant { storage.withLock { $0 } }

    func advance(by duration: Duration) {
        storage.withLock { $0 = $0.advanced(by: duration) }
    }
}

// MARK: - URLErrorCancellationTests

/// `URLSession` reports a cancelled task as `URLError(.cancelled)`, not as
/// `CancellationError`. Since the `URLSession` extensions are the library's
/// flagship integration, every policy that gives `CancellationError` special
/// treatment has to recognise that spelling too — otherwise cancelling a
/// screen's in-flight requests feeds failures into a circuit breaker, burns
/// retry attempts, and silently produces fallback values.
@Suite("Cancellation — URLError.cancelled")
struct URLErrorCancellationTests {

    // MARK: - Circuit Breaker

    @Test("breaker does not count URLError.cancelled as a dependency failure")
    func breakerIgnoresURLErrorCancelled() async {
        let breaker = CircuitBreaker(failureThreshold: 1)

        try? await breaker.execute { throw URLError(.cancelled) }

        #expect(StateKind(await breaker.state) == .closed)
    }

    @Test("URLError.cancelled in half-open does not re-open the circuit")
    func halfOpenIgnoresURLErrorCancelled() async throws {
        let clock = TestClock()
        let breaker = CircuitBreaker(
            failureThreshold: 1,
            successThreshold: 1,
            timeout: .seconds(10),
            now: { clock.now }
        )

        try? await breaker.execute { throw TestError() }
        clock.advance(by: .seconds(11))

        try? await breaker.execute { throw URLError(.cancelled) }
        #expect(StateKind(await breaker.state) == .halfOpen)

        // The trial slot must have been released, so a real probe can proceed.
        let result = try await breaker.execute { 42 }
        #expect(result == 42)
        #expect(StateKind(await breaker.state) == .closed)
    }

    // MARK: - Retry Policy

    @Test("retry does not burn attempts on URLError.cancelled")
    func retryStopsOnURLErrorCancelled() async {
        let callCount = OSAllocatedUnfairLock(initialState: 0)
        let policy = RetryPolicy(maxAttempts: 4, delay: .immediate)

        await #expect(throws: URLError.self) {
            try await policy.execute {
                callCount.withLock { $0 += 1 }
                throw URLError(.cancelled)
            }
        }

        #expect(callCount.withLock { $0 } == 1)
    }

    // MARK: - Fallback

    @Test("fallback does not substitute a value for URLError.cancelled")
    func fallbackPropagatesURLErrorCancelled() async {
        let policy = FallbackPolicy(value: "default")

        await #expect(throws: URLError.self) {
            try await policy.execute { throw URLError(.cancelled) }
        }
    }

    @Test("chain fallback does not substitute a value for URLError.cancelled")
    func fallbackChainPropagatesURLErrorCancelled() async {
        let chain = PolicyChain
            .retry(attempts: 1, delay: .immediate)
            .fallback("default")

        await #expect(throws: URLError.self) {
            try await chain.execute { throw URLError(.cancelled) }
        }
    }

    // MARK: - Other URLError codes are unaffected

    @Test("a non-cancellation URLError still counts as a failure")
    func otherURLErrorsStillCount() async {
        let breaker = CircuitBreaker(failureThreshold: 1)

        try? await breaker.execute { throw URLError(.timedOut) }

        #expect(StateKind(await breaker.state) == .open)
    }
}

// MARK: - CircuitBreakerIsFailureTests

/// Without a predicate, a circuit breaker treats every thrown error as evidence
/// that the dependency is unhealthy — including errors that say the opposite,
/// such as a decoded `404 → NotFound` or a validation rejection. `isFailure`
/// is the breaker's counterpart to ``RetryPolicy``'s `shouldRetry`.
@Suite("CircuitBreaker — isFailure")
struct CircuitBreakerIsFailureTests {

    @Test("an error the predicate rejects does not trip the circuit")
    func rejectedErrorDoesNotTrip() async {
        let breaker = CircuitBreaker(
            failureThreshold: 1,
            isFailure: { !($0 is BusinessError) }
        )

        for _ in 0..<5 {
            try? await breaker.execute { throw BusinessError() }
        }

        #expect(StateKind(await breaker.state) == .closed)
    }

    @Test("an error the predicate accepts still trips the circuit")
    func acceptedErrorTrips() async {
        let breaker = CircuitBreaker(
            failureThreshold: 2,
            isFailure: { !($0 is BusinessError) }
        )

        try? await breaker.execute { throw BusinessError() }   // ignored
        try? await breaker.execute { throw TestError() }        // counted, 1 of 2
        #expect(StateKind(await breaker.state) == .closed)

        try? await breaker.execute { throw TestError() }        // counted, 2 of 2
        #expect(StateKind(await breaker.state) == .open)
    }

    @Test("the rejected error still propagates to the caller")
    func rejectedErrorStillThrows() async {
        let breaker = CircuitBreaker(
            failureThreshold: 1,
            isFailure: { !($0 is BusinessError) }
        )

        await #expect(throws: BusinessError.self) {
            try await breaker.execute { throw BusinessError() }
        }
    }

    @Test("an error the predicate rejects does not re-open a half-open circuit")
    func rejectedErrorDoesNotReopenHalfOpen() async throws {
        let clock = TestClock()
        let breaker = CircuitBreaker(
            failureThreshold: 1,
            successThreshold: 1,
            timeout: .seconds(10),
            isFailure: { !($0 is BusinessError) },
            now: { clock.now }
        )

        try? await breaker.execute { throw TestError() }
        clock.advance(by: .seconds(11))

        try? await breaker.execute { throw BusinessError() }
        #expect(StateKind(await breaker.state) == .halfOpen)

        // The trial slot must have been released for a real probe to run.
        let result = try await breaker.execute { 7 }
        #expect(result == 7)
        #expect(StateKind(await breaker.state) == .closed)
    }

    @Test("cancellation is ignored even when the predicate would accept it")
    func cancellationOverridesPredicate() async {
        let breaker = CircuitBreaker(
            failureThreshold: 1,
            isFailure: { _ in true }   // "everything is a failure"
        )

        try? await breaker.execute { throw CancellationError() }
        try? await breaker.execute { throw URLError(.cancelled) }

        #expect(StateKind(await breaker.state) == .closed)
    }
}

// MARK: - EntryCancellationTests

/// Runs `body` inside a task that has already been cancelled by the time
/// `body` starts, so the policy under test is *entered* cancelled rather than
/// cancelled mid-flight.
private func runEnteredCancelled<T: Sendable>(
    _ body: @escaping @Sendable () async throws -> T
) async -> Result<T, any Error> {
    let task = Task {
        while !Task.isCancelled {
            await Task.yield()
        }
        return try await body()
    }
    task.cancel()
    return await task.result
}

/// The typical arrival path is teardown: a screen is dismissed, its task tree
/// is cancelled, and calls already queued behind an actor hop still reach the
/// policy. `RetryPolicy` has always checked before its first attempt; these
/// pin the same behaviour for the other three, so a cancelled caller never
/// sends work to the dependency.
@Suite("Cancellation — already-cancelled entry")
struct EntryCancellationTests {

    @Test("a closed breaker does not run the operation for a cancelled task")
    func closedBreaker() async {
        let ran = OSAllocatedUnfairLock(initialState: false)
        let breaker = CircuitBreaker(failureThreshold: 1)

        let result = await runEnteredCancelled {
            try await breaker.execute { ran.withLock { $0 = true } }
        }

        #expect(throws: CancellationError.self) { try result.get() }
        #expect(ran.withLock { $0 } == false)
        #expect(StateKind(await breaker.state) == .closed)
    }

    @Test("an open breaker reports cancellation, not a rejection, and emits nothing")
    func openBreaker() async {
        let events = OSAllocatedUnfairLock(initialState: [String]())
        let breaker = CircuitBreaker(
            failureThreshold: 1,
            timeout: .seconds(60),
            onEvent: { event in events.withLock { $0.append("\(event)") } }
        )
        try? await breaker.execute { throw TestError() }
        let eventsBefore = events.withLock { $0.count }

        let result = await runEnteredCancelled {
            try await breaker.execute { 1 }
        }

        #expect(throws: CancellationError.self) { try result.get() }
        #expect(events.withLock { $0.count } == eventsBefore)
    }

    @Test("a cancelled caller does not move an elapsed breaker to half-open or take its trial slot")
    func elapsedBreakerKeepsTrialSlot() async throws {
        let clock = TestClock()
        let breaker = CircuitBreaker(
            failureThreshold: 1,
            successThreshold: 1,
            halfOpenMaxCalls: 1,
            timeout: .seconds(10),
            now: { clock.now }
        )
        try? await breaker.execute { throw TestError() }
        clock.advance(by: .seconds(11))

        let cancelled = await runEnteredCancelled {
            try await breaker.execute { 1 }
        }
        #expect(throws: CancellationError.self) { try cancelled.get() }

        // The single trial slot is still free for a real probe.
        let probe = try await breaker.execute { 7 }
        #expect(probe == 7)
        #expect(StateKind(await breaker.state) == .closed)
    }

    @Test("a timeout policy does not run the operation for a cancelled task")
    func timeoutPolicy() async {
        let ran = OSAllocatedUnfairLock(initialState: false)
        let policy = TimeoutPolicy(duration: .seconds(5))

        let result = await runEnteredCancelled {
            try await policy.execute { ran.withLock { $0 = true } }
        }

        #expect(throws: CancellationError.self) { try result.get() }
        #expect(ran.withLock { $0 } == false)
    }

    @Test("a fallback policy neither runs the operation nor uses the fallback for a cancelled task")
    func fallbackPolicy() async {
        let ran = OSAllocatedUnfairLock(initialState: false)
        let fallbackUsed = OSAllocatedUnfairLock(initialState: false)
        let policy = FallbackPolicy(
            value: 0,
            onEvent: { _ in fallbackUsed.withLock { $0 = true } }
        )

        let result = await runEnteredCancelled {
            try await policy.execute {
                ran.withLock { $0 = true }
                return 1
            }
        }

        #expect(throws: CancellationError.self) { try result.get() }
        #expect(ran.withLock { $0 } == false)
        #expect(fallbackUsed.withLock { $0 } == false)
    }

    @Test("a chain fallback over a breaker propagates entry cancellation")
    func chainFallback() async {
        let ran = OSAllocatedUnfairLock(initialState: false)
        let chain = PolicyChain
            .circuitBreaker(CircuitBreaker(failureThreshold: 1))
            .fallback(0)

        let result = await runEnteredCancelled {
            try await chain.execute {
                ran.withLock { $0 = true }
                return 1
            }
        }

        #expect(throws: CancellationError.self) { try result.get() }
        #expect(ran.withLock { $0 } == false)
    }
}
