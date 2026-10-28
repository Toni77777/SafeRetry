// CircuitBreakerGenerationTests.swift
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

/// A one-shot gate that parks an operation mid-flight, releasing the breaker's
/// actor so the test can drive state transitions underneath the parked call.
private final class Gate: Sendable {
    private let continuation = OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>(
        initialState: nil
    )
    private let parked = OSAllocatedUnfairLock(initialState: false)

    /// Suspends until ``open()`` is called.
    func park() async {
        await withCheckedContinuation { continuation in
            self.continuation.withLock { $0 = continuation }
            parked.withLock { $0 = true }
        }
    }

    /// Spins until the operation has actually suspended inside ``park()``.
    func waitUntilParked() async {
        while !parked.withLock({ $0 }) {
            await Task.yield()
        }
    }

    /// Resumes the parked operation.
    func open() {
        continuation.withLock { continuation in
            continuation?.resume()
            continuation = nil
        }
    }
}

// MARK: - CircuitBreakerGenerationTests

/// Regression tests for counter attribution across state generations.
///
/// `CircuitBreaker` releases its actor for the duration of `await operation()`,
/// so a call can finish long after the state it started in is gone. Checking
/// only the *current state* on the way out cannot distinguish "nothing changed"
/// from "changed and cycled back" — and every transition wipes the counters.
/// Without a generation check, a call from a dead generation corrupts the
/// counters of the live one.
@Suite("CircuitBreaker — Generations")
struct CircuitBreakerGenerationTests {

    // MARK: - Half-Open Slot Accounting

    @Test("a stale half-open call does not free a slot owned by a later generation")
    func staleProbeDoesNotFreeCurrentGenerationSlot() async throws {
        let clock = TestClock()
        let breaker = CircuitBreaker(
            failureThreshold: 1,
            successThreshold: 9,    // never close, so the breaker stays half-open
            halfOpenMaxCalls: 2,
            timeout: .seconds(10),
            now: { clock.now }
        )

        try? await breaker.execute { throw TestError() }   // closed → open
        clock.advance(by: .seconds(11))

        // Generation 1: `stale` takes one of the two slots and parks.
        let staleGate = Gate()
        let staleCall = Task {
            try await breaker.execute {
                await staleGate.park()
                return 1
            }
        }
        await staleGate.waitUntilParked()

        // A second half-open call fails, ending generation 1.
        try? await breaker.execute { throw TestError() }
        #expect(StateKind(await breaker.state) == .open)

        // Generation 2: both slots are taken by live probes.
        let firstGate = Gate()
        let firstCall = Task {
            try await breaker.execute {
                await firstGate.park()
                return 2
            }
        }
        let secondGate = Gate()
        clock.advance(by: .seconds(11))
        await firstGate.waitUntilParked()
        let secondCall = Task {
            try await breaker.execute {
                await secondGate.park()
                return 3
            }
        }
        await secondGate.waitUntilParked()

        // Sanity check: the limit holds while both live probes are in flight.
        await #expect(throws: CircuitBreakerError.self) {
            try await breaker.execute { 4 }
        }

        // The generation-1 call finally succeeds. Its slot belongs to a
        // generation that no longer exists, so releasing it must not hand a
        // third concurrent probe to a dependency that allows only two.
        staleGate.open()
        _ = try? await staleCall.value

