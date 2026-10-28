// FallbackPolicyTests.swift
// SafeRetry — A composable resilience library for Swift.

import Testing
@testable import SafeRetry

// MARK: - Test Helpers

private struct OperationError: Error, Sendable {
    let code: Int
    init(_ code: Int = 1) { self.code = code }
}

private struct HandlerError: Error, Equatable {}

// MARK: - FallbackPolicyTests

@Suite("FallbackPolicy")
struct FallbackPolicyTests {

    // MARK: - Value Fallback

    @Test("value fallback returns operation result on success")
    func valueFallbackPassesThrough() async throws {
        let policy = FallbackPolicy(value: "default")
        let result = try await policy.execute { "success" }
        #expect(result == "success")
    }

    @Test("value fallback returns value on error")
    func valueFallbackOnError() async throws {
        let policy = FallbackPolicy(value: "default")
        let result = try await policy.execute { throw OperationError() }
        #expect(result == "default")
    }

    // MARK: - Handler Fallback

    @Test("handler fallback receives the original error")
    func handlerReceivesOriginalError() async throws {
        let policy = FallbackPolicy<String> { error in
            guard let opError = error as? OperationError else {
                return "wrong-error"
            }
            return "recovered-\(opError.code)"
        }

        let result = try await policy.execute { throw OperationError(42) }
        #expect(result == "recovered-42")
    }

    @Test("handler fallback that also throws propagates handler's error")
    func handlerErrorPropagated() async {
        let policy = FallbackPolicy<String> { _ in
            throw HandlerError()
        }

        do {
            _ = try await policy.execute { throw OperationError() }
            Issue.record("Expected HandlerError")
        } catch is HandlerError {
            // Expected — handler's error, not the original OperationError.
        } catch {
            Issue.record("Expected HandlerError, got \(error)")
        }
    }

    @Test("cancellation propagates and does not trigger fallback")
    func cancellationPropagates() async {
        let policy = FallbackPolicy(value: "default")

        let task = Task {
            try await policy.execute {
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
}
