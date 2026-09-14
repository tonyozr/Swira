#if canImport(AppKit)
import AppKit
import SwiraCore
import Logging

/// Central `@MainActor` model the whole app reads from and writes to.
///
/// Every async Jira call is dispatched here; view controllers observe the published properties
/// and redraw when they change. This mirrors the role `AppModel` (or a store) plays in SwiftUI
/// apps, but for AppKit all observation is manual KVO/delegation.
@MainActor
final class AppModel {

    // MARK: - Configuration

    let swira: Swira?
    let configurationError: String?
    let logger: Logger

    // MARK: - Sidebar state

    /// Favourite filters (plain names, no hierarchy separator).
    private(set) var favourites: [JiraFilter] = []
    /// Root nodes of the filter tree (name-encoded hierarchy, spec §2.2).
    private(set) var filterTree: [FilterTreeNode] = []
    /// Whether the last sidebar load came from cache and may be stale.
    private(set) var sidebarIsStale: Bool = false
    private(set) var sidebarStoredAt: Date? = nil
    private(set) var isLoadingSidebar: Bool = false

    // MARK: - Selection

    /// The currently selected filter (drives the content area).
    private(set) var selectedFilter: JiraFilter? = nil

    // MARK: - Issue list state

    private(set) var issues: [JiraIssue] = []
    private(set) var nextPageToken: String? = nil
    private(set) var isLoadingIssues: Bool = false
    private(set) var issueLoadError: String? = nil
    private(set) var columns: [FilterColumn] = defaultColumns

    // MARK: - Sort

    private(set) var sortField: String = "updated"
    private(set) var sortDescending: Bool = true

    // MARK: - View mode (per-filter, spec §3)

    enum ViewMode { case table, split }
    private var viewModes: [String: ViewMode] = [:]

    func viewMode(for filterId: String) -> ViewMode {
        viewModes[filterId] ?? .table
    }

    func setViewMode(_ mode: ViewMode, for filterId: String) {
        viewModes[filterId] = mode
        notifyContentChanged()
    }

    // MARK: - Callbacks (AppKit-style observation)

    var onSidebarChanged: (() -> Void)?
    var onSelectionChanged: (() -> Void)?
    var onIssuesChanged: (() -> Void)?
    var onContentChanged: (() -> Void)?

    // MARK: - Init

    init(swira: Swira?, configurationError: String?, logger: Logger) {
        self.swira = swira
        self.configurationError = configurationError
        self.logger = logger
    }

    // MARK: - Sidebar loading

    func loadSidebar(fresh: Bool = false) {
        guard let swira else { return }
        guard !isLoadingSidebar else { return }
        isLoadingSidebar = true
        notifySidebarChanged()

        Task {
            let policy: CachePolicy = fresh ? .networkOnly : .default
            do {
                let favsResult = try await swira.filters.favourites(policy: policy)
                let treeResult = try await swira.filters.tree(policy: policy)

                // Spec §2.1: exclude from Favourites anything already in the tree section.
                let structured = treeResult.value.filter {
                    !$0.children.isEmpty || $0.path.segments.count > 1
                }
                let structuredIds = Set(structured.flatMap { $0.allFilters.map(\.id) })
                let favsOnly = favsResult.value.filter { !structuredIds.contains($0.id) }

                self.favourites = favsOnly
                self.filterTree = structured
                self.sidebarIsStale = favsResult.isStale
                self.sidebarStoredAt = favsResult.storedAt
                self.isLoadingSidebar = false
                notifySidebarChanged()
            } catch {
                self.isLoadingSidebar = false
                self.logger.error("Sidebar load failed: \(error)")
                notifySidebarChanged()
            }
        }
    }

    // MARK: - Selection

    func select(_ filter: JiraFilter?) {
        selectedFilter = filter
        issues = []
        nextPageToken = nil
        issueLoadError = nil
        columns = defaultColumns
        notifySelectionChanged()
        if let filter {
            loadIssues(for: filter, pageToken: nil)
        }
    }

    // MARK: - Issue loading

    func loadIssues(for filter: JiraFilter, pageToken: String?) {
        guard let swira else { return }
        guard !isLoadingIssues else { return }
        isLoadingIssues = true
        notifyIssuesChanged()

        let id = filter.id
        let field = sortField
        let descending = sortDescending

        Task {
            do {
                var jql = "filter = \(id)"
                if isSafeFieldToken(field) {
                    jql += " ORDER BY \(field) \(descending ? "DESC" : "ASC")"
                }
                let cols = (try? await resolveColumns(id: id, swira: swira)) ?? defaultColumns
                let fieldIds = Set(cols.map(\.value)).union(SearchService.previewFields)
                let page = try await swira.search.search(
                    jql: jql,
                    fields: Array(fieldIds),
                    maxResults: 50,
                    pageToken: pageToken
                )

                if pageToken == nil {
                    self.issues = page.values
                } else {
                    self.issues.append(contentsOf: page.values)
                }
                self.nextPageToken = page.nextPageToken
                self.columns = cols
                self.isLoadingIssues = false
                self.issueLoadError = nil
                notifyIssuesChanged()
            } catch {
                self.isLoadingIssues = false
                self.issueLoadError = (error as? SwiraError)?.errorDescription ?? "\(error)"
                self.logger.error("Issue load failed: \(error)")
                notifyIssuesChanged()
            }
        }
    }

