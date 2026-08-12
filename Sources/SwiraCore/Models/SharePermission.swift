import Foundation

/// Who a filter is shared with.
///
/// Jira encodes this as a flat object with a `type` discriminator and a different nested payload
/// per type, so `Codable` is written by hand rather than synthesized.
public enum ShareScope: Sendable, Hashable {
    /// Visible to everyone, including anonymous users.
    case global
    /// Visible to any logged-in user. Jira v2 spells this `loggedin`.
    case authenticated
    /// Visible within a project, optionally narrowed to a single project role.
    case project(id: String, name: String?, roleId: String?, roleName: String?)
    /// Shared with a project the current user cannot see. Jira reports the share exists but
    /// withholds the project, so there is nothing to show beyond the fact of it.
    case projectUnknown
    case group(name: String?, groupId: String?)
    case user(accountId: String, displayName: String?)
    /// A type this version of Swira does not know about.
    ///
    /// Deliberately not an error: Atlassian adds share types over time, and one unrecognized
    /// entry must not make an otherwise readable filter undecodable.
    case unknown(String)

    /// The wire value of the `type` discriminator.
    public var typeName: String {
        switch self {
        case .global: return "global"
        case .authenticated: return "authenticated"
        case .project: return "project"
        case .projectUnknown: return "projectUnknown"
        case .group: return "group"
        case .user: return "user"
        case .unknown(let raw): return raw
        }
    }

    /// A short label for lists and summaries.
    public var displayName: String {
        switch self {
        case .global: return "Public"
        case .authenticated: return "Any logged-in user"
        case .project(_, let name, _, let roleName):
            let project = name ?? "project"
            return roleName.map { "\(project) (\($0))" } ?? project
        case .projectUnknown: return "A project you cannot see"
        case .group(let name, let groupId): return name ?? groupId ?? "group"
        case .user(let accountId, let displayName): return displayName ?? accountId
        case .unknown(let raw): return raw
        }
    }
}

/// A share entry as Jira returns it, with the server-assigned identifier used to delete it.
public struct SharePermission: Sendable, Hashable, Codable {
    /// Absent on shares that have not been persisted yet.
    public let id: Int?
    public let scope: ShareScope

    public init(id: Int? = nil, scope: ShareScope) {
        self.id = id
        self.scope = scope
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, project, role, group, user
    }

    private struct ProjectPayload: Codable {
        let id: String?
        let key: String?
        let name: String?
    }

    private struct RolePayload: Codable {
        let id: String?
        let name: String?
    }

    private struct GroupPayload: Codable {
        let name: String?
        let groupId: String?
    }

    private struct UserPayload: Codable {
        let accountId: String?
        let displayName: String?
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int.self, forKey: .id)

        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "global":
            scope = .global
        // Jira v2 says `loggedin`, v3 says `authenticated`; both mean the same thing, and a
        // client that understands only one of them breaks on the other deployment.
        case "authenticated", "loggedin":
            scope = .authenticated
        case "project":
            let project = try container.decodeIfPresent(ProjectPayload.self, forKey: .project)
            let role = try container.decodeIfPresent(RolePayload.self, forKey: .role)
            guard let projectId = project?.id else {
                // A `project` share whose project is withheld — the caller lacks browse permission.
                scope = .projectUnknown
                return
            }
            scope = .project(
                id: projectId,
                name: project?.name ?? project?.key,
                roleId: role?.id,
                roleName: role?.name
            )
        case "projectUnknown":
            scope = .projectUnknown
        case "group":
            let group = try container.decodeIfPresent(GroupPayload.self, forKey: .group)
            scope = .group(name: group?.name, groupId: group?.groupId)
        case "user":
            let user = try container.decodeIfPresent(UserPayload.self, forKey: .user)
            scope = .user(accountId: user?.accountId ?? "", displayName: user?.displayName)
        default:
            scope = .unknown(type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encode(scope.typeName, forKey: .type)

        switch scope {
        case .project(let id, let name, let roleId, let roleName):
            try container.encode(ProjectPayload(id: id, key: nil, name: name), forKey: .project)
            if let roleId {
                try container.encode(RolePayload(id: roleId, name: roleName), forKey: .role)
            }
        case .group(let name, let groupId):
            try container.encode(GroupPayload(name: name, groupId: groupId), forKey: .group)
        case .user(let accountId, let displayName):
            try container.encode(
                UserPayload(accountId: accountId, displayName: displayName),
                forKey: .user
            )
        case .global, .authenticated, .projectUnknown, .unknown:
            break
        }
    }
}

/// A share to be created.
///
/// A separate type from `SharePermission` because Jira reads and writes shares in different
/// shapes: it returns nested objects (`"group": {"name": …}`) but accepts flat keys
/// (`"groupname": …`). Reusing one type here would silently produce requests Jira rejects.
public struct SharePermissionInput: Sendable, Hashable, Codable {
    public let type: String
    public let projectId: String?
    public let projectRoleId: String?
    public let groupname: String?
    public let groupId: String?
    public let accountId: String?

    private init(
        type: String,
        projectId: String? = nil,
        projectRoleId: String? = nil,
        groupname: String? = nil,
        groupId: String? = nil,
        accountId: String? = nil
    ) {
        self.type = type
        self.projectId = projectId
        self.projectRoleId = projectRoleId
        self.groupname = groupname
        self.groupId = groupId
        self.accountId = accountId
    }

    public static let global = SharePermissionInput(type: "global")
    public static let authenticated = SharePermissionInput(type: "authenticated")

    public static func project(id: String, roleId: String? = nil) -> SharePermissionInput {
        SharePermissionInput(type: "project", projectId: id, projectRoleId: roleId)
    }

    /// Prefer `groupId`: group names are mutable in Jira Cloud, group ids are not.
    public static func group(name: String? = nil, groupId: String? = nil) -> SharePermissionInput {
        SharePermissionInput(type: "group", groupname: name, groupId: groupId)
    }

    public static func user(accountId: String) -> SharePermissionInput {
        SharePermissionInput(type: "user", accountId: accountId)
    }
}
