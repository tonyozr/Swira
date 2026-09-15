import Foundation

/// Request descriptions for writing to an issue: field updates and workflow transitions.
///
/// Identical on both deployments — unlike search and filters, the single-issue write API did
/// not change shape between Jira Server/Data Center and Cloud.
public enum IssueEndpoints {
    public static func update(key: String) -> HTTPRequest {
        HTTPRequest(method: .put, path: "issue/\(key)")
    }

    /// Fetches a narrow slice of an issue's fields — used to read a field's *current* server
    /// value immediately before a partial update, rather than trusting whatever a caller happens
    /// to have cached client-side (which may predate the caller's own last load, or may never
    /// have been fetched at all if the field wasn't previously requested).
    public static func get(key: String, fields: [String]) -> HTTPRequest {
        HTTPRequest(method: .get, path: "issue/\(key)", queryItems: [
            URLQueryItem(name: "fields", value: fields.joined(separator: ","))
        ])
    }

    /// The transitions currently available for this issue — which depends on its current
    /// status and its project's workflow, not a fixed list.
    public static func transitions(key: String) -> HTTPRequest {
        HTTPRequest(method: .get, path: "issue/\(key)/transitions")
    }

    public static func transition(key: String) -> HTTPRequest {
        HTTPRequest(method: .post, path: "issue/\(key)/transitions")
    }
}

/// The body of a `PUT /issue/{key}` request: a partial set of fields to overwrite.
///
/// Unlike `FilterInput`, this is never a full replacement — Jira applies only the keys present
/// here and leaves every other field untouched, which is what makes single-cell edits safe.
struct UpdateIssueFieldsRequest: Encodable, Sendable {
    let fields: [String: JSONValue]
}

struct TransitionsResponse: Decodable, Sendable {
    let transitions: [IssueTransition]
}

struct TransitionRequest: Encodable, Sendable {
    struct Ref: Encodable, Sendable {
        let id: String
    }
    let transition: Ref
}

/// The narrow response shape for `IssueEndpoints.get(key:fields: ["timetracking"])` — only what
/// `IssueService.currentTimeTracking(issueKey:)` needs, not a full issue decode.
struct TimeTrackingFieldResponse: Decodable, Sendable {
    struct Fields: Decodable, Sendable {
        let timetracking: TimeTracking?
    }
    struct TimeTracking: Decodable, Sendable {
        let originalEstimate: String?
        let remainingEstimate: String?
    }
    let fields: Fields
}
