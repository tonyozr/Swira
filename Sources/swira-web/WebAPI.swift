import Foundation
import SwiraCore

/// The JSON API the browser UI talks to.
///
/// The web client never speaks to Jira directly (see docs/CLIENT-SPEC.md §4): every route here
/// is a thin translation between HTTP and `SwiraCore` services.
struct WebAPI: Sendable {
    let swira: Swira?
    /// Why `swira` is nil, when it is — shown by the UI as a setup banner.
    let configurationError: String?

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    // MARK: - Routing

    func handle(_ request: HTTPServer.Request) async -> HTTPServer.Response {
        do {
            return try await route(request)
        } catch let error as SwiraError {
            return errorResponse(
                error.errorDescription ?? "Jira request failed",
                status: statusCode(for: error)
            )
        } catch let error as UnconfiguredError {
            return errorResponse(error.message, status: 424)
        } catch {
            return errorResponse("\(error)", status: 502)
        }
    }

    private func route(_ request: HTTPServer.Request) async throws -> HTTPServer.Response {
        let segments = request.path.split(separator: "/").map(String.init)
        let method = request.method

        if method == "GET", segments.isEmpty {
            return .html(WebUI.indexHTML)
        }

        if method == "GET", segments == ["api", "config"] {
            return try json(ConfigDTO(
                siteUrl: swira?.configuration.site.baseURL.absoluteString,
                deployment: swira.map {
                    $0.configuration.site.deployment == .cloud ? "cloud" : "dataCenter"
                },
                error: configurationError
            ))
        }

        if method == "GET", segments == ["api", "sidebar"] {
            let swira = try requireSwira()
            // The user's own request for freshness (the Refresh button, spec-driven necessity:
            // starring a filter in Jira's own UI has no way to signal this client to notice)
            // overrides the default TTL.
            let policy: CachePolicy = request.query["fresh"] == "1" ? .networkOnly : .default
            let favourites = try await swira.filters.favourites(policy: policy)
            let tree = try await swira.filters.tree(policy: policy)
            // The sidebar's tree section holds only name-structured filters (spec §2.2);
            // plain names live in Favourites alone.
            let structured = tree.value.filter { !$0.children.isEmpty || $0.path.segments.count > 1 }
            return try json(SidebarDTO(
                favourites: favourites.value.map(FilterDTO.init),
                tree: structured.map(NodeDTO.init),
                meta: MetaDTO(favourites)
            ))
        }

        if method == "GET", segments == ["api", "filters", "search"] {
            let swira = try requireSwira()
            let query = request.query["q"] ?? ""
            guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
                return try json([FilterRefDTO]())
            }
            // Used for two things: resolving an `filter = <id>` reference's display name, and
            // the picker that lets a user swap which filter a reference points to. Both want a
            // short list, quickly — never the full paginated search.
            let result = try await swira.filters.search(
                FilterQuery(name: query, maxResults: 8, expand: []),
                policy: .default
            )
            return try json(result.value.values.map { FilterRefDTO(id: $0.id, name: $0.name) })
        }

        if segments.count == 3, segments[0] == "api", segments[1] == "filter" {
            let id = segments[2]
            switch method {
            case "GET":
                let swira = try requireSwira()
                let filter = try await swira.filters.get(id: id)
                return try json(
                    FilterDetailDTO(filter: FilterDTO(filter.value), meta: MetaDTO(filter))
                )
            case "DELETE":
                let swira = try requireSwira()
                try await swira.filters.delete(id: id)
                return .json(Data("{}".utf8))
            default:
                return .notFound()
            }
        }

