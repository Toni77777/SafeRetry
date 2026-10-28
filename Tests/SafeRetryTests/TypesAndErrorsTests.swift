// TypesAndErrorsTests.swift
// SafeRetry — A composable resilience library for Swift.

import Testing
@testable import SafeRetry

// MARK: - CircuitState Tests

@Suite("CircuitState")
struct CircuitStateTests {

    @Test("description for closed state")
    func closedDescription() {
        #expect(CircuitState.closed.description == "closed")
    }

    @Test("description for open state")
    func openDescription() {
        let instant = ContinuousClock().now
        #expect(CircuitState.open(until: instant).description == "open")
    }

    @Test("description for halfOpen state")
    func halfOpenDescription() {
        #expect(CircuitState.halfOpen.description == "halfOpen")
    }

    @Test("equatable: closed == closed")
    func closedEquatable() {
        #expect(CircuitState.closed == CircuitState.closed)
    }

    @Test("equatable: closed != halfOpen")
    func closedNotHalfOpen() {
        #expect(CircuitState.closed != CircuitState.halfOpen)
    }

    @Test("equatable: open states with same instant are equal")
    func openEquatable() {
        let instant = ContinuousClock().now
        #expect(CircuitState.open(until: instant) == CircuitState.open(until: instant))
    }

    @Test("equatable: open states with different instants are not equal")
    func openDifferentInstants() {
        let a = ContinuousClock().now
        let b = a.advanced(by: .seconds(100))
        #expect(CircuitState.open(until: a) != CircuitState.open(until: b))
    }
}

// MARK: - ServerError Tests

@Suite("ServerError")
struct ServerErrorTests {

    @Test("stores the status code")
    func statusCode() {
        let error = ServerError(statusCode: 503)
        #expect(error.statusCode == 503)
    }

    @Test("equatable: same codes are equal")
    func equatable() {
        #expect(ServerError(statusCode: 500) == ServerError(statusCode: 500))
    }

    @Test("equatable: different codes are not equal")
    func notEqual() {
        #expect(ServerError(statusCode: 500) != ServerError(statusCode: 502))
    }

    @Test("conforms to Error")
    func conformsToError() {
        let error: any Error = ServerError(statusCode: 500)
        #expect(error is ServerError)
    }
}

// MARK: - TimeoutError Tests

@Suite("TimeoutError")
struct TimeoutErrorTests {

    @Test("stores the exceeded duration")
    func duration() {
        let error = TimeoutError(duration: .seconds(5))
        #expect(error.duration == .seconds(5))
    }

    @Test("conforms to Error and Sendable")
    func conformsToError() {
        let error: any Error & Sendable = TimeoutError(duration: .milliseconds(100))
        #expect(error is TimeoutError)
    }
}

// MARK: - CircuitBreakerError Tests

@Suite("CircuitBreakerError")
struct CircuitBreakerErrorTests {

    @Test("open case carries retryAfter duration")
    func openCase() {
        let error = CircuitBreakerError.open(retryAfter: .seconds(25))

        if case .open(let retryAfter) = error {
            #expect(retryAfter == .seconds(25))
        } else {
            Issue.record("Expected .open case")
        }
    }

    @Test("halfOpenRejected case matches correctly")
    func halfOpenRejectedCase() {
        let error = CircuitBreakerError.halfOpenRejected
        if case .halfOpenRejected = error {
            // Expected.
        } else {
            Issue.record("Expected .halfOpenRejected")
        }
    }
}

// MARK: - RegistryError Tests

@Suite("RegistryError")
struct RegistryErrorTests {

    @Test("notFound carries the name")
    func notFoundName() {
        let error = RegistryError.notFound(name: "payments")
        #expect(error == .notFound(name: "payments"))
    }

    @Test("typeMismatch carries name, expected, and found")
    func typeMismatchProperties() {
        let error = RegistryError.typeMismatch(
            name: "api",
            expected: "PolicyChain",
            found: "CircuitBreaker"
        )

        if case .typeMismatch(let name, let expected, let found) = error {
            #expect(name == "api")
            #expect(expected == "PolicyChain")
            #expect(found == "CircuitBreaker")
        } else {
            Issue.record("Expected .typeMismatch")
        }
    }

