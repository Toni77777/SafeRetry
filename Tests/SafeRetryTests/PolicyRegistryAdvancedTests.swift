// PolicyRegistryAdvancedTests.swift
// SafeRetry — A composable resilience library for Swift.

import Testing
@testable import SafeRetry

// MARK: - PolicyRegistryAdvancedTests

@Suite("PolicyRegistry — Advanced")
struct PolicyRegistryAdvancedTests {

    private func makeRegistry() -> PolicyRegistry { PolicyRegistry() }

    // MARK: - Empty state

    @Test("empty registry has no registered names")
    func emptyRegistryHasNoNames() async {
        let registry = makeRegistry()
        let names = await registry.registeredNames
        #expect(names.isEmpty)
    }

    // MARK: - Mixed types

    @Test("registry stores different types under different names")
    func mixedTypes() async throws {
        let registry = makeRegistry()

        await registry.register("chain", chain: PolicyChain.timeout(.seconds(1)))
        await registry.register("breaker", circuitBreaker: CircuitBreaker(failureThreshold: 3))
        await registry.register("retry", retryPolicy: RetryPolicy(maxAttempts: 2))

        let names = Set(await registry.registeredNames)
        #expect(names == ["chain", "breaker", "retry"])

        // Each retrieves correctly.
        _ = try await registry.chain(for: "chain")
        _ = try await registry.circuitBreaker(for: "breaker")
        _ = try await registry.retryPolicy(for: "retry")
    }

    // MARK: - Overwrite

    @Test("registering the same name overwrites the previous entry")
    func overwrite() async throws {
        let registry = makeRegistry()

        await registry.register("key", chain: PolicyChain.timeout(.seconds(1)))
        await registry.register("key", circuitBreaker: CircuitBreaker(failureThreshold: 5))

        // Now "key" holds a CircuitBreaker, not a PolicyChain.
        do {
            _ = try await registry.chain(for: "key")
            Issue.record("Expected RegistryError.typeMismatch")
        } catch is RegistryError {
            // Expected.
        }

        // CircuitBreaker retrieval works.
        _ = try await registry.circuitBreaker(for: "key")
    }

    // MARK: - Unregister non-existent

    @Test("unregistering a non-existent name does not error")
    func unregisterNonExistent() async {
        let registry = makeRegistry()
        await registry.unregister("ghost")
        // No error thrown — this is a no-op.
        let names = await registry.registeredNames
        #expect(names.isEmpty)
    }

    // MARK: - typeMismatch for RetryPolicy

    @Test("typeMismatch thrown when retrieving RetryPolicy as CircuitBreaker")
    func typeMismatchRetryAsBreaker() async {
        let registry = makeRegistry()
        await registry.register("r", retryPolicy: RetryPolicy(maxAttempts: 1))

        do {
            _ = try await registry.circuitBreaker(for: "r")
            Issue.record("Expected RegistryError.typeMismatch")
        } catch let error as RegistryError {
            guard case .typeMismatch(let name, let expected, _) = error else {
                Issue.record("Expected .typeMismatch, got \(error)")
                return
            }
            #expect(name == "r")
            #expect(expected == "CircuitBreaker")
        } catch {
            Issue.record("Expected RegistryError, got \(error)")
        }
    }
}