        if method == "GET", segments.count == 4,
           segments[0] == "api", segments[1] == "filter", segments[3] == "issues" {
            let id = segments[2]
            let swira = try requireSwira()
            let limit = request.query["limit"].flatMap(Int.init) ?? 50

            let resolvedColumns = try await resolveColumns(id: id, swira: swira)
            // The table needs whatever the configured columns ask for; the split view needs its
            // own fixed set regardless of what the columns are, since its cards render those
            // fields no matter which columns the table is showing.
            let fieldIds = Set(resolvedColumns.columns.map(\.value))
                .union(SearchService.previewFields)

            // `filter = <id> ORDER BY x y` is standard, valid JQL — appending an ORDER BY
            // overrides whatever order the filter's own JQL specifies, without touching the
            // stored filter. Field id is restricted to a safe character set before it ever
            // reaches string interpolation into JQL: this is a local server, but still a
            // network-facing one, and the parameter is otherwise attacker-controlled.
            var jql = "filter = \(id)"
            if let sortField = request.query["sortField"], isSafeFieldToken(sortField) {
                let direction = request.query["sortDir"]?.lowercased() == "asc" ? "ASC" : "DESC"
                jql += " ORDER BY \(sortField) \(direction)"
            }

            let page = try await swira.search.search(
                jql: jql,
                fields: Array(fieldIds),
                maxResults: limit,
                pageToken: request.query["pageToken"]
            )
            let browseBase = swira.configuration.site.baseURL.absoluteString
            return try json(IssuesDTO(
                issues: page.values.map { IssueDTO($0, browseBase: browseBase) },
                nextPageToken: page.nextPageToken,
                columns: resolvedColumns.columns,
                columnsAreDefault: resolvedColumns.isDefault
            ))
        }

        if segments.count == 4,
           segments[0] == "api", segments[1] == "filter", segments[3] == "columns" {
            let id = segments[2]
            let swira = try requireSwira()
            switch method {
            case "GET":
                let resolved = try await resolveColumns(id: id, swira: swira)
                return try json(ColumnsDTO(columns: resolved.columns, isDefault: resolved.isDefault))
            case "PUT":
                let body = try decode(SetColumnsBody.self, from: request)
                try await swira.filters.setColumns(id: id, fieldIds: body.fieldIds)
                let resolved = try await resolveColumns(id: id, swira: swira)
                return try json(ColumnsDTO(columns: resolved.columns, isDefault: resolved.isDefault))
            case "DELETE":
                try await swira.filters.resetColumns(id: id)
                let resolved = try await resolveColumns(id: id, swira: swira)
                return try json(ColumnsDTO(columns: resolved.columns, isDefault: resolved.isDefault))
            default:
                return .notFound()
            }
        }

        if method == "GET", segments == ["api", "fields"] {
            let swira = try requireSwira()
            let fields = try await swira.reference.fields()
            return try json(fields.value.map { FieldRefDTO(id: $0.id, name: $0.name) })
        }

        if method == "GET", segments == ["api", "priorities"] {
            let swira = try requireSwira()
            let priorities = try await swira.reference.priorities()
            return try json(priorities.value.map {
                PriorityRefDTO(id: $0.id, name: $0.name, iconUrl: $0.iconUrl)
            })
        }

        if method == "GET", segments.count == 4,
           segments[0] == "api", segments[1] == "project", segments[3] == "versions" {
            let swira = try requireSwira()
            let versions = try await swira.reference.projectVersions(projectIdOrKey: segments[2])
            return try json(versions.value.map {
                VersionRefDTO(id: $0.id, name: $0.name, released: $0.released ?? false)
            })
        }

