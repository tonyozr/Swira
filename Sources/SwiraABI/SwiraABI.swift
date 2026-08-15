import Foundation
import SwiraCore

/// A flat C ABI over `SwiraCore`, built as a Windows DLL (`SwiraABI.dll`) that `SwiraWin`
/// P/Invokes directly — no HTTP, no `swira-web` subprocess. This is the "local IPC" option the
/// original plan named as an alternative to a full Swift-native WinUI toolchain (which requires
/// thebrowsercompany/swift-winrt's experimental toolchain fork, not the stock release compiler
/// this repo otherwise builds with): all business logic and every Jira call still lives in
/// Swift/`SwiraCore`; only WinUI's own XAML surface — which has no non-.NET public API — is C#.
///
/// Async `SwiraCore` calls are bridged to C by taking a C function-pointer callback plus an
/// opaque context pointer, and invoking it once with either a JSON payload or `nil` (on failure,
/// with the message retrievable via `swira_last_error`). The callback fires on a Swift
/// concurrency worker thread; callers must hop back to their own UI thread themselves.
///
/// JSON shapes here intentionally mirror `Sources/swira-web/WebAPI.swift`'s DTOs — same
/// contract, different transport — so the two clients (web, WinUI) read as the same API even
/// though this one never touches a socket.

// MARK: - Global state

/// Guarded by `stateLock`. `Swira` is `Sendable`, so sharing it across threads behind a lock is
/// sound; there is exactly one configured instance per process, matching the single-window,
/// single-account model every Swira client presents (docs/CLIENT-SPEC.md §1).
nonisolated(unsafe) private var gSwira: Swira?
nonisolated(unsafe) private var gLastError: String = ""
private let stateLock = NSLock()

private func setSwira(_ swira: Swira?) {
    stateLock.lock(); gSwira = swira; stateLock.unlock()
}

private func currentSwira() -> Swira? {
    stateLock.lock(); defer { stateLock.unlock() }
    return gSwira
}

private func setLastError(_ message: String) {
    stateLock.lock(); gLastError = message; stateLock.unlock()
}

// MARK: - Callback plumbing

public typealias SwiraCallback = @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void

/// A C function pointer plus its opaque context, boxed so it can cross into a `Task {}` closure.
/// Both members are trivial (an address, and a value the caller alone owns and interprets) —
/// there is nothing here for Swift's region-based isolation checker to actually protect against,
/// it just has no vocabulary for "this is a raw callback contract," hence `@unchecked`.
private struct Reply: @unchecked Sendable {
    let callback: SwiraCallback
    let context: UnsafeMutableRawPointer?
}

private let abiEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
}()

private func succeed<T: Encodable>(_ value: T, _ reply: Reply) {
    guard let data = try? abiEncoder.encode(value), let json = String(data: data, encoding: .utf8) else {
        fail("Failed to encode response.", reply)
        return
    }
    json.withCString { reply.callback($0, reply.context) }
}

private func fail(_ message: String, _ reply: Reply) {
    setLastError(message)
    reply.callback(nil, reply.context)
}

private func describe(_ error: Error) -> String {
    (error as? SwiraError)?.errorDescription ?? "\(error)"
}

private func cString(_ pointer: UnsafePointer<CChar>?) -> String {
    pointer.map { String(cString: $0) } ?? ""
}

private func optionalCString(_ pointer: UnsafePointer<CChar>?) -> String? {
    guard let pointer else { return nil }
    let value = String(cString: pointer)
    return value.isEmpty ? nil : value
}

// MARK: - Lifecycle

/// Reads `JIRA_URL` / `JIRA_EMAIL` / `JIRA_API_TOKEN` (and aliases — see
/// `SwiraConfiguration.fromEnvironment`) and assembles the core. Returns `1` on success, `0` on
/// failure (message via `swira_last_error`). Synchronous: this only builds value types, it never
/// makes a network call.
@_cdecl("swira_configure")
public func swira_configure() -> Int32 {
    do {
        let swira = try Swira.fromEnvironment()
        setSwira(swira)
        return 1
    } catch {
        setSwira(nil)
        setLastError(describe(error))
        return 0
    }
}

