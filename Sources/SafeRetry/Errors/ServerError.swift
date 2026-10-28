// ServerError.swift
// SafeRetry — A composable resilience library for Swift.

// MARK: - ServerError

/// Error thrown when an HTTP response has a 5xx status code.
///
/// ``ServerError`` is treated as retryable by the resilient
/// `URLSession` extensions.
///
/// > Note: The error carries only the status code. When the `URLSession`
/// > extensions map a 5xx response to a ``ServerError``, the response body and
/// > headers — including `Retry-After` — are not preserved, so a server's own
/// > guidance on when to retry cannot be honoured. Call `URLSession` directly
/// > and drive a ``RetryPolicy`` yourself if you need them.
public struct ServerError: Error, Sendable, Equatable, CustomStringConvertible {

    /// The HTTP status code (500–599).
    public let statusCode: Int

    /// Creates a server error for the given HTTP status code.
    ///
    /// Exposed so callers can construct the error in their own `shouldRetry`
    /// predicates, request mocks, and tests. The value is not validated — the
    /// `URLSession` extensions only produce codes of 500 and above.
    ///
    /// - Parameter statusCode: The HTTP status code the server returned.
    public init(statusCode: Int) {
        self.statusCode = statusCode
    }

    /// A human-readable description including the status code.
    public var description: String {
        "Server returned HTTP \(statusCode)"
    }
}