        if method == "GET", segments == ["api", "users", "search"] {
            let swira = try requireSwira()
            let query = request.query["q"] ?? ""
            guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
                return try json([UserRefDTO]())
            }
            let users = try await swira.reference.searchUsers(matching: query)
            return try json(users.map { UserRefDTO(accountId: $0.accountId, displayName: $0.displayName) })
        }

        if method == "PUT", segments.count == 4,
           segments[0] == "api", segments[1] == "issue", segments[3] == "fields" {
            let key = segments[2]
            let swira = try requireSwira()
            let body = try decode(FieldEditBody.self, from: request)
            switch body.kind {
            case "text":
                guard let fieldId = body.fieldId, let value = body.value else {
                    return errorResponse("A text edit needs fieldId and value.", status: 400)
                }
                try await swira.issue.setText(issueKey: key, fieldId: fieldId, value: value)
            case "number":
                guard let fieldId = body.fieldId, let raw = body.value, let value = Double(raw) else {
                    return errorResponse("A number edit needs fieldId and a numeric value.", status: 400)
                }
                try await swira.issue.setNumber(issueKey: key, fieldId: fieldId, value: value)
            case "priority":
                guard let priorityId = body.priorityId else {
                    return errorResponse("A priority edit needs priorityId.", status: 400)
                }
                try await swira.issue.setPriority(issueKey: key, priorityId: priorityId)
            case "assignee":
                try await swira.issue.setAssignee(issueKey: key, accountId: body.accountId)
            case "labels":
                try await swira.issue.setLabels(issueKey: key, labels: body.labels ?? [])
            case "fixVersions":
                try await swira.issue.setFixVersions(issueKey: key, versionIds: body.versionIds ?? [])
            default:
                return errorResponse("Unknown edit kind '\(body.kind)'.", status: 400)
            }
            return .json(Data("{}".utf8))
        }

        if method == "GET", segments.count == 4,
           segments[0] == "api", segments[1] == "issue", segments[3] == "transitions" {
            let swira = try requireSwira()
            let transitions = try await swira.issue.transitions(issueKey: segments[2])
            return try json(transitions.map {
                TransitionDTO(id: $0.id, name: $0.name, toStatusName: $0.to?.name)
            })
        }

        if method == "POST", segments.count == 4,
           segments[0] == "api", segments[1] == "issue", segments[3] == "transitions" {
            let swira = try requireSwira()
            let body = try decode(TransitionBody.self, from: request)
            try await swira.issue.transition(issueKey: segments[2], transitionId: body.transitionId)
            return .json(Data("{}".utf8))
        }

        if method == "POST", segments == ["api", "validate"] {
            let swira = try requireSwira()
            let body = try decode(JQLBody.self, from: request)
            let result = try await swira.jql.validate(body.jql)
            return try json(
                ValidationDTO(valid: result.isValid, errors: result.errors + result.warnings)
            )
        }

        if method == "GET", segments == ["api", "jql", "autocomplete"] {
            let swira = try requireSwira()
            let data = try await swira.jql.autocompleteData()
            return try json(AutocompleteDataDTO(data))
        }

        if method == "GET", segments == ["api", "jql", "suggestions"] {
            let swira = try requireSwira()
            let fieldName = request.query["fieldName"] ?? ""
            guard !fieldName.isEmpty else {
                return try json([SuggestionDTO]())
            }
            let results = try await swira.jql.suggestions(
                fieldName: fieldName,
                fieldValue: request.query["fieldValue"]
            )
            return try json(results.map { SuggestionDTO(value: $0.value, label: $0.plainDisplayName) })
        }

        if method == "POST", segments.count == 4,
           segments[0] == "api", segments[1] == "filter", segments[3] == "jql" {
            let id = segments[2]
            let swira = try requireSwira()
            let body = try decode(JQLBody.self, from: request)
            let validation = try await swira.jql.validate(body.jql)
            guard validation.isValid else {
                return try json(ValidationDTO(valid: false, errors: validation.errors), status: 400)
            }
            let current = try await swira.filters.get(id: id, policy: .networkOnly).value
            let updated = try await swira.filters.update(
                id: id,
                FilterInput(name: current.name, jql: body.jql, description: current.description)
            )
            return try json(FilterDetailDTO(filter: FilterDTO(updated), meta: nil))
        }

        if method == "POST", segments == ["api", "filters"] {
            let swira = try requireSwira()
            let body = try decode(CreateBody.self, from: request)
            // Conflict rule (spec §2.3): block creation when the name is taken, before Jira
            // gets a chance to either reject it or silently allow a duplicate.
            let name = FilterPath(segments: body.path).filterName
            let existing = try await swira.filters.search(
                FilterQuery(name: name), policy: .networkOnly
            )
            if existing.value.values.contains(where: { $0.name == name }) {
                return errorResponse("A filter named '\(name)' already exists.", status: 409)
            }
            let created = try await swira.filters.create(
                at: FilterPath(segments: body.path),
                jql: body.jql,
                description: body.description
            )
            return try json(FilterDetailDTO(filter: FilterDTO(created), meta: nil))
        }

        return .notFound()
    }

    // MARK: - Helpers

    private func requireSwira() throws -> Swira {
        guard let swira else {
            // The stored message is already a complete, user-facing sentence from
            // `SwiraConfiguration.fromEnvironment` — rethrowing it wrapped in another
            // `.configuration` would prefix it twice.
            throw UnconfiguredError(
                message: configurationError ?? "Jira credentials are not configured."
            )
        }
        return swira
    }

    private struct UnconfiguredError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func json<T: Encodable>(_ value: T, status: Int = 200) throws -> HTTPServer.Response {
        .json(try encoder.encode(value), status: status)
    }

    private func decode<T: Decodable>(_ type: T.Type, from request: HTTPServer.Request) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: request.body)
        } catch {
            throw SwiraError.decoding(path: "\(type)", snippet: "invalid request body")
        }
    }

    private func errorResponse(_ message: String, status: Int) -> HTTPServer.Response {
        let payload = (try? encoder.encode(["error": message])) ?? Data()
        return .json(payload, status: status)
    }

    private func statusCode(for error: SwiraError) -> Int {
        switch error {
        case .configuration: return 424
        case .unauthorized, .forbidden: return 502
        case .notFound: return 404
        case .jira(let status, _, _): return status >= 500 ? 502 : 400
        default: return 502
        }
    }

    // MARK: - Columns

    private struct ResolvedColumns {
        let columns: [FilterColumn]
        let isDefault: Bool
    }

    /// The columns to show for a filter, falling back to a sensible default set when none are
    /// configured — Jira answers `404` for `GET .../columns` on a filter that has never had
    /// columns set, which is the ordinary case, not an error condition.
    private func resolveColumns(id: String, swira: Swira) async throws -> ResolvedColumns {
        do {
            let columns = try await swira.filters.columns(id: id)
            guard !columns.isEmpty else {
                return ResolvedColumns(columns: defaultColumns, isDefault: true)
            }
            return ResolvedColumns(columns: columns, isDefault: false)
        } catch let error as SwiraError {
            if case .notFound = error {
                return ResolvedColumns(columns: defaultColumns, isDefault: true)
            }
            throw error
        }
    }

    /// A JQL field token is a bare identifier, `cf[10001]`, or similar — never quotes, spaces,
    /// or clause syntax. Restricting to this set before interpolating a client-supplied sort
    /// field into JQL text keeps a malformed or hostile request from doing anything beyond
    /// "produce an invalid query," which Jira itself will then simply reject.
    private func isSafeFieldToken(_ token: String) -> Bool {
        !token.isEmpty && token.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "_" || $0 == "[" || $0 == "]"
        }
    }
}

