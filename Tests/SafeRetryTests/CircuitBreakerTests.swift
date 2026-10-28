// CircuitBreakerTests.swift
// SafeRetry — A composable resilience library for Swift.

import os
import Testing
@testable import SafeRetry

// MARK: - Test Helpers

private struct TestError: Error, Equatable {}

/// A controllable clock backed by `OSAllocatedUnfairLock` for strict `Sendable` compliance.
private struct TestClock: Sendable {
    private let storage: OSAllocatedUnfairLock<ContinuousClock.Instant>

    init(_ instant: ContinuousClock.Instant = ContinuousClock().now) {
        self.storage = OSAllocatedUnfairLock(initialState: instant)
    }

    var now: ContinuousClock.Instant {
        storage.withLock { $0 }
    }

    func advance(by duration: Duration) {
        storage.withLock { $0 = $0.advanced(by: duration) }
    }
}

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

// MARK: - CircuitBreakerTests

@Suite("CircuitBreaker")
struct CircuitBreakerTests {

    @Test("accepts minimum valid configuration values")
    func acceptsMinimumValidConfiguration() async throws {
        let breaker = CircuitBreaker(
            failureThreshold: 1,
            successThreshold: 1,
            halfOpenMaxCalls: 1,
            timeout: .milliseconds(1),
            rollingWindow: .milliseconds(1)
        )

        let result = try await breaker.execute { 42 }
        #expect(result == 42)
        #expect(await breaker.state == .closed)
    }

    // MARK: - Closed State

    @Test("stays closed when failures are below threshold")
    func staysClosedBelowThreshold() async {
        let breaker = CircuitBreaker(failureThreshold: 3)

        try? await breaker.execute { throw TestError() }
        try? await breaker.execute { throw TestError() }

        #expect(await breaker.state == .closed)
    }

    // MARK: - Opening

    @Test("opens after reaching failure threshold")
    func opensAfterThreshold() async {
        let breaker = CircuitBreaker(failureThreshold: 3)

        for _ in 0..<3 {
            try? await breaker.execute { throw TestError() }
        }

        #expect(StateKind(await breaker.state) == .open)
    }