    func loadNextPage() {
        guard let filter = selectedFilter, let token = nextPageToken else { return }
        loadIssues(for: filter, pageToken: token)
    }

    // MARK: - Sort

    func setSort(field: String, descending: Bool) {
        sortField = field
        sortDescending = descending
        if let filter = selectedFilter {
            issues = []
            nextPageToken = nil
            loadIssues(for: filter, pageToken: nil)
        }
    }

    // MARK: - JQL update

    func updateJQL(_ jql: String, for filter: JiraFilter) async throws {
        guard let swira else { return }
        let validation = try await swira.jql.validate(jql)
        guard validation.errors.isEmpty else {
            throw ValidationError(messages: validation.errors)
        }
        let current = try await swira.filters.get(id: filter.id, policy: .networkOnly).value
        _ = try await swira.filters.update(
            id: filter.id,
            FilterInput(name: current.name, jql: jql, description: current.description)
        )
        // Reload issues with the new JQL.
        if selectedFilter?.id == filter.id {
            issues = []
            nextPageToken = nil
            loadIssues(for: current, pageToken: nil)
        }
    }

    // MARK: - Filter creation

    func createFilter(segments: [String], jql: String, description: String?) async throws -> JiraFilter {
        guard let swira else { throw AppError.notConfigured }
        let path = FilterPath(segments: segments)
        // Name-conflict guard (spec §2.3).
        let existing = try await swira.filters.search(
            FilterQuery(name: path.filterName), policy: .networkOnly
        )
        if existing.value.values.contains(where: { $0.name == path.filterName }) {
            throw AppError.conflict("A filter named '\(path.filterName)' already exists.")
        }
        let created = try await swira.filters.create(at: path, jql: jql, description: description)
        loadSidebar(fresh: true)
        return created
    }

    // MARK: - Filter deletion

    func deleteFilter(_ filter: JiraFilter) async throws {
        guard let swira else { throw AppError.notConfigured }
        try await swira.filters.delete(id: filter.id)
        if selectedFilter?.id == filter.id {
            select(nil)
        }
        loadSidebar(fresh: true)
    }

    // MARK: - Rename / move

    func renameFilter(id: String, newName: String) async throws {
        guard let swira else { throw AppError.notConfigured }
        let current = try await swira.filters.get(id: id, policy: .networkOnly).value
        if current.name != newName {
            let existing = try await swira.filters.search(FilterQuery(name: newName), policy: .networkOnly)
            if existing.value.values.contains(where: { $0.name == newName && $0.id != id }) {
                throw AppError.conflict("A filter named '\(newName)' already exists.")
            }
        }
        _ = try await swira.filters.update(
            id: id,
            FilterInput(name: newName, jql: current.jql ?? "", description: current.description)
        )
        loadSidebar(fresh: true)
    }

    // MARK: - Private helpers

    private func resolveColumns(id: String, swira: Swira) async throws -> [FilterColumn] {
        do {
            let cols = try await swira.filters.columns(id: id)
            return cols.isEmpty ? defaultColumns : cols
        } catch let error as SwiraError {
            if case .notFound = error { return defaultColumns }
            throw error
        }
    }

    private func notifySidebarChanged() { onSidebarChanged?() }
    private func notifySelectionChanged() { onSelectionChanged?() }
    private func notifyIssuesChanged() { onIssuesChanged?() }
    private func notifyContentChanged() { onContentChanged?() }
}

// MARK: - Errors

struct ValidationError: Error, LocalizedError {
    let messages: [String]
    var errorDescription: String? { messages.joined(separator: "\n") }
}

enum AppError: Error, LocalizedError {
    case notConfigured
    case conflict(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Swira is not configured — set JIRA_URL, JIRA_EMAIL, and JIRA_API_TOKEN."
        case .conflict(let msg): return msg
        }
    }
}

// MARK: - Defaults

private let defaultColumns: [FilterColumn] = [
    FilterColumn(label: "Summary", value: "summary"),
    FilterColumn(label: "Status", value: "status"),
    FilterColumn(label: "Type", value: "issuetype"),
    FilterColumn(label: "Priority", value: "priority"),
    FilterColumn(label: "Assignee", value: "assignee"),
    FilterColumn(label: "Updated", value: "updated"),
]

/// Accepts a bare identifier or `cf[10001]`-shaped token for safe interpolation into JQL.
private func isSafeFieldToken(_ token: String) -> Bool {
    !token.isEmpty && token.allSatisfy {
        $0.isLetter || $0.isNumber || $0 == "_" || $0 == "[" || $0 == "]"
    }
}
#endif
