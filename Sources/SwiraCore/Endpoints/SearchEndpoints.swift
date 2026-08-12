import Foundation

/// Request descriptions for issue search.
///
/// All of these are POST, including the read-only ones: the JQL of a real filter routinely
/// exceeds what a URL can carry, and Jira removed the GET variants along with the old
/// `/rest/api/3/search` endpoint.
public enum SearchEndpoints {
    public static func search() -> HTTPRequest {
        HTTPRequest(method: .post, path: "search/jql")
    }

    public static func approximateCount() -> HTTPRequest {
        HTTPRequest(method: .post, path: "search/approximate-count")
    }

    public static func bulkFetch() -> HTTPRequest {
        HTTPRequest(method: .post, path: "issue/bulkfetch")
    }

    /// The pre-cursor search endpoint, still the only one Server / Data Center has.
    public static func legacySearch() -> HTTPRequest {
        HTTPRequest(method: .post, path: "search")
    }
}

/// The body of a `/search/jql` request.
struct IssueSearchRequest: Encodable, Sendable {
    let jql: String
    let maxResults: Int
    /// Which fields to return. `["*navigable"]` mirrors what the Jira issue navigator shows.
    let fields: [String]
    /// Cursor from the previous page; `nil` for the first page.
    let nextPageToken: String?
    let expand: String?
}

/// The body of a `/search/approximate-count` request.
struct ApproximateCountRequest: Encodable, Sendable {
    let jql: String
}

struct ApproximateCountResponse: Decodable, Sendable {
    let count: Int
}

/// The `/search/jql` response.
///
/// Note the absence of `total`: the cursor-based endpoint that replaced `/search` does not count
/// matches, which is why `SearchService` exposes a separate approximate count.
struct IssueSearchResponse: Decodable, Sendable {
    let issues: [JiraIssue]
    let nextPageToken: String?
    let isLast: Bool?

    private enum CodingKeys: String, CodingKey {
        case issues, nextPageToken, isLast
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        issues = try container.decodeIfPresent([JiraIssue].self, forKey: .issues) ?? []
        nextPageToken = try container.decodeIfPresent(String.self, forKey: .nextPageToken)
        isLast = try container.decodeIfPresent(Bool.self, forKey: .isLast)
    }

    /// Jira sometimes sends `isLast: true` *and* a token. The flag wins — following the token
    /// past the end of the results yields an empty page at best and loops at worst.
    var page: TokenPage<JiraIssue> {
        TokenPage(values: issues, nextPageToken: isLast == true ? nil : nextPageToken)
    }
}

/// The body of a Data Center `POST /search` request — offset pagination, no cursor.
struct LegacyIssueSearchRequest: Encodable, Sendable {
    let jql: String
    let startAt: Int
    let maxResults: Int
    let fields: [String]
}

/// The Data Center `POST /search` response.
struct LegacyIssueSearchResponse: Decodable, Sendable {
    let issues: [JiraIssue]
    let startAt: Int
    let total: Int

    private enum CodingKeys: String, CodingKey {
        case issues, startAt, total
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        issues = try container.decodeIfPresent([JiraIssue].self, forKey: .issues) ?? []
        startAt = try container.decodeIfPresent(Int.self, forKey: .startAt) ?? 0
        total = try container.decodeIfPresent(Int.self, forKey: .total) ?? issues.count
    }

    /// Bridges offset pagination into the token shape the public API speaks.
    ///
    /// The synthesized token is simply the next offset as a string. Callers already treat tokens
    /// as opaque — which is exactly what lets one `SearchService` API cover both deployments.
    var tokenPage: TokenPage<JiraIssue> {
        let next = startAt + issues.count
        return TokenPage(
            values: issues,
            nextPageToken: next < total && !issues.isEmpty ? String(next) : nil
        )
    }
}

struct BulkFetchRequest: Encodable, Sendable {
    let issueIdsOrKeys: [String]
    let fields: [String]
}

struct BulkFetchResponse: Decodable, Sendable {
    let issues: [JiraIssue]
    let issueErrors: [JSONValue]?
}
