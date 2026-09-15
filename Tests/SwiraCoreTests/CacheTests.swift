import Foundation
import Testing

@testable import SwiraCore

@Suite("Caching")
struct CacheTests {
    private let request = HTTPRequest(method: .get, path: "myself")

    private func makeClient(_ mock: MockTransport, cache: CacheStore) -> JiraClient {
        JiraClient(transport: mock, auth: NoAuthProvider(), cache: cache)
    }

    private func makeOfflineClient(_ mock: MockTransport, cache: CacheStore) -> JiraClient {
        JiraClient(transport: mock, auth: NoAuthProvider(), cache: cache, offline: true)
    }

    @Test("A fresh cache entry is served without touching the network")
    func servesFreshCache() async throws {
        let cache = MemoryCacheStore()
        let mock = MockTransport(stubs: [.ok(try Fixture.data("myself"))])
        let client = makeClient(mock, cache: cache)

        let first: Cached<JiraUser> = try await client.sendCached(request, policy: .cacheFirst(ttl: 60))
        let second: Cached<JiraUser> = try await client.sendCached(request, policy: .cacheFirst(ttl: 60))

        #expect(first.origin == .network)
        #expect(second.origin == .cache)
        #expect(!second.isStale)
        #expect(second.value.accountId == first.value.accountId)
        #expect(await mock.requestCount == 1)
    }

    @Test("An entry past its TTL is revalidated")
    func revalidatesExpiredCache() async throws {
        let cache = MemoryCacheStore()
        let body = try Fixture.data("myself")
        await cache.store(
            CacheEntry(
                key: request.cacheKey,
                data: body,
                etag: nil,
                storedAt: Date(timeIntervalSinceNow: -3600)
            )
        )
        let mock = MockTransport(stubs: [.ok(body)])

        let result: Cached<JiraUser> = try await makeClient(mock, cache: cache)
            .sendCached(request, policy: .cacheFirst(ttl: 60))

        #expect(result.origin == .network)
        #expect(await mock.requestCount == 1)
    }

    @Test("A stored ETag is replayed and a 304 costs no body")
    func revalidatesWithETag() async throws {
        let cache = MemoryCacheStore()
        let mock = MockTransport(stubs: [
            .ok(try Fixture.data("myself"), headers: ["ETag": "\"v1\""]),
            .status(304),
        ])
        let client = makeClient(mock, cache: cache)

        let first: Cached<JiraUser> = try await client.sendCached(request, policy: .networkOnly)
        let second: Cached<JiraUser> = try await client.sendCached(request, policy: .networkOnly)

        #expect(first.origin == .network)
        // A 304 means the cached body is still current, so the value comes from the cache.
        #expect(second.origin == .cache)
        #expect(!second.isStale)
        #expect(second.value.displayName == "Mia Krystof")

        let revalidation = try #require(await mock.recorded.last)
        #expect(revalidation.headers["If-None-Match"] == "\"v1\"")
    }

    @Test("When the network fails, stale cache is served and marked as such")
    func fallsBackToCacheOffline() async throws {
        let cache = MemoryCacheStore()
        let mock = MockTransport(stubs: [
            .ok(try Fixture.data("myself")),
            .failure(.transport(description: "the network is unreachable")),
        ])
        let client = makeClient(mock, cache: cache)

        _ = try await client.sendCached(request, as: JiraUser.self, policy: .networkOnly)
        let offline: Cached<JiraUser> = try await client.sendCached(request, policy: .networkOnly)

        #expect(offline.origin == .cache)
        // The caller must be able to tell this apart from a live answer.
        #expect(offline.isStale)
        #expect(offline.storedAt != nil)
        #expect(offline.value.accountId == "5b10a2844c20165700ede21g")
    }

