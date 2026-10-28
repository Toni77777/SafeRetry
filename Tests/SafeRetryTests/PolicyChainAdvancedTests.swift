// PolicyChainAdvancedTests.swift
// SafeRetry — A composable resilience library for Swift.

import os
import Testing
@testable import SafeRetry

// MARK: - Test Helpers

private struct TestError: Error {}

// MARK: - PolicyChainAdvancedTests

@Suite("PolicyChain — Advanced")
struct PolicyChainAdvancedTests {

    // MARK: - Fallback with Handler

    @Test("fallback with handler receives the original error")
    func fallbackHandlerReceivesError() async throws {
        let result = try await PolicyChain
            .retry(attempts: 2, delay: .immediate)
            .fallback { error in
                "recovered-from-\(type(of: error))"
            }
            .execute {
                throw TestError()
            }

        #expect(result == "recovered-from-TestError")
    }

    // MARK: - retry(_ policy:) with actor

    @Test("retry with RetryPolicy actor works in chain")
    func retryWithPolicyActor() async throws {
        let callCount = OSAllocatedUnfairLock(initialState: 0)
        let policy = RetryPolicy(maxAttempts: 3, delay: .immediate)

        let result = try await PolicyChain
            .retry(policy)
            .execute {
                let count = callCount.withLock { c -> Int in
                    c += 1
                    return c
                }
                if count < 3 { throw TestError() }
                return count
            }

        #expect(result == 3)
    }

    // MARK: - timeout(_ policy:) with an observer

    @Test("static timeout(_ policy:) forwards timeoutExceeded to onEvent")
    func staticTimeoutPolicyEmitsEvents() async throws {
        let events = OSAllocatedUnfairLock<[PolicyEvent]>(initialState: [])
        let policy = TimeoutPolicy(duration: .milliseconds(20)) { event in
            events.withLock { $0.append(event) }
        }

        await #expect(throws: TimeoutError.self) {
            try await PolicyChain
                .timeout(policy)
                .execute {
                    try await Task.sleep(for: .seconds(10))
                }
        }

