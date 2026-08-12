import Foundation
import Testing

@testable import SwiraCore

@Suite("Auth provider identity fingerprints")
struct AuthIdentityFingerprintTests {
    @Test("Identical credentials fingerprint identically")
    func sameCredentialsMatch() {
        let a = BasicAuthProvider(email: "mia@example.com", apiToken: Secret("t1"))
        let b = BasicAuthProvider(email: "mia@example.com", apiToken: Secret("t1"))
        #expect(a.identityFingerprint == b.identityFingerprint)
    }

    @Test("A different email, or a different token, changes the fingerprint")
    func differingCredentialsDiffer() {
        let base = BasicAuthProvider(email: "mia@example.com", apiToken: Secret("t1"))
        let differentEmail = BasicAuthProvider(email: "other@example.com", apiToken: Secret("t1"))
        let differentToken = BasicAuthProvider(email: "mia@example.com", apiToken: Secret("t2"))

        #expect(base.identityFingerprint != differentEmail.identityFingerprint)
        #expect(base.identityFingerprint != differentToken.identityFingerprint)
    }

    @Test("Bearer and Basic never collide, even carrying the same secret")
    func schemesDoNotCollide() {
        let basic = BasicAuthProvider(email: "x", apiToken: Secret("shared"))
        let bearer = BearerAuthProvider(token: Secret("shared"))
        #expect(basic.identityFingerprint != bearer.identityFingerprint)
    }

    @Test("The fingerprint never contains the raw secret")
    func fingerprintDoesNotLeakSecret() {
        let auth = BasicAuthProvider(email: "mia@example.com", apiToken: Secret("super-secret-token"))
        #expect(!auth.identityFingerprint.contains("super-secret-token"))

        let bearer = BearerAuthProvider(token: Secret("another-secret"))
        #expect(!bearer.identityFingerprint.contains("another-secret"))
    }
}

@Suite("CacheIdentity")
struct CacheIdentityTests {
    private func makeTemporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("swira-identity-tests-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("A directory with no prior record is wiped defensively, not trusted by default")
    func firstRunClearsUnattributedEntries() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Simulates leftover entries from before this mechanism existed, or from manual tinkering.
        let leftover = directory.appendingPathComponent("some-old-entry.json")
        try Data("{}".utf8).write(to: leftover)

        CacheIdentity.reconcile(directory: directory, fingerprint: "site-a|3|basic:abc")

        #expect(!FileManager.default.fileExists(atPath: leftover.path))
        let marker = try String(
            contentsOf: directory.appendingPathComponent(".identity"), encoding: .utf8
        )
        #expect(marker == "site-a|3|basic:abc")
    }

    @Test("The same identity across runs leaves entries untouched")
    func sameIdentityPreservesEntries() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        CacheIdentity.reconcile(directory: directory, fingerprint: "site-a|3|basic:abc")
        let entry = directory.appendingPathComponent("filter-search.json")
        try Data(#"{"kept":true}"#.utf8).write(to: entry)

        CacheIdentity.reconcile(directory: directory, fingerprint: "site-a|3|basic:abc")

        #expect(FileManager.default.fileExists(atPath: entry.path))
    }

    @Test("A changed identity wipes every prior entry before recording the new one")
    func changedIdentityClearsEntries() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        CacheIdentity.reconcile(directory: directory, fingerprint: "site-a|3|basic:abc")
        let entry = directory.appendingPathComponent("filter-search.json")
        try Data(#"{"account":"a"}"#.utf8).write(to: entry)

        // The account switched — the DC-to-Cloud scenario this feature exists for.
        CacheIdentity.reconcile(directory: directory, fingerprint: "site-b|2|bearer:xyz")

        #expect(!FileManager.default.fileExists(atPath: entry.path))
        let marker = try String(
            contentsOf: directory.appendingPathComponent(".identity"), encoding: .utf8
        )
        #expect(marker == "site-b|2|bearer:xyz")
    }
}

@Suite("Swira facade cache isolation")
struct SwiraCacheIsolationTests {
    private func makeTemporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("swira-facade-cache-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("Constructing Swira for a different account clears what the previous account cached")
    func accountSwitchInvalidatesDiskCache() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let site = try JiraSite(urlString: "https://example.atlassian.net")

        // Account A runs, and something ends up cached on disk under its identity.
        _ = Swira(
            configuration: SwiraConfiguration(site: site, cacheDirectory: directory),
            auth: BasicAuthProvider(email: "a@example.com", apiToken: Secret("token-a")),
            transport: MockTransport(stubs: [])
        )
        let diskCache = FileSystemCacheStore(directory: directory)
        await diskCache.store(CacheEntry(key: "GET filter/favourite", data: Data("[]".utf8)))
        #expect(await diskCache.load("GET filter/favourite") != nil)

        // Account B configures Swira against the same on-disk cache directory.
        _ = Swira(
            configuration: SwiraConfiguration(site: site, cacheDirectory: directory),
            auth: BasicAuthProvider(email: "b@example.com", apiToken: Secret("token-b")),
            transport: MockTransport(stubs: [])
        )

        // Account A's cached favourites must not leak into account B's session.
        #expect(await diskCache.load("GET filter/favourite") == nil)
    }

    @Test("Re-running with the same account leaves its cache in place")
    func sameAccountKeepsCache() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let site = try JiraSite(urlString: "https://example.atlassian.net")
        let auth = BasicAuthProvider(email: "a@example.com", apiToken: Secret("token-a"))

        _ = Swira(
            configuration: SwiraConfiguration(site: site, cacheDirectory: directory),
            auth: auth,
            transport: MockTransport(stubs: [])
        )
        let diskCache = FileSystemCacheStore(directory: directory)
        await diskCache.store(CacheEntry(key: "GET filter/favourite", data: Data("[]".utf8)))

        _ = Swira(
            configuration: SwiraConfiguration(site: site, cacheDirectory: directory),
            auth: auth,
            transport: MockTransport(stubs: [])
        )

        #expect(await diskCache.load("GET filter/favourite") != nil)
    }

    @Test("An explicitly supplied cache is never touched by reconciliation")
    func explicitCacheIsUntouched() async throws {
        let site = try JiraSite(urlString: "https://example.atlassian.net")
        let memoryCache = MemoryCacheStore()
        await memoryCache.store(CacheEntry(key: "GET filter/favourite", data: Data("[]".utf8)))

        _ = Swira(
            configuration: SwiraConfiguration(site: site),
            auth: BasicAuthProvider(email: "different@example.com", apiToken: Secret("t")),
            transport: MockTransport(stubs: []),
            cache: memoryCache
        )

        #expect(await memoryCache.load("GET filter/favourite") != nil)
    }
}