/// The most recent failure message from any `swira_*` call on this process. Owned by the
/// library; do not free it.
@_cdecl("swira_last_error")
public func swira_last_error() -> UnsafePointer<CChar>? {
    stateLock.lock(); let message = gLastError; stateLock.unlock()
    #if os(Windows)
    return UnsafePointer(_strdup(message))
    #else
    return UnsafePointer(strdup(message))
    #endif
}

/// Frees a string this library handed back via a callback or `swira_last_error`.
@_cdecl("swira_free_string")
public func swira_free_string(_ pointer: UnsafeMutablePointer<CChar>?) {
    free(pointer)
}

// MARK: - Sidebar

@_cdecl("swira_get_sidebar")
public func swira_get_sidebar(
    _ fresh: Int32, _ callback: @escaping SwiraCallback, _ context: UnsafeMutableRawPointer?
) {
    let reply = Reply(callback: callback, context: context)
    guard let swira = currentSwira() else { return fail("Not configured.", reply) }
    let policy: CachePolicy = fresh != 0 ? .networkOnly : .default
    Task {
        do {
            let favourites = try await swira.filters.favourites(policy: policy)
            let tree = try await swira.filters.tree(policy: policy)
            let structured = tree.value.filter { !$0.children.isEmpty || $0.path.segments.count > 1 }
            let structuredIds = Set(structured.flatMap { $0.allFilters.map(\.id) })
            let favouritesOnly = favourites.value.filter { !structuredIds.contains($0.id) }
            succeed(
                SidebarDTO(
                    favourites: favouritesOnly.map(FilterDTO.init),
                    tree: structured.map(NodeDTO.init),
                    meta: MetaDTO(favourites)
                ),
                reply
            )
        } catch {
            fail(describe(error), reply)
        }
    }
}

// MARK: - Filter issues

@_cdecl("swira_get_filter_issues")
public func swira_get_filter_issues(
    _ filterId: UnsafePointer<CChar>?,
    _ sortField: UnsafePointer<CChar>?,
    _ sortDirDescending: Int32,
    _ limit: Int32,
    _ pageToken: UnsafePointer<CChar>?,
    _ callback: @escaping SwiraCallback,
    _ context: UnsafeMutableRawPointer?
) {
    let reply = Reply(callback: callback, context: context)
    guard let swira = currentSwira() else { return fail("Not configured.", reply) }
    let id = cString(filterId)
    let field = optionalCString(sortField)
    let token = optionalCString(pageToken)
    let requestedLimit = Int(limit)

    Task {
        do {
            var jql = "filter = \(id)"
            if let field, isSafeFieldToken(field) {
                jql += " ORDER BY \(field) \(sortDirDescending != 0 ? "DESC" : "ASC")"
            }
            let columns = try await resolveColumns(id: id, swira: swira)
            let fieldIds = Set(columns.map(\.value)).union(SearchService.previewFields)
            let page = try await swira.search.search(
                jql: jql,
                fields: Array(fieldIds),
                maxResults: requestedLimit > 0 ? requestedLimit : 50,
                pageToken: token
            )
            let browseBase = swira.configuration.site.baseURL.absoluteString
            succeed(
                IssuesDTO(
                    issues: page.values.map { IssueDTO($0, browseBase: browseBase) },
                    nextPageToken: page.nextPageToken,
                    columns: columns.map { ColumnRefDTO(label: $0.label, value: $0.value) }
                ),
                reply
            )
        } catch {
            fail(describe(error), reply)
        }
    }
}

/// Columns configured for a filter, falling back to a fixed default set — matches
/// `WebAPI.resolveColumns`: Jira answers `404` for a filter that has never had columns set,
/// which is the ordinary case, not an error.
private func resolveColumns(id: String, swira: Swira) async throws -> [FilterColumn] {
    do {
        let columns = try await swira.filters.columns(id: id)
        return columns.isEmpty ? defaultColumns : columns
    } catch let error as SwiraError {
        if case .notFound = error { return defaultColumns }
        throw error
    }
}

