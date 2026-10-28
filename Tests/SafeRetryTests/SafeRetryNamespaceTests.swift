// SafeRetryNamespaceTests.swift
// SafeRetry — A composable resilience library for Swift.

import os
import Testing
@testable import SafeRetry

// MARK: - Test Helpers

private struct TestError: Error {}

// MARK: - ResilientNamespaceTests

@Suite("SafeRetry Namespace")
struct ResilientNamespaceTests {

    // MARK: - retry

    @Test("retry succeeds on first attempt")
    func retrySucceedsImmediately() async throws {
        let result = try await SafeRetry.retry(attempts: 3) { 42 }
        #expect(result == 42)
    }

    @Test("retry retries and succeeds within attempts")
    func retryRetriesAndSucceeds() async throws {
        let callCount = OSAllocatedUnfairLock(initialState: 0)

        let result = try await SafeRetry.retry(attempts: 3) {
            let count = callCount.withLock { c -> Int in
                c += 1
                return c
            }
            if count < 2 { throw TestError() }
            return "ok"
        }

        #expect(result == "ok")
        #expect(callCount.withLock { $0 } == 2)
    }

    @Test("retry throws after exhausting attempts")
    func retryExhausts() async {
        do {
            _ = try await SafeRetry.retry(attempts: 2) {
                throw TestError()
            }
            Issue.record("Expected TestError")
        } catch is TestError {
            // Expected.
        } catch {
            Issue.record("Expected TestError, got \(error)")
        }
    }

    @Test("retry uses default exponential delay strategy")
    func retryUsesDefaultDelay() async throws {
        // Default delay is .exponential(base: .seconds(1)).
        // With 1 attempt, no delay is applied — just verify default works.
        let result = try await SafeRetry.retry(attempts: 1) { "fast" }
        #expect(result == "fast")
    }

    @Test("retry accepts custom delay strategy")
    func retryWithCustomDelay() async throws {
        let result = try await SafeRetry.retry(
            attempts: 2,
            delay: .fixed(.milliseconds(10))
        ) {
            "done"
        }
        #expect(result == "done")
    }

    // MARK: - withCircuitBreaker

    @Test("withCircuitBreaker passes through on success")
    func withCircuitBreakerSuccess() async throws {
        let breaker = CircuitBreaker(failureThreshold: 3)
        let result = try await SafeRetry.withCircuitBreaker(breaker) { 99 }
        #expect(result == 99)
    }

    @Test("withCircuitBreaker propagates operation error")
    func withCircuitBreakerFailure() async {
        let breaker = CircuitBreaker(failureThreshold: 3)

        do {
            _ = try await SafeRetry.withCircuitBreaker(breaker) {
                throw TestError()
            }
            Issue.record("Expected TestError")
        } catch is TestError {
            // Expected.
        } catch {
            Issue.record("Expected TestError, got \(error)")
        }
    }

    @Test("withCircuitBreaker rejects when circuit is open")
    func withCircuitBreakerRejects() async {
        let breaker = CircuitBreaker(failureThreshold: 2)

        try? await breaker.execute { throw TestError() }
        try? await breaker.execute { throw TestError() }

        do {
            _ = try await SafeRetry.withCircuitBreaker(breaker) { 1 }
            Issue.record("Expected CircuitBreakerError")
        } catch is CircuitBreakerError {
            // Expected.
        } catch {
            Issue.record("Expected CircuitBreakerError, got \(error)")
        }
    }

    // MARK: - Registry convenience

    @Test("SafeRetry.registry is the shared PolicyRegistry")
    func registryIsShared() {
        #expect(SafeRetry.registry === PolicyRegistry.shared)
    }
}
