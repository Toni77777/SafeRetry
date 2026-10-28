// FallbackChain.swift
// SafeRetry — A composable resilience library for Swift.

// MARK: - FallbackChain

/// A policy chain terminated with a fallback.
///
/// `execute(_:)` converts non-cancellation failures into fallback values, but
/// still propagates `CancellationError`.
///
/// Created via `PolicyChain.fallback(_:onEvent:)` (constant value) or
/// `PolicyChain.fallback(onEvent:_:)` (handler).
public struct FallbackChain<T: Sendable>: Sendable {

    // MARK: - Properties

    private let chain: PolicyChain
    private let onEvent: (@Sendable (PolicyEvent) -> Void)?
    private let handler: @Sendable (any Error) async throws -> T

    // MARK: - Initialisation

    internal init(
        chain: PolicyChain,
        onEvent: (@Sendable (PolicyEvent) -> Void)? = nil,
        handler: @escaping @Sendable (any Error) async throws -> T
    ) {
        self.chain = chain
        self.onEvent = onEvent
        self.handler = handler
    }

    // MARK: - Execute

    /// Runs the operation through the chain, returning the fallback on non-cancellation failure.
    ///
    /// - Parameter operation: The async throwing closure to execute.
    /// - Returns: The operation's result on success, or the fallback value on non-cancellation failure.
    /// - Throws: The cancellation error if the task is cancelled — both
    ///   `CancellationError` and `URLError(.cancelled)` propagate rather than
    ///   producing a fallback value — or an error thrown by the handler.
    public func execute(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        do {
            return try await chain.execute(operation)
        } catch where isCancellation(error) {
            throw error
        } catch {
            onEvent?(.fallbackUsed)
            return try await handler(error)
        }
    }
}