private let defaultColumns: [FilterColumn] = [
    FilterColumn(label: "Summary", value: "summary"),
    FilterColumn(label: "Status", value: "status"),
    FilterColumn(label: "Type", value: "issuetype"),
    FilterColumn(label: "Priority", value: "priority"),
    FilterColumn(label: "Assignee", value: "assignee"),
    FilterColumn(label: "Updated", value: "updated"),
]

/// Same restriction as `WebAPI.isSafeFieldToken`: a bare identifier or `cf[10001]`-shaped
/// token, never quotes/spaces/clause syntax, before it's interpolated into JQL text.
private func isSafeFieldToken(_ token: String) -> Bool {
    !token.isEmpty && token.allSatisfy {
        $0.isLetter || $0.isNumber || $0 == "_" || $0 == "[" || $0 == "]"
    }
}

// MARK: - JQL

@_cdecl("swira_validate_jql")
public func swira_validate_jql(
    _ jql: UnsafePointer<CChar>?, _ callback: @escaping SwiraCallback, _ context: UnsafeMutableRawPointer?
) {
    let reply = Reply(callback: callback, context: context)
    guard let swira = currentSwira() else { return fail("Not configured.", reply) }
    let query = cString(jql)
    Task {
        do {
            let result = try await swira.jql.validate(query)
            succeed(ValidationDTO(valid: result.errors.isEmpty, errors: result.errors + result.warnings), reply)
        } catch {
            fail(describe(error), reply)
        }
    }
}

@_cdecl("swira_update_filter_jql")
public func swira_update_filter_jql(
    _ filterId: UnsafePointer<CChar>?,
    _ jql: UnsafePointer<CChar>?,
    _ callback: @escaping SwiraCallback,
    _ context: UnsafeMutableRawPointer?
) {
    let reply = Reply(callback: callback, context: context)
    guard let swira = currentSwira() else { return fail("Not configured.", reply) }
    let id = cString(filterId)
    let query = cString(jql)
    Task {
        do {
            let validation = try await swira.jql.validate(query)
            guard validation.errors.isEmpty else {
                return succeed(ValidationDTO(valid: false, errors: validation.errors), reply)
            }
            let current = try await swira.filters.get(id: id, policy: .networkOnly).value
            let updated = try await swira.filters.update(
                id: id,
                FilterInput(name: current.name, jql: query, description: current.description)
            )
            succeed(FilterDTO(updated), reply)
        } catch {
            fail(describe(error), reply)
        }
    }
}

// MARK: - Columns

@_cdecl("swira_get_columns")
public func swira_get_columns(
    _ filterId: UnsafePointer<CChar>?, _ callback: @escaping SwiraCallback, _ context: UnsafeMutableRawPointer?
) {
    let reply = Reply(callback: callback, context: context)
    guard let swira = currentSwira() else { return fail("Not configured.", reply) }
    let id = cString(filterId)
    Task {
        do {
            let columns = try await resolveColumns(id: id, swira: swira)
            succeed(ColumnsDTO(columns: columns.map { ColumnRefDTO(label: $0.label, value: $0.value) }), reply)
        } catch {
            fail(describe(error), reply)
        }
    }
}

/// `fieldIds` is a JSON array of field id strings (e.g. `["summary","status"]`), matching the
/// order the caller wants the columns to appear in.
@_cdecl("swira_set_columns")
public func swira_set_columns(
    _ filterId: UnsafePointer<CChar>?,
    _ fieldIdsJSON: UnsafePointer<CChar>?,
    _ callback: @escaping SwiraCallback,
    _ context: UnsafeMutableRawPointer?
) {
    let reply = Reply(callback: callback, context: context)
    guard let swira = currentSwira() else { return fail("Not configured.", reply) }
    let id = cString(filterId)
    let fieldIds: [String]
    do {
        fieldIds = try JSONDecoder().decode([String].self, from: Data(cString(fieldIdsJSON).utf8))
    } catch {
        return fail("Invalid field id list.", reply)
    }
    Task {
        do {
            try await swira.filters.setColumns(id: id, fieldIds: fieldIds)
            let columns = try await resolveColumns(id: id, swira: swira)
            succeed(ColumnsDTO(columns: columns.map { ColumnRefDTO(label: $0.label, value: $0.value) }), reply)
        } catch {
            fail(describe(error), reply)
        }
    }
}