    @Test("A 403 is served from cache instead of failing offline")
    func fallsBackToCacheOnForbidden() async throws {
        let cache = MemoryCacheStore()
        let mock = MockTransport(stubs: [
            .ok(try Fixture.data("myself")),
            .status(403),
        ])
        let client = makeClient(mock, cache: cache)

        _ = try await client.sendCached(request, as: JiraUser.self, policy: .networkOnly)
        let forbidden: Cached<JiraUser> = try await client.sendCached(request, policy: .networkOnly)

        // A token that lost a permission (or a WAF rule that started blocking this route)
        // shouldn't leave the client with nothing to show when it last succeeded.
        #expect(forbidden.origin == .cache)
        #expect(forbidden.isStale)
        #expect(forbidden.value.accountId == "5b10a2844c20165700ede21g")
    }

    @Test("Refresh (expire): a subsequent read revalidates, and a fresh answer replaces the old one")
    func expiredEntryRevalidatesSuccessfully() async throws {
        let cache = MemoryCacheStore()
        // Two different `myself` bodies (a display name change is enough to tell them apart) —
        // the second stands in for what a real server round trip would answer after Refresh.
        let updated = Data(
            String(decoding: try Fixture.data("myself"), as: UTF8.self)
                .replacingOccurrences(of: "Mia Krystof", with: "Mia Renamed").utf8
        )
        let mock = MockTransport(stubs: [.ok(updated)])
        let client = makeClient(mock, cache: cache)
        await cache.store(CacheEntry(key: request.cacheKey, data: try Fixture.data("myself")))

        await client.expireCache()
        let after: Cached<JiraUser> = try await client.sendCached(request, policy: .default)

        #expect(after.origin == .network)
        #expect(after.value.displayName == "Mia Renamed")
    }

    @Test("Refresh (expire): if the revalidation attempt fails, the old value is still served")
    func expiredEntryFallsBackOnFailure() async throws {
        let cache = MemoryCacheStore()
        let mock = MockTransport(stubs: [.status(503)])
        let client = makeClient(mock, cache: cache)
        await cache.store(CacheEntry(key: request.cacheKey, data: try Fixture.data("myself")))

        await client.expireCache()
        let after: Cached<JiraUser> = try await client.sendCached(request, policy: .default)

        // Expired, not deleted: even though the entry looked stale enough to revalidate, it was
        // still there for `fetchAndCache`'s fallback the moment the revalidation itself failed.
        #expect(after.origin == .cache)
        #expect(after.isStale)
        #expect(after.value.displayName == "Mia Krystof")
    }

    @Test("A 5xx is treated as 'unavailable' and falls back to cache too")
    func fallsBackToCacheOnServerError() async throws {
        let cache = MemoryCacheStore()
        let mock = MockTransport(stubs: [
            .ok(try Fixture.data("myself")),
            .status(503),
        ])
        let client = makeClient(mock, cache: cache)

        _ = try await client.sendCached(request, as: JiraUser.self, policy: .networkOnly)
        let unavailable: Cached<JiraUser> = try await client.sendCached(request, policy: .networkOnly)

        #expect(unavailable.origin == .cache)
        #expect(unavailable.isStale)
    }

