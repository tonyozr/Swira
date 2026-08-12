import Foundation

/// Request descriptions for the lookup data a filter editor needs: projects, fields, users, groups.
public enum ReferenceEndpoints {
    public static func currentUser() -> HTTPRequest {
        HTTPRequest(method: .get, path: "myself")
    }

    public static func projects(
        query: String? = nil,
        startAt: Int = 0,
        maxResults: Int = 50
    ) -> HTTPRequest {
        var queryItems = [
            URLQueryItem(name: "startAt", value: String(startAt)),
            URLQueryItem(name: "maxResults", value: String(maxResults)),
            URLQueryItem(name: "orderBy", value: "name"),
        ]
        if let query, !query.isEmpty {
            queryItems.append(URLQueryItem(name: "query", value: query))
        }
        return HTTPRequest(method: .get, path: "project/search", queryItems: queryItems)
    }

    /// Every project, as Server / Data Center serves it: one bare, unpaginated array.
    public static func legacyProjects() -> HTTPRequest {
        HTTPRequest(method: .get, path: "project")
    }

    /// Every field on the site. Not paginated — Jira returns the lot in one response.
    public static func fields() -> HTTPRequest {
        HTTPRequest(method: .get, path: "field")
    }

    /// User search. Same path on both deployments; only the parameter name differs —
    /// `query` on Cloud, `username` on Server / Data Center.
    public static func searchUsers(
        query: String,
        maxResults: Int = 50,
        deployment: JiraDeployment = .cloud
    ) -> HTTPRequest {
        HTTPRequest(
            method: .get,
            path: "user/search",
            queryItems: [
                URLQueryItem(
                    name: deployment == .cloud ? "query" : "username",
                    value: query
                ),
                URLQueryItem(name: "maxResults", value: String(maxResults)),
            ]
        )
    }

    /// Every priority defined on the site. Not paginated, and — unlike fields, projects, and
    /// users — identical in shape on both deployments, so no dialect branching is needed here.
    public static func priorities() -> HTTPRequest {
        HTTPRequest(method: .get, path: "priority")
    }

    /// Every version of a project — the choices a `fixVersions` picker offers. A bare array,
    /// identical in shape on both deployments.
    public static func projectVersions(projectIdOrKey: String) -> HTTPRequest {
        HTTPRequest(method: .get, path: "project/\(projectIdOrKey)/versions")
    }

    public static func searchGroups(query: String, maxResults: Int = 50) -> HTTPRequest {
        HTTPRequest(
            method: .get,
            path: "groups/picker",
            queryItems: [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "maxResults", value: String(maxResults)),
            ]
        )
    }
}

/// The `/groups/picker` response, which nests the groups rather than returning a bare array.
struct GroupPickerResponse: Decodable, Sendable {
    let groups: [JiraGroup]
    let total: Int?
}
