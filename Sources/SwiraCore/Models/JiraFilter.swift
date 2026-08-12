import Foundation

/// A saved Jira filter.
public struct JiraFilter: Sendable, Hashable, Codable {
    public let id: String
    public let name: String
    public let description: String?
    public let owner: JiraUser?
    public let jql: String?
    /// Where a browser should open this filter. Jira builds it; Swira never assembles it by hand.
    public let viewUrl: String?
    public let searchUrl: String?
    public let favourite: Bool
    public let favouritedCount: Int?
    /// Who the filter is shared with. Empty means private to the owner.
    public let sharePermissions: [SharePermission]
    /// Who may edit it, which Jira tracks separately from who may see it.
    public let editPermissions: [SharePermission]
    /// Whether the authenticated user may modify this filter. Absent unless requested via expand.
    public let isWritable: Bool?
    public let subscriptions: [FilterSubscription]

    public init(
        id: String,
        name: String,
        description: String? = nil,
        owner: JiraUser? = nil,
        jql: String? = nil,
        viewUrl: String? = nil,
        searchUrl: String? = nil,
        favourite: Bool = false,
        favouritedCount: Int? = nil,
        sharePermissions: [SharePermission] = [],
        editPermissions: [SharePermission] = [],
        isWritable: Bool? = nil,
        subscriptions: [FilterSubscription] = []
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.owner = owner
        self.jql = jql
        self.viewUrl = viewUrl
        self.searchUrl = searchUrl
        self.favourite = favourite
        self.favouritedCount = favouritedCount
        self.sharePermissions = sharePermissions
        self.editPermissions = editPermissions
        self.isWritable = isWritable
        self.subscriptions = subscriptions
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, description, owner, jql, viewUrl, searchUrl
        case favourite, favouritedCount, sharePermissions, editPermissions
        case isWritable, subscriptions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        owner = try container.decodeIfPresent(JiraUser.self, forKey: .owner)
        jql = try container.decodeIfPresent(String.self, forKey: .jql)
        viewUrl = try container.decodeIfPresent(String.self, forKey: .viewUrl)
        searchUrl = try container.decodeIfPresent(String.self, forKey: .searchUrl)
        favourite = try container.decodeIfPresent(Bool.self, forKey: .favourite) ?? false
        favouritedCount = try container.decodeIfPresent(Int.self, forKey: .favouritedCount)
        sharePermissions = try container.decodeIfPresent(
            [SharePermission].self, forKey: .sharePermissions
        ) ?? []
        editPermissions = try container.decodeIfPresent(
            [SharePermission].self, forKey: .editPermissions
        ) ?? []
        isWritable = try container.decodeIfPresent(Bool.self, forKey: .isWritable)
        subscriptions = try container.decodeIfPresent(
            ListOrWrapped<FilterSubscription>.self, forKey: .subscriptions
        )?.items ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(owner, forKey: .owner)
        try container.encodeIfPresent(jql, forKey: .jql)
        try container.encodeIfPresent(viewUrl, forKey: .viewUrl)
        try container.encodeIfPresent(searchUrl, forKey: .searchUrl)
        try container.encode(favourite, forKey: .favourite)
        try container.encodeIfPresent(favouritedCount, forKey: .favouritedCount)
        try container.encode(sharePermissions, forKey: .sharePermissions)
        try container.encode(editPermissions, forKey: .editPermissions)
        try container.encodeIfPresent(isWritable, forKey: .isWritable)
        try container.encode(subscriptions, forKey: .subscriptions)
    }

    /// Whether anyone other than the owner can see this filter.
    public var isShared: Bool {
        !sharePermissions.isEmpty
    }
}

/// A field to display in a filter's result columns.
public struct FilterColumn: Sendable, Hashable, Codable {
    /// Human-readable name, e.g. `Summary`.
    public let label: String
    /// Field id used when setting columns, e.g. `summary` or `customfield_10001`.
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

/// An email subscription that delivers a filter's results on a schedule.
public struct FilterSubscription: Sendable, Hashable, Codable {
    public let id: Int?
    public let user: JiraUser?
    public let group: JiraGroup?

    public init(id: Int? = nil, user: JiraUser? = nil, group: JiraGroup? = nil) {
        self.id = id
        self.user = user
        self.group = group
    }
}

/// A Jira group.
public struct JiraGroup: Sendable, Hashable, Codable {
    public let name: String?
    /// Prefer this over `name` for identity: Jira Cloud group names can be renamed, ids cannot.
    public let groupId: String?

    public init(name: String? = nil, groupId: String? = nil) {
        self.name = name
        self.groupId = groupId
    }
}

/// Decodes a collection Jira sends either as a bare array or as `{"size": n, "items": [...]}`.
///
/// `subscriptions` and `sharedUsers` arrive in both shapes depending on the endpoint and the
/// deployment, and a client that assumes one of them fails on real instances.
struct ListOrWrapped<Item: Codable & Sendable>: Codable, Sendable {
    let items: [Item]

    private enum CodingKeys: String, CodingKey {
        case items
    }

    init(from decoder: Decoder) throws {
        if let array = try? [Item](from: decoder) {
            items = array
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([Item].self, forKey: .items) ?? []
    }

    func encode(to encoder: Encoder) throws {
        try items.encode(to: encoder)
    }
}