@_cdecl("swira_reset_columns")
public func swira_reset_columns(
    _ filterId: UnsafePointer<CChar>?, _ callback: @escaping SwiraCallback, _ context: UnsafeMutableRawPointer?
) {
    let reply = Reply(callback: callback, context: context)
    guard let swira = currentSwira() else { return fail("Not configured.", reply) }
    let id = cString(filterId)
    Task {
        do {
            try await swira.filters.resetColumns(id: id)
            let columns = try await resolveColumns(id: id, swira: swira)
            succeed(ColumnsDTO(columns: columns.map { ColumnRefDTO(label: $0.label, value: $0.value) }), reply)
        } catch {
            fail(describe(error), reply)
        }
    }
}

// MARK: - Reference data

@_cdecl("swira_get_fields")
public func swira_get_fields(_ callback: @escaping SwiraCallback, _ context: UnsafeMutableRawPointer?) {
    let reply = Reply(callback: callback, context: context)
    guard let swira = currentSwira() else { return fail("Not configured.", reply) }
    Task {
        do {
            let fields = try await swira.reference.fields()
            succeed(fields.value.map { FieldRefDTO(id: $0.id, name: $0.name) }, reply)
        } catch {
            fail(describe(error), reply)
        }
    }
}

/// Field and function names for JQL autocomplete (§3.3) — the token being typed.
@_cdecl("swira_jql_autocomplete")
public func swira_jql_autocomplete(_ callback: @escaping SwiraCallback, _ context: UnsafeMutableRawPointer?) {
    let reply = Reply(callback: callback, context: context)
    guard let swira = currentSwira() else { return fail("Not configured.", reply) }
    Task {
        do {
            let data = try await swira.jql.autocompleteData()
            succeed(
                AutocompleteDataDTO(
                    fields: data.visibleFieldNames.map { AutocompleteItemDTO(value: $0.value, label: $0.displayName) },
                    functions: data.visibleFunctionNames.map { AutocompleteItemDTO(value: $0.value, label: $0.displayName) }
                ),
                reply
            )
        } catch {
            fail(describe(error), reply)
        }
    }
}

/// Suggested values for a field (§3.3) — once the caret sits after a comparison operator.
@_cdecl("swira_jql_suggestions")
public func swira_jql_suggestions(
    _ fieldName: UnsafePointer<CChar>?,
    _ fieldValue: UnsafePointer<CChar>?,
    _ callback: @escaping SwiraCallback,
    _ context: UnsafeMutableRawPointer?
) {
    let reply = Reply(callback: callback, context: context)
    guard let swira = currentSwira() else { return fail("Not configured.", reply) }
    let field = cString(fieldName)
    let value = optionalCString(fieldValue)
    Task {
        do {
            let results = try await swira.jql.suggestions(fieldName: field, fieldValue: value)
            succeed(results.map { AutocompleteItemDTO(value: $0.value, label: $0.plainDisplayName) }, reply)
        } catch {
            fail(describe(error), reply)
        }
    }
}

@_cdecl("swira_get_priorities")
public func swira_get_priorities(_ callback: @escaping SwiraCallback, _ context: UnsafeMutableRawPointer?) {
    let reply = Reply(callback: callback, context: context)
    guard let swira = currentSwira() else { return fail("Not configured.", reply) }
    Task {
        do {
            let priorities = try await swira.reference.priorities()
            succeed(priorities.value.map { PriorityRefDTO(id: $0.id, name: $0.name, iconUrl: $0.iconUrl) }, reply)
        } catch {
            fail(describe(error), reply)
        }
    }
}

@_cdecl("swira_search_users")
public func swira_search_users(
    _ query: UnsafePointer<CChar>?, _ callback: @escaping SwiraCallback, _ context: UnsafeMutableRawPointer?
) {
    let reply = Reply(callback: callback, context: context)
    guard let swira = currentSwira() else { return fail("Not configured.", reply) }
    let text = cString(query)
    Task {
        do {
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
                return succeed([UserRefDTO](), reply)
            }
            let users = try await swira.reference.searchUsers(matching: text)
            succeed(users.map { UserRefDTO(accountId: $0.accountId, displayName: $0.displayName) }, reply)
        } catch {
            fail(describe(error), reply)
        }
    }
}