    @Test("With no cached entry, a 403 still surfaces as an error")
    func forbiddenPropagatesWithoutACacheEntry() async throws {
        let cache = MemoryCacheStore()
        let mock = MockTransport(stubs: [.status(403)])
        let client = makeClient(mock, cache: cache)

        await #expect(throws: SwiraError.forbidden) {
            let _: Cached<JiraUser> = try await client.sendCached(request, policy: .networkOnly)
        }
    }

    @Test("A POST-only read (issue search) caches just like a GET")
    func cachesCacheableReadPost() async throws {
        let cache = MemoryCacheStore()
        let mock = MockTransport(stubs: [.ok(try Fixture.data("search-page1"))])
        let client = makeClient(mock, cache: cache)
        let search = HTTPRequest(method: .post, path: "search/jql", isCacheableRead: true)

        let first: Cached<IssueSearchResponse> = try await client.sendCached(
            search,
            body: IssueSearchRequest(jql: "project = SWIRA", maxResults: 50, fields: [], nextPageToken: nil, expand: nil),
            policy: .cacheFirst(ttl: 60)
        )
        let second: Cached<IssueSearchResponse> = try await client.sendCached(
            search,
            body: IssueSearchRequest(jql: "project = SWIRA", maxResults: 50, fields: [], nextPageToken: nil, expand: nil),
            policy: .cacheFirst(ttl: 60)
        )

        #expect(first.origin == .network)
        #expect(second.origin == .cache)
        #expect(await mock.requestCount == 1)
    }

    @Test("A POST-only read with a different body is a different cache entry")
    func cacheableReadPostKeysOnBody() async throws {
        let cache = MemoryCacheStore()
        let mock = MockTransport(stubs: [
            .ok(try Fixture.data("search-page1")),
            .ok(try Fixture.data("search-page2")),
        ])
        let client = makeClient(mock, cache: cache)
        let search = HTTPRequest(method: .post, path: "search/jql", isCacheableRead: true)

        _ = try await client.sendCached(
            search,
            body: IssueSearchRequest(jql: "project = SWIRA", maxResults: 50, fields: [], nextPageToken: nil, expand: nil),
            as: IssueSearchResponse.self,
            policy: .cacheFirst(ttl: 60)
        )
        let other: Cached<IssueSearchResponse> = try await client.sendCached(
            search,
            body: IssueSearchRequest(jql: "project = OTHER", maxResults: 50, fields: [], nextPageToken: nil, expand: nil),
            policy: .cacheFirst(ttl: 60)
        )

        #expect(other.origin == .network)
        #expect(await mock.requestCount == 2)
    }

    @Test("offline: a cached read answers without the mock ever being called")
    func offlineServesCache() async throws {
        let cache = MemoryCacheStore()
        await cache.store(CacheEntry(key: request.cacheKey, data: try Fixture.data("myself")))
        // Empty stub list: if this reaches the transport at all, the test fails on the attempt,
        // not on a wrong answer.
        let mock = MockTransport(stubs: [])
        let client = makeOfflineClient(mock, cache: cache)

        let offline: Cached<JiraUser> = try await client.sendCached(request, policy: .networkOnly)

        #expect(offline.origin == .cache)
        #expect(offline.isStale)
        #expect(await mock.requestCount == 0)
    }

    @Test("offline: a read with nothing cached fails immediately, without touching the network")
    func offlineFailsWithoutCache() async throws {
        let cache = MemoryCacheStore()
        let mock = MockTransport(stubs: [])
        let client = makeOfflineClient(mock, cache: cache)

        // `.offline`, not a raw `.transport` failure — the caller (a WebAPI route, say) should
        // see "offline, nothing cached", not a network-failure message for a request that never
        // touched the network. See JiraClient.execute.
        await #expect(throws: SwiraError.offline(hasStaleCache: false)) {
            let _: Cached<JiraUser> = try await client.sendCached(request, policy: .cacheFirst(ttl: 60))
        }
        #expect(await mock.requestCount == 0)
    }

    @Test("offline: a write fails immediately instead of reaching the network")
    func offlineFailsWrites() async throws {
        let mock = MockTransport(stubs: [.ok(try Fixture.data("filter"))])
        let client = makeOfflineClient(mock, cache: MemoryCacheStore())
        let post = HTTPRequest(method: .post, path: "filter")

        await #expect(throws: SwiraError.offline(hasStaleCache: false)) {
            let _: JiraFilter = try await client.send(post, as: JiraFilter.self)
        }
        #expect(await mock.requestCount == 0)
    }

    @Test("An HTTP error is never masked by the cache")
    func doesNotMaskHTTPErrors() async throws {
        let cache = MemoryCacheStore()
        let mock = MockTransport(stubs: [
            .ok(try Fixture.data("myself")),
            .status(401),
        ])
        let client = makeClient(mock, cache: cache)

        _ = try await client.sendCached(request, as: JiraUser.self, policy: .networkOnly)

        // Falling back to cache here would hide revoked credentials behind stale data.
        await #expect(throws: SwiraError.unauthorized) {
            let _: Cached<JiraUser> = try await client.sendCached(request, policy: .networkOnly)
        }
    }

    @Test("cacheOnly refuses rather than reaching the network")
    func cacheOnlyNeverFetches() async throws {
        let cache = MemoryCacheStore()
        let mock = MockTransport(stubs: [])
        let client = makeClient(mock, cache: cache)

        await #expect(throws: SwiraError.offline(hasStaleCache: false)) {
            let _: Cached<JiraUser> = try await client.sendCached(request, policy: .cacheOnly)
        }
        #expect(await mock.requestCount == 0)

        await cache.store(
            CacheEntry(key: request.cacheKey, data: try Fixture.data("myself"))
        )
        let result: Cached<JiraUser> = try await client.sendCached(request, policy: .cacheOnly)
        #expect(result.origin == .cache)
        #expect(result.isStale)
        #expect(await mock.requestCount == 0)
    }

    @Test("staleWhileRevalidate serves cached immediately and refreshes behind the scenes")
    func staleWhileRevalidateRefreshes() async throws {
        let cache = MemoryCacheStore()
        let original = try Fixture.data("myself")
        var updated = String(decoding: original, as: UTF8.self)
        updated = updated.replacingOccurrences(of: "Mia Krystof", with: "Mia Renamed")

        let mock = MockTransport(stubs: [
            .ok(original),
            .ok(Data(updated.utf8)),
        ])
        let client = makeClient(mock, cache: cache)

        // Warm the cache.
        _ = try await client.sendCached(request, as: JiraUser.self, policy: .networkOnly)

        // Served from cache, honestly marked as unvalidated.
        let stale: Cached<JiraUser> = try await client.sendCached(request, policy: .staleWhileRevalidate)
        #expect(stale.origin == .cache)
        #expect(stale.isStale)
        #expect(stale.value.displayName == "Mia Krystof")

        // Once the background refresh lands, the cache holds the new body.
        await client.awaitPendingRefreshes()
        let after: Cached<JiraUser> = try await client.sendCached(request, policy: .cacheFirst(ttl: 60))
        #expect(after.origin == .cache)
        #expect(after.value.displayName == "Mia Renamed")
        #expect(await mock.requestCount == 2)
    }

    @Test("Stale reads while a refresh is in flight coalesce instead of stampeding")
    func staleWhileRevalidateDeduplicates() async throws {
        let cache = MemoryCacheStore()
        let body = try Fixture.data("myself")
        await cache.store(CacheEntry(key: request.cacheKey, data: body))

        // The gate holds the first refresh open so the later reads provably arrive while it is
        // still in flight — without it, a refresh could finish between loop iterations and the
        // next read would legitimately start another.
        let gate = GatedTransport(response: HTTPResponse(status: 200, body: body))
        let client = JiraClient(transport: gate, auth: NoAuthProvider(), cache: cache)

        for _ in 0..<5 {
            let _: Cached<JiraUser> = try await client.sendCached(request, policy: .staleWhileRevalidate)
        }
        await gate.open()
        await client.awaitPendingRefreshes()

        #expect(await gate.requestCount == 1)
    }

    @Test("staleWhileRevalidate with a cold cache fetches like a normal request")
    func staleWhileRevalidateColdCache() async throws {
        let cache = MemoryCacheStore()
        let mock = MockTransport(stubs: [.ok(try Fixture.data("myself"))])
        let client = makeClient(mock, cache: cache)

        let result: Cached<JiraUser> = try await client.sendCached(request, policy: .staleWhileRevalidate)

        #expect(result.origin == .network)
        #expect(!result.isStale)
    }

    @Test("A failed background refresh leaves the cached value in place")
    func staleWhileRevalidateSurvivesFailedRefresh() async throws {
        let cache = MemoryCacheStore()
        let body = try Fixture.data("myself")
        await cache.store(CacheEntry(key: request.cacheKey, data: body))

        let mock = MockTransport(stubs: [.failure(.transport(description: "unreachable"))])
        let client = makeClient(mock, cache: cache)

        let stale: Cached<JiraUser> = try await client.sendCached(request, policy: .staleWhileRevalidate)
        #expect(stale.value.displayName == "Mia Krystof")

        await client.awaitPendingRefreshes()

        // The reader already had an answer; the failure must not have evicted it.
        let again: Cached<JiraUser> = try await client.sendCached(request, policy: .cacheOnly)
        #expect(again.value.displayName == "Mia Krystof")
    }

    @Test("Mutations are never cached, and never answered from cache")
    func doesNotCacheMutations() async throws {
        let cache = MemoryCacheStore()
        let mock = MockTransport(stubs: [
            .ok(try Fixture.data("filter")),
            .ok(try Fixture.data("filter")),
        ])
        let client = makeClient(mock, cache: cache)
        let post = HTTPRequest(method: .post, path: "filter")

        let first: Cached<JiraFilter> = try await client.sendCached(post, policy: .cacheFirst(ttl: 60))
        let second: Cached<JiraFilter> = try await client.sendCached(post, policy: .cacheFirst(ttl: 60))

        #expect(first.origin == .network)
        #expect(second.origin == .network)
        #expect(await mock.requestCount == 2)
    }

    @Test("Editing a filter invalidates every cached filter response")
    func mutationInvalidatesFilterCache() async throws {
        let cache = MemoryCacheStore()
        let mock = MockTransport(stubs: [
            .ok(try Fixture.data("filter-search-page1")),
            .ok(try Fixture.data("filter")),
            .ok(try Fixture.data("filter-search-page1")),
        ])
        let service = FiltersService(client: makeClient(mock, cache: cache))

        let before = try await service.search(policy: .cacheFirst(ttl: 600))
        #expect(before.origin == .network)

        _ = try await service.update(id: "10000", FilterInput(name: "Renamed", jql: "type = Bug"))

        // Without invalidation this would still answer from the page cached before the edit.
        let after = try await service.search(policy: .cacheFirst(ttl: 600))
        #expect(after.origin == .network)
        #expect(await mock.requestCount == 3)
    }

    @Test("Cache keys ignore query parameter order but distinguish different queries")
    func keysDistinguishRequests() async throws {
        let cache = MemoryCacheStore()
        let mock = MockTransport(stubs: [
            .ok(try Fixture.data("filter-search-page1")),
            .ok(try Fixture.data("filter-search-page2")),
        ])
        let service = FiltersService(client: makeClient(mock, cache: cache))

        _ = try await service.search(FilterQuery(startAt: 0), policy: .cacheFirst(ttl: 600))
        let other = try await service.search(FilterQuery(startAt: 2), policy: .cacheFirst(ttl: 600))

        // A different page must not be served the first page's cached body.
        #expect(other.origin == .network)
        #expect(other.value.values.first?.name == "Recently updated")
    }
}