/// Columns shown when a filter has none configured — matches what the table showed before
/// columns were configurable, so turning the feature on changes nothing by default.
private let defaultColumns: [FilterColumn] = [
    FilterColumn(label: "Summary", value: "summary"),
    FilterColumn(label: "Status", value: "status"),
    FilterColumn(label: "Type", value: "issuetype"),
    FilterColumn(label: "Priority", value: "priority"),
    FilterColumn(label: "Assignee", value: "assignee"),
    FilterColumn(label: "Updated", value: "updated"),
]

// MARK: - Wire types

private struct ConfigDTO: Encodable {
    let siteUrl: String?
    let deployment: String?
    let error: String?
}

struct FilterDTO: Encodable {
    let id: String
    let name: String
    let jql: String?
    let favourite: Bool
    let viewUrl: String?
    let pathSegments: [String]

    init(_ filter: JiraFilter) {
        id = filter.id
        name = filter.name
        jql = filter.jql
        favourite = filter.favourite
        viewUrl = filter.viewUrl
        pathSegments = filter.path.segments
    }
}

struct NodeDTO: Encodable {
    let name: String
    let path: String
    let filter: FilterDTO?
    let children: [NodeDTO]

    init(_ node: FilterTreeNode) {
        name = node.name
        path = node.path.filterName
        filter = node.filter.map(FilterDTO.init)
        children = node.children.map(NodeDTO.init)
    }
}

/// Freshness metadata (spec §3.4): the UI must be able to say "cached, as of 12:04".
struct MetaDTO: Encodable {
    let origin: String
    let isStale: Bool
    let storedAt: Date?

    init<T>(_ cached: Cached<T>) {
        origin = cached.origin == .network ? "network" : "cache"
        isStale = cached.isStale
        storedAt = cached.storedAt
    }
}

