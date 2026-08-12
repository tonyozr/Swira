import Foundation

/// A Jira project.
public struct JiraProject: Sendable, Hashable, Codable {
    public let id: String
    public let key: String
    public let name: String
    public let projectTypeKey: String?
    public let simplified: Bool?
    public let avatarUrls: [String: String]?

    public init(
        id: String,
        key: String,
        name: String,
        projectTypeKey: String? = nil,
        simplified: Bool? = nil,
        avatarUrls: [String: String]? = nil
    ) {
        self.id = id
        self.key = key
        self.name = name
        self.projectTypeKey = projectTypeKey
        self.simplified = simplified
        self.avatarUrls = avatarUrls
    }

    /// The numeric id, for endpoints that take `projectId` rather than a key.
    public var numericId: Int? {
        Int(id)
    }
}

/// A project version, e.g. a fix version — `2.1.0`.
public struct JiraVersion: Sendable, Hashable, Codable {
    public let id: String
    public let name: String
    public let released: Bool?
    public let archived: Bool?

    public init(id: String, name: String, released: Bool? = nil, archived: Bool? = nil) {
        self.id = id
        self.name = name
        self.released = released
        self.archived = archived
    }
}

/// A priority level, e.g. `High`.
public struct JiraPriority: Sendable, Hashable, Codable {
    public let id: String
    public let name: String
    public let iconUrl: String?

    public init(id: String, name: String, iconUrl: String? = nil) {
        self.id = id
        self.name = name
        self.iconUrl = iconUrl
    }
}

/// A field that can appear in an issue or a JQL clause.
public struct JiraField: Sendable, Hashable, Codable {
    /// Stable identifier, e.g. `summary` or `customfield_10001`.
    public let id: String
    public let name: String
    /// Whether this is a custom field rather than one built into Jira.
    public let custom: Bool
    public let searchable: Bool
    public let orderable: Bool
    public let navigable: Bool
    /// Names usable on the left-hand side of a JQL clause. A custom field usually has two: its
    /// display name and `cf[10001]`.
    public let clauseNames: [String]
    public let schema: JSONValue?

    private enum CodingKeys: String, CodingKey {
        case id, name, custom, searchable, orderable, navigable, clauseNames, schema
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
        custom = try container.decodeIfPresent(Bool.self, forKey: .custom) ?? false
        searchable = try container.decodeIfPresent(Bool.self, forKey: .searchable) ?? false
        orderable = try container.decodeIfPresent(Bool.self, forKey: .orderable) ?? false
        navigable = try container.decodeIfPresent(Bool.self, forKey: .navigable) ?? false
        clauseNames = try container.decodeIfPresent([String].self, forKey: .clauseNames) ?? []
        schema = try container.decodeIfPresent(JSONValue.self, forKey: .schema)
    }

    /// The field's data type, e.g. `string`, `user`, `datetime`.
    public var type: String? {
        schema?["type"]?.stringValue
    }
}
