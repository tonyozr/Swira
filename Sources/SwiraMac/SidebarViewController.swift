#if canImport(AppKit)
import AppKit
import SwiraCore

// MARK: - Sidebar outline item

/// Typed nodes the `NSOutlineView` data source deals in.
enum SidebarItem {
    case sectionHeader(String)               // "FAVOURITES" / "FILTERS"
    case favourite(JiraFilter)
    case treeNode(FilterTreeNode)
}

// MARK: - SidebarViewController

/// The left pane: two sections — Favourites (spec §2.1) and the filter tree (§2.2).
///
/// Uses `NSOutlineView` with group rows for the section headers and a "+" button at the
/// bottom for filter creation (spec §2.3).
final class SidebarViewController: NSViewController {

    private let model: AppModel

    private var outlineView: NSOutlineView!
    private var scrollView: NSScrollView!
    private var addButton: NSButton!
    private var statusLabel: NSTextField!

    // Flat item arrays mirroring what `model` currently holds.
    private var favourites: [JiraFilter] = []
    private var treeRoots: [FilterTreeNode] = []

    // Persisted expand/collapse state keyed by full filter path (spec §2.2).
    private var expandedPaths: Set<String> = {
        let stored = UserDefaults.standard.stringArray(forKey: "SwiraMac.expandedPaths") ?? []
        return Set(stored)
    }()

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - View lifecycle

