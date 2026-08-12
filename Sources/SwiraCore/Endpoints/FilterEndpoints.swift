import Foundation

/// Criteria for `/filter/search`.
public struct FilterQuery: Sendable, Hashable {
    /// Matches filter names containing this text, case-insensitively.
    public var name: String?
    /// Restrict to filters owned by this account.
    public var ownerAccountId: String?
    /// Restrict to filters shared with this group.
    public var groupName: String?
    public var groupId: String?
    /// Restrict to filters shared with this project.
    public var projectId: Int?
    /// Restrict to these specific filter ids.
    public var ids: [String]
    public var orderBy: OrderBy?
    public var startAt: Int
    public var maxResults: Int
    /// Extra data to include. Several useful fields — notably `isWritable` — are absent otherwise.
    public var expand: [Expand]

    public enum OrderBy: String, Sendable, Hashable {
        case name
        case nameDescending = "-name"
        case favouriteCount
        case favouriteCountDescending = "-favourite_count"
        case owner
        case ownerDescending = "-owner"
        case id
        case idDescending = "-id"
    }

    public enum Expand: String, Sendable, Hashable, CaseIterable {
        case description
        case owner
        case jql
        case viewUrl
        case searchUrl
        case favourite
        case favouritedCount
        case sharePermissions
        case editPermissions
        case isWritable
        case subscriptions
    }

    public init(
        name: String? = nil,
        ownerAccountId: String? = nil,
        groupName: String? = nil,
        groupId: String? = nil,
        projectId: Int? = nil,
        ids: [String] = [],
        orderBy: OrderBy? = .name,
        startAt: Int = 0,
        maxResults: Int = 50,
        expand: [Expand] = Expand.allCases
    ) {
        self.name = name
        self.ownerAccountId = ownerAccountId
        self.groupName = groupName
        self.groupId = groupId
        self.projectId = projectId
        self.ids = ids
        self.orderBy = orderBy
        self.startAt = startAt
        self.maxResults = maxResults
        self.expand = expand
    }

    var queryItems: [URLQueryItem] {
        var items: [URLQueryItem] = []
        if let name { items.append(URLQueryItem(name: "filterName", value: name)) }
        if let ownerAccountId { items.append(URLQueryItem(name: "accountId", value: ownerAccountId)) }
        if let groupName { items.append(URLQueryItem(name: "groupname", value: groupName)) }
        if let groupId { items.append(URLQueryItem(name: "groupId", value: groupId)) }
        if let projectId { items.append(URLQueryItem(name: "projectId", value: String(projectId))) }
        for id in ids {
            items.append(URLQueryItem(name: "id", value: id))
        }
        if let orderBy { items.append(URLQueryItem(name: "orderBy", value: orderBy.rawValue)) }
        items.append(URLQueryItem(name: "startAt", value: String(startAt)))
        items.append(URLQueryItem(name: "maxResults", value: String(maxResults)))
        if !expand.isEmpty {
            items.append(
                URLQueryItem(name: "expand", value: expand.map(\.rawValue).joined(separator: ","))
            )
        }
        return items
    }
}

/// The body sent when creating or updating a filter.
public struct FilterInput: Sendable, Hashable, Codable {
    public var name: String
    public var jql: String
    public var description: String?
    public var favourite: Bool?
    public var sharePermissions: [SharePermissionInput]?
    public var editPermissions: [SharePermissionInput]?

    public init(
        name: String,
        jql: String,
        description: String? = nil,
        favourite: Bool? = nil,
        sharePermissions: [SharePermissionInput]? = nil,
        editPermissions: [SharePermissionInput]? = nil
    ) {
        self.name = name
        self.jql = jql
        self.description = description
        self.favourite = favourite
        self.sharePermissions = sharePermissions
        self.editPermissions = editPermissions
    }
}

/// Request descriptions for the filter endpoints.
///
/// Pure construction, no networking — which is what lets the URLs and parameters be asserted in
/// tests without a transport in sight.
public enum FilterEndpoints {
    private static let expandForSingleFilter =
        "description,owner,jql,viewUrl,searchUrl,favourite,favouritedCount,sharePermissions,editPermissions,isWritable,subscriptions"

    public static func search(_ query: FilterQuery) -> HTTPRequest {
        HTTPRequest(method: .get, path: "filter/search", queryItems: query.queryItems)
    }

    public static func get(id: String) -> HTTPRequest {
        HTTPRequest(
            method: .get,
            path: "filter/\(id)",
            queryItems: [URLQueryItem(name: "expand", value: expandForSingleFilter)]
        )
    }

