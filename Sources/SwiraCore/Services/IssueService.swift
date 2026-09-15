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

    /// Sets a date field (e.g. `duedate` or a date custom field), or clears it when `value` is `nil` or empty.
    public func setDate(issueKey: String, fieldId: String, value: String?) async throws {
        let jsonValue: JSONValue
        if let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty {
            jsonValue = .string(value)
        } else {
            jsonValue = .null
        }
        try await updateFields(issueKey: issueKey, fields: [fieldId: jsonValue])
    }

    /// Sets time tracking estimates on an issue.
    ///
    /// Jira supports duration strings such as `"1d"`, `"2h 30m"`, `"1w"`.
    /// Passing `nil` leaves the respective estimate untouched; passing an empty string clears it.
    ///
    /// Identical quirk on both deployments: when only one of the two estimates is present in the
    /// `timetracking` payload, Jira itself (not this method) silently auto-adjusts the other one
    /// from the pair's prior ratio, rather than leaving it alone — see JRASERVER-30459 /
    /// JRACLOUD-67539. This method has no way to "leave the other one alone" on Jira's behalf: it
    /// only controls what's *in* the payload. A caller editing a single estimate must pass both
    /// here (the untouched one set to its current value) for Jira to have nothing left to
    /// auto-adjust — and that current value has to come from *somewhere*: `currentTimeTracking`
    /// below fetches it fresh from Jira right before the update, rather than trusting whatever a
    /// caller has cached client-side, which may predate the caller's own last load or may never
    /// have been fetched at all. See `WebAPI`'s `estimate` edit kind for the read-then-merge
    /// pattern this enables.
    public func setTimeTracking(
        issueKey: String,
        originalEstimate: String? = nil,
        remainingEstimate: String? = nil
    ) async throws {
        var timetracking: [String: JSONValue] = [:]
        if let originalEstimate {
            let trimmed = originalEstimate.trimmingCharacters(in: .whitespaces)
            timetracking["originalEstimate"] = trimmed.isEmpty ? .null : .string(trimmed)
        }
        if let remainingEstimate {
            let trimmed = remainingEstimate.trimmingCharacters(in: .whitespaces)
            timetracking["remainingEstimate"] = trimmed.isEmpty ? .null : .string(trimmed)
        }
        guard !timetracking.isEmpty else { return }
        try await updateFields(issueKey: issueKey, fields: ["timetracking": .object(timetracking)])
    }

    /// The issue's current original/remaining estimate, read fresh from Jira.
    ///
    /// Exists so a caller editing just one of the two estimates can learn the other's actual,
    /// up-to-date value immediately before calling `setTimeTracking` with both — see that
    /// method's doc comment for why relying on a client-cached value isn't good enough.
    public func currentTimeTracking(
        issueKey: String
    ) async throws -> (originalEstimate: String?, remainingEstimate: String?) {
        let response = try await client.send(
            IssueEndpoints.get(key: issueKey, fields: ["timetracking"]),
            as: TimeTrackingFieldResponse.self
        )
        return (response.fields.timetracking?.originalEstimate, response.fields.timetracking?.remainingEstimate)
    }

    /// The transitions currently available for this issue, given its status and workflow.
    public func transitions(
        issueKey: String,
        policy: CachePolicy = .default
    ) async throws -> Cached<[IssueTransition]> {
        try await client.sendCached(
            IssueEndpoints.transitions(key: issueKey),
            as: TransitionsResponse.self,
            policy: policy
        ).map(\.transitions)
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
        // The issue moved to a new status, so its available transitions changed too.
        await client.invalidateCache(prefix: "GET issue/\(issueKey)/transitions")
    }

    private func updateFields(issueKey: String, fields: [String: JSONValue]) async throws {
        _ = try await client.send(
            IssueEndpoints.update(key: issueKey),
            body: UpdateIssueFieldsRequest(fields: fields),
            as: Empty.self
        )
        // A field edit can itself change which transitions apply (workflow conditions keyed on
        // fields), so drop the cached list rather than risk offering one that no longer applies.
        await client.invalidateCache(prefix: "GET issue/\(issueKey)/transitions")
    }
}
