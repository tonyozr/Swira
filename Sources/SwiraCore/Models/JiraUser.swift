import Foundation

/// A Jira account.
///
/// `accountId` is the only stable identifier in Jira Cloud — usernames are gone, and
/// `emailAddress` is absent unless the account's privacy settings expose it, so neither can be
/// relied on for identity.
public struct JiraUser: Sendable, Hashable, Codable {
    /// The account's stable identifier.
    ///
    /// On Jira Cloud this is the `accountId`. Jira Server / Data Center predates account ids and
    /// identifies users by `key` (stable) or `name` (the login); decoding falls back through those
    /// in that order, so this property is always populated on either deployment.
    public let accountId: String
    public let displayName: String
    public let emailAddress: String?
    public let active: Bool
    public let accountType: String?
    public let timeZone: String?
    public let avatarUrls: [String: String]?

    public init(
        accountId: String,
        displayName: String,
        emailAddress: String? = nil,
        active: Bool = true,
        accountType: String? = nil,
        timeZone: String? = nil,
        avatarUrls: [String: String]? = nil
    ) {
        self.accountId = accountId
        self.displayName = displayName
        self.emailAddress = emailAddress
        self.active = active
        self.accountType = accountType
        self.timeZone = timeZone
        self.avatarUrls = avatarUrls
    }

    private enum CodingKeys: String, CodingKey {
        case accountId, displayName, emailAddress, active, accountType, timeZone, avatarUrls
        case key, name
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let accountId = try container.decodeIfPresent(String.self, forKey: .accountId) {
            self.accountId = accountId
        } else if let key = try container.decodeIfPresent(String.self, forKey: .key) {
            self.accountId = key
        } else {
            self.accountId = try container.decode(String.self, forKey: .name)
        }
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? accountId
        emailAddress = try container.decodeIfPresent(String.self, forKey: .emailAddress)
        active = try container.decodeIfPresent(Bool.self, forKey: .active) ?? true
        accountType = try container.decodeIfPresent(String.self, forKey: .accountType)
        timeZone = try container.decodeIfPresent(String.self, forKey: .timeZone)
        avatarUrls = try container.decodeIfPresent([String: String].self, forKey: .avatarUrls)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accountId, forKey: .accountId)
        try container.encode(displayName, forKey: .displayName)
        try container.encodeIfPresent(emailAddress, forKey: .emailAddress)
        try container.encode(active, forKey: .active)
        try container.encodeIfPresent(accountType, forKey: .accountType)
        try container.encodeIfPresent(timeZone, forKey: .timeZone)
        try container.encodeIfPresent(avatarUrls, forKey: .avatarUrls)
    }
}