@_cdecl("swira_get_project_versions")
public func swira_get_project_versions(
    _ projectIdOrKey: UnsafePointer<CChar>?, _ callback: @escaping SwiraCallback, _ context: UnsafeMutableRawPointer?
) {
    let reply = Reply(callback: callback, context: context)
    guard let swira = currentSwira() else { return fail("Not configured.", reply) }
    let key = cString(projectIdOrKey)
    Task {
        do {
            let versions = try await swira.reference.projectVersions(projectIdOrKey: key)
            succeed(
                versions.value.map { VersionRefDTO(id: $0.id, name: $0.name, released: $0.released ?? false) },
                reply
            )
        } catch {
            fail(describe(error), reply)
        }
    }
}

@_cdecl("swira_get_transitions")
public func swira_get_transitions(
    _ issueKey: UnsafePointer<CChar>?, _ callback: @escaping SwiraCallback, _ context: UnsafeMutableRawPointer?
) {
    let reply = Reply(callback: callback, context: context)
    guard let swira = currentSwira() else { return fail("Not configured.", reply) }
    let key = cString(issueKey)
    Task {
        do {
            let transitions = try await swira.issue.transitions(issueKey: key)
            succeed(
                transitions.map { TransitionDTO(id: $0.id, name: $0.name, toStatusName: $0.to?.name) },
                reply
            )
        } catch {
            fail(describe(error), reply)
        }
    }
}

// MARK: - Issue editing

/// Sets a text-typed custom or system field on one issue. Basic field types only (§3.1 v1) — the
/// caller is responsible for only offering this on fields that are actually text (Jira itself
/// rejects a type mismatch, which surfaces as an ordinary failure here).
@_cdecl("swira_set_issue_text")
public func swira_set_issue_text(
    _ issueKey: UnsafePointer<CChar>?,
    _ fieldId: UnsafePointer<CChar>?,
    _ value: UnsafePointer<CChar>?,
    _ callback: @escaping SwiraCallback,
    _ context: UnsafeMutableRawPointer?
) {
    let reply = Reply(callback: callback, context: context)
    guard let swira = currentSwira() else { return fail("Not configured.", reply) }
    let key = cString(issueKey)
    let field = cString(fieldId)
    let text = cString(value)
    Task {
        do {
            try await swira.issue.setText(issueKey: key, fieldId: field, value: text)
            succeed(EmptyDTO(), reply)
        } catch {
            fail(describe(error), reply)
        }
    }
}

@_cdecl("swira_set_issue_priority")
public func swira_set_issue_priority(
    _ issueKey: UnsafePointer<CChar>?,
    _ priorityId: UnsafePointer<CChar>?,
    _ callback: @escaping SwiraCallback,
    _ context: UnsafeMutableRawPointer?
) {
    let reply = Reply(callback: callback, context: context)
    guard let swira = currentSwira() else { return fail("Not configured.", reply) }
    let key = cString(issueKey)
    let priority = cString(priorityId)
    Task {
        do {
            try await swira.issue.setPriority(issueKey: key, priorityId: priority)
            succeed(EmptyDTO(), reply)
        } catch {
            fail(describe(error), reply)
        }
    }
}

/// `accountId` is optional — pass an empty string (or omit) to clear the assignee.
@_cdecl("swira_set_issue_assignee")
public func swira_set_issue_assignee(
    _ issueKey: UnsafePointer<CChar>?,
    _ accountId: UnsafePointer<CChar>?,
    _ callback: @escaping SwiraCallback,
    _ context: UnsafeMutableRawPointer?
) {
    let reply = Reply(callback: callback, context: context)
    guard let swira = currentSwira() else { return fail("Not configured.", reply) }
    let key = cString(issueKey)
    let account = optionalCString(accountId)
    Task {
        do {
            try await swira.issue.setAssignee(issueKey: key, accountId: account)
            succeed(EmptyDTO(), reply)
        } catch {
            fail(describe(error), reply)
        }
    }
}