    /// Filters owned by the authenticated user.
    public static func my(includeFavourites: Bool = true) -> HTTPRequest {
        HTTPRequest(
            method: .get,
            path: "filter/my",
            queryItems: [
                URLQueryItem(name: "includeFavourites", value: includeFavourites ? "true" : "false"),
                URLQueryItem(name: "expand", value: expandForSingleFilter),
            ]
        )
    }

    public static func favourites() -> HTTPRequest {
        HTTPRequest(
            method: .get,
            path: "filter/favourite",
            queryItems: [URLQueryItem(name: "expand", value: expandForSingleFilter)]
        )
    }

    public static func create() -> HTTPRequest {
        // Deliberately no `expand`: the create response carries the full filter either way —
        // verified byte-identical with and without it against a live Data Center instance.
        HTTPRequest(method: .post, path: "filter")
    }

    public static func update(id: String) -> HTTPRequest {
        HTTPRequest(
            method: .put,
            path: "filter/\(id)",
            queryItems: [URLQueryItem(name: "expand", value: expandForSingleFilter)]
        )
    }

    public static func delete(id: String) -> HTTPRequest {
        HTTPRequest(method: .delete, path: "filter/\(id)")
    }

    public static func setFavourite(id: String, _ favourite: Bool) -> HTTPRequest {
        HTTPRequest(
            method: favourite ? .put : .delete,
            path: "filter/\(id)/favourite",
            queryItems: [URLQueryItem(name: "expand", value: expandForSingleFilter)]
        )
    }

    public static func columns(id: String) -> HTTPRequest {
        HTTPRequest(method: .get, path: "filter/\(id)/columns")
    }

    /// Sets the filter's columns.
    ///
    /// Sets a filter's columns.
    ///
    /// The two deployments disagree, and neither documented shape is reliably usable:
    /// - **Data Center** wants `application/x-www-form-urlencoded` with `columns` repeated
    ///   per field, matching its docs. Sending JSON here gets a `400`.
    /// - **Cloud**'s docs say the same, but its edge unconditionally appends `;charset=UTF-8`
    ///   to *any* Content-Type before the request reaches the API — confirmed with `curl`,
    ///   independent of this client entirely — and the endpoint then rejects that charset
    ///   parameter with `415`, making the documented form-encoded shape unusable through any
    ///   HTTP client. Cloud accepts a JSON body (`{"columns": [...]}`) instead, which sidesteps
    ///   the broken content type outright; confirmed by round-tripping through `GET` on a live
    ///   filter.
    public static func setColumns(
        id: String,
        fieldIds: [String],
        deployment: JiraDeployment = .cloud
    ) -> HTTPRequest {
        switch deployment {
        case .cloud:
            return HTTPRequest(method: .put, path: "filter/\(id)/columns")
        case .dataCenter:
            let encoded = fieldIds
                .map { "columns=\(formEncode($0))" }
                .joined(separator: "&")
            return HTTPRequest(
                method: .put,
                path: "filter/\(id)/columns",
                headers: ["Content-Type": "application/x-www-form-urlencoded"],
                body: Data(encoded.utf8)
            )
        }
    }

    public static func resetColumns(id: String) -> HTTPRequest {
        HTTPRequest(method: .delete, path: "filter/\(id)/columns")
    }

    public static func permissions(id: String) -> HTTPRequest {
        HTTPRequest(method: .get, path: "filter/\(id)/permission")
    }

    public static func addPermission(id: String) -> HTTPRequest {
        HTTPRequest(method: .post, path: "filter/\(id)/permission")
    }

    public static func removePermission(id: String, permissionId: Int) -> HTTPRequest {
        HTTPRequest(method: .delete, path: "filter/\(id)/permission/\(permissionId)")
    }

    public static func defaultShareScope() -> HTTPRequest {
        HTTPRequest(method: .get, path: "filter/defaultShareScope")
    }

    public static func setDefaultShareScope() -> HTTPRequest {
        HTTPRequest(method: .put, path: "filter/defaultShareScope")
    }

    /// Percent-encodes for a form body, where a space is `+` and `+` must itself be escaped.
    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

/// The share scope applied to filters a user creates without choosing one.
public enum DefaultShareScope: String, Sendable, Hashable, Codable {
    case global = "GLOBAL"
    case authenticated = "AUTHENTICATED"
    case `private` = "PRIVATE"
}

struct DefaultShareScopeBody: Sendable, Codable {
    let scope: DefaultShareScope
}

/// The JSON body Cloud's columns endpoint actually accepts — see `FilterEndpoints.setColumns`.
struct SetColumnsBody: Sendable, Codable {
    let columns: [String]
}
