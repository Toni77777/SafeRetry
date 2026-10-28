// URLSessionSafeRetryTests.swift
// SafeRetry — A composable resilience library for Swift.

import Foundation
import os
import Testing
@testable import SafeRetry

// MARK: - Mock URLProtocol

/// A `URLProtocol` subclass that lets tests control HTTP responses.
///
/// Each test configures `MockURLProtocol.handler` before making a request.
/// The handler receives the request and returns a `(Data, HTTPURLResponse)`
/// or throws an error.
private final class MockURLProtocol: URLProtocol, @unchecked Sendable {

    /// Handler closure — set per-test to control the mock response.
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Data, HTTPURLResponse))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        do {
            let (data, response) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - Helpers

private func makeSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
}

private func makeRequest() -> URLRequest {
    URLRequest(url: URL(string: "https://example.com/test")!)
}

private func httpResponse(statusCode: Int) -> HTTPURLResponse {
    HTTPURLResponse(
        url: URL(string: "https://example.com/test")!,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: nil
    )!
}

// MARK: - URLSessionResilientTests

@Suite("URLSession+SafeRetry", .serialized)
struct URLSessionResilientTests {

    // MARK: - Retry on Network Error

    @Test("retries on transient network error and succeeds")
    func retryOnNetworkError() async throws {
        let session = makeSession()
        let callCount = OSAllocatedUnfairLock(initialState: 0)

        MockURLProtocol.handler = { _ in
            let count = callCount.withLock { c -> Int in
                c += 1
                return c
            }
            if count < 3 {
                throw URLError(.networkConnectionLost)
            }
            return (Data("ok".utf8), httpResponse(statusCode: 200))
        }

        let policy = RetryPolicy(maxAttempts: 3, delay: .immediate)
        let (data, response) = try await session.data(for: makeRequest(), retrying: policy)

        #expect(String(data: data, encoding: .utf8) == "ok")
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(callCount.withLock { $0 } == 3)
    }

    // MARK: - No Retry on 404

    @Test("does not retry on 404 client error")
    func noRetryOn404() async throws {
        let session = makeSession()
        let callCount = OSAllocatedUnfairLock(initialState: 0)

        MockURLProtocol.handler = { _ in
            callCount.withLock { $0 += 1 }
            return (Data(), httpResponse(statusCode: 404))
        }

        // 404 is not a ServerError, so the request returns normally.
        let policy = RetryPolicy(maxAttempts: 3, delay: .immediate)
        let (_, response) = try await session.data(for: makeRequest(), retrying: policy)

        #expect((response as? HTTPURLResponse)?.statusCode == 404)
        #expect(callCount.withLock { $0 } == 1)
    }

    @Test("does not retry on non-transient URL error")
    func noRetryOnNonTransientURLError() async {
        let session = makeSession()
        let callCount = OSAllocatedUnfairLock(initialState: 0)

        MockURLProtocol.handler = { _ in
            callCount.withLock { $0 += 1 }
            throw URLError(.badURL)
        }

        let policy = RetryPolicy(maxAttempts: 3, delay: .immediate)

        do {
            _ = try await session.data(for: makeRequest(), retrying: policy)
            Issue.record("Expected URLError.badURL")
        } catch let error as URLError {
            #expect(error.code == .badURL)
        } catch {
            Issue.record("Expected URLError.badURL, got \(error)")
        }

        #expect(callCount.withLock { $0 } == 1)
    }

    // MARK: - Retry on cannotConnectToHost

    @Test("retries on cannotConnectToHost and succeeds")
    func retryOnCannotConnectToHost() async throws {
        let session = makeSession()
        let callCount = OSAllocatedUnfairLock(initialState: 0)

        MockURLProtocol.handler = { _ in
            let count = callCount.withLock { c -> Int in
                c += 1
                return c
            }
            if count < 2 {
                throw URLError(.cannotConnectToHost)
            }
            return (Data("connected".utf8), httpResponse(statusCode: 200))
        }

        let policy = RetryPolicy(maxAttempts: 3, delay: .immediate)
        let (data, _) = try await session.data(for: makeRequest(), retrying: policy)

        #expect(String(data: data, encoding: .utf8) == "connected")
        #expect(callCount.withLock { $0 } == 2)
    }

    // MARK: - Retry on notConnectedToInternet / dnsLookupFailed

