import Foundation

/// A workflow transition Jira currently allows on a specific issue.
///
/// Which transitions are available depends on the issue's current status and its project's
/// workflow, which is exactly why status cannot be set like an ordinary field (`fields.status`
/// is read-only on `PUT /issue`) — Jira requires going through whichever transition the
/// workflow permits from where the issue is now.
public struct IssueTransition: Sendable, Hashable, Codable {
    public let id: String
    public let name: String
    /// The status this transition leads to, when Jira includes it.
    public let to: TargetStatus?

    public init(id: String, name: String, to: TargetStatus? = nil) {
        self.id = id
        self.name = name
        self.to = to
    }

    public struct TargetStatus: Sendable, Hashable, Codable {
        public let name: String?
        public let statusCategory: StatusCategoryRef?

        public init(name: String? = nil, statusCategory: StatusCategoryRef? = nil) {
            self.name = name
            self.statusCategory = statusCategory
        }

        public struct StatusCategoryRef: Sendable, Hashable, Codable {
            public let key: String?

            public init(key: String? = nil) {
                self.key = key
            }
        }
    }
}
