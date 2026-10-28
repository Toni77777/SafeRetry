// Errors+LocalizedError.swift
// SafeRetry — A composable resilience library for Swift.

import Foundation

// MARK: - LocalizedError Conformances

// Every error in this library already renders itself through
// `CustomStringConvertible`, but that is not the property most callers reach
// for. `error.localizedDescription` is what lands in log lines, analytics
// payloads, and `catch { print(error.localizedDescription) }`. For a Swift
// error that conforms to neither `LocalizedError` nor `CustomNSError`,
// Foundation synthesises a placeholder — "The operation couldn’t be completed.
// (SafeRetry.ServerError error 1.)" — which discards the status code, the
// timeout duration, and the registry key.
//
// Conforming to `LocalizedError` and routing `errorDescription` to
// `description` makes both spellings agree.

extension ServerError: LocalizedError {

    /// The human-readable description of this error, matching `description`.
    public var errorDescription: String? { description }
}

extension TimeoutError: LocalizedError {

    /// The human-readable description of this error, matching `description`.
    public var errorDescription: String? { description }
}

extension CircuitBreakerError: LocalizedError {

    /// The human-readable description of this error, matching `description`.
    public var errorDescription: String? { description }
}

extension RegistryError: LocalizedError {

    /// The human-readable description of this error, matching `description`.
    public var errorDescription: String? { description }
}