/// `labelsJSON` is a JSON array of strings — the full replacement label set (Jira has no
/// "add one label" operation on a plain update; see `IssueService.setLabels`).
@_cdecl("swira_set_issue_labels")
public func swira_set_issue_labels(
    _ issueKey: UnsafePointer<CChar>?,
    _ labelsJSON: UnsafePointer<CChar>?,
    _ callback: @escaping SwiraCallback,
    _ context: UnsafeMutableRawPointer?
) {
    let reply = Reply(callback: callback, context: context)
    guard let swira = currentSwira() else { return fail("Not configured.", reply) }
    let key = cString(issueKey)
    let labels: [String]
    do {
        labels = try JSONDecoder().decode([String].self, from: Data(cString(labelsJSON).utf8))
    } catch {
        return fail("Invalid label list.", reply)
    }
    Task {
        do {
            try await swira.issue.setLabels(issueKey: key, labels: labels)
            succeed(EmptyDTO(), reply)
        } catch {
            fail(describe(error), reply)
        }
    }
}

/// `versionIdsJSON` is a JSON array of version id strings — the full replacement set, by id (see
/// `IssueService.setFixVersions`).
@_cdecl("swira_set_issue_fixversions")
public func swira_set_issue_fixversions(
    _ issueKey: UnsafePointer<CChar>?,
    _ versionIdsJSON: UnsafePointer<CChar>?,
    _ callback: @escaping SwiraCallback,
    _ context: UnsafeMutableRawPointer?
) {
    let reply = Reply(callback: callback, context: context)
    guard let swira = currentSwira() else { return fail("Not configured.", reply) }
    let key = cString(issueKey)
    let versionIds: [String]
    do {
        versionIds = try JSONDecoder().decode([String].self, from: Data(cString(versionIdsJSON).utf8))
    } catch {
        return fail("Invalid version id list.", reply)
    }
    Task {
        do {
            try await swira.issue.setFixVersions(issueKey: key, versionIds: versionIds)
            succeed(EmptyDTO(), reply)
        } catch {
            fail(describe(error), reply)
        }
    }
}

@_cdecl("swira_transition_issue")
public func swira_transition_issue(
    _ issueKey: UnsafePointer<CChar>?,
    _ transitionId: UnsafePointer<CChar>?,
    _ callback: @escaping SwiraCallback,
    _ context: UnsafeMutableRawPointer?
) {
    let reply = Reply(callback: callback, context: context)
    guard let swira = currentSwira() else { return fail("Not configured.", reply) }
    let key = cString(issueKey)
    let transition = cString(transitionId)
    Task {
        do {
            try await swira.issue.transition(issueKey: key, transitionId: transition)
            succeed(EmptyDTO(), reply)
        } catch {
            fail(describe(error), reply)
        }
    }
}

/// A short name-search, for the filter-reference chip's "change which filter it references"
/// picker (§3.3.1).
@_cdecl("swira_search_filters")
public func swira_search_filters(
    _ query: UnsafePointer<CChar>?, _ callback: @escaping SwiraCallback, _ context: UnsafeMutableRawPointer?
) {
    let reply = Reply(callback: callback, context: context)
    guard let swira = currentSwira() else { return fail("Not configured.", reply) }
    let text = cString(query)
    Task {
        do {
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
                return succeed([FilterRefDTO](), reply)
            }
            let result = try await swira.filters.search(
                FilterQuery(name: text, maxResults: 8), policy: .default
            )
            succeed(result.value.values.map { FilterRefDTO(id: $0.id, name: $0.name) }, reply)
        } catch {
            fail(describe(error), reply)
        }
    }
}

// MARK: - Filter creation

