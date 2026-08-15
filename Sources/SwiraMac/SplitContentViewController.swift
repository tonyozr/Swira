#if canImport(AppKit)
import AppKit
import WebKit
import SwiraCore

/// Split view mode (spec §3.2): thick-row list on the left, WKWebView issue page on the right.
///
/// All editing in this mode happens in the embedded Jira web page — the list is read-only.
final class SplitContentViewController: NSViewController {

    private let model: AppModel
    private var splitView: NSSplitView!
    private var listView: NSScrollView!
    private var tableView: NSTableView!
    private var webView: WKWebView!
    private var placeholderLabel: NSTextField!

    private var selectedIssueRow: Int = -1

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(splitView)

        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: container.topAnchor),
            splitView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // Left: thick-row issue list
        tableView = NSTableView()
        tableView.style = .plain
        tableView.rowSizeStyle = .large
        tableView.selectionHighlightStyle = .regular
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("issue"))
        col.title = "Issue"
        col.resizingMask = .autoresizingMask
        tableView.addTableColumn(col)

        listView = NSScrollView()
        listView.documentView = tableView
        listView.hasVerticalScroller = true
        listView.autohidesScrollers = true

        // Right: WKWebView (spec §3.2 — full Jira page, fully interactive)
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self

        placeholderLabel = NSTextField(labelWithString: "Select an issue")
        placeholderLabel.font = .systemFont(ofSize: 16)
        placeholderLabel.textColor = .tertiaryLabelColor
        placeholderLabel.alignment = .center
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false

        let rightContainer = NSView()
        rightContainer.addSubview(webView)
        rightContainer.addSubview(placeholderLabel)
        webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: rightContainer.topAnchor),
            webView.leadingAnchor.constraint(equalTo: rightContainer.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: rightContainer.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: rightContainer.bottomAnchor),
            placeholderLabel.centerXAnchor.constraint(equalTo: rightContainer.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: rightContainer.centerYAnchor),
        ])

        splitView.addArrangedSubview(listView)
        splitView.addArrangedSubview(rightContainer)
        splitView.setPosition(280, ofDividerAt: 0)

        self.view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        installObservers()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        tableView.reloadData()
    }

    private func installObservers() {
        model.onIssuesChanged = { [weak self] in
            guard let self, self.isViewLoaded, self.view.window != nil else { return }
            self.tableView.reloadData()
        }
        model.onSelectionChanged = { [weak self] in
            guard let self, self.isViewLoaded, self.view.window != nil else { return }
            self.selectedIssueRow = -1
            self.tableView.reloadData()
            self.updateWebView(for: nil)
        }
    }

    private func updateWebView(for issue: JiraIssue?) {
        guard let issue, let base = model.swira?.configuration.site.baseURL else {
            webView.isHidden = true
            placeholderLabel.isHidden = false
            return
        }
        webView.isHidden = false
        placeholderLabel.isHidden = true
        let url = base.appendingPathComponent("browse/\(issue.key)")
        webView.load(URLRequest(url: url))
    }
}

// MARK: - NSTableViewDataSource

extension SplitContentViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { model.issues.count }
}

// MARK: - NSTableViewDelegate

extension SplitContentViewController: NSTableViewDelegate {

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 68 }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard row < model.issues.count else { return nil }
        let issue = model.issues[row]

        let cellId = NSUserInterfaceItemIdentifier("SplitIssueCell")
        let cell = tableView.makeView(withIdentifier: cellId, owner: nil) as? SplitIssueCell
            ?? SplitIssueCell(identifier: cellId)
        cell.configure(with: issue)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        selectedIssueRow = row
        let issue = row >= 0 ? model.issues[row] : nil
        updateWebView(for: issue)
    }
}

// MARK: - WKNavigationDelegate

extension SplitContentViewController: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // Allow navigation within the same Jira instance; open external links in the system browser.
        if let url = navigationAction.request.url,
           let base = model.swira?.configuration.site.baseURL,
           url.host != base.host {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }
}

// MARK: - Thick row cell

/// A multi-line cell for the split view's issue list (spec §3.2: key, summary, status, assignee).
private final class SplitIssueCell: NSTableCellView {

    private let keyLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let assigneeLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        keyLabel.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        keyLabel.textColor = .secondaryLabelColor

        summaryLabel.font = .systemFont(ofSize: 13)
        summaryLabel.textColor = .labelColor
        summaryLabel.lineBreakMode = .byTruncatingTail

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor

        assigneeLabel.font = .systemFont(ofSize: 11)
        assigneeLabel.textColor = .secondaryLabelColor
        assigneeLabel.alignment = .right

        for v in [keyLabel, summaryLabel, statusLabel, assigneeLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            keyLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            keyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),

            summaryLabel.topAnchor.constraint(equalTo: keyLabel.bottomAnchor, constant: 2),
            summaryLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            summaryLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

            statusLabel.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 4),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),

            assigneeLabel.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            assigneeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(with issue: JiraIssue) {
        keyLabel.stringValue = issue.key
        summaryLabel.stringValue = issue.summary ?? "(no summary)"
        statusLabel.stringValue = issue.status ?? ""
        assigneeLabel.stringValue = issue.assignee?.displayName ?? "Unassigned"
    }
}
#endif
