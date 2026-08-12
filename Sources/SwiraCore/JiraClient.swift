import Foundation
import Logging

/// The single place that knows how to turn a Jira REST exchange into either a decoded value or a
/// `SwiraError`.
///
/// Services above it deal in domain types and never see status codes; the transport below it deals
/// in bytes and never sees meaning.
public actor JiraClient {
    private let transport: HTTPTransport
    private let auth: AuthProvider
    private let cache: CacheStore
    private let logger: Logger
    private let decoder = JSONCoding.makeDecoder()
    private let encoder = JSONCoding.makeEncoder()

    public init(
        transport: HTTPTransport,
        auth: AuthProvider,
        cache: CacheStore = NullCacheStore(),
        logger: Logger = Logger(label: "swira.client")
    ) {
        self.transport = transport
        self.auth = auth
        self.cache = cache
        self.logger = logger
    }

    /// Sends a request and decodes the response body.
    public func send<Response: Decodable & Sendable>(
        _ request: HTTPRequest,
        as type: Response.Type = Response.self
    ) async throws -> Response {
        let response = try await perform(request)
        return try decode(Response.self, from: response.body)
    }

    /// Sends a request whose response body is irrelevant (deletes, favourite toggles).
    @discardableResult
    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try await perform(request)
    }

    /// Encodes `body` as JSON and sends it. Keeps every call site from repeating the encode step.
    public func send<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        _ request: HTTPRequest,
        body: Body,
        as type: Response.Type = Response.self
    ) async throws -> Response {
        var request = request
        request.body = try encode(body)
        return try await send(request, as: Response.self)
    }

    // MARK: - Caching

    /// Sends a request under a cache policy, reporting whether the answer came off the network.
    ///
    /// Only GET is cached; anything else goes straight out, because caching a mutation would be
    /// meaningless at best.
    public func sendCached<Response: Decodable & Sendable>(
        _ request: HTTPRequest,
        as type: Response.Type = Response.self,
        policy: CachePolicy = .default
    ) async throws -> Cached<Response> {
        guard request.method == .get else {
            return Cached(value: try await send(request, as: Response.self), origin: .network)
        }

        let entry = await cache.load(request.cacheKey)

        switch policy {
        case .cacheOnly:
            guard let entry else {
                throw SwiraError.offline(hasStaleCache: false)
            }
            return Cached(
                value: try decode(Response.self, from: entry.data),
                origin: .cache,
                storedAt: entry.storedAt,
                isStale: true
            )

        case .cacheFirst(let ttl):
            if let entry, entry.age <= ttl {
                return Cached(
                    value: try decode(Response.self, from: entry.data),
                    origin: .cache,
                    storedAt: entry.storedAt,
                    isStale: false
                )
            }
            return try await fetchAndCache(request, as: Response.self, allowCacheFallback: true)

        case .staleWhileRevalidate:
            guard let entry else {
                return try await fetchAndCache(request, as: Response.self, allowCacheFallback: true)
            }
            let value = try decode(Response.self, from: entry.data)
            scheduleRefresh(request)
            // Marked stale because it was served without validating against the server — that is
            // the deal this policy offers. The refreshed value lands in the cache for the caller's
            // next request.
            return Cached(
                value: value,
                origin: .cache,
                storedAt: entry.storedAt,
                isStale: true
            )

        case .networkOnly:
            return try await fetchAndCache(request, as: Response.self, allowCacheFallback: true)
        }
    }

    /// Background refreshes started by `.staleWhileRevalidate`, keyed by cache key.
    ///
    /// Tracked rather than fired-and-forgotten so that (a) repeated stale reads of the same
    /// resource coalesce into one request instead of a stampede, and (b) tests and shutdown paths
    /// can wait for them deterministically.
    private var pendingRefreshes: [String: Task<Void, Never>] = [:]

    private func scheduleRefresh(_ request: HTTPRequest) {
        let key = request.cacheKey
        guard pendingRefreshes[key] == nil else { return }
        // An unstructured Task created on the actor inherits its isolation, so the closure may
        // touch actor state directly.
        pendingRefreshes[key] = Task {
            await self.refreshCache(request)
            self.pendingRefreshes[key] = nil
        }
    }

    /// Fetches and stores raw bytes, without decoding: a refresh has no caller to decode for.
    /// Best effort — the reader already has an answer, so a failure changes nothing for them,
    /// and the next stale read will try again.
    private func refreshCache(_ request: HTTPRequest) async {
        let key = request.cacheKey
        let entry = await cache.load(key)

        var request = request
        if let etag = entry?.etag {
            request.setHeader("If-None-Match", etag)
        }

        guard let response = try? await execute(request) else { return }

        if response.status == 304, let entry {
            await cache.store(CacheEntry(key: key, data: entry.data, etag: entry.etag))
        } else if response.isSuccess {
            await cache.store(
                CacheEntry(key: key, data: response.body, etag: response.header("ETag"))
            )
        }
    }

    /// Waits until every background refresh in flight has finished.
    public func awaitPendingRefreshes() async {
        while let task = pendingRefreshes.first?.value {
            await task.value
        }
    }

    /// Invalidates every cached response whose key starts with `prefix`.
    ///
    /// Called after a mutation, so a stale list cannot outlive the change that contradicts it.
    public func invalidateCache(prefix: String) async {
        await cache.removeAll(withPrefix: prefix)
    }

    public func clearCache() async {
        await cache.clear()
    }

    /// Goes to the network, revalidating with `If-None-Match` when an ETag is on hand.
    ///
    /// - Parameter allowCacheFallback: when the network fails, serve stale cache instead of
    ///   throwing. This is what makes the app usable on a train.
    @discardableResult
    private func fetchAndCache<Response: Decodable & Sendable>(
        _ request: HTTPRequest,
        as type: Response.Type,
        allowCacheFallback: Bool
    ) async throws -> Cached<Response> {
        let key = request.cacheKey
        let entry = await cache.load(key)

        var request = request
        if let etag = entry?.etag {
            request.setHeader("If-None-Match", etag)
        }

        let response: HTTPResponse
        do {
            response = try await execute(request)
        } catch let error as SwiraError {
            guard allowCacheFallback, case .transport = error, let entry else {
                throw error
            }
            logger.debug("Network failed; serving cached response", metadata: ["key": "\(key)"])
            return Cached(
                value: try decode(Response.self, from: entry.data),
                origin: .cache,
                storedAt: entry.storedAt,
                isStale: true
            )
        }

        // 304: the cached body is still current. Re-store it so its age restarts.
        if response.status == 304, let entry {
            let refreshed = CacheEntry(key: key, data: entry.data, etag: entry.etag)
            await cache.store(refreshed)
            return Cached(
                value: try decode(Response.self, from: entry.data),
                origin: .cache,
                storedAt: refreshed.storedAt,
                isStale: false
            )
        }

        guard response.isSuccess else {
            throw makeError(from: response, request: request)
        }

        let value = try decode(Response.self, from: response.body)
        await cache.store(
            CacheEntry(key: key, data: response.body, etag: response.header("ETag"))
        )
        return Cached(value: value, origin: .network)
    }

    // MARK: - Internals

    private func perform(_ request: HTTPRequest) async throws -> HTTPResponse {
        let response = try await execute(request)
        guard response.isSuccess else {
            throw makeError(from: response, request: request)
        }
        return response
    }

    /// Authorizes and sends, without interpreting the status. Callers decide what a status means.
    private func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
        var request = request
        try await auth.authorize(&request)

        logger.debug(
            "Jira request",
            metadata: ["method": "\(request.method.rawValue)", "path": "\(request.path)"]
        )

        let response = try await transport.send(request)

        // A CDN bot-protection challenge, not a Jira response. AWS WAF answers 202 — a success
        // status — with an empty body and this header, which would otherwise surface as a
        // baffling "empty response body" decoding error. Seen live in front of a Jira instance
        // during development; not retryable, because a non-browser client cannot solve the
        // challenge.
        if let wafAction = response.header("x-amzn-waf-action") {
            throw SwiraError.transport(
                description: """
                    The request was intercepted by the site's bot protection \
                    (AWS WAF action: \(wafAction)) and never reached Jira. \
                    This Jira instance does not allow API clients on this endpoint.
                    """
            )
        }

        return response
    }

    private func encode<Body: Encodable>(_ body: Body) throws -> Data {
        do {
            return try encoder.encode(body)
        } catch {
            throw SwiraError.transport(description: "Could not encode the request body: \(error)")
        }
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        if data.isEmpty {
            // Endpoints such as DELETE answer 204 with an empty body; `Empty` models that case.
            if let empty = Empty() as? Value {
                return empty
            }
            // Otherwise say so plainly. Handing an empty body to `JSONDecoder` yields
            // "The given data was not valid JSON" alongside an empty snippet, which tells the
            // reader nothing about what actually went wrong.
            throw SwiraError.decoding(
                path: "\(type)",
                snippet: "the response body was empty"
            )
        }
        do {
            return try decoder.decode(Value.self, from: data)
        } catch let error as DecodingError {
            throw SwiraError.decoding(path: describe(error), snippet: snippet(of: data))
        } catch {
            throw SwiraError.decoding(path: "\(type)", snippet: snippet(of: data))
        }
    }

    private func makeError(from response: HTTPResponse, request: HTTPRequest) -> SwiraError {
        let envelope = try? decoder.decode(JiraErrorEnvelope.self, from: response.body)
        let messages = envelope?.errorMessages ?? []
        let fieldErrors = envelope?.errors ?? [:]

        switch response.status {
        case 401:
            return .unauthorized
        case 403:
            // Jira answers 403 both for "you may not" and for CAPTCHA challenges after repeated
            // failed logins. The envelope is what distinguishes them, so keep it when present.
            return messages.isEmpty && fieldErrors.isEmpty
                ? .forbidden
                : .jira(status: 403, messages: messages, fieldErrors: fieldErrors)
        case 404:
            return .notFound(resource: request.path)
        case 429:
            return .rateLimited(retryAfter: response.retryAfterSeconds)
        default:
            return .jira(status: response.status, messages: messages, fieldErrors: fieldErrors)
        }
    }

    private func describe(_ error: DecodingError) -> String {
        let context: DecodingError.Context
        switch error {
        case .typeMismatch(_, let value), .valueNotFound(_, let value),
             .keyNotFound(_, let value), .dataCorrupted(let value):
            context = value
        @unknown default:
            return "unknown decoding error"
        }
        let path = context.codingPath.map(\.stringValue).joined(separator: ".")
        return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
    }

    private func snippet(of data: Data) -> String {
        let limit = 512
        let text = String(data: data.prefix(limit), encoding: .utf8) ?? "<\(data.count) bytes>"
        return data.count > limit ? text + "…" : text
    }
}

/// Jira's standard error envelope.
private struct JiraErrorEnvelope: Decodable {
    let errorMessages: [String]?
    let errors: [String: String]?
}

/// Stands in for "no response body expected".
public struct Empty: Codable, Sendable, Hashable {
    public init() {}
}
