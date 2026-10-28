// PolicyChainTests.swift
// SafeRetry — A composable resilience library for Swift.

import os
import Testing
@testable import SafeRetry

// MARK: - Test Helpers

private struct TestError: Error, Equatable {}

// MARK: - PolicyChainTests

@Suite("PolicyChain")
struct PolicyChainTests {

    // MARK: - Single Policy

    @Test("single policy chain works")
    func singlePolicyChain() async throws {
        let result = try await PolicyChain
            .timeout(.seconds(5))
            .execute { 42 }
        #expect(result == 42)
    }

    // MARK: - Retry + CircuitBreaker

    @Test("retry + circuitBreaker combination retries through the breaker")
    func retryAndCircuitBreaker() async throws {
        let callCount = OSAllocatedUnfairLock(initialState: 0)
        let breaker = CircuitBreaker(failureThreshold: 10)

        let result = try await PolicyChain
            .retry(attempts: 3, delay: .immediate)
            .circuitBreaker(breaker)
            .execute {
                let count = callCount.withLock { c -> Int in
                    c += 1
                    return c
                }
                if count < 3 { throw TestError() }
                return "ok"
            }

        #expect(result == "ok")
        #expect(callCount.withLock { $0 } == 3)
    }

    // MARK: - Timeout + Retry

    @Test("timeout wraps all retry attempts combined")
    func timeoutWrapsRetries() async {
        do {
            _ = try await PolicyChain
                .timeout(.milliseconds(100))
                .retry(attempts: 100, delay: .fixed(.milliseconds(50)))
                .execute {
                    throw TestError()
                }
            Issue.record("Expected TimeoutError")
        } catch is TimeoutError {
            // Expected — timeout fired before 100 retries could complete.
        } catch {
            Issue.record("Expected TimeoutError, got \(error)")
        }
    }

    // MARK: - Fallback

    @Test("fallback returns value when all policies fail")
    func fallbackOnFailure() async throws {
        let result = try await PolicyChain
            .retry(attempts: 2, delay: .immediate)
            .fallback("default")
            .execute {
                throw TestError()
            }

        #expect(result == "default")
    }

    @Test("fallback propagates cancellation")
    func fallbackPropagatesCancellation() async {
        let chain = PolicyChain
            .timeout(.seconds(10))
            .fallback("default")

        let task = Task {
            try await chain.execute {
                try await Task.sleep(for: .seconds(10))
                return "success"
            }
        }

        try? await Task.sleep(for: .milliseconds(20))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected CancellationError")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
    }

    @Test("fallback(_:onEvent:) emits fallbackUsed when the constant value is used")
    func fallbackValueEmitsEvent() async throws {
        let events = OSAllocatedUnfairLock<[PolicyEvent]>(initialState: [])

        let result = try await PolicyChain
            .retry(attempts: 2, delay: .immediate)
            .fallback("default", onEvent: { event in events.withLock { $0.append(event) } })
            .execute {
                throw TestError()
            }

        #expect(result == "default")
        let recorded = events.withLock { $0 }
        #expect(recorded.count == 1)
        if case .fallbackUsed = recorded.first {
            // Expected.
        } else {
            Issue.record("Expected a single fallbackUsed event, got \(recorded)")
        }
    }

    @Test("fallback(onEvent:_:) emits fallbackUsed and the handler may throw")
    func fallbackHandlerEmitsEventAndCanThrow() async {
        struct TranslatedError: Error, Equatable {}

        let sawFallbackUsed = OSAllocatedUnfairLock(initialState: false)

        let chain = PolicyChain
            .retry(attempts: 2, delay: .immediate)
            .fallback(onEvent: { event in
                if case .fallbackUsed = event {
                    sawFallbackUsed.withLock { $0 = true }
                }
            }) { (_: any Error) -> String in
                throw TranslatedError()
            }

        do {
            _ = try await chain.execute { throw TestError() }
            Issue.record("Expected TranslatedError")
        } catch is TranslatedError {
            #expect(sawFallbackUsed.withLock { $0 })
        } catch {
            Issue.record("Expected TranslatedError, got \(error)")
        }
    }

    // MARK: - Wrapping Order

    @Test("wrapping order matches API call order")
    func correctWrappingOrder() async throws {
        // ORDER 1: timeout OUTSIDE retry — timeout limits all retries combined.
        let attemptsOutside = OSAllocatedUnfairLock(initialState: 0)

        do {
            _ = try await PolicyChain
                .timeout(.milliseconds(100))
                .retry(attempts: 100, delay: .fixed(.milliseconds(20)))
                .execute {
                    attemptsOutside.withLock { $0 += 1 }
                    throw TestError()
                }
            Issue.record("Expected TimeoutError")
        } catch is TimeoutError {
            // Timeout fired — far fewer than 100 retries executed.
            let count = attemptsOutside.withLock { $0 }
            #expect(count < 20)
        } catch {
            Issue.record("Expected TimeoutError, got \(error)")
        }

        // ORDER 2: timeout INSIDE retry — each attempt has its own timeout.
        // A fast operation succeeds on attempt 3; per-attempt timeout doesn't fire.
        let attemptsInside = OSAllocatedUnfairLock(initialState: 0)

        let result = try await PolicyChain
            .retry(attempts: 3, delay: .immediate)
            .timeout(.seconds(1))
            .execute {
                let count = attemptsInside.withLock { c -> Int in
                    c += 1
                    return c
                }
                if count < 3 { throw TestError() }
                return count
            }

        #expect(result == 3)
        #expect(attemptsInside.withLock { $0 } == 3)
    }
}