    override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        // Outline view
        outlineView = NSOutlineView()
        outlineView.style = .sourceList
        outlineView.headerView = nil
        outlineView.indentationPerLevel = 14
        outlineView.rowSizeStyle = .default
        outlineView.selectionHighlightStyle = .sourceList
        outlineView.floatsGroupRows = false
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        outlineView.registerForDraggedTypes([.string])

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("filter"))
        column.title = "Filter"
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        // Status label (freshness, spec §3.4)
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(statusLabel)

        // "+" button (spec §2.3)
        addButton = NSButton(title: "+", target: self, action: #selector(addFilter(_:)))
        addButton.bezelStyle = .texturedRounded
        addButton.font = .systemFont(ofSize: 16, weight: .medium)
        addButton.toolTip = "Create new filter"
        addButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(addButton)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -4),

            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: addButton.leadingAnchor, constant: -4),
            statusLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),

            addButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            addButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
            addButton.widthAnchor.constraint(equalToConstant: 28),
            addButton.heightAnchor.constraint(equalToConstant: 24),
        ])

        self.view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        installObservers()
        model.loadSidebar()
    }

    // MARK: - Observers

    private func installObservers() {
        model.onSidebarChanged = { [weak self] in self?.reloadSidebar() }
        model.onSelectionChanged = { [weak self] in self?.syncSelection() }
    }

    private func reloadSidebar() {
        favourites = model.favourites
        treeRoots = model.filterTree
        outlineView.reloadData()
        restoreExpansion()
        syncSelection()
        updateStatusLabel()
    }

    private func syncSelection() {
        guard let filter = model.selectedFilter else {
            outlineView.deselectAll(nil)
            return
        }
        // Walk the outline to find and select the matching row.
        selectRow(matchingId: filter.id)
    }

    private func updateStatusLabel() {
        if model.isLoadingSidebar {
            statusLabel.stringValue = "Loading…"
            return
        }
        guard let storedAt = model.sidebarStoredAt else {
            statusLabel.stringValue = ""
            return
        }
        let fmt = DateFormatter()
        fmt.timeStyle = .short
        fmt.dateStyle = .none
        let timeStr = fmt.string(from: storedAt)
        if model.sidebarIsStale {
            statusLabel.stringValue = "⚠ as of \(timeStr)"
            statusLabel.textColor = .systemOrange
        } else {
            statusLabel.stringValue = "Updated \(timeStr)"
            statusLabel.textColor = .secondaryLabelColor
        }
    }

    // MARK: - Expansion persistence

    private func restoreExpansion() {
        // Expand roots that were previously expanded.
        for root in treeRoots {
            restoreExpansion(of: root)
        }
    }

    private func restoreExpansion(of node: FilterTreeNode) {
        let key = node.path.filterName
        if expandedPaths.contains(key) {
            outlineView.expandItem(SidebarItem.treeNode(node))
        }
        for child in node.children {
            restoreExpansion(of: child)
        }
    }

    private func persistExpansion() {
        UserDefaults.standard.set(Array(expandedPaths), forKey: "SwiraMac.expandedPaths")
    }

    // MARK: - Selection helper

    private func selectRow(matchingId id: String) {
        let rowCount = outlineView.numberOfRows
        for row in 0..<rowCount {
            if let item = outlineView.item(atRow: row) as? SidebarItem,
               case .favourite(let f) = item, f.id == id {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                return
            }
            if let item = outlineView.item(atRow: row) as? SidebarItem,
               case .treeNode(let node) = item, node.filter?.id == id {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                return
            }
        }
    }

    // MARK: - Actions

    @objc private func addFilter(_ sender: Any?) {
        let panel = FilterCreationPanel(model: model, defaultPath: defaultCreationPath())
        view.window?.beginSheet(panel.window!) { _ in }
    }

    private func defaultCreationPath() -> [String] {
        // If a tree node is selected, pre-fill with that path; otherwise use the default root.
        if let filter = model.selectedFilter {
            let segments = filter.path.segments
            if segments.count > 1 {
                return segments
            }
        }
        return [FilterPath.defaultRoot]
    }

    // MARK: - Context menu

    override func rightMouseDown(with event: NSEvent) {
        let point = outlineView.convert(event.locationInWindow, from: nil)
        let row = outlineView.row(at: point)
        guard row >= 0 else { return super.rightMouseDown(with: event) }
        let item = outlineView.item(atRow: row) as? SidebarItem

        let menu = NSMenu()
        if case .favourite(let f) = item {
            menu.addItem(NSMenuItem(
                title: "Rename \"\(f.path.leaf)\"",
                action: #selector(renameFilterMenuItem(_:)),
                keyEquivalent: ""
            ))
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(
                title: "Delete \"\(f.path.leaf)\"…",
                action: #selector(deleteFilterMenuItem(_:)),
                keyEquivalent: ""
            ))
        } else if case .treeNode(let node) = item, let _ = node.filter {
            menu.addItem(NSMenuItem(
                title: "Rename \"\(node.name)\"",
                action: #selector(renameFilterMenuItem(_:)),
                keyEquivalent: ""
            ))
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(
                title: "Delete \"\(node.name)\"…",
                action: #selector(deleteFilterMenuItem(_:)),
                keyEquivalent: ""
            ))
        } else {
            return super.rightMouseDown(with: event)
        }

        // Tag the items with the row index so the action can recover it.
        for item in menu.items { item.tag = row }
        NSMenu.popUpContextMenu(menu, with: event, for: outlineView)
    }

    @objc private func renameFilterMenuItem(_ sender: NSMenuItem) {
        let row = sender.tag
        guard let item = outlineView.item(atRow: row) as? SidebarItem else { return }
        let filter: JiraFilter?
        let currentLeaf: String
        switch item {
        case .favourite(let f):
            filter = f
            currentLeaf = f.path.leaf
        case .treeNode(let n):
            filter = n.filter
            currentLeaf = n.name
        default:
            return
        }
        guard let filter else { return }

        let alert = NSAlert()
        alert.messageText = "Rename Filter"
        alert.informativeText = "Enter a new leaf name for \"\(currentLeaf)\":"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = currentLeaf
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let newLeaf = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !newLeaf.isEmpty else { return }
            let newSegments = filter.path.segments.dropLast() + [newLeaf]
            let newName = FilterPath(segments: Array(newSegments)).filterName
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.model.renameFilter(id: filter.id, newName: newName)
                } catch {
                    self.showError(error)
                }
            }
        }
    }

    @objc private func deleteFilterMenuItem(_ sender: NSMenuItem) {
        let row = sender.tag
        guard let item = outlineView.item(atRow: row) as? SidebarItem else { return }
        let filter: JiraFilter?
        switch item {
        case .favourite(let f): filter = f
        case .treeNode(let n): filter = n.filter
        default: filter = nil
        }
        guard let filter else { return }

        let alert = NSAlert()
        alert.messageText = "Delete Filter"
        alert.informativeText = "Delete \"\(filter.path.leaf)\"? This cannot be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.model.deleteFilter(filter)
                } catch {
                    self.showError(error)
                }
            }
        }
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        alert.alertStyle = .warning
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

// MARK: - NSOutlineViewDataSource

