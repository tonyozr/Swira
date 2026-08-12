import Foundation
import Logging

/// Wraps any transport with bounded exponential backoff.
///
/// Retry rules, and why they are what they are:
/// - `429` is retried for every method, honoring `Retry-After`. Jira rate-limits aggressively and
///   the request provably never reached the business logic, so even POST is safe to repeat.
/// - `502/503/504` and outright network failures are retried only for idempotent methods. A POST
///   that times out may well have created a filter server-side; repeating it would create a second.
/// - `4xx` other than 429 is never retried — the request itself is wrong, and repeating it only
///   burns the rate limit.
public struct RetryingTransport: HTTPTransport {
    private let base: HTTPTransport
    private let maxRetries: Int
    private let logger: Logger

    /// Injected so tests do not spend real seconds sleeping.
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    public init(
        wrapping base: HTTPTransport,
        maxRetries: Int,
        logger: Logger = Logger(label: "swira.transport"),
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.base = base
        self.maxRetries = maxRetries
        self.logger = logger
        self.sleep = sleep
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var attempt = 0

        while true {
            do {
                let response = try await base.send(request)
                guard let delay = retryDelay(for: response, request: request, attempt: attempt) else {
                    return response
                }
                logger.debug(
                    "Retrying after HTTP status",
                    metadata: [
                        "status": "\(response.status)",
                        "path": "\(request.path)",
                        "attempt": "\(attempt + 1)",
                    ]
                )
                try await sleep(delay)
            } catch let error as SwiraError {
                guard case .transport = error,
                      request.method.isIdempotent,
                      attempt < maxRetries else {
                    throw error
                }
                logger.debug(
                    "Retrying after transport failure",
                    metadata: ["path": "\(request.path)", "attempt": "\(attempt + 1)"]
                )
                try await sleep(backoff(attempt: attempt))
            }

            attempt += 1
        }
    }

    /// How long to wait before repeating this request, or `nil` if it should not be repeated.
    private func retryDelay(
        for response: HTTPResponse,
        request: HTTPRequest,
        attempt: Int
    ) -> TimeInterval? {
        guard attempt < maxRetries else { return nil }

        switch response.status {
        case 429:
            return retryAfter(in: response) ?? backoff(attempt: attempt)
        case 502, 503, 504:
            guard request.method.isIdempotent else { return nil }
            return retryAfter(in: response) ?? backoff(attempt: attempt)
        default:
            return nil
        }
    }

    /// Exponential backoff with jitter, capped so a long outage cannot stall the UI for minutes.
    private func backoff(attempt: Int) -> TimeInterval {
        let exponential = min(pow(2.0, Double(attempt)), 8.0)
        return exponential * Double.random(in: 0.75...1.25)
    }

    private func retryAfter(in response: HTTPResponse) -> TimeInterval? {
        guard let raw = response.header("Retry-After"), let seconds = TimeInterval(raw) else {
            return nil
        }
        // Jira has been known to send implausibly large values; cap so a client never appears hung.
        return min(seconds, 60)
    }
}

extension HTTPResponse {
    /// `Retry-After` as seconds, for callers that need it after retries are exhausted.
    var retryAfterSeconds: TimeInterval? {
        guard let raw = header("Retry-After") else { return nil }
        return TimeInterval(raw)
    }
}