    @Test("cancellation does not count as a closed-state failure")
    func cancellationDoesNotCountAsClosedStateFailure() async {
        let breaker = CircuitBreaker(failureThreshold: 1)
        let gate = OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>(initialState: nil)

        let task = Task {
            try await breaker.execute {
                try await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        gate.withLock { $0 = continuation }
                    }
                    try Task.checkCancellation()
                    return 42
                } onCancel: {
                    gate.withLock { continuation in
                        continuation?.resume()
                        continuation = nil
                    }
                }
            }
        }

        while gate.withLock({ $0 }) == nil {
            await Task.yield()
        }

        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected CancellationError")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }

        #expect(await breaker.state == .closed)
    }

    // MARK: - Rejection

    @Test("rejects calls when circuit is open with correct retryAfter")
    func rejectsWhenOpen() async {
        let clock = TestClock()
        let breaker = CircuitBreaker(
            failureThreshold: 2,
            timeout: .seconds(30),
            now: { clock.now }
        )

        try? await breaker.execute { throw TestError() }
        try? await breaker.execute { throw TestError() }

        clock.advance(by: .seconds(5))

        do {
            _ = try await breaker.execute { 42 }
            Issue.record("Expected CircuitBreakerError.open")
        } catch let error as CircuitBreakerError {
            guard case .open(let retryAfter) = error else {
                Issue.record("Expected .open, got \(error)")
                return
            }
            #expect(retryAfter == .seconds(25))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // MARK: - State Reporting

    @Test("state stays open until the open window elapses")
    func stateStaysOpenBeforeDeadline() async {
        let clock = TestClock()
        let breaker = CircuitBreaker(
            failureThreshold: 1,
            timeout: .seconds(10),
            now: { clock.now }
        )

        try? await breaker.execute { throw TestError() }
        clock.advance(by: .seconds(9))

        #expect(StateKind(await breaker.state) == .open)
    }

    @Test("state reports halfOpen once the open window has elapsed")
    func stateReflectsElapsedOpenWindow() async {
        let clock = TestClock()
        let breaker = CircuitBreaker(
            failureThreshold: 1,
            timeout: .seconds(10),
            now: { clock.now }
        )

        try? await breaker.execute { throw TestError() }
        #expect(StateKind(await breaker.state) == .open)

        // The deadline passes with no call to drive the transition. A caller
        // polling `state` for a dashboard or a UI banner must not be told the
        // dependency is still being rejected when the next call would in fact
        // be admitted as a trial.
        clock.advance(by: .seconds(11))
        #expect(StateKind(await breaker.state) == .halfOpen)
    }

    @Test("reading state does not itself emit a transition event")
    func readingStateEmitsNothing() async {
        let clock = TestClock()
        let collected = OSAllocatedUnfairLock<[PolicyEvent]>(initialState: [])
        let breaker = CircuitBreaker(
            failureThreshold: 1,
            timeout: .seconds(10),
            onEvent: { event in collected.withLock { $0.append(event) } },
            now: { clock.now }
        )

        try? await breaker.execute { throw TestError() }
        clock.advance(by: .seconds(11))

        let before = collected.withLock { $0.count }
        _ = await breaker.state
        _ = await breaker.state
        #expect(collected.withLock { $0.count } == before)

        // The real transition still emits when a call actually drives it.
        _ = try? await breaker.execute { 1 }
        let transitions = collected.withLock { events in
            events.filter { if case .circuitStateChanged = $0 { return true } else { return false } }.count
        }
        #expect(transitions == 3)   // closed→open, open→halfOpen, halfOpen→closed
    }

    // MARK: - Half-Open Transition

    @Test("transitions to half-open after timeout elapses")
    func transitionsToHalfOpen() async {
        let clock = TestClock()
        let breaker = CircuitBreaker(
            failureThreshold: 2,
            successThreshold: 2,
            timeout: .seconds(30),
            now: { clock.now }
        )

        try? await breaker.execute { throw TestError() }
        try? await breaker.execute { throw TestError() }
        #expect(StateKind(await breaker.state) == .open)

        clock.advance(by: .seconds(31))

        // One success keeps half-open (need 2)
        _ = try? await breaker.execute { 42 }
        #expect(StateKind(await breaker.state) == .halfOpen)
    }

    // MARK: - Closing from Half-Open

    @Test("closes after enough successful half-open calls")
    func closesAfterSuccessfulHalfOpen() async throws {
        let clock = TestClock()
        let breaker = CircuitBreaker(
            failureThreshold: 2,
            successThreshold: 2,
            timeout: .seconds(30),
            now: { clock.now }
        )

        try? await breaker.execute { throw TestError() }
        try? await breaker.execute { throw TestError() }
        clock.advance(by: .seconds(31))

        let r1 = try await breaker.execute { 1 }
        let r2 = try await breaker.execute { 2 }

        #expect(r1 == 1)
        #expect(r2 == 2)
        #expect(await breaker.state == .closed)
    }

    // MARK: - Re-Opening from Half-Open

    @Test("re-opens on failure during half-open")
    func reopensOnHalfOpenFailure() async {
        let clock = TestClock()
        let breaker = CircuitBreaker(
            failureThreshold: 2,
            timeout: .seconds(30),
            now: { clock.now }
        )

        try? await breaker.execute { throw TestError() }
        try? await breaker.execute { throw TestError() }
        clock.advance(by: .seconds(31))

        try? await breaker.execute { throw TestError() }
        #expect(StateKind(await breaker.state) == .open)
    }

    @Test("cancellation in half-open does not re-open the circuit")
    func cancellationDoesNotReopenHalfOpenCircuit() async throws {
        let clock = TestClock()
        let breaker = CircuitBreaker(
            failureThreshold: 2,
            successThreshold: 1,
            timeout: .seconds(30),
            now: { clock.now }
        )
        let gate = OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>(initialState: nil)

        try? await breaker.execute { throw TestError() }
        try? await breaker.execute { throw TestError() }
        clock.advance(by: .seconds(31))

        let task = Task {
            try await breaker.execute {
                try await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        gate.withLock { $0 = continuation }
                    }
                    try Task.checkCancellation()
                    return 7
                } onCancel: {
                    gate.withLock { continuation in
                        continuation?.resume()
                        continuation = nil
                    }
                }
            }
        }

        while gate.withLock({ $0 }) == nil {
            await Task.yield()
        }

        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected CancellationError")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }

        #expect(StateKind(await breaker.state) == .halfOpen)

        let result = try await breaker.execute { 42 }
        #expect(result == 42)
        #expect(await breaker.state == .closed)
    }

    // MARK: - Reset

    @Test("reset forces circuit to closed state")
    func resetForcesClosed() async throws {
        let breaker = CircuitBreaker(failureThreshold: 2)

        try? await breaker.execute { throw TestError() }
        try? await breaker.execute { throw TestError() }
        #expect(StateKind(await breaker.state) == .open)

        await breaker.reset()
        #expect(await breaker.state == .closed)

        let result = try await breaker.execute { 42 }
        #expect(result == 42)
    }

    // MARK: - Rolling Window

    @Test("rolling window expires old failures")
    func rollingWindowExpiry() async {
        let clock = TestClock()
        let breaker = CircuitBreaker(
            failureThreshold: 3,
            rollingWindow: .seconds(60),
            now: { clock.now }
        )

        // Two failures at time 0
        try? await breaker.execute { throw TestError() }
        try? await breaker.execute { throw TestError() }
        #expect(await breaker.state == .closed)

        // Advance past the rolling window — old failures expire
        clock.advance(by: .seconds(61))

        // One more failure — only this one is in the window
        try? await breaker.execute { throw TestError() }
        #expect(await breaker.state == .closed)

        // Two more failures — now 3 in the current window
        try? await breaker.execute { throw TestError() }
        try? await breaker.execute { throw TestError() }
        #expect(StateKind(await breaker.state) == .open)
    }

    @Test("rolling window boundary is inclusive: a failure exactly rollingWindow old still counts")
    func rollingWindowBoundaryIsInclusive() async {
        let clock = TestClock()
        let breaker = CircuitBreaker(
            failureThreshold: 2,
            rollingWindow: .seconds(60),
            now: { clock.now }
        )

        try? await breaker.execute { throw TestError() }
        clock.advance(by: .seconds(60))
        try? await breaker.execute { throw TestError() }

        // Documented on `init(failureThreshold:…:rollingWindow:…)`.
        #expect(StateKind(await breaker.state) == .open)
    }

    @Test("a failure one nanosecond past the rolling window no longer counts")
    func rollingWindowJustPastBoundaryExpires() async {
        let clock = TestClock()
        let breaker = CircuitBreaker(
            failureThreshold: 2,
            rollingWindow: .seconds(60),
            now: { clock.now }
        )

        try? await breaker.execute { throw TestError() }
        clock.advance(by: .seconds(60) + .nanoseconds(1))
        try? await breaker.execute { throw TestError() }

        #expect(await breaker.state == .closed)
    }

    // MARK: - Concurrent Half-Open

    @Test("concurrent calls in half-open respect halfOpenMaxCalls limit")
    func concurrentHalfOpenLimit() async throws {
        let clock = TestClock()
        let breaker = CircuitBreaker(
            failureThreshold: 2,
            halfOpenMaxCalls: 1,
            timeout: .seconds(10),
            now: { clock.now }
        )

        try? await breaker.execute { throw TestError() }
        try? await breaker.execute { throw TestError() }
        clock.advance(by: .seconds(11))

        // Gate: stores a continuation so we can suspend the first operation.
        let gate = OSAllocatedUnfairLock<CheckedContinuation<Int, Never>?>(
            initialState: nil
        )

        // First call enters half-open and suspends inside the operation.
        let firstTask = Task {
            try await breaker.execute {
                await withCheckedContinuation { cont in
                    gate.withLock { $0 = cont }
                }
            }
        }

        // Spin until the first task has stored its continuation.
        while gate.withLock({ $0 }) == nil {
            await Task.yield()
        }

        // Second call should be rejected — one call already in flight.
        do {
            _ = try await breaker.execute { 99 }
            Issue.record("Expected halfOpenRejected")
        } catch let error as CircuitBreakerError {
            guard case .halfOpenRejected = error else {
                Issue.record("Expected halfOpenRejected, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        // Release the first operation.
        gate.withLock { $0?.resume(returning: 42) }
        let result = try await firstTask.value
        #expect(result == 42)
    }

    @Test("a failure landing after the circuit opened neither reopens it nor extends its deadline")
    func lateFailureDoesNotExtendOpenWindow() async throws {
        let clock = TestClock()
        let collected = OSAllocatedUnfairLock<[PolicyEvent]>(initialState: [])
        let breaker = CircuitBreaker(
            failureThreshold: 1,
            timeout: .seconds(10),
            onEvent: { event in
                collected.withLock { $0.append(event) }
            },
            now: { clock.now }
        )

        // Gate: lets a closed-state call suspend mid-flight, releasing the actor.
        let gate = OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>(
            initialState: nil
        )

        let slowCall = Task {
            try await breaker.execute {
                await withCheckedContinuation { cont in gate.withLock { $0 = cont } }
                throw TestError()
            }
        }
        while gate.withLock({ $0 }) == nil {
            await Task.yield()
        }

        // A second call fails first and trips the circuit open until t0 + 10 s.
        try? await breaker.execute { throw TestError() }
        #expect(StateKind(await breaker.state) == .open)

        // Time passes, then the in-flight call finally fails into an open circuit.
        clock.advance(by: .seconds(5))
        gate.withLock { $0?.resume() }
        _ = try? await slowCall.value

        // That late failure belongs to the generation that already tripped, so it
        // must not re-open the breaker with a fresh t0 + 15 s deadline.
        clock.advance(by: .seconds(6)) // t0 + 11 s — past the original deadline.
        _ = try? await breaker.execute {}
        #expect(StateKind(await breaker.state) != .open)

        let selfTransition = collected.withLock { events in
            events.contains { event in
                if case .circuitStateChanged(from: .open, to: .open) = event { return true }
                return false
            }
        }
        #expect(!selfTransition, "open → open is not a state change and must not be emitted")
    }

    // MARK: - Event Emission

    @Test("emits events on every state transition")
    func eventsOnTransitions() async {
        let clock = TestClock()
        let collected = OSAllocatedUnfairLock<[PolicyEvent]>(initialState: [])

        let breaker = CircuitBreaker(
            failureThreshold: 2,
            timeout: .seconds(10),
            onEvent: { event in
                collected.withLock { $0.append(event) }
            },
            now: { clock.now }
        )

        // Closed → Open (2 failures)
        try? await breaker.execute { throw TestError() }
        try? await breaker.execute { throw TestError() }

        // Rejected while open
        _ = try? await breaker.execute { 42 }

        // Open → Half-open → Closed (timeout + success)
        clock.advance(by: .seconds(11))
        _ = try? await breaker.execute { 42 }

        let events = collected.withLock { $0 }

        let transitions = events.compactMap {
            event -> (StateKind, StateKind)? in
            if case .circuitStateChanged(from: let from, to: let to) = event {
                return (StateKind(from), StateKind(to))
            }
            return nil
        }

        #expect(transitions.count == 3)
        #expect(transitions[0] == (.closed, .open))
        #expect(transitions[1] == (.open, .halfOpen))
        #expect(transitions[2] == (.halfOpen, .closed))

        let rejectionCount = events.filter { event in
            if case .circuitCallRejected = event { return true }
            return false
        }.count

        #expect(rejectionCount == 1)
    }
}
