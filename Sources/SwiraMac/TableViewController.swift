#if canImport(AppKit)
import AppKit
import SwiraCore

/// Table view mode (spec §3.1): one thin row per issue, configurable columns.
///
/// Columns are read from `model.columns` (which follows the filter's configured set with a
/// fixed fallback). Cells are read-only in this prototype; in-cell editing is v1 scope but
/// requires the full IssueService plumbing left to a future pass.
final class TableViewController: NSViewController {

    private let model: AppModel
    private var tableView: NSTableView!
    private var scrollView: NSScrollView!
    private var statusBar: NSTextField!
    private var loadMoreButton: NSButton!
    private var spinner: NSProgressIndicator!

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        // Table
        tableView = NSTableView()
        tableView.style = .plain
        tableView.rowSizeStyle = .default
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsColumnResizing = true
        tableView.allowsColumnReordering = true
        tableView.columnAutoresizingStyle = .sequentialColumnAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.doubleAction = #selector(openInBrowser(_:))
        tableView.target = self

        scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        // Status bar
        statusBar = NSTextField(labelWithString: "")
        statusBar.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusBar.textColor = .secondaryLabelColor
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(statusBar)

        // Load More button
        loadMoreButton = NSButton(title: "Load More", target: self, action: #selector(loadMore(_:)))
        loadMoreButton.bezelStyle = .rounded
        loadMoreButton.isHidden = true
        loadMoreButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(loadMoreButton)

        // Spinner
        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isHidden = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(spinner)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: statusBar.topAnchor, constant: -2),

            statusBar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            statusBar.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),

            loadMoreButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            loadMoreButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),

            spinner.trailingAnchor.constraint(equalTo: loadMoreButton.leadingAnchor, constant: -6),
            spinner.centerYAnchor.constraint(equalTo: loadMoreButton.centerYAnchor),
        ])

        self.view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        installObservers()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        rebuildColumns()
        tableView.reloadData()
        updateStatusBar()
    }

    // MARK: - Observers

    private func installObservers() {
        model.onIssuesChanged = { [weak self] in
            guard let self, self.isViewLoaded, self.view.window != nil else { return }
            self.rebuildColumns()
            self.tableView.reloadData()
            self.updateStatusBar()
        }
        model.onSelectionChanged = { [weak self] in
            guard let self, self.isViewLoaded, self.view.window != nil else { return }
            self.rebuildColumns()
            self.tableView.reloadData()
            self.updateStatusBar()
        }
    }

    // MARK: - Columns

    private func rebuildColumns() {
        // Remove existing data columns (keep none initially — rebuild from scratch).
        while tableView.tableColumns.count > 0 {
            tableView.removeTableColumn(tableView.tableColumns[0])
        }

        for col in model.columns {
            let tc = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(col.value))
            tc.title = col.label
            tc.minWidth = 60
            tc.width = preferredWidth(for: col.value)
            tableView.addTableColumn(tc)
        }
    }

    private func preferredWidth(for fieldId: String) -> CGFloat {
        switch fieldId {
        case "summary": return 300
        case "status", "issuetype", "priority": return 90
        case "assignee": return 130
        case "updated", "created": return 130
        default: return 120
        }
    }

    // MARK: - Status bar

    private func updateStatusBar() {
        if model.isLoadingIssues {
            statusBar.stringValue = "Loading…"
            spinner.isHidden = false
            spinner.startAnimation(nil)
            loadMoreButton.isHidden = true
        } else if let error = model.issueLoadError {
            statusBar.stringValue = "⚠ \(error)"
            statusBar.textColor = .systemRed
            spinner.isHidden = true
            spinner.stopAnimation(nil)
            loadMoreButton.isHidden = true
        } else {
            let count = model.issues.count
            statusBar.stringValue = "\(count) issue\(count == 1 ? "" : "s")"
            statusBar.textColor = .secondaryLabelColor
            spinner.isHidden = true
            spinner.stopAnimation(nil)
            loadMoreButton.isHidden = model.nextPageToken == nil
        }
    }

    // MARK: - Actions

    @objc private func loadMore(_ sender: Any?) {
        model.loadNextPage()
    }

    @objc private func openInBrowser(_ sender: Any?) {
        let row = tableView.clickedRow
        guard row >= 0, row < model.issues.count else { return }
        let issue = model.issues[row]
        if let base = model.swira?.configuration.site.baseURL {
            let url = base.appendingPathComponent("browse/\(issue.key)")
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - NSTableViewDataSource

extension TableViewController: NSTableViewDataSource {

    func numberOfRows(in tableView: NSTableView) -> Int {
        model.issues.count
    }
}

// MARK: - NSTableViewDelegate

extension TableViewController: NSTableViewDelegate {

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard row < model.issues.count, let tableColumn else { return nil }
        let issue = model.issues[row]
        let fieldId = tableColumn.identifier.rawValue

        let cell = tableView.makeView(
            withIdentifier: NSUserInterfaceItemIdentifier("IssueCell"), owner: nil
        ) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = NSUserInterfaceItemIdentifier("IssueCell")

        if cell.textField == nil {
            let tf = NSTextField(labelWithString: "")
            tf.lineBreakMode = .byTruncatingTail
            tf.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(tf)
            cell.textField = tf
            NSLayoutConstraint.activate([
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            ])
        }

        cell.textField?.stringValue = cellValue(issue: issue, fieldId: fieldId)
        cell.textField?.textColor = fieldId == "status"
            ? statusColor(for: issue.statusCategory)
            : .labelColor
        return cell
    }

    private func cellValue(issue: JiraIssue, fieldId: String) -> String {
        switch fieldId {
        case "summary":   return issue.summary ?? ""
        case "status":    return issue.status ?? ""
        case "issuetype": return issue.issueType ?? ""
        case "priority":  return issue.priority ?? ""
        case "assignee":  return issue.assignee?.displayName ?? "Unassigned"
        case "updated":   return issue.updated.map { shortDate($0) } ?? ""
        case "created":   return issue.created.map { shortDate($0) } ?? ""
        default:
            // Generic: try to pull a string or nested name from the field bag.
            if let field = issue.fields[fieldId] {
                if let str = field.stringValue { return str }
                if let name = field["name"]?.stringValue { return name }
                if let displayName = field["displayName"]?.stringValue { return displayName }
            }
            return ""
        }
    }

    private func statusColor(for category: String?) -> NSColor {
        switch category {
        case "new":          return .secondaryLabelColor
        case "indeterminate": return .systemBlue
        case "done":         return .systemGreen
        default:             return .labelColor
        }
    }

    private func shortDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .short
        fmt.timeStyle = .none
        return fmt.string(from: date)
    }
}
#endif
