// TimeoutPolicyTests.swift
// SafeRetry — A composable resilience library for Swift.

import os
import Testing
@testable import SafeRetry

// MARK: - Test Helpers

/// Parks an operation in a way that ignores cancellation, so a test can force
/// the timer child of ``TimeoutPolicy``'s race to finish first.
private struct UncancellableGate: Sendable {
    private let continuation = OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>(
        initialState: nil
    )
    private let parked = OSAllocatedUnfairLock(initialState: false)

    func park() async {
        await withCheckedContinuation { continuation in
            self.continuation.withLock { $0 = continuation }
            parked.withLock { $0 = true }
        }
    }

    func waitUntilParked() async {
        while !parked.withLock({ $0 }) {
            await Task.yield()
        }
    }

    func open() {
        continuation.withLock { continuation in
            continuation?.resume()
            continuation = nil
        }
    }
}

// MARK: - TimeoutPolicyTests

@Suite("TimeoutPolicy")
struct TimeoutPolicyTests {

    @Test("accepts very small positive duration")
    func acceptsSmallPositiveDuration() async throws {
        let policy = TimeoutPolicy(duration: .nanoseconds(1))
        let result = try await policy.execute { 1 }
        #expect(result == 1)
    }

    // MARK: - Success Path

    @Test("fast operation completes before timeout")
    func fastOperationCompletes() async throws {
        let policy = TimeoutPolicy(duration: .seconds(1))
        let result = try await policy.execute { 42 }
        #expect(result == 42)
    }

    // MARK: - Timeout

    @Test("slow operation is cancelled and throws TimeoutError")
    func slowOperationTimesOut() async {
        let policy = TimeoutPolicy(duration: .milliseconds(50))

        do {
            _ = try await policy.execute {
                try await Task.sleep(for: .seconds(10))
                return 42
            }
            Issue.record("Expected TimeoutError")
        } catch let error as TimeoutError {
            #expect(error.duration == .milliseconds(50))
        } catch {
            Issue.record("Expected TimeoutError, got \(error)")
        }
    }

    @Test("timeout fires within a reasonable margin of the configured duration")
    func timeoutDurationRespected() async {
        let policy = TimeoutPolicy(duration: .milliseconds(100))
        let clock = ContinuousClock()
        let start = clock.now

        do {
            _ = try await policy.execute {
                try await Task.sleep(for: .seconds(10))
                return 42
            }
            Issue.record("Expected TimeoutError")
        } catch is TimeoutError {
            let elapsed = clock.now - start
            // Must be at least ~100 ms but well under 2 s.
            #expect(elapsed >= .milliseconds(80))
            #expect(elapsed < .seconds(2))
        } catch {
            Issue.record("Expected TimeoutError, got \(error)")
        }
    }

    // MARK: - Cancellation

    @Test("cancellation surfaces even when the timer loses its own race", .timeLimit(.minutes(1)))
    func cancelledTimerSurfacesCancellation() async {
        // The operation is not cancellation-aware, so when the outer task is
        // cancelled the timer child is the only one that can finish — it wakes
        // from `Task.sleep` with an error and reports the cancelled sentinel.
        // This is the path that turns that sentinel into a `CancellationError`
        // rather than silently discarding it.
        let policy = TimeoutPolicy(duration: .seconds(60))
        let gate = UncancellableGate()

        let task = Task {
            try await policy.execute {
                await gate.park()
                return 42
            }
        }

        await gate.waitUntilParked()
        task.cancel()

        // Let the timer win, then release the operation so the group can close.
        // Cancellation only *enqueues* the timer child; it still has to be
        // scheduled, wake from `Task.sleep`, and complete before the operation
        // does. A single `Task.yield()` is not a head start on a multi-threaded
        // executor — the released operation reliably won the race on Xcode 27
        // and the policy correctly returned its value. The timer wakes in well
        // under a millisecond, so this is a wide margin, TSan included.
        try? await Task.sleep(for: .milliseconds(50))
        gate.open()

        do {
            _ = try await task.value
            Issue.record("Expected CancellationError")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
    }

    @Test("cancellation of outer task propagates correctly")
    func outerCancellationPropagates() async {
        let policy = TimeoutPolicy(duration: .seconds(10))

        let task = Task {
            try await policy.execute {
                try await Task.sleep(for: .seconds(100))
                return 42
            }
        }

        // Give the task a moment to enter the group.
        try? await Task.sleep(for: .milliseconds(10))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected CancellationError")
        } catch is CancellationError {
            // Expected — outer cancellation surfaces as CancellationError.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
    }
}
