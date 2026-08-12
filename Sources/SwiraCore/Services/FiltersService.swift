import Foundation

/// Everything Swira can do with Jira filters.
///
/// This is the surface the Mac app, the CLI, and the WinUI client all drive; nothing above it
/// should need to know a REST path.
public actor FiltersService {
    private let client: JiraClient
    private let deployment: JiraDeployment

    public init(client: JiraClient, deployment: JiraDeployment = .cloud) {
        self.client = client
        self.deployment = deployment
    }

    /// Every cached filter response shares this key prefix, so one call drops them all.
    private static let cachePrefix = "GET filter"

    // MARK: - Reading

    /// One page of filters matching `query`.
    ///
    /// The result reports whether it came off the network, so a UI can say so rather than passing
    /// off cached data as current.
    public func search(
        _ query: FilterQuery = FilterQuery(),
        policy: CachePolicy = .default
    ) async throws -> Cached<OffsetPage<JiraFilter>> {
        switch deployment {
        case .cloud:
            return try await client.sendCached(
                FilterEndpoints.search(query),
                as: OffsetPage<JiraFilter>.self,
                policy: policy
            )

        case .dataCenter:
            // Server has no `filter/search`; favourites are the only listing it offers, so
            // "search" means filtering them client-side by name. Narrower than Cloud — filters
            // never favourited are invisible — but it is everything the deployment exposes.
            let favourites = try await favourites(policy: policy)
            return favourites.map { filters in
                let matching: [JiraFilter]
                if let name = query.name, !name.isEmpty {
                    matching = filters.filter {
                        $0.name.localizedCaseInsensitiveContains(name)
                    }
                } else {
                    matching = filters
                }
                return OffsetPage(
                    values: matching,
                    startAt: 0,
                    maxResults: matching.count,
                    total: matching.count,
                    isLast: true
                )
            }
        }
    }

    /// Every filter matching `query`, fetched lazily page by page.
    ///
    /// Prefer this over `search` when the caller wants the whole set: it keeps the page size and
    /// the offset bookkeeping out of the call site.
    /// Always goes to the network: a walk over every page is a deliberate full refresh, and mixing
    /// cached and live pages would produce a list that never existed on the server.
    ///
    /// `nonisolated` because it only builds a lazy sequence — nothing is fetched until the caller
    /// iterates, so hopping onto the actor first would buy nothing.
    public nonisolated func all(_ query: FilterQuery = FilterQuery()) -> PagedSequence<JiraFilter> {
        PagedSequence { [self] cursor in
            var query = query
            if case .offset(let startAt) = cursor {
                query.startAt = startAt
            }
            // Routed through `search` so the deployment dialect applies; `.networkOnly` keeps the
            // full walk an explicit refresh rather than a mix of cached and live pages.
            let page = try await search(query, policy: .networkOnly).value
            return (page.values, page.hasMore ? .offset(page.nextStartAt) : nil)
        }
    }

    public func get(id: String, policy: CachePolicy = .default) async throws -> Cached<JiraFilter> {
        try await client.sendCached(
            FilterEndpoints.get(id: id),
            as: JiraFilter.self,
            policy: policy
        )
    }

    /// Filters owned by the authenticated user.
    ///
    /// On Data Center — which has no `filter/my` — this returns favourites instead: the closest
    /// thing that deployment has to "my filters", and what its own UI shows in the sidebar.
    public func mine(
        includeFavourites: Bool = true,
        policy: CachePolicy = .default
    ) async throws -> Cached<[JiraFilter]> {
        switch deployment {
        case .cloud:
            return try await client.sendCached(
                FilterEndpoints.my(includeFavourites: includeFavourites),
                as: [JiraFilter].self,
                policy: policy
            )
        case .dataCenter:
            return try await favourites(policy: policy)
        }
    }

    public func favourites(policy: CachePolicy = .default) async throws -> Cached<[JiraFilter]> {
        try await client.sendCached(
            FilterEndpoints.favourites(),
            as: [JiraFilter].self,
            policy: policy
        )
    }

    // MARK: - Writing

    /// Creates a filter.
    ///
    /// Unless the input explicitly asks otherwise, `favourite` is decided by the shape of the
    /// name, stated outright rather than left to Jira's default so behaviour cannot drift
    /// between Cloud and Data Center:
    ///
    /// - A **standalone** name (no hierarchy separator) is created as a **favourite**. The
    ///   sidebar's Favourites section is the *only* place a plain-named filter is ever shown
    ///   (spec §2.1/§2.2) — creating one non-favourite would make it invisible immediately.
    /// - A **hierarchical** name (`Swira: Versions: Current`) is created **non-favourite**: it
    ///   is already visible in the filter tree by virtue of its name, and favouriting is a
    ///   separate, explicit choice there.
    public func create(_ input: FilterInput) async throws -> JiraFilter {
        var input = input
        if input.favourite == nil {
            input.favourite = FilterPath(name: input.name).isRoot
        }
        let created = try await client.send(
            FilterEndpoints.create(), body: input, as: JiraFilter.self
        )
        await invalidate()
        return created
    }

    /// Replaces the filter's definition.
    ///
    /// Jira treats this as a full replacement, not a merge: fields omitted from `input` are
    /// cleared. Callers editing one field should start from the current filter, not an empty input.
    public func update(id: String, _ input: FilterInput) async throws -> JiraFilter {
        let updated = try await client.send(
            FilterEndpoints.update(id: id), body: input, as: JiraFilter.self
        )
        await invalidate()
        return updated
    }

    public func delete(id: String) async throws {
        _ = try await client.send(FilterEndpoints.delete(id: id))
        await invalidate()
    }

    @discardableResult
    public func setFavourite(id: String, _ favourite: Bool) async throws -> JiraFilter {
        let filter = try await client.send(
            FilterEndpoints.setFavourite(id: id, favourite),
            as: JiraFilter.self
        )
        await invalidate()
        return filter
    }

    // MARK: - Columns

    public func columns(id: String) async throws -> [FilterColumn] {
        try await client.send(FilterEndpoints.columns(id: id), as: [FilterColumn].self)
    }

    /// Sets the columns shown for this filter, in order.
    ///
    /// - Parameter fieldIds: field ids such as `summary`, `status`, `customfield_10001` — the
    ///   `value` of a `FilterColumn`, not its `label`.
    public func setColumns(id: String, fieldIds: [String]) async throws {
        let request = FilterEndpoints.setColumns(id: id, fieldIds: fieldIds, deployment: deployment)
        switch deployment {
        case .cloud:
            // Cloud's request carries no body of its own (see FilterEndpoints.setColumns) —
            // attached here as JSON, the shape that endpoint actually accepts in practice.
            _ = try await client.send(request, body: SetColumnsBody(columns: fieldIds), as: Empty.self)
        case .dataCenter:
            _ = try await client.send(request)
        }
        await invalidate()
    }

    /// Clears the filter's columns, so results fall back to the user's default layout.
    public func resetColumns(id: String) async throws {
        _ = try await client.send(FilterEndpoints.resetColumns(id: id))
        await invalidate()
    }

    // MARK: - Sharing

    public func permissions(id: String) async throws -> [SharePermission] {
        try await client.send(FilterEndpoints.permissions(id: id), as: [SharePermission].self)
    }

    /// Adds a share. Returns the full share list as Jira now sees it.
    @discardableResult
    public func addPermission(
        id: String,
        _ permission: SharePermissionInput
    ) async throws -> [SharePermission] {
        let permissions = try await client.send(
            FilterEndpoints.addPermission(id: id),
            body: permission,
            as: [SharePermission].self
        )
        await invalidate()
        return permissions
    }

    public func removePermission(id: String, permissionId: Int) async throws {
        _ = try await client.send(
            FilterEndpoints.removePermission(id: id, permissionId: permissionId)
        )
        await invalidate()
    }

    /// The share scope applied to filters the user creates without picking one.
    public func defaultShareScope() async throws -> DefaultShareScope {
        try await client.send(
            FilterEndpoints.defaultShareScope(),
            as: DefaultShareScopeBody.self
        ).scope
    }

    @discardableResult
    public func setDefaultShareScope(_ scope: DefaultShareScope) async throws -> DefaultShareScope {
        try await client.send(
            FilterEndpoints.setDefaultShareScope(),
            body: DefaultShareScopeBody(scope: scope),
            as: DefaultShareScopeBody.self
        ).scope
    }

    // MARK: - Hierarchy

    /// The filter tree, reconstructed from the name-encoded hierarchy (see `FilterPath`).
    ///
    /// Built over the union of the user's own filters and their favourites — the same set a
    /// sidebar would show. Callers wanting a tree over a different set fetch it themselves and
    /// hand it to `FilterTree.build(from:)`, which is pure.
    public func tree(policy: CachePolicy = .default) async throws -> Cached<[FilterTreeNode]> {
        let own = try await mine(policy: policy)
        let starred = try await favourites(policy: policy)

        var seen = Set<String>()
        var combined: [JiraFilter] = []
        for filter in own.value + starred.value where seen.insert(filter.id).inserted {
            combined.append(filter)
        }

        // The result is only as fresh as its stalest ingredient, and only "network" if nothing
        // came from cache — anything else would let a UI mark a half-cached tree as live.
        return Cached(
            value: FilterTree.build(from: combined),
            origin: own.origin == .network && starred.origin == .network ? .network : .cache,
            storedAt: [own.storedAt, starred.storedAt].compactMap { $0 }.min(),
            isStale: own.isStale || starred.isStale
        )
    }

    /// Creates a filter at a position in the hierarchy.
    ///
    /// Purely a naming convenience: the filter is stored under the path's flat name
    /// (`Swira: Versions: Current`), which is all the hierarchy there is. Parent nodes need not
    /// exist — the tree materializes them as virtual nodes.
    public func create(
        at path: FilterPath,
        jql: String,
        description: String? = nil,
        sharePermissions: [SharePermissionInput]? = nil
    ) async throws -> JiraFilter {
        try await create(
            FilterInput(
                name: path.filterName,
                jql: jql,
                description: description,
                sharePermissions: sharePermissions
            )
        )
    }

    // MARK: - Cache

    /// Drops every cached filter response.
    ///
    /// Called after any mutation. Deliberately blunt: a change to one filter can move it in or out
    /// of any cached search page, and working out which pages is more expensive — and easier to get
    /// wrong — than simply refetching.
    private func invalidate() async {
        await client.invalidateCache(prefix: Self.cachePrefix)
    }
}
