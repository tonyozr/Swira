import Foundation

/// A Jira issue, as returned by a search.
///
/// `fields` stays untyped on purpose: which fields exist depends on the project, the issue type,
/// and every custom field an admin has ever added, so no fixed model could cover it. The typed
/// accessors below handle the handful of fields every Jira site has.
public struct JiraIssue: Sendable, Hashable, Codable {
    public let id: String
    public let key: String
    public let fields: [String: JSONValue]

    public init(id: String, key: String, fields: [String: JSONValue] = [:]) {
        self.id = id
        self.key = key
        self.fields = fields
    }

    private enum CodingKeys: String, CodingKey {
        case id, key, fields
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        key = try container.decode(String.self, forKey: .key)
        fields = try container.decodeIfPresent([String: JSONValue].self, forKey: .fields) ?? [:]
    }
}

// MARK: - Common fields

extension JiraIssue {
    public var summary: String? {
        fields["summary"]?.stringValue
    }

    /// The status name, e.g. `In Progress`.
    public var status: String? {
        fields["status"]?["name"]?.stringValue
    }

    /// The status category key — `new`, `indeterminate`, or `done`.
    ///
    /// Prefer this over `status` when colouring or grouping: status *names* are configured per
    /// workflow and differ between projects, while the category keys are fixed by Jira.
    public var statusCategory: String? {
        fields["status"]?.path("statusCategory.key")?.stringValue
    }

    public var issueType: String? {
        fields["issuetype"]?["name"]?.stringValue
    }

    public var priority: String? {
        fields["priority"]?["name"]?.stringValue
    }

    public var projectKey: String? {
        fields["project"]?["key"]?.stringValue
    }

    /// The assignee, or `nil` when unassigned.
    public var assignee: JiraUser? {
        decodeUser(fields["assignee"])
    }

    public var reporter: JiraUser? {
        decodeUser(fields["reporter"])
    }

    public var labels: [String] {
        fields["labels"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    public var created: Date? {
        parseDate(fields["created"]?.stringValue)
    }

    public var updated: Date? {
        parseDate(fields["updated"]?.stringValue)
    }

    private func decodeUser(_ value: JSONValue?) -> JiraUser? {
        guard let value, !value.isNull, let accountId = value["accountId"]?.stringValue else {
            return nil
        }
        return JiraUser(
            accountId: accountId,
            displayName: value["displayName"]?.stringValue ?? accountId,
            emailAddress: value["emailAddress"]?.stringValue,
            active: value["active"]?.boolValue ?? true,
            avatarUrls: value["avatarUrls"]?.objectValue?.compactMapValues(\.stringValue)
        )
    }

    private func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        return JSONCoding.parseDate(raw)
    }
}
