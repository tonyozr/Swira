import Foundation

/// Request descriptions for writing to an issue: field updates and workflow transitions.
///
/// Identical on both deployments — unlike search and filters, the single-issue write API did
/// not change shape between Jira Server/Data Center and Cloud.
public enum IssueEndpoints {
    public static func update(key: String) -> HTTPRequest {
        HTTPRequest(method: .put, path: "issue/\(key)")
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
