// RetryPolicyEventTests.swift
// SafeRetry — A composable resilience library for Swift.

import os
import Testing
@testable import SafeRetry

// MARK: - Test Helpers

private struct TestError: Error, Equatable {}

/// Renders a ``PolicyEvent`` as a compact, comparable tag.
///
/// ``PolicyEvent`` cannot be `Equatable` — it carries `any Error` — so
/// asserting an exact event *sequence* means reducing each event to a value
/// that can be compared. Durations are included where the contract pins them
/// and omitted where they are measured (``PolicyEvent/attemptSucceeded(attempt:duration:)``).
private func tag(_ event: PolicyEvent) -> String {
    switch event {
    case .attemptStarted(let attempt):
        return "started(\(attempt))"
    case .attemptSucceeded(let attempt, _):
        return "succeeded(\(attempt))"
    case .attemptFailed(let attempt, _, let nextDelay):
        return "failed(\(attempt), next: \(nextDelay.map(String.init(describing:)) ?? "nil"))"
    case .retryExhausted(let totalAttempts, _):
        return "exhausted(\(totalAttempts))"
    case .retryScheduled(let attempt, let delay):
        return "scheduled(\(attempt), \(delay))"
    case .circuitStateChanged(let from, let to):
        return "circuit(\(from) -> \(to))"
    case .circuitCallRejected(let state):
        return "rejected(\(state))"
    case .timeoutExceeded(let duration):
        return "timeout(\(duration))"
    case .fallbackUsed:
        return "fallbackUsed"
    }
}

/// Collects events in emission order.
private struct Recorder: Sendable {
    private let storage = OSAllocatedUnfairLock<[PolicyEvent]>(initialState: [])

    var record: @Sendable (PolicyEvent) -> Void {
        { event in storage.withLock { $0.append(event) } }
    }

    var events: [PolicyEvent] { storage.withLock { $0 } }
    var tags: [String] { events.map(tag) }
}

// MARK: - RetryPolicyEventTests

/// `RetryPolicy` emits five of the nine ``PolicyEvent`` cases, and the order
/// they arrive in is part of its contract — the callback is synchronous
/// precisely so that events describe state changes in the order they happen.
@Suite("RetryPolicy — Events")
struct RetryPolicyEventTests {

    // MARK: - Success After Retries

