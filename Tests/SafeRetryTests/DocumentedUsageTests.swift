// DocumentedUsageTests.swift
// SafeRetry — A composable resilience library for Swift.

import Foundation
import os
import Testing
@testable import SafeRetry

// MARK: - Test Helpers

private struct NotFoundError: Error {}
private struct ValidationError: Error {}
private struct TransientError: Error {}

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
private enum StateKind: Equatable {
    case closed, open, halfOpen

    init(_ state: CircuitState) {
        switch state {
        case .closed: self = .closed
        case .open: self = .open
        case .halfOpen: self = .halfOpen
        }
    }
}

// MARK: - DocumentedUsageTests

/// Executable versions of the snippets in `README.md` and the DocC articles.
///
/// Documentation examples drift: a snippet that no longer compiles is a defect
/// a reader hits before any test does, and nothing in a normal build catches
/// it. Each test here mirrors a documented example closely enough that an API
/// change which invalidates the docs also fails the suite.
@Suite("Documented usage")
struct DocumentedUsageTests {

    // MARK: - README: shouldRetry on a chain

    @Test("the documented chain shouldRetry predicate filters retries")
    func chainShouldRetryPredicate() async {
        let callCount = OSAllocatedUnfairLock(initialState: 0)

        // README §URLSession integration and GettingStarted Step 6.
        let chain = PolicyChain
            .timeout(.seconds(10))
            .retry(attempts: 3, delay: .immediate) { error, _ in
                (error as? URLError)?.code != .badURL
            }

        await #expect(throws: URLError.self) {
            try await chain.execute {
                callCount.withLock { $0 += 1 }
                throw URLError(.badURL)
            }
        }

