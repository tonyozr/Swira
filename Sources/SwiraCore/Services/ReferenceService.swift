import Foundation

/// Lookup data: who you are, and the projects, fields, users, and groups you can pick from.
///
/// Everything here changes rarely, which is what makes it worth caching aggressively — see
/// `CachePolicy`. Without it, opening a share picker would re-fetch the whole site's field list.
public actor ReferenceService {
    private let client: JiraClient
    private let deployment: JiraDeployment

    public init(client: JiraClient, deployment: JiraDeployment = .cloud) {
        self.client = client
        self.deployment = deployment
    }

    /// The authenticated account.
    ///
    /// - Parameter policy: defaults to going to the network, because this doubles as the
    ///   credential check — answering it from cache would report success for a token Jira has
    ///   since rejected.
    public func currentUser(policy: CachePolicy = .networkOnly) async throws -> Cached<JiraUser> {
        try await client.sendCached(
            ReferenceEndpoints.currentUser(),
            as: JiraUser.self,
            policy: policy
        )
    }

    public func projects(
        matching query: String? = nil,
        startAt: Int = 0,
        maxResults: Int = 50,
        policy: CachePolicy = .reference
    ) async throws -> Cached<OffsetPage<JiraProject>> {
        switch deployment {
        case .cloud:
            return try await client.sendCached(
                ReferenceEndpoints.projects(query: query, startAt: startAt, maxResults: maxResults),
                as: OffsetPage<JiraProject>.self,
                policy: policy
            )

        case .dataCenter:
            // Server's `GET /project` is one flat, unpaginated array — so pagination and name
            // matching happen here, on the cached copy, keeping the public shape identical.
            let all = try await client.sendCached(
                ReferenceEndpoints.legacyProjects(),
                as: [JiraProject].self,
                policy: policy
            )
            return all.map { projects in
                let matching: [JiraProject]
                if let query, !query.isEmpty {
                    matching = projects.filter {
                        $0.name.localizedCaseInsensitiveContains(query)
                            || $0.key.localizedCaseInsensitiveContains(query)
                    }
                } else {
                    matching = projects
                }
                let page = Array(matching.dropFirst(startAt).prefix(maxResults))
                return OffsetPage(
                    values: page,
                    startAt: startAt,
                    maxResults: maxResults,
                    total: matching.count,
                    isLast: startAt + page.count >= matching.count
                )
            }
        }
    }

    /// Every project the user can see, fetched lazily page by page.
    public nonisolated func allProjects(matching query: String? = nil) -> PagedSequence<JiraProject> {
        PagedSequence { [self] cursor in
            var startAt = 0
            if case .offset(let value) = cursor {
                startAt = value
            }
            let page = try await projects(
                matching: query,
                startAt: startAt,
                policy: .networkOnly
            ).value
            return (page.values, page.hasMore ? .offset(page.nextStartAt) : nil)
        }
    }

    /// Every field defined on the site, built-in and custom.
    ///
    /// On a large site this response is big and almost never changes, which makes it the single
    /// best thing in the core to serve from cache.
    public func fields(policy: CachePolicy = .reference) async throws -> Cached<[JiraField]> {
        try await client.sendCached(
            ReferenceEndpoints.fields(),
            as: [JiraField].self,
            policy: policy
        )
    }

    /// Finds users by display name or email, for share pickers.
    ///
    /// Not cached: these run per keystroke against an ever-changing query, so a cache would fill
    /// with entries that are each used once.
    public func searchUsers(matching query: String, maxResults: Int = 50) async throws -> [JiraUser] {
        guard !query.isEmpty else { return [] }
        return try await client.send(
            ReferenceEndpoints.searchUsers(
                query: query,
                maxResults: maxResults,
                deployment: deployment
            ),
            as: [JiraUser].self
        )
    }

    /// Every priority defined on the site, for a priority picker.
    public func priorities(policy: CachePolicy = .reference) async throws -> Cached<[JiraPriority]> {
        try await client.sendCached(
            ReferenceEndpoints.priorities(),
            as: [JiraPriority].self,
            policy: policy
        )
    }

    /// Every version of a project, for a `fixVersions` (or `versions`) picker.
    public func projectVersions(
        projectIdOrKey: String,
        policy: CachePolicy = .reference
    ) async throws -> Cached<[JiraVersion]> {
        try await client.sendCached(
            ReferenceEndpoints.projectVersions(projectIdOrKey: projectIdOrKey),
            as: [JiraVersion].self,
            policy: policy
        )
    }

    public func searchGroups(matching query: String, maxResults: Int = 50) async throws -> [JiraGroup] {
        guard !query.isEmpty else { return [] }
        return try await client.send(
            ReferenceEndpoints.searchGroups(query: query, maxResults: maxResults),
            as: GroupPickerResponse.self
        ).groups
    }
}
