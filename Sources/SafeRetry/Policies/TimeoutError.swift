// TimeoutError.swift
// SafeRetry — A composable resilience library for Swift.

// MARK: - TimeoutError

/// Error thrown when an operation exceeds its allowed duration.
public struct TimeoutError: Error, Sendable, Equatable, CustomStringConvertible {

    /// The timeout threshold that was exceeded.
    public let duration: Duration

    /// Creates a timeout error for the given threshold.
    ///
    /// Exposed so callers can construct the error in their own timeout
    /// wrappers, request mocks, and tests.
    ///
    /// - Parameter duration: The timeout threshold that was exceeded.
    public init(duration: Duration) {
        self.duration = duration
    }

    /// A human-readable description including the timeout threshold.
    public var description: String {
        "Operation timed out after \(duration)"
    }
}
