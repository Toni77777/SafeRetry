// FallbackPolicy.swift
// SafeRetry — A composable resilience library for Swift.

// MARK: - FallbackPolicy

/// Provides a substitute value when an operation fails.
///
/// On error the policy either returns a fixed fallback value or invokes
/// a handler closure that receives the original error and can produce
/// an alternative result (or rethrow).
///
/// ```swift
/// let policy = FallbackPolicy(value: CachedUser.default)
/// let user = try await policy.execute {
///     try await api.fetchUser()
/// }
/// ```
public struct FallbackPolicy<T: Sendable>: Sendable {

    // MARK: - Properties

    private let handler: @Sendable (any Error) async throws -> T

    /// Optional callback invoked when the fallback is used.
    private let onEvent: (@Sendable (PolicyEvent) -> Void)?

    // MARK: - Initialisation

    /// Creates a fallback policy that returns a constant value on error.
    ///
    /// - Parameters:
    ///   - value: The value to return when the operation fails.
    ///   - onEvent: Optional synchronous callback invoked on policy events.
    ///     Runs inline with execution, so it must not block. Spawn a `Task`
    ///     inside the closure if async work is required.
    public init(
        value: T,
        onEvent: (@Sendable (PolicyEvent) -> Void)? = nil
    ) {
        self.handler = { _ in value }
        self.onEvent = onEvent
    }

    /// Creates a fallback policy with a handler closure.
    ///
    /// The handler receives the original error and can return an alternative
    /// result or throw a different error.
    ///
    /// - Parameters:
    ///   - handler: A closure that receives the operation's error
    ///     and returns a fallback value, or throws.
    ///   - onEvent: Optional synchronous callback invoked on policy events.
    ///     Runs inline with execution, so it must not block. Spawn a `Task`
    ///     inside the closure if async work is required.
    public init(
        handler: @escaping @Sendable (any Error) async throws -> T,
        onEvent: (@Sendable (PolicyEvent) -> Void)? = nil
    ) {
        self.handler = handler
        self.onEvent = onEvent
    }

    // MARK: - Execute

    /// Executes `operation`, falling back to the configured handler on error.
    ///
    /// - Parameter operation: The primary async throwing closure.
    /// - Returns: The operation's result on success, or the fallback on failure.
    /// - Throws: The cancellation error if the task is cancelled — both
    ///   `CancellationError` and `URLError(.cancelled)` propagate rather than
    ///   producing a fallback value, and an already-cancelled task throws
    ///   `CancellationError` without running `operation` — or the handler's
    ///   error if the handler itself throws.
    public func execute(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()

        do {
            return try await operation()
        } catch where isCancellation(error) {
            throw error
        } catch {
            emitEvent(.fallbackUsed)
            return try await handler(error)
        }
    }

    // MARK: - Event Emission

    private func emitEvent(_ event: PolicyEvent) {
        onEvent?(event)
    }
}
