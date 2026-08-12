import Foundation

/// Writes to a single issue's fields, and drives it through its workflow.
///
/// Deliberately typed, purpose-built methods rather than a raw `[String: JSONValue]` passthrough:
/// Jira's wire shape for a field varies by field type (a plain string for text, a nested
/// `{"id": …}` for priority, a deployment-dependent shape for assignee), and a caller — the web
/// UI today, AppKit or WinUI later — should not have to know any of that to edit a cell.
///
/// Status is conspicuously absent from the setters here: Jira does not accept `fields.status` on
/// a plain update. Changing status means finding a workflow transition that leads there and
/// applying it — see `transitions(issueKey:)` and `transition(issueKey:transitionId:)`.
public actor IssueService {
    private let client: JiraClient
    private let deployment: JiraDeployment

    public init(client: JiraClient, deployment: JiraDeployment = .cloud) {
        self.client = client
        self.deployment = deployment
    }

    /// Sets a plain text field, e.g. `summary` or a text custom field.
    public func setText(issueKey: String, fieldId: String, value: String) async throws {
        try await updateFields(issueKey: issueKey, fields: [fieldId: .string(value)])
    }

    /// Sets a numeric field.
    public func setNumber(issueKey: String, fieldId: String, value: Double) async throws {
        try await updateFields(issueKey: issueKey, fields: [fieldId: .double(value)])
    }

    /// Sets the priority by id (from `ReferenceService.priorities()`).
    public func setPriority(issueKey: String, priorityId: String) async throws {
        try await updateFields(
            issueKey: issueKey,
            fields: ["priority": .object(["id": .string(priorityId)])]
        )
    }

    /// Sets the assignee, or clears it when `accountId` is `nil`.
    ///
    /// - Parameter accountId: despite the name, this is a Data Center *username* on that
    ///   deployment — callers get the right identifier for either case from
    ///   `JiraUser.accountId`, which already carries the deployment-appropriate value (see
    ///   `JiraUser`'s decoding fallback from `key`/`name`).
    public func setAssignee(issueKey: String, accountId: String?) async throws {
        let value: JSONValue
        if let accountId {
            let key = deployment == .cloud ? "accountId" : "name"
            value = .object([key: .string(accountId)])
        } else {
            value = .null
        }
        try await updateFields(issueKey: issueKey, fields: ["assignee": value])
    }

    /// Replaces the full label set. Jira has no "add one label" operation on a plain update, so
    /// the caller supplies the complete list they want the issue to end up with.
    public func setLabels(issueKey: String, labels: [String]) async throws {
        try await updateFields(
            issueKey: issueKey,
            fields: ["labels": .array(labels.map(JSONValue.string))]
        )
    }

    /// Replaces the full set of fix versions, by id — like `setLabels`, this is a full
    /// replacement, not an add/remove operation, since Jira's plain field update has no other
    /// mode. IDs, not names: `fixVersions` is validated against the project's actual versions,
    /// and an id is unambiguous where a name could collide across projects.
    public func setFixVersions(issueKey: String, versionIds: [String]) async throws {
        try await updateFields(
            issueKey: issueKey,
            fields: ["fixVersions": .array(versionIds.map { .object(["id": .string($0)]) })]
        )
    }

    /// The transitions currently available for this issue, given its status and workflow.
    public func transitions(issueKey: String) async throws -> [IssueTransition] {
        try await client.send(
            IssueEndpoints.transitions(key: issueKey),
            as: TransitionsResponse.self
        ).transitions
    }

    /// Applies a transition, moving the issue to whatever status it leads to.
    ///
    /// - Parameter transitionId: an id from `transitions(issueKey:)` — not a status id or name.
    ///   Jira validates this against the issue's current workflow state itself; an id that was
    ///   valid a moment ago can be rejected if something else changed the issue meanwhile.
    public func transition(issueKey: String, transitionId: String) async throws {
        _ = try await client.send(
            IssueEndpoints.transition(key: issueKey),
            body: TransitionRequest(transition: TransitionRequest.Ref(id: transitionId)),
            as: Empty.self
        )
    }

    private func updateFields(issueKey: String, fields: [String: JSONValue]) async throws {
        _ = try await client.send(
            IssueEndpoints.update(key: issueKey),
            body: UpdateIssueFieldsRequest(fields: fields),
            as: Empty.self
        )
    }
}
