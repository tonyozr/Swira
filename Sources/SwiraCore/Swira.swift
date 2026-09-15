import Foundation
import Logging

/// The assembled core: one value that hands out every service, already wired together.
///
/// Clients construct this once and hold it. Nothing above it should have to know how a transport,
/// an auth provider, and a cache fit together.
public struct Swira: Sendable {
    public let configuration: SwiraConfiguration
    /// The credentials wired into every service call. Exposed alongside `configuration` for
    /// callers that need to authorize a request of their own outside the REST services here —
    /// e.g. `swira-web`'s Jira reverse proxy, which forwards arbitrary Jira paths rather than
    /// going through `JiraClient`.
    public let auth: AuthProvider
    /// The same on-disk cache every service reads and writes through `JiraClient`. Exposed
    /// alongside `auth` for the same reason: `swira-web`'s Jira reverse proxy caches its own
    /// (non-REST) responses so Split View still has something to show when Jira is unreachable,
    /// and sharing this store — rather than standing up a second one — keeps identity/reconcile
    /// handling (see `CacheIdentity`) in the one place that already does it.
    public let cache: CacheStore
    /// True when this instance never touches the network — set from `Swira.init(offline:)`.
    /// Exposed for the same reason as `auth`/`cache`: `swira-web`'s Jira reverse proxy needs to
    /// honor the same flag for Split View's embedded page, which bypasses `JiraClient` entirely.
    public let offline: Bool
    public let filters: FiltersService
    public let jql: JQLService
    public let search: SearchService
    public let reference: ReferenceService
    public let issue: IssueService

    private let client: JiraClient

    /// Assembles the core.
    ///
    /// - Parameters:
    ///   - transport: pass `nil` for the real one. Tests pass a stub; nothing else should.
    ///   - cache: pass `nil` for the on-disk cache, or `NullCacheStore()` to disable caching.
    ///   - offline: when true, every request fails as though the network were unreachable — see
    ///     `JiraClient.execute`. Cached reads still answer from whatever is already on disk;
    ///     writes and anything with no cached entry fail immediately, rather than genuinely
    ///     attempting (and timing out on) the network.
    public init(
        configuration: SwiraConfiguration,
        auth: AuthProvider,
        transport: HTTPTransport? = nil,
        cache: CacheStore? = nil,
        offline: Bool = false,
        logger: Logger = Logger(label: "swira")
    ) {
        let resolvedTransport = transport ?? RetryingTransport(
            wrapping: URLSessionTransport(configuration: configuration),
            maxRetries: configuration.maxRetries,
            logger: logger
        )

        // Only the default on-disk cache is reconciled: an explicitly supplied store (tests, a
        // memory cache, a caller's own store pointed elsewhere) is the caller's responsibility,
        // and this directory may not even be what it uses.
        if cache == nil {
            CacheIdentity.reconcile(
                directory: configuration.cacheDirectory,
                fingerprint: CacheIdentity.fingerprint(site: configuration.site, auth: auth)
            )
        }
        let resolvedCache = cache ?? SQLiteCacheStore(
            directory: configuration.cacheDirectory,
            logger: logger
        )
        let client = JiraClient(
            transport: resolvedTransport,
            auth: auth,
            cache: resolvedCache,
            offline: offline,
            logger: logger
        )

        // The deployment (Cloud vs Data Center) follows from the API version; services use it to
        // pick dialect-specific endpoints while keeping one public API.
        let deployment = configuration.site.deployment

        self.configuration = configuration
        self.auth = auth
        self.cache = resolvedCache
        self.offline = offline
        self.client = client
        self.filters = FiltersService(client: client, deployment: deployment)
        self.jql = JQLService(client: client, deployment: deployment)
        self.search = SearchService(client: client, deployment: deployment)
        self.reference = ReferenceService(client: client, deployment: deployment)
        self.issue = IssueService(client: client, deployment: deployment)
    }

    /// Builds the core from `JIRA_URL`, `JIRA_EMAIL`, and `JIRA_API_TOKEN`.
    ///
    /// See `SwiraConfiguration.fromEnvironment` for the full list of variables consulted.
    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment,
        transport: HTTPTransport? = nil,
        cache: CacheStore? = nil,
        offline: Bool = false
    ) throws -> Swira {
        let (configuration, auth) = try SwiraConfiguration.fromEnvironment(environment)
        return Swira(
            configuration: configuration,
            auth: auth,
            transport: transport,
            cache: cache,
            offline: offline
        )
    }

    /// Verifies the credentials work, returning the account they belong to.
    ///
    /// Bypasses the cache entirely — including the fall-back-to-cache-on-network-failure path the
    /// cached reads use. A cached answer would report success for a token Jira has since revoked,
    /// or with no network at all, and catching exactly that is this call's only job.
    @discardableResult
    public func verifyCredentials() async throws -> JiraUser {
        try await client.send(ReferenceEndpoints.currentUser(), as: JiraUser.self)
    }

    /// Empties the on-disk cache.
    public func clearCache() async {
        await client.clearCache()
    }

    /// Expires every cached response whose key starts with `prefix` (every one, if omitted),
    /// without deleting any of them — see `JiraClient.expireCache`. What a UI's "Refresh" action
    /// should call: it forces the next read of each one to genuinely check with the server, but
    /// never makes already-cached data disappear just because that check fails or is offline.
    public func expireCache(prefix: String = "") async {
        await client.expireCache(prefix: prefix)
    }
}