/// `pathSegmentsJSON` is a JSON array (e.g. `["Swira","Versions","Current"]`) — see
/// `FilterPath`/CLIENT-SPEC.md §2.3. A single-element array creates a standalone (non-hierarchical)
/// filter.
@_cdecl("swira_create_filter")
public func swira_create_filter(
    _ pathSegmentsJSON: UnsafePointer<CChar>?,
    _ jql: UnsafePointer<CChar>?,
    _ description: UnsafePointer<CChar>?,
    _ callback: @escaping SwiraCallback,
    _ context: UnsafeMutableRawPointer?
) {
    let reply = Reply(callback: callback, context: context)
    guard let swira = currentSwira() else { return fail("Not configured.", reply) }
    let segments: [String]
    do {
        segments = try JSONDecoder().decode([String].self, from: Data(cString(pathSegmentsJSON).utf8))
    } catch {
        return fail("Invalid filter path.", reply)
    }
    let query = cString(jql)
    let desc = optionalCString(description)
    Task {
        do {
            let path = FilterPath(segments: segments)
            // Name-conflict guard (spec §2.3): block creation when the name is already taken,
            // before Jira gets a chance to either reject it or silently allow a duplicate —
            // mirrors WebAPI's POST /api/filters.
            let existing = try await swira.filters.search(
                FilterQuery(name: path.filterName), policy: .networkOnly
            )
            if existing.value.values.contains(where: { $0.name == path.filterName }) {
                return fail("A filter named '\(path.filterName)' already exists.", reply)
            }
            let created = try await swira.filters.create(at: path, jql: query, description: desc)
            succeed(FilterDTO(created), reply)
        } catch {
            fail(describe(error), reply)
        }
    }
}

// MARK: - Filter deletion / rename (§2.3)

@_cdecl("swira_delete_filter")
public func swira_delete_filter(
    _ filterId: UnsafePointer<CChar>?, _ callback: @escaping SwiraCallback, _ context: UnsafeMutableRawPointer?
) {
    let reply = Reply(callback: callback, context: context)
    guard let swira = currentSwira() else { return fail("Not configured.", reply) }
    let id = cString(filterId)
    Task {
        do {
            try await swira.filters.delete(id: id)
            succeed(EmptyDTO(), reply)
        } catch {
            fail(describe(error), reply)
        }
    }
}

/// Renames one filter (a leaf in the sidebar tree, or a standalone favourite) to `newName` — the
/// flat Jira name, already `": "`-joined if hierarchical. "Move" in the tree UI *is* this
/// operation (§2.3): the name is the hierarchy, so relocating a filter is just giving it a
/// different name.
@_cdecl("swira_rename_filter")
public func swira_rename_filter(
    _ filterId: UnsafePointer<CChar>?,
    _ newName: UnsafePointer<CChar>?,
    _ callback: @escaping SwiraCallback,
    _ context: UnsafeMutableRawPointer?
) {
    let reply = Reply(callback: callback, context: context)
    guard let swira = currentSwira() else { return fail("Not configured.", reply) }
    let id = cString(filterId)
    let name = cString(newName)
    Task {
        do {
            let current = try await swira.filters.get(id: id, policy: .networkOnly).value
            if current.name != name {
                let existing = try await swira.filters.search(FilterQuery(name: name), policy: .networkOnly)
                if let conflict = existing.value.values.first(where: { $0.name == name && $0.id != id }) {
                    return fail("A filter named '\(conflict.name)' already exists.", reply)
                }
            }
            let updated = try await swira.filters.update(
                id: id, FilterInput(name: name, jql: current.jql ?? "", description: current.description)
            )
            succeed(FilterDTO(updated), reply)
        } catch {
            fail(describe(error), reply)
        }
    }
}