@Suite("Swira facade")
struct SwiraFacadeTests {
    @Test("verifyCredentials fails on a dead network even when /myself is cached")
    func verifyCredentialsIgnoresCache() async throws {
        let cache = MemoryCacheStore()
        let mock = MockTransport(stubs: [
            .ok(try Fixture.data("myself")),
            .failure(.transport(description: "the network is unreachable")),
        ])
        let swira = Swira(
            configuration: SwiraConfiguration(
                site: try JiraSite(urlString: "https://example.atlassian.net")
            ),
            auth: NoAuthProvider(),
            transport: mock,
            cache: cache
        )

        // Warm the cache with a successful cached read of the same endpoint.
        let warm = try await swira.reference.currentUser(policy: .networkOnly)
        #expect(warm.origin == .network)

        // The cached copy must not stand in: this call's whole job is to prove the
        // credentials work right now.
        do {
            _ = try await swira.verifyCredentials()
            Issue.record("Expected a transport error")
        } catch let error as SwiraError {
            guard case .transport = error else {
                Issue.record("Expected .transport, got \(error)")
                return
            }
        }
    }
}

@Suite("FileSystemCacheStore")
struct FileSystemCacheStoreTests {
    private func makeTemporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("swira-tests-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("Entries survive a round trip through the filesystem")
    func storesAndLoads() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = FileSystemCacheStore(directory: directory)
        let entry = CacheEntry(key: "GET filter/10", data: Data("{}".utf8), etag: "\"v1\"")
        await store.store(entry)

        let loaded = try #require(await store.load("GET filter/10"))
        #expect(loaded.data == entry.data)
        #expect(loaded.etag == "\"v1\"")
        #expect(await store.load("GET filter/11") == nil)
    }