        #expect(callCount.withLock { $0 } == 1, "badURL must not be retried")
    }

    @Test("the static chain shouldRetry predicate filters retries")
    func staticChainShouldRetryPredicate() async {
        let callCount = OSAllocatedUnfairLock(initialState: 0)

        let chain = PolicyChain.retry(attempts: 4, delay: .immediate) { error, _ in
            error is TransientError
        }

        await #expect(throws: ValidationError.self) {
            try await chain.execute {
                let count = callCount.withLock { c -> Int in
                    c += 1
                    return c
                }
                if count == 1 { throw TransientError() }
                throw ValidationError()
            }
        }

        #expect(callCount.withLock { $0 } == 2)
    }

    @Test("a pre-built RetryPolicy can carry shouldRetry into a chain")
    func chainRetryPolicyWithShouldRetry() async {
        let events = OSAllocatedUnfairLock<[PolicyEvent]>(initialState: [])
        let callCount = OSAllocatedUnfairLock(initialState: 0)

        // README §Observing a chain — a policy instance keeps its onEvent,
        // and the instance overload still accepts a predicate.
        let policy = RetryPolicy(maxAttempts: 5, delay: .immediate, onEvent: { event in
            events.withLock { $0.append(event) }
        })
        let chain = PolicyChain
            .timeout(.seconds(5))
            .retry(policy, shouldRetry: { error, _ in error is TransientError })

        await #expect(throws: ValidationError.self) {
            try await chain.execute {
                let count = callCount.withLock { c -> Int in
                    c += 1
                    return c
                }
                if count < 3 { throw TransientError() }
                throw ValidationError()
            }
        }

        #expect(callCount.withLock { $0 } == 3)
        #expect(!events.withLock { $0 }.isEmpty, "a pre-built policy keeps its observer")
    }

    // MARK: - README: isFailure

    @Test("the documented isFailure example keeps caller errors off the breaker")
    func isFailureExample() async {
        // README §Not every error is the dependency's fault.
        let breaker = CircuitBreaker(
            failureThreshold: 5,
            isFailure: { error in
                !(error is NotFoundError) && !(error is ValidationError)
            }
        )

        for _ in 0..<10 {
            try? await breaker.execute { throw NotFoundError() }
            try? await breaker.execute { throw ValidationError() }
        }

        #expect(StateKind(await breaker.state) == .closed)
    }

    // MARK: - README: retryAfter

    @Test("the documented retryAfter backoff reads a duration without switching on the case")
    func retryAfterExample() async throws {
        let breaker = CircuitBreaker(failureThreshold: 1, timeout: .seconds(30))
        try? await breaker.execute { throw TransientError() }

        var observed: Duration?
        do {
            _ = try await breaker.execute { 1 }
        } catch let error as CircuitBreakerError {
            observed = error.retryAfter ?? .seconds(1)
        }

        let retryAfter = try #require(observed)
        #expect(retryAfter > .zero)
        #expect(retryAfter <= .seconds(30))
    }

    // MARK: - README: fallback onEvent on both forms

    @Test("both documented chain fallback forms accept an onEvent callback")
    func fallbackOnEventForms() async throws {
        let handlerEvents = OSAllocatedUnfairLock<[PolicyEvent]>(initialState: [])
        let valueEvents = OSAllocatedUnfairLock<[PolicyEvent]>(initialState: [])

        // Observability.md §Observing a PolicyChain.
        let handlerForm = PolicyChain
            .retry(attempts: 2, delay: .immediate)
            .fallback(onEvent: { event in
                handlerEvents.withLock { $0.append(event) }
            }) { _ in "cached" }

        let valueForm = PolicyChain
            .retry(attempts: 2, delay: .immediate)
            .fallback("cached", onEvent: { event in
                valueEvents.withLock { $0.append(event) }
            })

        #expect(try await handlerForm.execute { throw TransientError() } == "cached")
        #expect(try await valueForm.execute { throw TransientError() } == "cached")
        #expect(handlerEvents.withLock { $0 }.count == 1)
        #expect(valueEvents.withLock { $0 }.count == 1)
    }

    // MARK: - README: EventStream fan-out

    @Test("the documented EventStream fan-out collects events from several policies")
    func eventStreamFanOut() async throws {
        // Observability.md §Fanning Policy Events into a Shared Stream.
        let events = EventStream<PolicyEvent>()

        // Labelled explicitly: in a `@testable` context the internal
        // initialisers' `now:`/`sleep:` parameters come last, so a trailing
        // closure would bind to those instead of to `onEvent`.
        let breaker = CircuitBreaker(failureThreshold: 5, onEvent: { events.emit($0) })
        let retry = RetryPolicy(maxAttempts: 3, delay: .immediate, onEvent: { events.emit($0) })

        let consumer = Task { () -> Int in
            var count = 0
            for await _ in events { count += 1 }
            return count
        }

        _ = try? await retry.execute { throw TransientError() }
        try? await breaker.execute { throw TransientError() }
        events.finish()

        #expect(await consumer.value > 0)
    }

    // MARK: - GettingStarted: exhaustive CircuitBreakerError handling

    @Test("the documented CircuitBreakerError switch is exhaustive")
    func circuitBreakerErrorSwitchIsExhaustive() async {
        // GettingStarted Step 3 / MigratingFromRxSwift.
        let breaker = CircuitBreaker(failureThreshold: 1, timeout: .seconds(30))
        try? await breaker.execute { throw TransientError() }

        var message = ""
        do {
            _ = try await breaker.execute { 1 }
        } catch let error as CircuitBreakerError {
            switch error {
            case .open(let retryAfter):
                message = "Service down. Retry after \(retryAfter)."
            case .halfOpenRejected:
                message = "Recovery in progress, try again shortly."
            }
        } catch {
            message = "other: \(error)"
        }

        #expect(message.hasPrefix("Service down."))
    }

    // MARK: - README: timeout must sit inside the breaker

    @Test("a timeout outside the breaker hides timed-out calls from it")
    func timeoutOutsideBreakerHidesFailures() async {
        // README §Put the timeout inside the breaker, GettingStarted Step 4.
        // TimeoutPolicy enforces its deadline by cancelling, and the breaker
        // exempts cancellation — so these timeouts are never counted.
        let breaker = CircuitBreaker(failureThreshold: 2, timeout: .seconds(30))

        for _ in 0..<5 {
            _ = try? await PolicyChain
                .timeout(.milliseconds(20))
                .circuitBreaker(breaker)
                .execute { try await Task.sleep(for: .seconds(10)) }
        }

        #expect(
            StateKind(await breaker.state) == .closed,
            "the documented pitfall: a hanging dependency never trips this ordering"
        )
    }

    @Test("a timeout inside the breaker is counted as a failure")
    func timeoutInsideBreakerCountsFailures() async {
        // The documented fix — the breaker sees TimeoutError, not cancellation.
        let breaker = CircuitBreaker(failureThreshold: 2, timeout: .seconds(30))

        for _ in 0..<5 {
            _ = try? await PolicyChain
                .circuitBreaker(breaker)
                .timeout(.milliseconds(20))
                .execute { try await Task.sleep(for: .seconds(10)) }
        }

        #expect(StateKind(await breaker.state) == .open)
    }

    // MARK: - README: an open breaker does not cut the retry loop short

    @Test("an open breaker inside a retry still consumes every attempt")
    func openBreakerDoesNotEndRetryLoop() async {
        // README §Choosing an order — "it does *not* cut the loop short".
        let breaker = CircuitBreaker(failureThreshold: 1, timeout: .seconds(30))
        try? await breaker.execute { throw TransientError() }

        let rejections = OSAllocatedUnfairLock(initialState: 0)
        let policy = RetryPolicy(maxAttempts: 3, delay: .immediate, onEvent: { event in
            if case .attemptFailed(_, let error, _) = event, error is CircuitBreakerError {
                rejections.withLock { $0 += 1 }
            }
        })

        await #expect(throws: CircuitBreakerError.self) {
            try await PolicyChain.retry(policy).circuitBreaker(breaker).execute { 1 }
        }

        #expect(rejections.withLock { $0 } == 3, "all three attempts run and are rejected")
    }

    // MARK: - MigratingFromRxSwift: retry outside timeout bounds each attempt

    @Test("the translated Rx chain gives every attempt its own timeout")
    func retryOutsideTimeoutBoundsEachAttempt() async throws {
        // MigratingFromRxSwift §Side-by-Side: Composition — Rx's
        // `.timeout(…).retry(3)` becomes `.retry(…).timeout(…)`. Two hung
        // attempts each time out on their own, and the third still gets a
        // full deadline; under one shared budget it would never start.
        let attempts = OSAllocatedUnfairLock(initialState: 0)

        let result = try await PolicyChain
            .retry(attempts: 3)
            .timeout(.milliseconds(30))
            .execute {
                let attempt = attempts.withLock { count -> Int in
                    count += 1
                    return count
                }
                if attempt < 3 {
                    try await Task.sleep(for: .seconds(10))
                }
                return attempt
            }

        #expect(result == 3)
    }

    // MARK: - README: shouldRetry gives up at the first rejection

    @Test("the documented predicate stops the loop at the first breaker rejection")
    func shouldRetryVetoesBreakerRejections() async {
        let breaker = CircuitBreaker(failureThreshold: 1, timeout: .seconds(30))
        try? await breaker.execute { throw TransientError() }

        let attempts = OSAllocatedUnfairLock(initialState: 0)
        let policy = RetryPolicy(maxAttempts: 3, delay: .immediate, onEvent: { event in
            if case .attemptStarted = event { attempts.withLock { $0 += 1 } }
        })

        await #expect(throws: CircuitBreakerError.self) {
            try await PolicyChain
                .retry(policy, shouldRetry: { error, _ in !(error is CircuitBreakerError) })
                .circuitBreaker(breaker)
                .execute { 1 }
        }

        #expect(attempts.withLock { $0 } == 1)
    }

    // MARK: - CircuitBreaker: successThreshold is not strictly consecutive

    @Test("a cancelled probe frees its slot without clearing the success tally")
    func halfOpenSuccessesSurviveACancelledProbe() async throws {
        // CircuitBreaker's `successThreshold` doc: the successes that close the
        // circuit need not be back-to-back.
        let clock = TestClock()
        let breaker = CircuitBreaker(
            failureThreshold: 1,
            successThreshold: 2,
            timeout: .seconds(30),
            now: { clock.now }
        )

        try? await breaker.execute { throw TransientError() }
        clock.advance(by: .seconds(31))

        // Probe 1 succeeds — one success banked, circuit stays half-open.
        _ = try await breaker.execute { 1 }
        #expect(StateKind(await breaker.state) == .halfOpen)

        // Probe 2 is cancelled — slot freed, tally untouched, no transition.
        await #expect(throws: CancellationError.self) {
            try await breaker.execute { throw CancellationError() }
        }
        #expect(StateKind(await breaker.state) == .halfOpen)

        // Probe 3 succeeds and reaches successThreshold despite the gap.
        _ = try await breaker.execute { 2 }
        #expect(StateKind(await breaker.state) == .closed)
    }

    // MARK: - README: URLSession retry filtering

    @Test("the documented transient-error allowlist is what retrying: uses")
    func transientAllowlistMatchesDocs() async {
        // README §URLSession integration lists exactly these codes.
        let documented: [URLError.Code] = [
            .networkConnectionLost, .timedOut, .cannotConnectToHost,
            .notConnectedToInternet, .dnsLookupFailed, .cannotFindHost,
        ]
        for code in documented {
            #expect(
                URLSession.isRetryable(URLError(code)),
                "\(code) is documented as retryable"
            )
        }

        // Documented as *not* retried.
        #expect(!URLSession.isRetryable(URLError(.badURL)))
        #expect(!URLSession.isRetryable(URLError(.unsupportedURL)))
        #expect(!URLSession.isRetryable(URLError(.cancelled)))

        // 5xx is retried; 4xx never reaches the predicate as a ServerError.
        #expect(URLSession.isRetryable(ServerError(statusCode: 503)))
        #expect(!URLSession.isRetryable(ValidationError()))
    }
}
