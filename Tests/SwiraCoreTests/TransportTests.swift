import Foundation
import Testing

@testable import SwiraCore

@Suite("RetryingTransport")
struct RetryingTransportTests {
    /// Every test injects this so the suite never spends real seconds asleep.
    private static let noSleep: @Sendable (TimeInterval) async throws -> Void = { _ in }

    private func makeRetrying(_ mock: MockTransport, maxRetries: Int = 3) -> RetryingTransport {
        RetryingTransport(wrapping: mock, maxRetries: maxRetries, sleep: Self.noSleep)
    }

    @Test("A rate-limited request is retried and the eventual success is returned")
    func retriesRateLimiting() async throws {
        let mock = MockTransport(stubs: [
            .status(429, headers: ["Retry-After": "1"]),
            .ok(Data(#"{"ok":true}"#.utf8)),
        ])
        let transport = makeRetrying(mock)

        let response = try await transport.send(HTTPRequest(method: .get, path: "myself"))

        #expect(response.status == 200)
        #expect(await mock.requestCount == 2)
    }

    @Test("A POST is retried on 429 — the request never reached the business logic")
    func retriesRateLimitedPost() async throws {
        let mock = MockTransport(stubs: [
            .status(429),
            .ok(Data(#"{"id":"1"}"#.utf8)),
        ])
        let transport = makeRetrying(mock)

        let response = try await transport.send(HTTPRequest(method: .post, path: "filter"))

        #expect(response.status == 200)
        #expect(await mock.requestCount == 2)
    }

    @Test("A POST is not retried on 503 — it may already have taken effect server-side")
    func doesNotRetryPostOnServerError() async throws {
        let mock = MockTransport(stubs: [.status(503)])
        let transport = makeRetrying(mock)

        let response = try await transport.send(HTTPRequest(method: .post, path: "filter"))

        #expect(response.status == 503)
        #expect(await mock.requestCount == 1)
    }

    @Test("A GET is retried on 503")
    func retriesIdempotentServerError() async throws {
        let mock = MockTransport(stubs: [
            .status(503),
            .ok(Data(#"{"ok":true}"#.utf8)),
        ])
        let transport = makeRetrying(mock)

        _ = try await transport.send(HTTPRequest(method: .get, path: "filter/search"))

        #expect(await mock.requestCount == 2)
    }

    @Test("A 400 is never retried — repeating a malformed request only burns the rate limit")
    func doesNotRetryClientError() async throws {
        let mock = MockTransport(stubs: [.status(400)])
        let transport = makeRetrying(mock)

        let response = try await transport.send(HTTPRequest(method: .get, path: "filter/1"))

        #expect(response.status == 400)
        #expect(await mock.requestCount == 1)
    }

    @Test("Retries are bounded and the last response is surfaced")
    func stopsAfterMaxRetries() async throws {
        let mock = MockTransport(stubs: Array(repeating: .status(429), count: 10))
        let transport = makeRetrying(mock, maxRetries: 2)

        let response = try await transport.send(HTTPRequest(method: .get, path: "myself"))

        #expect(response.status == 429)
        // The original attempt plus two retries.
        #expect(await mock.requestCount == 3)
    }

    @Test("A network failure on a GET is retried; on a POST it propagates immediately")
    func handlesTransportFailures() async throws {
        let retriable = MockTransport(stubs: [
            .failure(.transport(description: "connection reset")),
            .ok(Data(#"{"ok":true}"#.utf8)),
        ])
        _ = try await makeRetrying(retriable).send(HTTPRequest(method: .get, path: "myself"))
        #expect(await retriable.requestCount == 2)

        let fatal = MockTransport(stubs: [.failure(.transport(description: "timed out"))])
        await #expect(throws: SwiraError.self) {
            _ = try await makeRetrying(fatal).send(HTTPRequest(method: .post, path: "filter"))
        }
        #expect(await fatal.requestCount == 1)
    }
}

@Suite("HTTP messages")
struct HTTPMessageTests {
    @Test("Header lookup ignores case, because platforms normalize differently")
    func headerLookupIsCaseInsensitive() {
        let response = HTTPResponse(status: 200, headers: ["Retry-After": "42", "ETag": "\"abc\""])
        #expect(response.header("retry-after") == "42")
        #expect(response.header("RETRY-AFTER") == "42")
        #expect(response.header("etag") == "\"abc\"")
        #expect(response.header("Missing") == nil)
    }

    @Test("Cache keys are stable regardless of query parameter order")
    func cacheKeyIsOrderIndependent() {
        let first = HTTPRequest(
            method: .get,
            path: "filter/search",
            queryItems: [
                URLQueryItem(name: "startAt", value: "0"),
                URLQueryItem(name: "maxResults", value: "50"),
            ]
        )
        let second = HTTPRequest(
            method: .get,
            path: "filter/search",
            queryItems: [
                URLQueryItem(name: "maxResults", value: "50"),
                URLQueryItem(name: "startAt", value: "0"),
            ]
        )
        #expect(first.cacheKey == second.cacheKey)
        #expect(first.cacheKey == "GET filter/search?maxResults=50&startAt=0")
    }
}
