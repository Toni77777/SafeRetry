// PolicyRegistry.swift
// SafeRetry — A composable resilience library for Swift.

// MARK: - PolicyRegistry

/// A central, actor-isolated registry for named resilience policies.
///
/// Register policies once (typically at app launch) and retrieve them
/// anywhere by name.
///
/// Chains, circuit breakers, and retry policies share one namespace.
/// Registering under a name already in use replaces the previous entry,
/// whatever its kind; looking it up with the old kind's accessor then throws
/// ``RegistryError/typeMismatch(name:expected:found:)``.
///
/// ```swift
/// await PolicyRegistry.shared.register("payments", chain:
///     PolicyChain
///         .retry(attempts: 3, delay: .exponential(base: .seconds(1)))
///         .timeout(.seconds(10))
/// )
///
/// let result = try await PolicyRegistry.shared
///     .chain(for: "payments")
///     .execute { try await api.charge(amount: total) }
/// ```
public actor PolicyRegistry {

    // MARK: - Shared Instance

    /// The process-wide shared registry.
    public static let shared = PolicyRegistry()

    // MARK: - Storage

    private var entries: [String: any Sendable] = [:]

    // MARK: - Initialisation

    /// Creates an empty policy registry.
    public init() {}

    // MARK: - Register

    /// Registers a ``PolicyChain`` under the given name.
    ///
    /// - Parameters:
    ///   - name: A unique key for this policy.
    ///   - chain: The policy chain to store.
    public func register(_ name: String, chain: PolicyChain) {
        entries[name] = chain
    }

    /// Registers a ``CircuitBreaker`` under the given name.
    ///
    /// - Parameters:
    ///   - name: A unique key for this policy.
    ///   - circuitBreaker: The circuit breaker to store.
    public func register(_ name: String, circuitBreaker: CircuitBreaker) {
        entries[name] = circuitBreaker
    }

    /// Registers a ``RetryPolicy`` under the given name.
    ///
    /// - Parameters:
    ///   - name: A unique key for this policy.
    ///   - retryPolicy: The retry policy to store.
    public func register(_ name: String, retryPolicy: RetryPolicy) {
        entries[name] = retryPolicy
    }

    // MARK: - Retrieve

    /// Returns the ``PolicyChain`` registered under the given name.
    ///
    /// - Parameter name: The key used during registration.
    /// - Throws: ``RegistryError/notFound(name:)`` if no entry exists, or
    ///   ``RegistryError/typeMismatch(name:expected:found:)`` if the stored
    ///   value is not a ``PolicyChain``.
    public func chain(for name: String) throws -> PolicyChain {
        try resolve(name)
    }

    /// Returns the ``CircuitBreaker`` registered under the given name.
    ///
    /// - Parameter name: The key used during registration.
    /// - Throws: ``RegistryError/notFound(name:)`` if no entry exists, or
    ///   ``RegistryError/typeMismatch(name:expected:found:)`` if the stored
    ///   value is not a ``CircuitBreaker``.
    public func circuitBreaker(for name: String) throws -> CircuitBreaker {
        try resolve(name)
    }

    /// Returns the ``RetryPolicy`` registered under the given name.
    ///
    /// - Parameter name: The key used during registration.
    /// - Throws: ``RegistryError/notFound(name:)`` if no entry exists, or
    ///   ``RegistryError/typeMismatch(name:expected:found:)`` if the stored
    ///   value is not a ``RetryPolicy``.
    public func retryPolicy(for name: String) throws -> RetryPolicy {
        try resolve(name)
    }

    // MARK: - Remove

    /// Removes the policy registered under the given name, if any.
    ///
    /// - Parameter name: The key to remove.
    public func unregister(_ name: String) {
        entries.removeValue(forKey: name)
    }

    /// Removes all registered policies.
    public func unregisterAll() {
        entries.removeAll()
    }

    // MARK: - Inspection

    /// The names of all currently registered policies, in no particular order.
    ///
    /// Backed by a dictionary, so the order varies between calls and between
    /// runs. Sort the result if you need a stable sequence.
    public var registeredNames: [String] {
        Array(entries.keys)
    }

    // MARK: - Private

    private func resolve<T: Sendable>(_ name: String) throws -> T {
        guard let value = entries[name] else {
            throw RegistryError.notFound(name: name)
        }
        guard let typed = value as? T else {
            throw RegistryError.typeMismatch(
                name: name,
                expected: String(describing: T.self),
                found: String(describing: type(of: value))
            )
        }
        return typed
    }
}