    @Test("notFound != typeMismatch")
    func differentCasesNotEqual() {
        let a = RegistryError.notFound(name: "x")
        let b = RegistryError.typeMismatch(name: "x", expected: "A", found: "B")
        #expect(a != b)
    }
}

// MARK: - TimeoutPolicy Direct Tests

@Suite("TimeoutPolicy — Direct")
struct TimeoutPolicyDirectTests {

    @Test("duration property reflects init value")
    func durationProperty() {
        let policy = TimeoutPolicy(duration: .seconds(42))
        #expect(policy.duration == .seconds(42))
    }
}

// MARK: - FallbackPolicy Generic Tests

@Suite("FallbackPolicy — Generics")
struct FallbackPolicyGenericTests {

    @Test("works with Int type")
    func intType() async throws {
        let policy = FallbackPolicy(value: 0)
        let result = try await policy.execute { throw ServerError(statusCode: 500) }
        #expect(result == 0)
    }

    @Test("works with optional type")
    func optionalType() async throws {
        let policy = FallbackPolicy<String?>(value: nil)
        let result = try await policy.execute { throw ServerError(statusCode: 500) }
        #expect(result == nil)
    }

    @Test("works with array type")
    func arrayType() async throws {
        let policy = FallbackPolicy<[Int]>(value: [])
        let result = try await policy.execute { throw ServerError(statusCode: 500) }
        #expect(result == [])
    }

    @Test("handler init works with non-String type")
    func handlerWithIntType() async throws {
        let policy = FallbackPolicy<Int> { _ in -1 }
        let result = try await policy.execute { throw ServerError(statusCode: 500) }
        #expect(result == -1)
    }
}

// MARK: - LocalizedError Tests

@Suite("Errors — LocalizedError")
struct ErrorsLocalizedDescriptionTests {

    /// `localizedDescription` is the spelling that reaches log lines and
    /// analytics. Without a `LocalizedError` conformance Foundation would
    /// synthesise "The operation couldn’t be completed. (SafeRetry.… error 1.)"
    /// and drop every detail these errors carry.
    @Test("localizedDescription matches description", arguments: [
        (ServerError(statusCode: 503) as any Error, "Server returned HTTP 503"),
        (
            TimeoutError(duration: .seconds(5)) as any Error,
            "Operation timed out after 5.0 seconds"
        ),
        (
            CircuitBreakerError.open(retryAfter: .seconds(30)) as any Error,
            "Circuit breaker is open; retry after 30.0 seconds"
        ),
        (
            CircuitBreakerError.halfOpenRejected as any Error,
            "Circuit breaker is half-open and at capacity"
        ),
        (
            RegistryError.notFound(name: "payments") as any Error,
            "No policy registered under the name \"payments\""
        ),
        (
            RegistryError.typeMismatch(
                name: "payments",
                expected: "PolicyChain",
                found: "RetryPolicy"
            ) as any Error,
            "Policy \"payments\" has type RetryPolicy, expected PolicyChain"
        ),
    ])
    func localizedDescriptionIsUseful(error: any Error, expected: String) {
        #expect(error.localizedDescription == expected)
        #expect(error.localizedDescription == String(describing: error))
    }
}

// MARK: - CircuitBreakerError retryAfter

@Suite("CircuitBreakerError — retryAfter")
struct CircuitBreakerErrorRetryAfterTests {

    @Test("open exposes its remaining duration through retryAfter")
    func openExposesRetryAfter() {
        #expect(CircuitBreakerError.open(retryAfter: .seconds(25)).retryAfter == .seconds(25))
    }

    @Test("halfOpenRejected has no retryAfter")
    func halfOpenRejectedHasNoRetryAfter() {
        // A half-open slot frees when the in-flight probe finishes, which has
        // no deadline — so there is genuinely no duration to report here.
        #expect(CircuitBreakerError.halfOpenRejected.retryAfter == nil)
    }
}