    @Test("retries on notConnectedToInternet and succeeds")
    func retryOnNotConnectedToInternet() async throws {
        let session = makeSession()
        let callCount = OSAllocatedUnfairLock(initialState: 0)

        MockURLProtocol.handler = { _ in
            let count = callCount.withLock { c -> Int in
                c += 1
                return c
            }
            if count < 2 {
                throw URLError(.notConnectedToInternet)
            }
            return (Data("back online".utf8), httpResponse(statusCode: 200))
        }

        let policy = RetryPolicy(maxAttempts: 3, delay: .immediate)
        let (data, _) = try await session.data(for: makeRequest(), retrying: policy)

        #expect(String(data: data, encoding: .utf8) == "back online")
        #expect(callCount.withLock { $0 } == 2)
    }

    @Test("retries on dnsLookupFailed and succeeds")
    func retryOnDNSLookupFailed() async throws {
        let session = makeSession()
        let callCount = OSAllocatedUnfairLock(initialState: 0)

        MockURLProtocol.handler = { _ in
            let count = callCount.withLock { c -> Int in
                c += 1
                return c
            }
            if count < 2 {
                throw URLError(.dnsLookupFailed)
            }
            return (Data("resolved".utf8), httpResponse(statusCode: 200))
        }

        let policy = RetryPolicy(maxAttempts: 3, delay: .immediate)
        let (data, _) = try await session.data(for: makeRequest(), retrying: policy)

        #expect(String(data: data, encoding: .utf8) == "resolved")
        #expect(callCount.withLock { $0 } == 2)
    }

    @Test("retries on cannotFindHost and succeeds")
    func retryOnCannotFindHost() async throws {
        let session = makeSession()
        let callCount = OSAllocatedUnfairLock(initialState: 0)

        MockURLProtocol.handler = { _ in
            let count = callCount.withLock { c -> Int in
                c += 1
                return c
            }
            if count < 2 {
                throw URLError(.cannotFindHost)
            }
            return (Data("found".utf8), httpResponse(statusCode: 200))
        }

        let policy = RetryPolicy(maxAttempts: 3, delay: .immediate)
        let (data, _) = try await session.data(for: makeRequest(), retrying: policy)

        #expect(String(data: data, encoding: .utf8) == "found")
        #expect(callCount.withLock { $0 } == 2)
    }

    // MARK: - Retry on 503

    @Test("retries on 503 with ServerError and eventually succeeds")
    func retryOn503() async throws {
        let session = makeSession()
        let callCount = OSAllocatedUnfairLock(initialState: 0)

        MockURLProtocol.handler = { _ in
            let count = callCount.withLock { c -> Int in
                c += 1
                return c
            }
            if count < 2 {
                return (Data(), httpResponse(statusCode: 503))
            }
            return (Data("recovered".utf8), httpResponse(statusCode: 200))
        }

        let policy = RetryPolicy(maxAttempts: 3, delay: .immediate)
        let (data, response) = try await session.data(for: makeRequest(), retrying: policy)

        #expect(String(data: data, encoding: .utf8) == "recovered")
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(callCount.withLock { $0 } == 2)
    }

    // MARK: - ServerError Propagation

    @Test("throws ServerError when all retries exhaust on 500")
    func serverErrorAfterExhaustion() async {
        let session = makeSession()

        MockURLProtocol.handler = { _ in
            (Data(), httpResponse(statusCode: 500))
        }

        let policy = RetryPolicy(maxAttempts: 2, delay: .immediate)

        do {
            _ = try await session.data(for: makeRequest(), retrying: policy)
            Issue.record("Expected ServerError")
        } catch let error as ServerError {
            #expect(error.statusCode == 500)
        } catch {
            Issue.record("Expected ServerError, got \(error)")
        }
    }

    // MARK: - PolicyChain Integration

    @Test("resilience chain applies policies to URL request")
    func resilienceChainWorks() async throws {
        let session = makeSession()
        let callCount = OSAllocatedUnfairLock(initialState: 0)

        MockURLProtocol.handler = { _ in
            let count = callCount.withLock { c -> Int in
                c += 1
                return c
            }
            if count < 2 {
                throw URLError(.timedOut)
            }
            return (Data("chain-ok".utf8), httpResponse(statusCode: 200))
        }

        let chain = PolicyChain.retry(attempts: 3, delay: .immediate)
        let (data, _) = try await session.data(for: makeRequest(), resilience: chain)

        #expect(String(data: data, encoding: .utf8) == "chain-ok")
        #expect(callCount.withLock { $0 } == 2)
    }
}
