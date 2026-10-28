// RetryPolicyAdvancedTests.swift
// SafeRetry — A composable resilience library for Swift.

import os
import Testing
@testable import SafeRetry

// MARK: - Test Helpers

private struct TestError: Error {}

// MARK: - RetryPolicyAdvancedTests

@Suite("RetryPolicy — Advanced")
struct RetryPolicyAdvancedTests {

    // MARK: - Jitter

    @Test("retry with full jitter applies randomised delay")
    func retryWithFullJitter() async throws {
        let callCount = OSAllocatedUnfairLock(initialState: 0)
        let policy = RetryPolicy(
            maxAttempts: 2,
            delay: .fixed(.milliseconds(10)),
            jitter: .full
        )

        let result = try await policy.execute {
            let count = callCount.withLock { c -> Int in
                c += 1
                return c
            }
            if count < 2 { throw TestError() }
            return count
        }

        #expect(result == 2)
    }

    @Test("retry with equal jitter applies randomised delay")
    func retryWithEqualJitter() async throws {
        let callCount = OSAllocatedUnfairLock(initialState: 0)
        let policy = RetryPolicy(
            maxAttempts: 2,
            delay: .fixed(.milliseconds(10)),
            jitter: .equal
        )

        let result = try await policy.execute {
            let count = callCount.withLock { c -> Int in
                c += 1
                return c
            }
            if count < 2 { throw TestError() }
            return count
        }

        #expect(result == 2)
    }

    @Test("retry with a negative delay and jitter does not trap")
    func retryWithNegativeDelayAndJitter() async throws {
        let callCount = OSAllocatedUnfairLock(initialState: 0)
        let sleptDurations = OSAllocatedUnfairLock<[Duration]>(initialState: [])

        // A negative `fixed` interval used to crash the whole retry loop
        // inside `JitterStrategy.apply(to:)` on the first failure.
        let policy = RetryPolicy(
            maxAttempts: 2,
            delay: .fixed(.seconds(-5)),
            jitter: .full,
            sleep: { duration in
                sleptDurations.withLock { $0.append(duration) }
            }
        )

        let result = try await policy.execute {
            let count = callCount.withLock { c -> Int in
                c += 1
                return c
            }
            if count < 2 { throw TestError() }
            return count
        }

        #expect(result == 2)
        // The jittered delay clamps to zero, so the loop skips the sleep.
        #expect(sleptDurations.withLock { $0 }.isEmpty)
    }

    // MARK: - Delay strategies via RetryPolicy

    @Test("retry with exponential delay sleeps for the computed durations")
    func retryWithExponentialDelay() async throws {
        let callCount = OSAllocatedUnfairLock(initialState: 0)
        let sleptDurations = OSAllocatedUnfairLock<[Duration]>(initialState: [])

        let policy = RetryPolicy(
            maxAttempts: 3,
            delay: .exponential(base: .milliseconds(50)),
            jitter: .none,
            onEvent: nil,
            sleep: { duration in sleptDurations.withLock { $0.append(duration) } }
        )

        let result = try await policy.execute {
            let count = callCount.withLock { c -> Int in
                c += 1
                return c
            }
            if count < 3 { throw TestError() }
            return "done"
        }

        #expect(result == "done")
        // Attempt 1 fails -> 50ms delay, attempt 2 fails -> 100ms delay.
        #expect(sleptDurations.withLock { $0 } == [.milliseconds(50), .milliseconds(100)])
    }