    @Test("Prefix removal drops a family of entries and leaves the rest")
    func removesByPrefix() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = FileSystemCacheStore(directory: directory)
        await store.store(CacheEntry(key: "GET filter/search?a=1", data: Data("1".utf8)))
        await store.store(CacheEntry(key: "GET filter/10", data: Data("2".utf8)))
        await store.store(CacheEntry(key: "GET myself", data: Data("3".utf8)))

        await store.removeAll(withPrefix: "GET filter")

        #expect(await store.load("GET filter/search?a=1") == nil)
        #expect(await store.load("GET filter/10") == nil)
        #expect(await store.load("GET myself") != nil)
    }

    @Test("Expiring marks matching entries without deleting or backdating them")
    func expiresByPrefix() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = FileSystemCacheStore(directory: directory)
        await store.store(CacheEntry(key: "GET filter/10", data: Data("filter".utf8), etag: "\"v1\""))
        await store.store(CacheEntry(key: "GET myself", data: Data("me".utf8)))

        await store.expireAll(withPrefix: "GET filter")

        let filter = try #require(await store.load("GET filter/10"))
        #expect(filter.data == Data("filter".utf8))
        #expect(filter.etag == "\"v1\"")
        #expect(filter.expired)
        // `storedAt` — and so the age a UI would display — is untouched: only the freshness
        // *check* changes, not the truth about when this was last actually fetched.
        #expect(filter.age < 5)
        // Untouched: a different prefix, not marked expired.
        let me = try #require(await store.load("GET myself"))
        #expect(!me.expired)
    }

    @Test("Filenames stay short and safe even for long, punctuation-heavy keys")
    func producesSafeFilenames() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = FileSystemCacheStore(directory: directory)
        let key = "GET filter/search?" + (0..<50).map { "param\($0)=value/\($0)" }.joined(separator: "&")
        await store.store(CacheEntry(key: key, data: Data("{}".utf8)))

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let name = try #require(files.first)
        // Windows path limits make this a correctness concern, not a tidiness one.
        #expect(name.count < 120)
        #expect(!name.contains("/"))
        #expect(!name.contains("?"))
        #expect(await store.load(key) != nil)
    }

    @Test("A corrupt entry is discarded instead of failing the read")
    func discardsCorruptEntries() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = FileSystemCacheStore(directory: directory)
        await store.store(CacheEntry(key: "GET myself", data: Data("{}".utf8)))

        let file = try #require(
            try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first
        )
        try Data("not json at all".utf8).write(to: file)

        #expect(await store.load("GET myself") == nil)
    }

    @Test("Writing to an unwritable location degrades to a cache miss, not an error")
    func toleratesUnwritableDirectory() async throws {
        // A path under a file, which can never be a directory.
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("swira-not-a-dir-\(UUID().uuidString)")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let store = FileSystemCacheStore(directory: file.appendingPathComponent("cache"))
        await store.store(CacheEntry(key: "GET myself", data: Data("{}".utf8)))

        #expect(await store.load("GET myself") == nil)
    }
}
