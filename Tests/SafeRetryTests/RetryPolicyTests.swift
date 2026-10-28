// RetryPolicyTests.swift
// SafeRetry — A composable resilience library for Swift.

import os
import Testing
@testable import SafeRetry

// MARK: - Test Helpers

private struct TestError: Error, Equatable {}

// MARK: - RetryPolicyTests

@Suite("RetryPolicy")
struct RetryPolicyTests {

    // MARK: - Success

    @Test("succeeds on first attempt")
    func succeedsImmediately() async throws {
        let policy = RetryPolicy(maxAttempts: 3)
        let result = try await policy.execute { 42 }
        #expect(result == 42)
    }

    // MARK: - Retry on Failure

    @Test("retries until success within maxAttempts")
    func retriesUntilSuccess() async throws {
        let callCount = OSAllocatedUnfairLock(initialState: 0)
        let policy = RetryPolicy(maxAttempts: 3)

        let result = try await policy.execute {
            let count = callCount.withLock { c -> Int in
                c += 1
                return c
            }
            if count < 3 { throw TestError() }
            return count
        }

        #expect(result == 3)
    }

    @Test("throws last error when all attempts exhausted")
    func exhaustsAttempts() async {
        let policy = RetryPolicy(maxAttempts: 2)

        do {
            _ = try await policy.execute { throw TestError() }
            Issue.record("Expected TestError")
        } catch is TestError {
            // Expected.
        } catch {
            Issue.record("Expected TestError, got \(error)")
        }
    }

    // MARK: - Cancellation

    @Test("cancellation stops retries immediately")
    func cancellationStopsRetries() async {
        let policy = RetryPolicy(maxAttempts: 100, delay: .fixed(.milliseconds(10)))
        let callCount = OSAllocatedUnfairLock(initialState: 0)

        let task = Task {
            try await policy.execute {
                callCount.withLock { $0 += 1 }
                throw TestError()
            }
        }

        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected CancellationError")
        } catch is CancellationError {
            // Expected.
        } catch {
            // TestError is also acceptable if the task finished an attempt before cancellation.
        }

        let count = callCount.withLock { $0 }
        #expect(count < 100)
    }

    @Test("cancellation prevents the next immediate retry")
    func cancellationPreventsImmediateRetry() async {
        let policy = RetryPolicy(maxAttempts: 100, delay: .immediate)
        let callCount = OSAllocatedUnfairLock(initialState: 0)
        let gate = OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>(initialState: nil)

        let task = Task {
            try await policy.execute {
                let attempt = callCount.withLock { c -> Int in
                    c += 1
                    return c
                }

                if attempt == 1 {
                    await withCheckedContinuation { continuation in
                        gate.withLock { $0 = continuation }
                    }
                }

                throw TestError()
            }
        }

        while gate.withLock({ $0 }) == nil {
            await Task.yield()
        }

        task.cancel()
        gate.withLock { continuation in
            continuation?.resume()
            continuation = nil
        }

        do {
            _ = try await task.value
            Issue.record("Expected CancellationError")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }

        #expect(callCount.withLock { $0 } == 1)
    }
}