        await #expect(throws: CircuitBreakerError.self) {
            try await breaker.execute { 5 }
        }

        firstGate.open()
        secondGate.open()
        _ = try? await firstCall.value
        _ = try? await secondCall.value
    }

    // MARK: - Half-Open Success Accounting

    @Test("a stale half-open success does not count toward a later generation's successThreshold")
    func staleProbeSuccessDoesNotCloseCircuit() async throws {
        let clock = TestClock()
        let breaker = CircuitBreaker(
            failureThreshold: 1,
            successThreshold: 2,    // two healthy probes required to close
            halfOpenMaxCalls: 2,
            timeout: .seconds(10),
            now: { clock.now }
        )

        try? await breaker.execute { throw TestError() }   // closed → open
        clock.advance(by: .seconds(11))

        // Generation 1: `stale` parks holding one slot.
        let staleGate = Gate()
        let staleCall = Task {
            try await breaker.execute {
                await staleGate.park()
                return 1
            }
        }
        await staleGate.waitUntilParked()

        // End generation 1 and open generation 2.
        try? await breaker.execute { throw TestError() }
        clock.advance(by: .seconds(11))

        // One genuine generation-2 probe succeeds: 1 of the 2 required.
        _ = try? await breaker.execute { 10 }
        #expect(StateKind(await breaker.state) == .halfOpen)

        // The stale success must not supply the second one.
        staleGate.open()
        _ = try? await staleCall.value

        #expect(
            StateKind(await breaker.state) == .halfOpen,
            "one real probe plus a stale success must not satisfy successThreshold: 2"
        )
    }

    @Test("a stale half-open failure does not re-open a later generation")
    func staleProbeFailureDoesNotReopenLaterGeneration() async throws {
        let clock = TestClock()
        let breaker = CircuitBreaker(
            failureThreshold: 1,
            successThreshold: 9,    // never close
            halfOpenMaxCalls: 2,
            timeout: .seconds(10),
            now: { clock.now }
        )

        try? await breaker.execute { throw TestError() }   // closed → open
        clock.advance(by: .seconds(11))

        // Generation 1: `stale` parks, and will eventually fail.
        let staleGate = Gate()
        let staleCall = Task {
            try await breaker.execute {
                await staleGate.park()
                throw TestError()
            }
        }
        await staleGate.waitUntilParked()

        // End generation 1, then open generation 2.
        try? await breaker.execute { throw TestError() }
        clock.advance(by: .seconds(11))
        _ = try? await breaker.execute { 1 }
        #expect(StateKind(await breaker.state) == .halfOpen)

        // The generation-1 failure must not end generation 2's trial period.
        staleGate.open()
        _ = try? await staleCall.value
        #expect(StateKind(await breaker.state) == .halfOpen)
    }

    // MARK: - Closed-State Failure Accounting

    @Test("a failure from before a recovery does not count against the recovered circuit")
    func staleFailureDoesNotCountAfterRecovery() async throws {
        let clock = TestClock()
        let breaker = CircuitBreaker(
            failureThreshold: 2,
            successThreshold: 1,
            timeout: .seconds(10),
            now: { clock.now }
        )

        // A slow call starts while the circuit is healthy, then parks.
        let staleGate = Gate()
        let staleCall = Task {
            try await breaker.execute {
                await staleGate.park()
                throw TestError()
            }
        }
        await staleGate.waitUntilParked()

        // The circuit trips on two other failures, waits out the window, and
        // recovers via a successful probe.
        try? await breaker.execute { throw TestError() }
        try? await breaker.execute { throw TestError() }
        #expect(StateKind(await breaker.state) == .open)

        clock.advance(by: .seconds(11))
        _ = try? await breaker.execute { 1 }
        #expect(StateKind(await breaker.state) == .closed)

        // The long-dead failure lands in a freshly closed circuit.
        staleGate.open()
        _ = try? await staleCall.value
        #expect(StateKind(await breaker.state) == .closed)

        // A single fresh failure is 1 of 2 — the recovered circuit must stay
        // closed. If the stale failure was counted, this re-opens it.
        try? await breaker.execute { throw TestError() }
        #expect(
            StateKind(await breaker.state) == .closed,
            "one failure must not reach failureThreshold: 2 after a recovery"
        )
    }

    // MARK: - Reset

    @Test("a call in flight across reset does not count against the reset circuit")
    func staleFailureDoesNotCountAfterReset() async throws {
        let breaker = CircuitBreaker(failureThreshold: 1)

        let staleGate = Gate()
        let staleCall = Task {
            try await breaker.execute {
                await staleGate.park()
                throw TestError()
            }
        }
        await staleGate.waitUntilParked()

        await breaker.reset()

        staleGate.open()
        _ = try? await staleCall.value

        #expect(
            StateKind(await breaker.state) == .closed,
            "reset() clears the counters, so a call that predates it must not trip the breaker"
        )
    }
}