/// A minimal filter reference: just enough to resolve or pick one by name, for the JQL
/// editor's filter-reference chips.
struct FilterRefDTO: Encodable {
    let id: String
    let name: String
}

private struct SidebarDTO: Encodable {
    let favourites: [FilterDTO]
    let tree: [NodeDTO]
    let meta: MetaDTO
}

private struct FilterDetailDTO: Encodable {
    let filter: FilterDTO
    let meta: MetaDTO?
}

struct IssueDTO: Encodable {
    let key: String
    let summary: String?
    let status: String?
    let statusCategory: String?
    let issueType: String?
    let priority: String?
    let assignee: String?
    let updated: Date?
    let browseUrl: String
    /// Every requested field, untyped — how the table renders arbitrary configured columns
    /// (including custom fields) without a typed Swift property for each one.
    let fields: [String: JSONValue]

    init(_ issue: JiraIssue, browseBase: String) {
        key = issue.key
        summary = issue.summary
        status = issue.status
        statusCategory = issue.statusCategory
        issueType = issue.issueType
        priority = issue.priority
        assignee = issue.assignee?.displayName
        updated = issue.updated
        browseUrl = "\(browseBase)/browse/\(issue.key)"
        fields = issue.fields
    }
}

struct ColumnRefDTO: Encodable {
    let label: String
    let value: String
}

private struct IssuesDTO: Encodable {
    let issues: [IssueDTO]
    let nextPageToken: String?
    let columns: [ColumnRefDTO]
    let columnsAreDefault: Bool

    init(issues: [IssueDTO], nextPageToken: String?, columns: [FilterColumn], columnsAreDefault: Bool) {
        self.issues = issues
        self.nextPageToken = nextPageToken
        self.columns = columns.map { ColumnRefDTO(label: $0.label, value: $0.value) }
        self.columnsAreDefault = columnsAreDefault
    }
}

struct ColumnsDTO: Encodable {
    let columns: [ColumnRefDTO]
    let isDefault: Bool

    init(columns: [FilterColumn], isDefault: Bool) {
        self.columns = columns.map { ColumnRefDTO(label: $0.label, value: $0.value) }
        self.isDefault = isDefault
    }
}

struct FieldRefDTO: Encodable {
    let id: String
    let name: String
}

struct PriorityRefDTO: Encodable {
    let id: String
    let name: String
    let iconUrl: String?
}

struct VersionRefDTO: Encodable {
    let id: String
    let name: String
    let released: Bool
}

struct UserRefDTO: Encodable {
    let accountId: String
    let displayName: String
}

struct TransitionDTO: Encodable {
    let id: String
    let name: String
    let toStatusName: String?
}

private struct SetColumnsBody: Decodable {
    let fieldIds: [String]
}

/// A discriminated edit request for one field of one issue. `kind` selects which of the other
/// (all-optional) payload keys are consulted — mirrors `IssueService`'s typed setters rather
/// than exposing Jira's raw per-field-type JSON shapes to the client.
private struct FieldEditBody: Decodable {
    let kind: String
    let fieldId: String?
    let value: String?
    let priorityId: String?
    let accountId: String?
    let labels: [String]?
    let versionIds: [String]?
}

private struct TransitionBody: Decodable {
    let transitionId: String
}

private struct ValidationDTO: Encodable {
    let valid: Bool
    let errors: [String]
}

struct AutocompleteFieldDTO: Encodable {
    let value: String
    let label: String
}

struct AutocompleteDataDTO: Encodable {
    let fields: [AutocompleteFieldDTO]
    let functions: [AutocompleteFieldDTO]

    init(_ data: JQLAutocompleteData) {
        fields = data.visibleFieldNames.map { AutocompleteFieldDTO(value: $0.value, label: $0.displayName) }
        functions = data.visibleFunctionNames.map { AutocompleteFieldDTO(value: $0.value, label: $0.displayName) }
    }
}

struct SuggestionDTO: Encodable {
    let value: String
    let label: String
}

private struct JQLBody: Decodable {
    let jql: String
}

private struct CreateBody: Decodable {
    let path: [String]
    let jql: String
    let description: String?
}
