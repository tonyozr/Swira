import Foundation
import Testing

@testable import SwiraCore

/// Mirrors `FileSystemCacheStoreTests` — same contract (`CacheStore`), same test shapes, so any
/// behavioral difference between the two backends shows up as an obvious asymmetry between the
/// two suites rather than something only one of them happens to check.
@Suite("SQLiteCacheStore")
struct SQLiteCacheStoreTests {
    private func makeTemporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("swira-sqlite-tests-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("Entries survive a round trip through SQLite")
    func storesAndLoads() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SQLiteCacheStore(directory: directory)
        let entry = CacheEntry(key: "GET filter/10", data: Data("{}".utf8), etag: "\"v1\"")
        await store.store(entry)

        let loaded = try #require(await store.load("GET filter/10"))
        #expect(loaded.data == entry.data)
        #expect(loaded.etag == "\"v1\"")
        #expect(await store.load("GET filter/11") == nil)
    }

    @Test("Storing under an existing key overwrites it, not duplicates it")
    func overwritesExistingKey() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SQLiteCacheStore(directory: directory)
        await store.store(CacheEntry(key: "GET myself", data: Data("first".utf8)))
        await store.store(CacheEntry(key: "GET myself", data: Data("second".utf8), etag: "\"v2\""))

        let loaded = try #require(await store.load("GET myself"))
        #expect(loaded.data == Data("second".utf8))
        #expect(loaded.etag == "\"v2\"")
    }

    @Test("Prefix removal drops a family of entries and leaves the rest")
    func removesByPrefix() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SQLiteCacheStore(directory: directory)
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

        let store = SQLiteCacheStore(directory: directory)
        await store.store(CacheEntry(key: "GET filter/10", data: Data("filter".utf8), etag: "\"v1\""))
        await store.store(CacheEntry(key: "GET myself", data: Data("me".utf8)))

        await store.expireAll(withPrefix: "GET filter")

        let filter = try #require(await store.load("GET filter/10"))
        #expect(filter.data == Data("filter".utf8))
        #expect(filter.etag == "\"v1\"")
        #expect(filter.expired)
        #expect(filter.age < 5)
        let me = try #require(await store.load("GET myself"))
        #expect(!me.expired)
    }

    @Test("Expiring with no prefix marks everything")
    func expiresEverything() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SQLiteCacheStore(directory: directory)
        await store.store(CacheEntry(key: "GET a", data: Data("1".utf8)))
        await store.store(CacheEntry(key: "GET b", data: Data("2".utf8)))

        await store.expireAll()

        #expect(try #require(await store.load("GET a")).expired)
        #expect(try #require(await store.load("GET b")).expired)
    }

    @Test("remove drops exactly the one entry named")
    func removesSingleEntry() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SQLiteCacheStore(directory: directory)
        await store.store(CacheEntry(key: "GET a", data: Data("1".utf8)))
        await store.store(CacheEntry(key: "GET b", data: Data("2".utf8)))

        await store.remove("GET a")

        #expect(await store.load("GET a") == nil)
        #expect(await store.load("GET b") != nil)
    }

    @Test("clear empties every entry")
    func clearsEverything() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SQLiteCacheStore(directory: directory)
        await store.store(CacheEntry(key: "GET a", data: Data("1".utf8)))
        await store.store(CacheEntry(key: "GET b", data: Data("2".utf8)))

        await store.clear()

        #expect(await store.load("GET a") == nil)
        #expect(await store.load("GET b") == nil)
    }

    @Test("A new store pointed at the same directory sees what an earlier one wrote")
    func persistsAcrossInstances() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        await SQLiteCacheStore(directory: directory)
            .store(CacheEntry(key: "GET myself", data: Data("{}".utf8), etag: "\"v1\""))

        // A fresh instance — as a new process launch would create — opens the same database file
        // rather than a stale in-memory copy.
        let reopened = SQLiteCacheStore(directory: directory)
        let loaded = try #require(await reopened.load("GET myself"))
        #expect(loaded.etag == "\"v1\"")
    }

    @Test("An entry with an empty body round-trips without crashing")
    func handlesEmptyBody() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SQLiteCacheStore(directory: directory)
        await store.store(CacheEntry(key: "GET empty", data: Data()))

        let loaded = try #require(await store.load("GET empty"))
        #expect(loaded.data.isEmpty)
    }

    @Test("Binary data with embedded nulls survives intact")
    func handlesBinaryData() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SQLiteCacheStore(directory: directory)
        let bytes = Data([0x00, 0xFF, 0x00, 0x41, 0x00, 0xFE])
        await store.store(CacheEntry(key: "GET bin", data: bytes))

        let loaded = try #require(await store.load("GET bin"))
        #expect(loaded.data == bytes)
    }

    @Test("Writing to an unwritable location degrades to a cache miss, not a crash")
    func toleratesUnwritableDirectory() async throws {
        // A path under a file, which can never be a directory.
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("swira-sqlite-not-a-dir-\(UUID().uuidString)")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let store = SQLiteCacheStore(directory: file.appendingPathComponent("cache"))
        await store.store(CacheEntry(key: "GET myself", data: Data("{}".utf8)))

        #expect(await store.load("GET myself") == nil)
    }

    @Test("Conforms to CacheStore and drops in wherever the protocol is expected")
    func usableThroughTheProtocol() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store: CacheStore = SQLiteCacheStore(directory: directory)
        await store.store(CacheEntry(key: "GET x", data: Data("1".utf8)))
        #expect(await store.load("GET x")?.data == Data("1".utf8))
    }
}