/// Renames a whole branch — every filter whose name is `oldPrefix` itself or starts with
/// `oldPrefix + ": "` — by swapping in `newPrefix`. Validates every rename in the subtree for
/// name conflicts *before* sending the first one (§2.3: "a branch move MUST be validated for
/// every filter in the subtree before the first rename is sent, so a conflict can never leave
/// the branch half-moved"), against a freshly-fetched full filter list so a conflict with a
/// filter outside the moving subtree is never missed.
@_cdecl("swira_rename_branch")
public func swira_rename_branch(
    _ oldPrefix: UnsafePointer<CChar>?,
    _ newPrefix: UnsafePointer<CChar>?,
    _ callback: @escaping SwiraCallback,
    _ context: UnsafeMutableRawPointer?
) {
    let reply = Reply(callback: callback, context: context)
    guard let swira = currentSwira() else { return fail("Not configured.", reply) }
    let oldPath = cString(oldPrefix)
    let newPath = cString(newPrefix)
    Task {
        do {
            let favourites = try await swira.filters.favourites(policy: .networkOnly).value
            let tree = try await swira.filters.tree(policy: .networkOnly).value
            var allFilters = favourites
            for node in tree { allFilters.append(contentsOf: node.allFilters) }
            // De-duplicate: a filter can appear in both `favourites` and the tree.
            var seen = Set<String>()
            allFilters = allFilters.filter { seen.insert($0.id).inserted }

            let moving = allFilters.filter { $0.name == oldPath || $0.name.hasPrefix(oldPath + ": ") }
            guard !moving.isEmpty else {
                return fail("No filters found under '\(oldPath)'.", reply)
            }
            let stationary = allFilters.filter { f in !moving.contains { $0.id == f.id } }
            let stationaryNames = Set(stationary.map(\.name))

            var renames: [(id: String, newName: String, jql: String?, description: String?)] = []
            for filter in moving {
                let suffix = filter.name.dropFirst(oldPath.count)
                let newName = newPath + suffix
                if stationaryNames.contains(newName) {
                    return fail("A filter named '\(newName)' already exists.", reply)
                }
                renames.append((filter.id, newName, filter.jql, filter.description))
            }
            // Also guard against the subtree's own renamed names colliding with each other
            // (shouldn't happen since they're derived from already-distinct originals, but a
            // failed partial run is worse than a defensive check).
            guard Set(renames.map(\.newName)).count == renames.count else {
                return fail("Renaming would produce duplicate filter names.", reply)
            }

            for rename in renames {
                _ = try await swira.filters.update(
                    id: rename.id,
                    FilterInput(name: rename.newName, jql: rename.jql ?? "", description: rename.description)
                )
            }
            succeed(EmptyDTO(), reply)
        } catch {
            fail(describe(error), reply)
        }
    }
}

// MARK: - DTOs (mirror Sources/swira-web/WebAPI.swift's wire shapes)

private struct FilterDTO: Encodable {
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

private struct NodeDTO: Encodable {
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

private struct SidebarDTO: Encodable {
    let favourites: [FilterDTO]
    let tree: [NodeDTO]
    let meta: MetaDTO
}

/// Freshness metadata (§3.4): the UI must be able to say "cached, as of 12:04" and never present
/// stale data as current.
private struct MetaDTO: Encodable {
    let origin: String
    let isStale: Bool
    let storedAt: Date?

    init<T>(_ cached: Cached<T>) {
        origin = cached.origin == .network ? "network" : "cache"
        isStale = cached.isStale
        storedAt = cached.storedAt
    }
}

private struct IssueDTO: Encodable {
    let key: String
    let summary: String?
    let status: String?
    let statusCategory: String?
    let issueType: String?
    let priority: String?
    let assignee: String?
    let updated: Date?
    let browseUrl: String
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

private struct ColumnRefDTO: Encodable {
    let label: String
    let value: String
}

private struct IssuesDTO: Encodable {
    let issues: [IssueDTO]
    let nextPageToken: String?
    let columns: [ColumnRefDTO]
}

private struct ColumnsDTO: Encodable {
    let columns: [ColumnRefDTO]
}

private struct FilterRefDTO: Encodable {
    let id: String
    let name: String
}

private struct FieldRefDTO: Encodable {
    let id: String
    let name: String
}

private struct AutocompleteItemDTO: Encodable {
    let value: String
    let label: String
}

private struct AutocompleteDataDTO: Encodable {
    let fields: [AutocompleteItemDTO]
    let functions: [AutocompleteItemDTO]
}

private struct PriorityRefDTO: Encodable {
    let id: String
    let name: String
    let iconUrl: String?
}

private struct UserRefDTO: Encodable {
    let accountId: String
    let displayName: String
}

private struct VersionRefDTO: Encodable {
    let id: String
    let name: String
    let released: Bool
}

private struct TransitionDTO: Encodable {
    let id: String
    let name: String
    let toStatusName: String?
}

/// A `{}` success payload for mutations that have nothing else to report.
private struct EmptyDTO: Encodable {}

private struct ValidationDTO: Encodable {
    let valid: Bool
    let errors: [String]
}