        let recorded = events.withLock { $0 }
        #expect(recorded.count == 1)
        guard case .timeoutExceeded(let duration) = try #require(recorded.first) else {
            Issue.record("expected a timeoutExceeded event, got \(recorded)")
            return
        }
        #expect(duration == .milliseconds(20))
    }

    @Test("instance timeout(_ policy:) forwards timeoutExceeded to onEvent")
    func instanceTimeoutPolicyEmitsEvents() async throws {
        let events = OSAllocatedUnfairLock<[PolicyEvent]>(initialState: [])
        let policy = TimeoutPolicy(duration: .milliseconds(20)) { event in
            events.withLock { $0.append(event) }
        }

        await #expect(throws: TimeoutError.self) {
            try await PolicyChain
                .retry(attempts: 1, delay: .immediate)
                .timeout(policy)
                .execute {
                    try await Task.sleep(for: .seconds(10))
                }
        }

        #expect(events.withLock { $0 }.count == 1)
    }

    // MARK: - Static circuitBreaker entry point

    @Test("static circuitBreaker factory creates a working chain")
    func staticCircuitBreakerEntry() async throws {
        let breaker = CircuitBreaker(failureThreshold: 5)
        let result = try await PolicyChain
            .circuitBreaker(breaker)
            .execute { "ok" }

        #expect(result == "ok")
    }

    @Test("static circuitBreaker rejects when open")
    func staticCircuitBreakerRejects() async {
        let breaker = CircuitBreaker(failureThreshold: 2)

        try? await breaker.execute { throw TestError() }
        try? await breaker.execute { throw TestError() }

        do {
            _ = try await PolicyChain
                .circuitBreaker(breaker)
                .execute { 1 }
            Issue.record("Expected CircuitBreakerError")
        } catch is CircuitBreakerError {
            // Expected.
        } catch {
            Issue.record("Expected CircuitBreakerError, got \(error)")
        }
    }

    // MARK: - Instance retry(attempts:) chaining

    @Test("instance retry(attempts:delay:jitter:) chains correctly")
    func instanceRetryConvenience() async throws {
        let callCount = OSAllocatedUnfairLock(initialState: 0)

        let result = try await PolicyChain
            .timeout(.seconds(5))
            .retry(attempts: 3, delay: .immediate, jitter: .none)
            .execute {
                let count = callCount.withLock { c -> Int in
                    c += 1
                    return c
                }
                if count < 2 { throw TestError() }
                return "done"
            }

        #expect(result == "done")
    }

    // MARK: - Presets

    @Test("Preset.default executes successfully")
    func presetDefault() async throws {
        let result = try await PolicyChain.Preset.default
            .execute { 42 }
        #expect(result == 42)
    }

    @Test("Preset.aggressive executes successfully")
    func presetAggressive() async throws {
        let result = try await PolicyChain.Preset.aggressive
            .execute { "fast" }
        #expect(result == "fast")
    }

    @Test("Preset.conservative executes successfully")
    func presetConservative() async throws {
        let result = try await PolicyChain.Preset.conservative
            .execute { 99 }
        #expect(result == 99)
    }

    @Test("Preset.default retries on failure")
    func presetDefaultRetries() async throws {
        let callCount = OSAllocatedUnfairLock(initialState: 0)

        let result = try await PolicyChain.Preset.default
            .execute {
                let count = callCount.withLock { c -> Int in
                    c += 1
                    return c
                }
                if count < 2 { throw TestError() }
                return count
            }

        #expect(result == 2)
    }

    @Test("a preset over an open breaker gives up at the first rejection")
    func presetFailsFastOnOpenBreaker() async {
        let presets: [(name: String, chain: PolicyChain)] = [
            ("default", PolicyChain.Preset.default),
            ("aggressive", PolicyChain.Preset.aggressive),
        ]

        for preset in presets {
            // A frozen clock keeps the breaker open for the whole test.
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

            // The presets build their retry with a real sleep (#4), and their
            // first backoff is 1 s (`.default`) or 500 ms (`.aggressive`). A
            // guard well inside that turns a retry still waiting out its
            // backoff into a TimeoutError, instead of spending seconds or —
            // for `.aggressive` — minutes before the counts below can fail.
            let guardPolicy = TimeoutPolicy(duration: .milliseconds(250))
            await #expect(throws: CircuitBreakerError.self, "\(preset.name)") {
                try await guardPolicy.execute {
                    try await preset.chain.circuitBreaker(breaker).execute { 1 }
                }
            }

            #expect(rejections.withLock { $0 } == 1, "\(preset.name)")
        }
    }

    @Test("Preset.conservative times out slow operations", .timeLimit(.minutes(1)))
    func presetConservativeTimeout() async {
        do {
            _ = try await PolicyChain.Preset.conservative
                .execute {
                    try await Task.sleep(for: .seconds(60))
                    return 1
                }
            Issue.record("Expected TimeoutError")
        } catch is TimeoutError {
            // Expected — each of the 2 attempts is individually bounded by the
            // preset's 5s per-attempt timeout, so both attempts time out and
            // the retry policy exhausts (5s + 2s delay + 5s ≈ 12s wall time).
        } catch {
            Issue.record("Expected TimeoutError, got \(error)")
        }
    }

    // MARK: - FallbackChain direct

    @Test("FallbackChain.execute returns operation result on success")
    func fallbackChainSuccessPath() async throws {
        let result = try await PolicyChain
            .timeout(.seconds(5))
            .fallback("default")
            .execute { "success" }

        #expect(result == "success")
    }

    @Test("FallbackChain.execute returns fallback on operation failure")
    func fallbackChainFailurePath() async throws {
        let result = try await PolicyChain
            .timeout(.seconds(5))
            .fallback("default")
            .execute { throw TestError() }

        #expect(result == "default")
    }

    // MARK: - Chain with operation error propagation

    @Test("chain propagates operation error when no fallback is set")
    func chainPropagatesError() async {
        do {
            _ = try await PolicyChain
                .timeout(.seconds(5))
                .execute { throw TestError() }
            Issue.record("Expected TestError")
        } catch is TestError {
            // Expected.
        } catch {
            Issue.record("Expected TestError, got \(error)")
        }
    }
}