    @Test("retry with linear delay sleeps for the computed durations")
    func retryWithLinearDelay() async throws {
        let callCount = OSAllocatedUnfairLock(initialState: 0)
        let sleptDurations = OSAllocatedUnfairLock<[Duration]>(initialState: [])

        let policy = RetryPolicy(
            maxAttempts: 3,
            delay: .linear(
                initial: .milliseconds(30),
                increment: .milliseconds(20),
                maxDelay: .seconds(1)
            ),
            jitter: .none,
            onEvent: nil,
            sleep: { duration in sleptDurations.withLock { $0.append(duration) } }
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
        // Attempt 1 fails -> 30ms delay, attempt 2 fails -> 50ms delay.
        // `.linear` is computed with exact Duration arithmetic (no Double
        // round trip), so this can be an exact equality check.
        #expect(sleptDurations.withLock { $0 } == [.milliseconds(30), .milliseconds(50)])
    }

    // MARK: - shouldRetry Predicate

    @Test("shouldRetry predicate stops retries when it returns false")
    func shouldRetryPredicateStopsRetries() async {
        let callCount = OSAllocatedUnfairLock(initialState: 0)
        let policy = RetryPolicy(maxAttempts: 5, delay: .immediate)

        struct TransientError: Error {}
        struct FatalError: Error {}

        do {
            _ = try await policy.execute(shouldRetry: { error, _ in
                error is TransientError
            }) {
                let count = callCount.withLock { c -> Int in
                    c += 1
                    return c
                }
                if count < 2 { throw TransientError() }
                throw FatalError()
            }
            Issue.record("Expected FatalError")
        } catch is FatalError {
            // Expected — predicate returned false for FatalError, no more retries.
        } catch {
            Issue.record("Expected FatalError, got \(error)")
        }

        // Two calls: first throws TransientError (retried), second throws FatalError (not retried).
        #expect(callCount.withLock { $0 } == 2)
    }

    @Test("shouldRetry predicate receives correct attempt index")
    func shouldRetryPredicateReceivesAttempt() async {
        let receivedAttempts = OSAllocatedUnfairLock<[Int]>(initialState: [])
        let policy = RetryPolicy(maxAttempts: 4, delay: .immediate)

        struct Err: Error {}

        _ = try? await policy.execute(shouldRetry: { _, attempt in
            receivedAttempts.withLock { $0.append(attempt) }
            return true
        }) {
            throw Err()
        }

        // shouldRetry is called for attempts 1, 2, 3 (not 4, because attempt 4 is the last).
        #expect(receivedAttempts.withLock { $0 } == [1, 2, 3])
    }

    @Test("shouldRetry predicate returning false on first attempt throws immediately")
    func shouldRetryFalseOnFirstAttempt() async {
        let policy = RetryPolicy(maxAttempts: 5, delay: .immediate)
        let callCount = OSAllocatedUnfairLock(initialState: 0)

        struct Err: Error {}

        do {
            _ = try await policy.execute(shouldRetry: { _, _ in false }) {
                callCount.withLock { $0 += 1 }
                throw Err()
            }
            Issue.record("Expected Err")
        } catch is Err {
            // Expected.
        } catch {
            Issue.record("Expected Err, got \(error)")
        }

        #expect(callCount.withLock { $0 } == 1)
    }

    // MARK: - Circuit Breaker Rejections

    @Test(
        "without shouldRetry, a CircuitBreakerError is not retried",
        arguments: [CircuitBreakerError.open(retryAfter: .seconds(30)), .halfOpenRejected]
    )
    func breakerRejectionNotRetriedByDefault(rejection: CircuitBreakerError) async {
        let callCount = OSAllocatedUnfairLock(initialState: 0)
        let slept = OSAllocatedUnfairLock<[Duration]>(initialState: [])
        let policy = RetryPolicy(
            maxAttempts: 3,
            delay: .exponential(base: .seconds(1)),
            sleep: { duration in slept.withLock { $0.append(duration) } }
        )

        await #expect(throws: rejection) {
            try await policy.execute {
                callCount.withLock { $0 += 1 }
                throw rejection
            }
        }

        #expect(callCount.withLock { $0 } == 1)
        #expect(slept.withLock { $0 }.isEmpty, "no backoff is waited out")
    }

    @Test("a shouldRetry that allows CircuitBreakerError retries an open breaker")
    func shouldRetryCanRetryOpenBreaker() async {
        // The predicate replaces the default rather than refining it, so
        // `{ _, _ in true }` restores retrying through every rejection.
        let start = ContinuousClock().now
        let rejections = OSAllocatedUnfairLock(initialState: 0)
        let breaker = CircuitBreaker(
            failureThreshold: 1,
            timeout: .seconds(30),
            onEvent: { event in
                if case .circuitCallRejected = event { rejections.withLock { $0 += 1 } }
            },
            now: { start }
        )
        try? await breaker.execute { throw TestError() }

        let slept = OSAllocatedUnfairLock<[Duration]>(initialState: [])
        let policy = RetryPolicy(
            maxAttempts: 3,
            delay: .exponential(base: .seconds(1)),
            sleep: { duration in slept.withLock { $0.append(duration) } }
        )

        await #expect(throws: CircuitBreakerError.self) {
            try await PolicyChain
                .retry(policy, shouldRetry: { _, _ in true })
                .circuitBreaker(breaker)
                .execute { 1 }
        }

        #expect(rejections.withLock { $0 } == 3)
        #expect(slept.withLock { $0 } == [.seconds(1), .seconds(2)])
    }

    // MARK: - Properties

    @Test("public properties reflect init parameters")
    func propertiesReflectInit() {
        let policy = RetryPolicy(
            maxAttempts: 5,
            delay: .fixed(.seconds(2)),
            jitter: .full
        )
        #expect(policy.maxAttempts == 5)
        // DelayStrategy is not Equatable, so verify via computed delay.
        #expect(policy.delay.delay(forAttempt: 1) == .seconds(2))
        #expect(policy.jitter == .full)
    }

    // MARK: - Single attempt

    @Test("maxAttempts = 1 means no retries")
    func singleAttemptNoRetry() async {
        let policy = RetryPolicy(maxAttempts: 1)

        do {
            _ = try await policy.execute { throw TestError() }
            Issue.record("Expected TestError")
        } catch is TestError {
            // Expected — no retries, immediate failure.
        } catch {
            Issue.record("Expected TestError, got \(error)")
        }
    }
}
