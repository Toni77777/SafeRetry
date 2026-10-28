// PolicyRegistryTests.swift
// SafeRetry — A composable resilience library for Swift.

import Testing
@testable import SafeRetry

// MARK: - PolicyRegistryTests

@Suite("PolicyRegistry")
struct PolicyRegistryTests {

    // Fresh registry for each test — avoids cross-test pollution via `shared`.
    private func makeRegistry() -> PolicyRegistry { PolicyRegistry() }

    // MARK: - Register & Retrieve PolicyChain

    @Test("register and retrieve a PolicyChain by name")
    func registerAndRetrieveChain() async throws {
        let registry = makeRegistry()
        let chain = PolicyChain.timeout(.seconds(5))

        await registry.register("api", chain: chain)
        let retrieved = try await registry.chain(for: "api")
        let result = try await retrieved.execute { 42 }
        #expect(result == 42)
    }

    // MARK: - Register & Retrieve CircuitBreaker

    @Test("register and retrieve a CircuitBreaker by name")
    func registerAndRetrieveCircuitBreaker() async throws {
        let registry = makeRegistry()
        let breaker = CircuitBreaker(failureThreshold: 5)

        await registry.register("payments", circuitBreaker: breaker)
        let retrieved = try await registry.circuitBreaker(for: "payments")
        let result = try await retrieved.execute { "ok" }
        #expect(result == "ok")
    }

    // MARK: - Register & Retrieve RetryPolicy

    @Test("register and retrieve a RetryPolicy by name")
    func registerAndRetrieveRetryPolicy() async throws {
        let registry = makeRegistry()
        let policy = RetryPolicy(maxAttempts: 2)

        await registry.register("fetch", retryPolicy: policy)
        let retrieved = try await registry.retryPolicy(for: "fetch")
        let result = try await retrieved.execute { 99 }
        #expect(result == 99)
    }

    // MARK: - Not Found

    @Test("throws notFound for unknown name")
    func notFoundError() async {
        let registry = makeRegistry()

        do {
            _ = try await registry.chain(for: "nonexistent")
            Issue.record("Expected RegistryError.notFound")
        } catch let error as RegistryError {
            #expect(error == .notFound(name: "nonexistent"))
        } catch {
            Issue.record("Expected RegistryError, got \(error)")
        }
    }

    // MARK: - Type Mismatch

    @Test("throws typeMismatch when retrieving wrong type")
    func typeMismatchError() async {
        let registry = makeRegistry()
        let breaker = CircuitBreaker(failureThreshold: 3)

        await registry.register("breaker", circuitBreaker: breaker)

        do {
            _ = try await registry.chain(for: "breaker")
            Issue.record("Expected RegistryError.typeMismatch")
        } catch let error as RegistryError {
            guard case .typeMismatch(let name, let expected, _) = error else {
                Issue.record("Expected .typeMismatch, got \(error)")
                return
            }
            #expect(name == "breaker")
            #expect(expected == "PolicyChain")
        } catch {
            Issue.record("Expected RegistryError, got \(error)")
        }
    }

    // MARK: - Unregister

    @Test("unregister removes the entry")
    func unregisterRemovesEntry() async {
        let registry = makeRegistry()
        let chain = PolicyChain.timeout(.seconds(1))

        await registry.register("temp", chain: chain)
        await registry.unregister("temp")

        do {
            _ = try await registry.chain(for: "temp")
            Issue.record("Expected RegistryError.notFound")
        } catch let error as RegistryError {
            #expect(error == .notFound(name: "temp"))
        } catch {
            Issue.record("Expected RegistryError, got \(error)")
        }
    }

    // MARK: - Unregister All

    @Test("unregisterAll clears every entry")
    func unregisterAllClearsEntries() async {
        let registry = makeRegistry()

        await registry.register("a", chain: PolicyChain.timeout(.seconds(1)))
        await registry.register("b", circuitBreaker: CircuitBreaker(failureThreshold: 3))

        await registry.unregisterAll()

        let names = await registry.registeredNames
        #expect(names.isEmpty)
    }

    // MARK: - Registered Names

    @Test("registeredNames returns all stored keys")
    func registeredNamesReturnsKeys() async {
        let registry = makeRegistry()

        await registry.register("x", chain: PolicyChain.timeout(.seconds(1)))
        await registry.register("y", circuitBreaker: CircuitBreaker(failureThreshold: 2))

        let names = await registry.registeredNames
        #expect(Set(names) == ["x", "y"])
    }

    // MARK: - Concurrent Registration

    @Test("concurrent registrations are safe")
    func concurrentRegistrationsAreSafe() async {
        let registry = makeRegistry()

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    let chain = PolicyChain.timeout(.seconds(1))
                    await registry.register("chain-\(i)", chain: chain)
                }
            }
        }

        let names = await registry.registeredNames
        #expect(names.count == 100)
    }

    // MARK: - Shared Instance

    @Test("shared instance is the same across calls")
    func sharedInstanceIdentity() {
        let a = PolicyRegistry.shared
        let b = PolicyRegistry.shared
        #expect(a === b)
    }

    // MARK: - SafeRetry.registry Convenience

    @Test("SafeRetry.registry returns the shared instance")
    func resilienceRegistryConvenience() {
        let fromNamespace = SafeRetry.registry
        let fromShared = PolicyRegistry.shared
        #expect(fromNamespace === fromShared)
    }
}
