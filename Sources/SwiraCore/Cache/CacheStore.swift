import Foundation

/// A cached response body, with what is needed to revalidate and age it.
public struct CacheEntry: Sendable, Hashable, Codable {
    /// The request this was stored for. Kept so prefix invalidation can work over hashed filenames.
    public let key: String
    public let data: Data
    /// Jira's `ETag`, replayed as `If-None-Match` so an unchanged resource costs a 304, not a body.
    public let etag: String?
    public let storedAt: Date
    /// Set by `CacheStore.expireAll` ("Refresh"): forces the next `.cacheFirst`/`.default` read
    /// to attempt a real revalidation regardless of `age`/`ttl`, without discarding `storedAt` —
    /// which stays the true last-successful-fetch time, so a fallback serving this entry after a
    /// *failed* revalidation still reports an honest age ("12m ago"), not the moment it was
    /// marked expired. A successful revalidation (fresh body or a 304) always clears this.
    public let expired: Bool

    public init(key: String, data: Data, etag: String? = nil, storedAt: Date = Date(), expired: Bool = false) {
        self.key = key
        self.data = data
        self.etag = etag
        self.storedAt = storedAt
        self.expired = expired
    }

    public var age: TimeInterval {
        Date().timeIntervalSince(storedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case key, data, etag, storedAt, expired
    }

    /// Manual `init(from:)`: `expired` defaults to `false` for an entry written before this field
    /// existed, rather than failing to decode it.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        data = try container.decode(Data.self, forKey: .data)
        etag = try container.decodeIfPresent(String.self, forKey: .etag)
        storedAt = try container.decode(Date.self, forKey: .storedAt)
        expired = try container.decodeIfPresent(Bool.self, forKey: .expired) ?? false
    }
}

/// Where cached responses are kept.
public protocol CacheStore: Sendable {
    func load(_ key: String) async -> CacheEntry?
    func store(_ entry: CacheEntry) async
    func remove(_ key: String) async
    /// Drops every entry whose key starts with `prefix`. Used to invalidate a whole family of
    /// requests after a mutation — every `filter/search` page at once, say. A mutation is the
    /// right place for an outright drop: it just succeeded, so the caller already knows the old
    /// cached answer is wrong, and there is no offline concern (a mutation cannot have succeeded
    /// while offline in the first place).
    func removeAll(withPrefix prefix: String) async
    func clear() async
    /// Marks every entry whose key starts with `prefix` as though its TTL had already elapsed,
    /// without deleting it: the next `.cacheFirst`/`.default` read goes to the network to
    /// revalidate (a 304 just refreshes its age; a changed body replaces it), but if that attempt
    /// fails — network down, 403, 5xx, or `offline` mode — the entry is still there for
    /// `JiraClient.fetchAndCache`'s existing fallback to serve, marked stale. This is the "Refresh"
    /// primitive: unlike `removeAll(withPrefix:)`, it never makes data disappear just because the
    /// server round trip it triggers doesn't succeed.
    func expireAll(withPrefix prefix: String) async
}

extension CacheStore {
    /// Convenience for expiring the whole store — `expireAll(withPrefix: "")` matches every key.
    public func expireAll() async {
        await expireAll(withPrefix: "")
    }
}

/// How fresh a caller needs the data to be.
public enum CachePolicy: Sendable, Hashable {
    /// Always go to the network. Falls back to the cache only when the network fails outright.
    case networkOnly
    /// Use the cache while it is younger than `ttl`; otherwise revalidate.
    case cacheFirst(ttl: TimeInterval)
    /// Return the cached value immediately and refresh in the background.
    ///
    /// The refreshed value lands in the cache, not in the value already returned — the caller
    /// sees it on its next request. Suits a list a UI re-reads on appearance; unsuitable when the
    /// caller needs to know the moment fresh data arrives.
    case staleWhileRevalidate
    /// Never touch the network. Fails if nothing is cached.
    case cacheOnly

    public static let `default` = CachePolicy.cacheFirst(ttl: 300)
    /// For reference data — projects, fields — which changes on the order of days.
    public static let reference = CachePolicy.cacheFirst(ttl: 3600)
}

/// Where a value came from.
///
/// Top-level rather than nested inside `Cached` because a type nested in a generic is itself
/// generic — `Cached<A>.Origin` and `Cached<B>.Origin` would be different types, which breaks any
/// code that transforms one `Cached` into another.
public enum CacheOrigin: Sendable, Hashable {
    case network
    case cache
}

/// A value plus where it came from and how old it is.
///
/// Reading code has to be able to tell a fresh answer from a cached one; collapsing them would let
/// a UI present day-old data as current, which is exactly the failure offline support invites.
public struct Cached<Value: Sendable>: Sendable {
    public let value: Value
    public let origin: CacheOrigin
    /// When the value was fetched from Jira. `nil` for a value that just came off the network.
    public let storedAt: Date?
    /// Whether the value was served without confirming it is current.
    ///
    /// True when the cache answered past its freshness window, when the network failed and the
    /// cache stood in, and under `.cacheOnly` and `.staleWhileRevalidate`, where serving without
    /// validation is the deal. False for a network response and for a cache hit inside its TTL,
    /// which the caller declared fresh enough by choosing that TTL.
    public let isStale: Bool

    public init(value: Value, origin: CacheOrigin, storedAt: Date? = nil, isStale: Bool = false) {
        self.value = value
        self.origin = origin
        self.storedAt = storedAt
        self.isStale = isStale
    }

}

extension Cached {
    /// Transforms the value while preserving where it came from and how old it is.
    public func map<T: Sendable>(_ transform: (Value) throws -> T) rethrows -> Cached<T> {
        // Module-qualified: inside `Cached<Value>`, a bare `Cached<T>` resolves to the enclosing
        // type rather than a fresh specialization.
        SwiraCore.Cached<T>(
            value: try transform(value),
            origin: origin,
            storedAt: storedAt,
            isStale: isStale
        )
    }
}

/// An in-memory cache. Used by tests, and by clients that should not touch the disk.
public actor MemoryCacheStore: CacheStore {
    private var entries: [String: CacheEntry] = [:]

    public init() {}

    public func load(_ key: String) async -> CacheEntry? {
        entries[key]
    }

    public func store(_ entry: CacheEntry) async {
        entries[entry.key] = entry
    }

    public func remove(_ key: String) async {
        entries[key] = nil
    }

    public func removeAll(withPrefix prefix: String) async {
        for key in entries.keys where key.hasPrefix(prefix) {
            entries[key] = nil
        }
    }

    public func clear() async {
        entries.removeAll()
    }

    public func expireAll(withPrefix prefix: String) async {
        for key in entries.keys where key.hasPrefix(prefix) {
            guard let entry = entries[key] else { continue }
            entries[key] = CacheEntry(
                key: entry.key, data: entry.data, etag: entry.etag, storedAt: entry.storedAt, expired: true
            )
        }
    }
}

/// A cache that ignores everything written to it.
///
/// The way to run without caching, so no call site needs an optional store.
public struct NullCacheStore: CacheStore {
    public init() {}
    public func load(_ key: String) async -> CacheEntry? { nil }
    public func store(_ entry: CacheEntry) async {}
    public func remove(_ key: String) async {}
    public func removeAll(withPrefix prefix: String) async {}
    public func clear() async {}
    public func expireAll(withPrefix prefix: String) async {}
}
