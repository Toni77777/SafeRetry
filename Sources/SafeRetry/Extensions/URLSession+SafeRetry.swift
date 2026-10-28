// URLSession+SafeRetry.swift
// SafeRetry — A composable resilience library for Swift.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - URLSession + SafeRetry

extension URLSession {

    /// Fetches data for a request, retrying transient failures automatically.
    ///
    /// The method retries only on errors that are likely transient — infrastructure-level
    /// failures where the same request has a real chance of succeeding moments later:
    /// - `URLError.networkConnectionLost`
    /// - `URLError.timedOut`
    /// - `URLError.cannotConnectToHost`
    /// - `URLError.notConnectedToInternet`
    /// - `URLError.dnsLookupFailed`
    /// - `URLError.cannotFindHost`
    /// - HTTP 5xx responses (mapped to ``ServerError``)
    ///
    /// Errors that indicate a problem with the request itself (bad URL, unsupported
    /// scheme, cancelled, etc.) or with the response body are **not** retried, since
    /// retrying would just reproduce the same failure.
    ///
    /// HTTP 4xx responses are **not** retried and return normally so the
    /// caller can inspect the status code.
    ///
    /// ```swift
    /// let policy = RetryPolicy(
    ///     maxAttempts: 3,
    ///     delay: .exponential(base: .seconds(1))
    /// )
    /// let (data, response) = try await URLSession.shared.data(
    ///     for: request,
    ///     retrying: policy
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - request: The URL request to perform.
    ///   - policy: The ``RetryPolicy`` that controls retry attempts and backoff.
    /// - Returns: A tuple containing the response body and the URL response.
    /// - Throws: The last retryable ``ServerError``/`URLError`, a non-retryable
    ///   error from the underlying call, or the cancellation error if the task
    ///   is cancelled — `CancellationError`, or `URLError(.cancelled)` when
    ///   `URLSession` itself observes the cancellation.
    public func data(
        for request: URLRequest,
        retrying policy: RetryPolicy
    ) async throws -> (Data, URLResponse) {
        try await policy.execute(shouldRetry: { error, _ in
            Self.isRetryable(error)
        }) {
            try await self.resilientData(for: request)
        }
    }

    /// Fetches data for a request, applying a full resilience ``PolicyChain``.
    ///
    /// The chain may include retry, circuit breaker, timeout, and fallback
    /// policies. HTTP 5xx responses are mapped to ``ServerError`` so that
    /// retry policies can intercept them.
    ///
    /// ```swift
    /// let chain = PolicyChain.Preset.default
    /// let (data, response) = try await URLSession.shared.data(
    ///     for: request,
    ///     resilience: chain
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - request: The URL request to perform.
    ///   - chain: The ``PolicyChain`` to apply around the network call.
    /// - Returns: A tuple containing the response body and the URL response.
    /// - Throws: Any error that escapes the chain (e.g. ``ServerError``,
    ///   `URLError`, ``TimeoutError``, ``CircuitBreakerError``).
    public func data(
        for request: URLRequest,
        resilience chain: PolicyChain
    ) async throws -> (Data, URLResponse) {
        try await chain.execute {
            try await self.resilientData(for: request)
        }
    }

    // MARK: - Private

    /// Performs the request and maps 5xx responses to ``ServerError``.
    ///
    /// 4xx responses pass through normally so callers can handle them.
    private func resilientData(
        for request: URLRequest
    ) async throws -> (Data, URLResponse) {
        let (data, response) = try await self.data(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode >= 500 {
            throw ServerError(statusCode: http.statusCode)
        }

        return (data, response)
    }

    /// Whether SafeRetry treats `error` as transient and therefore worth
    /// retrying. `internal` rather than `private` so the allowlist the
    /// documentation promises can be asserted directly in tests.
    internal static func isRetryable(_ error: any Error) -> Bool {
        if error is ServerError {
            return true
        }
        guard let urlError = error as? URLError else {
            return false
        }
        switch urlError.code {
        case .networkConnectionLost, .timedOut, .cannotConnectToHost,
             .notConnectedToInternet, .dnsLookupFailed, .cannotFindHost:
            return true
        default:
            return false
        }
    }
}
