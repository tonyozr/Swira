import Foundation

/// Runs JQL and returns issues.
///
/// Exists so a filter can be previewed — "what does this query actually match?" — which is the
/// question that makes a filter editor useful rather than a text box over a string.
public actor SearchService {
    /// Fields worth showing in a preview list. `*navigable` would work but pulls far more data
    /// than a preview needs, and the response size is the slow part of this call.
    public static let previewFields = [
        "summary", "status", "issuetype", "priority", "assignee", "project", "updated",
    ]

    private let client: JiraClient
    private let deployment: JiraDeployment

    public init(client: JiraClient, deployment: JiraDeployment = .cloud) {
        self.client = client
        self.deployment = deployment
    }

    /// One page of issues matching `jql`.
    ///
    /// - Parameter pageToken: cursor from a previous page's `nextPageToken`; `nil` starts over.
    ///   Opaque to the caller on both deployments: a Jira Cloud cursor, or a synthesized offset
    ///   on Data Center. Treat it as a value to hand back, never to parse.
    public func search(
        jql: String,
        fields: [String] = previewFields,
        maxResults: Int = 50,
        pageToken: String? = nil,
        expand: String? = nil
    ) async throws -> TokenPage<JiraIssue> {
        switch deployment {
        case .cloud:
            let response: IssueSearchResponse = try await client.send(
                SearchEndpoints.search(),
                body: IssueSearchRequest(
                    jql: jql,
                    maxResults: maxResults,
                    fields: fields,
                    nextPageToken: pageToken,
                    expand: expand
                ),
                as: IssueSearchResponse.self
            )
            return response.page

        case .dataCenter:
            let response: LegacyIssueSearchResponse = try await client.send(
                SearchEndpoints.legacySearch(),
                body: LegacyIssueSearchRequest(
                    jql: jql,
                    startAt: pageToken.flatMap(Int.init) ?? 0,
                    maxResults: maxResults,
                    fields: fields
                ),
                as: LegacyIssueSearchResponse.self
            )
            return response.tokenPage
        }
    }

    /// Every issue matching `jql`, fetched lazily page by page.
    public nonisolated func all(
        jql: String,
        fields: [String] = previewFields,
        pageSize: Int = 100
    ) -> PagedSequence<JiraIssue> {
        PagedSequence { [self] cursor in
            var token: String?
            if case .token(let value) = cursor {
                token = value
            }
            // Both deployments flow through `search`, which already speaks the right dialect.
            let page = try await search(
                jql: jql,
                fields: fields,
                maxResults: pageSize,
                pageToken: token
            )
            return (page.values, page.nextPageToken.map { PageCursor.token($0) })
        }
    }

    /// Roughly how many issues match.
    ///
    /// Approximate by design on Cloud: the cursor-based search endpoint stopped returning an
    /// exact total, and `/search/approximate-count` is the only count offered. Present it as
    /// "about N", never as a figure to compute with. On Data Center the count comes from the
    /// legacy search's `total` and happens to be exact — but callers should not rely on that,
    /// or the same UI becomes subtly wrong on Cloud.
    public func approximateCount(jql: String) async throws -> Int {
        switch deployment {
        case .cloud:
            return try await client.send(
                SearchEndpoints.approximateCount(),
                body: ApproximateCountRequest(jql: jql),
                as: ApproximateCountResponse.self
            ).count

        case .dataCenter:
            // A zero-result search is the cheapest way to a total: no issue bodies travel.
            return try await client.send(
                SearchEndpoints.legacySearch(),
                body: LegacyIssueSearchRequest(jql: jql, startAt: 0, maxResults: 0, fields: []),
                as: LegacyIssueSearchResponse.self
            ).total
        }
    }

    /// Runs a saved filter and returns the first `limit` issues.
    ///
    /// Uses `filter = <id>` rather than the filter's own JQL, so the result reflects what Jira
    /// would show for the filter — including any clause the caller cannot see in the query text.
    public func preview(filterId: String, limit: Int = 25) async throws -> TokenPage<JiraIssue> {
        try await search(jql: "filter = \(filterId)", maxResults: limit)
    }

    /// Fetches specific issues by id or key.
    public func fetch(
        idsOrKeys: [String],
        fields: [String] = previewFields
    ) async throws -> [JiraIssue] {
        guard !idsOrKeys.isEmpty else { return [] }

        switch deployment {
        case .cloud:
            return try await client.send(
                SearchEndpoints.bulkFetch(),
                body: BulkFetchRequest(issueIdsOrKeys: idsOrKeys, fields: fields),
                as: BulkFetchResponse.self
            ).issues

        case .dataCenter:
            // No bulk-fetch endpoint; a JQL `in` clause is the one-round-trip equivalent.
            // JQL cannot mix ids and keys in one clause, so split by shape.
            let ids = idsOrKeys.filter { $0.allSatisfy(\.isNumber) }
            let keys = idsOrKeys.filter { !$0.allSatisfy(\.isNumber) }

            var issues: [JiraIssue] = []
            for (field, values) in [("id", ids), ("key", keys)] where !values.isEmpty {
                let jql = "\(field) in (\(values.joined(separator: ",")))"
                let page = try await search(jql: jql, fields: fields, maxResults: values.count)
                issues.append(contentsOf: page.values)
            }
            return issues
        }
    }
}
