// Cancellation.swift
// SafeRetry — A composable resilience library for Swift.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Cancellation Detection

/// Whether `error` represents cooperative task cancellation rather than a
/// genuine failure.
///
/// Swift's own cancellation spelling is `CancellationError`, but
/// `URLSession` reports a cancelled task as `URLError(.cancelled)` — and the
/// `URLSession` extensions are this library's primary integration point. Every
/// policy that treats cancellation specially (``RetryPolicy`` not burning an
/// attempt, ``CircuitBreaker`` not counting a dependency failure,
/// ``FallbackPolicy`` not substituting a value) has to recognise both, or
/// cancelling a screen's in-flight requests quietly corrupts the policy's view
/// of the world.
///
/// - Parameter error: The error to classify.
/// - Returns: `true` for `CancellationError` and `URLError(.cancelled)`.
internal func isCancellation(_ error: any Error) -> Bool {
    if error is CancellationError {
        return true
    }
    if let urlError = error as? URLError, urlError.code == .cancelled {
        return true
    }
    return false
}