    @Test("emits the full attempt lifecycle when a retry eventually succeeds")
    func eventSequenceOnEventualSuccess() async throws {
        let recorder = Recorder()
        let callCount = OSAllocatedUnfairLock(initialState: 0)
        let policy = RetryPolicy(
            maxAttempts: 3,
            delay: .fixed(.milliseconds(50)),
            jitter: .none,
            onEvent: recorder.record,
            sleep: { _ in }
        )

        let result = try await policy.execute {
            let count = callCount.withLock { c -> Int in
                c += 1
                return c
            }
            if count < 3 { throw TestError() }
            return count
        }

        #expect(result == 3)
        #expect(recorder.tags == [
            "started(1)",
            "failed(1, next: 0.05 seconds)",
            "scheduled(2, 0.05 seconds)",
            "started(2)",
            "failed(2, next: 0.05 seconds)",
            "scheduled(3, 0.05 seconds)",
            "started(3)",
            "succeeded(3)",
        ])
    }

    @Test("emits only started then succeeded when the first attempt works")
    func eventSequenceOnImmediateSuccess() async throws {
        let recorder = Recorder()
        let policy = RetryPolicy(maxAttempts: 3, onEvent: recorder.record)

        _ = try await policy.execute { 42 }

        #expect(recorder.tags == ["started(1)", "succeeded(1)"])
    }

    // MARK: - Exhaustion

    @Test("final attempt reports no next delay and is followed by retryExhausted")
    func eventSequenceOnExhaustion() async {
        let recorder = Recorder()
        let policy = RetryPolicy(
            maxAttempts: 2,
            delay: .fixed(.milliseconds(50)),
            jitter: .none,
            onEvent: recorder.record,
            sleep: { _ in }
        )

        await #expect(throws: TestError.self) {
            try await policy.execute { throw TestError() }
        }

        #expect(recorder.tags == [
            "started(1)",
            "failed(1, next: 0.05 seconds)",
            "scheduled(2, 0.05 seconds)",
            "started(2)",
            "failed(2, next: nil)",
            "exhausted(2)",
        ])
    }

    @Test("retryExhausted carries the final error")
    func exhaustedCarriesLastError() async {
        let recorder = Recorder()
        let policy = RetryPolicy(maxAttempts: 2, onEvent: recorder.record)

        await #expect(throws: TestError.self) {
            try await policy.execute { throw TestError() }
        }

        let lastError = recorder.events.compactMap { event -> (any Error)? in
            if case .retryExhausted(_, let error) = event { return error }
            return nil
        }.last
        #expect(lastError is TestError)
    }

    // MARK: - shouldRetry

    @Test("a shouldRetry veto ends the sequence without retryExhausted")
    func shouldRetryVetoEmitsNoExhaustion() async {
        let recorder = Recorder()
        let policy = RetryPolicy(
            maxAttempts: 5,
            delay: .fixed(.milliseconds(50)),
            onEvent: recorder.record,
            sleep: { _ in }
        )

        await #expect(throws: TestError.self) {
            try await policy.execute(shouldRetry: { _, _ in false }) {
                throw TestError()
            }
        }

        // A vetoed failure is not an exhausted retry budget: attempts remained,
        // the policy was told not to use them. No `retryExhausted` is emitted,
        // and the failure reports no next delay because none was scheduled.
        #expect(recorder.tags == ["started(1)", "failed(1, next: nil)"])
    }

    @Test("a veto partway through still emits the earlier retries")
    func shouldRetryVetoAfterRetries() async {
        let recorder = Recorder()
        let callCount = OSAllocatedUnfairLock(initialState: 0)
        let policy = RetryPolicy(
            maxAttempts: 5,
            delay: .fixed(.milliseconds(10)),
            jitter: .none,
            onEvent: recorder.record,
            sleep: { _ in }
        )

        await #expect(throws: TestError.self) {
            try await policy.execute(shouldRetry: { _, attempt in attempt < 2 }) {
                callCount.withLock { $0 += 1 }
                throw TestError()
            }
        }

        #expect(recorder.tags == [
            "started(1)",
            "failed(1, next: 0.01 seconds)",
            "scheduled(2, 0.01 seconds)",
            "started(2)",
            "failed(2, next: nil)",
        ])
        #expect(callCount.withLock { $0 } == 2)
    }

    @Test("without shouldRetry, a breaker rejection ends the sequence like a veto")
    func breakerRejectionEmitsNoExhaustion() async {
        let recorder = Recorder()
        let policy = RetryPolicy(
            maxAttempts: 5,
            delay: .fixed(.milliseconds(50)),
            onEvent: recorder.record,
            sleep: { _ in }
        )

        await #expect(throws: CircuitBreakerError.self) {
            try await policy.execute {
                throw CircuitBreakerError.open(retryAfter: .seconds(30))
            }
        }

        #expect(recorder.tags == ["started(1)", "failed(1, next: nil)"])
    }

    // MARK: - Delay Reporting

    @Test("the reported next delay is the delay actually slept")
    func reportedDelayMatchesSleptDelay() async {
        let recorder = Recorder()
        let slept = OSAllocatedUnfairLock<[Duration]>(initialState: [])
        let policy = RetryPolicy(
            maxAttempts: 4,
            delay: .exponential(base: .milliseconds(10)),
            jitter: .none,
            onEvent: recorder.record,
            sleep: { duration in slept.withLock { $0.append(duration) } }
        )

        _ = try? await policy.execute { throw TestError() }

        let scheduled = recorder.events.compactMap { event -> Duration? in
            if case .retryScheduled(_, let delay) = event { return delay }
            return nil
        }
        let reportedNext = recorder.events.compactMap { event -> Duration? in
            if case .attemptFailed(_, _, let next) = event { return next }
            return nil
        }

        #expect(slept.withLock { $0 } == [.milliseconds(10), .milliseconds(20), .milliseconds(40)])
        #expect(scheduled == slept.withLock { $0 })
        #expect(reportedNext == slept.withLock { $0 })
    }

    @Test("jitter is applied once — the reported delay is the jittered one")
    func jitteredDelayIsReportedNotRecomputed() async {
        let recorder = Recorder()
        let slept = OSAllocatedUnfairLock<[Duration]>(initialState: [])
        let policy = RetryPolicy(
            maxAttempts: 3,
            delay: .fixed(.seconds(10)),
            jitter: .full,
            onEvent: recorder.record,
            sleep: { duration in slept.withLock { $0.append(duration) } }
        )

        _ = try? await policy.execute { throw TestError() }

        let scheduled = recorder.events.compactMap { event -> Duration? in
            if case .retryScheduled(_, let delay) = event { return delay }
            return nil
        }

        // `.full` jitter randomises each delay, so the only way these agree is
        // if the single jittered value is reused for the event and the sleep.
        #expect(scheduled == slept.withLock { $0 })
        #expect(scheduled.count == 2)
        for delay in scheduled {
            #expect(delay >= .zero)
            #expect(delay <= .seconds(10))
        }
    }

    // MARK: - Attempt Duration

    @Test("attemptSucceeded reports a non-negative measured duration")
    func succeededReportsDuration() async throws {
        let recorder = Recorder()
        let policy = RetryPolicy(maxAttempts: 1, onEvent: recorder.record)

        _ = try await policy.execute { 1 }

        let duration = recorder.events.compactMap { event -> Duration? in
            if case .attemptSucceeded(_, let duration) = event { return duration }
            return nil
        }.first
        #expect(try #require(duration) >= .zero)
    }

    // MARK: - Cancellation

    @Test("a cancelled attempt emits no failure or exhaustion event")
    func cancellationEmitsNoFailureEvents() async {
        let recorder = Recorder()
        let policy = RetryPolicy(maxAttempts: 3, onEvent: recorder.record)

        await #expect(throws: CancellationError.self) {
            try await policy.execute { throw CancellationError() }
        }

        #expect(recorder.tags == ["started(1)"])
    }
}