extension SidebarViewController: NSOutlineViewDataSource {

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            // Root: two section headers + their children counts.
            return 2
        }
        if let sidebarItem = item as? SidebarItem {
            switch sidebarItem {
            case .sectionHeader(let title):
                return title == "FAVOURITES" ? favourites.count : treeRoots.count
            case .treeNode(let node):
                return node.children.count
            case .favourite:
                return 0
            }
        }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return SidebarItem.sectionHeader(index == 0 ? "FAVOURITES" : "FILTERS")
        }
        if let sidebarItem = item as? SidebarItem {
            switch sidebarItem {
            case .sectionHeader(let title):
                if title == "FAVOURITES" {
                    return SidebarItem.favourite(favourites[index])
                } else {
                    return SidebarItem.treeNode(treeRoots[index])
                }
            case .treeNode(let node):
                return SidebarItem.treeNode(node.children[index])
            default:
                break
            }
        }
        fatalError("Unexpected outline item")
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if let sidebarItem = item as? SidebarItem {
            switch sidebarItem {
            case .sectionHeader: return true
            case .treeNode(let node): return !node.children.isEmpty
            case .favourite: return false
            }
        }
        return false
    }

    // MARK: Drag source

    func outlineView(
        _ outlineView: NSOutlineView,
        pasteboardWriterForItem item: Any
    ) -> NSPasteboardWriting? {
        guard let sidebarItem = item as? SidebarItem else { return nil }
        let filterId: String
        switch sidebarItem {
        case .favourite(let f): filterId = f.id
        case .treeNode(let n):
            guard let f = n.filter else { return nil }
            filterId = f.id
        default: return nil
        }
        let pbi = NSPasteboardItem()
        pbi.setString(filterId, forType: .string)
        return pbi
    }

    // MARK: Drop target (move within tree — a rename, spec §2.3)

    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard item is SidebarItem else { return [] }
        return .move
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        guard let targetItem = item as? SidebarItem,
              case .treeNode(let targetNode) = targetItem else { return false }
        guard let filterId = info.draggingPasteboard.string(forType: .string) else { return false }

        // Find the source filter.
        let allFilters = model.favourites + model.filterTree.flatMap { $0.allFilters }
        guard let sourceFilter = allFilters.first(where: { $0.id == filterId }) else { return false }

        let newName = targetNode.path.appending(sourceFilter.path.leaf).filterName
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.model.renameFilter(id: filterId, newName: newName)
            } catch {
                self.showError(error)
            }
        }
        return true
    }
}

// MARK: - NSOutlineViewDelegate

extension SidebarViewController: NSOutlineViewDelegate {

    func outlineView(
        _ outlineView: NSOutlineView,
        isGroupItem item: Any
    ) -> Bool {
        if case .sectionHeader = item as? SidebarItem { return true }
        return false
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        shouldSelectItem item: Any
    ) -> Bool {
        // Section headers are not selectable; virtual tree nodes (no filter) are expandable but
        // do not load a query.
        if case .sectionHeader = item as? SidebarItem { return false }
        if case .treeNode(let node) = item as? SidebarItem, node.filter == nil { return false }
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let sidebarItem = item as? SidebarItem else { return nil }

        switch sidebarItem {
        case .sectionHeader(let title):
            let cell = outlineView.makeView(
                withIdentifier: NSUserInterfaceItemIdentifier("HeaderCell"), owner: nil
            ) as? NSTableCellView ?? NSTableCellView()
            cell.identifier = NSUserInterfaceItemIdentifier("HeaderCell")
            if cell.textField == nil {
                let tf = NSTextField(labelWithString: "")
                tf.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
                tf.textColor = .secondaryLabelColor
                tf.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(tf)
                cell.textField = tf
                NSLayoutConstraint.activate([
                    tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
                ])
            }
            cell.textField?.stringValue = title
            return cell

        case .favourite(let filter):
            return makeFilterCell(outlineView, name: filter.path.leaf, isVirtual: false)

        case .treeNode(let node):
            return makeFilterCell(outlineView, name: node.name, isVirtual: node.isVirtual)
        }
    }

    private func makeFilterCell(_ outlineView: NSOutlineView, name: String, isVirtual: Bool) -> NSView {
        let cell = outlineView.makeView(
            withIdentifier: NSUserInterfaceItemIdentifier("FilterCell"), owner: nil
        ) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = NSUserInterfaceItemIdentifier("FilterCell")
        if cell.textField == nil {
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(tf)
            cell.textField = tf
            NSLayoutConstraint.activate([
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            ])
        }
        cell.textField?.stringValue = name
        cell.textField?.textColor = isVirtual ? .secondaryLabelColor : .labelColor
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = outlineView.selectedRow
        guard row >= 0 else { return }
        guard let item = outlineView.item(atRow: row) as? SidebarItem else { return }

        switch item {
        case .favourite(let f):
            model.select(f)
        case .treeNode(let node):
            if let filter = node.filter {
                model.select(filter)
            }
        default:
            break
        }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        if let node = (notification.userInfo?["NSObject"] as? SidebarItem).flatMap({
            if case .treeNode(let n) = $0 { return n } else { return nil }
        }) {
            expandedPaths.insert(node.path.filterName)
            persistExpansion()
        }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if let node = (notification.userInfo?["NSObject"] as? SidebarItem).flatMap({
            if case .treeNode(let n) = $0 { return n } else { return nil }
        }) {
            expandedPaths.remove(node.path.filterName)
            persistExpansion()
        }
    }
}
#endif
