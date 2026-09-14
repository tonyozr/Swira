#if canImport(AppKit)
import AppKit

/// The single main window (spec §1): sidebar on the left, content area on the right.
///
/// Uses `NSSplitViewController` with a fixed-width sidebar panel and a flexible content panel.
/// The toolbar lives on the window (not on either child view controller) so it spans the full
/// width and the view switcher / Edit Query actions are always visible.
final class MainWindowController: NSWindowController {

    private let model: AppModel
    private var splitViewController: NSSplitViewController!
    private var sidebarVC: SidebarViewController!
    private var contentVC: ContentViewController!

    init(model: AppModel) {
        self.model = model
        let window = Self.makeWindow()
        super.init(window: window)
        buildLayout()
        buildToolbar()
        installObservers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Layout

    private func buildLayout() {
        sidebarVC = SidebarViewController(model: model)
        contentVC = ContentViewController(model: model)

        splitViewController = NSSplitViewController()
        splitViewController.splitView.isVertical = true
        splitViewController.splitView.dividerStyle = .thin

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 320
        sidebarItem.preferredThicknessFraction = 0.22

        let contentItem = NSSplitViewItem(viewController: contentVC)
        contentItem.minimumThickness = 400

        splitViewController.addSplitViewItem(sidebarItem)
        splitViewController.addSplitViewItem(contentItem)

        window?.contentViewController = splitViewController
    }

    // MARK: - Toolbar

    private func buildToolbar() {
        let toolbar = NSToolbar(identifier: "SwiraMacToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
        window?.titleVisibility = .hidden
    }

    // MARK: - Observers

    private func installObservers() {
        model.onSelectionChanged = { [weak self] in
            self?.updateToolbarState()
        }
        model.onContentChanged = { [weak self] in
            self?.updateToolbarState()
        }
    }

    private func updateToolbarState() {
        window?.toolbar?.validateVisibleItems()
    }

    // MARK: - Window factory

    private static func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Swira"
        window.minSize = NSSize(width: 700, height: 450)
        window.center()
        window.setFrameAutosaveName("SwiraMacMainWindow")
        return window
    }
}

// MARK: - NSToolbarDelegate

extension MainWindowController: NSToolbarDelegate {

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.viewSwitcher, .flexibleSpace, .editQuery, .refreshSidebar]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.viewSwitcher, .flexibleSpace, .editQuery, .refreshSidebar]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {

        case .viewSwitcher:
            let segmented = NSSegmentedControl(
                images: [
                    NSImage(systemSymbolName: "tablecells", accessibilityDescription: "Table view")!,
                    NSImage(systemSymbolName: "sidebar.squares.left", accessibilityDescription: "Split view")!,
                ],
                trackingMode: .selectOne,
                target: self,
                action: #selector(viewSwitcherChanged(_:))
            )
            segmented.selectedSegment = 0
            segmented.setWidth(36, forSegment: 0)
            segmented.setWidth(36, forSegment: 1)
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = segmented
            item.label = "View"
            return item

        case .editQuery:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Edit Query"
            item.toolTip = "Edit the filter's JQL query"
            item.image = NSImage(systemSymbolName: "pencil.line", accessibilityDescription: "Edit Query")
            item.target = self
            item.action = #selector(editQuery(_:))
            item.isEnabled = model.selectedFilter != nil
            return item

        case .refreshSidebar:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Refresh"
            item.toolTip = "Reload filters from Jira"
            item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
            item.target = self
            item.action = #selector(refreshSidebar(_:))
            return item

        default:
            return nil
        }
    }

    // MARK: - Toolbar actions

    @objc private func viewSwitcherChanged(_ sender: NSSegmentedControl) {
        guard let filter = model.selectedFilter else { return }
        let mode: AppModel.ViewMode = sender.selectedSegment == 0 ? .table : .split
        model.setViewMode(mode, for: filter.id)
        contentVC.applyViewMode(mode)
    }

    @objc private func editQuery(_ sender: Any?) {
        guard let filter = model.selectedFilter else { return }
        let panel = QueryEditorPanel(model: model, filter: filter)
        window?.beginSheet(panel.window!) { _ in }
    }

    @objc private func refreshSidebar(_ sender: Any?) {
        model.loadSidebar(fresh: true)
    }
}

// MARK: - Toolbar item identifiers

private extension NSToolbarItem.Identifier {
    static let viewSwitcher = NSToolbarItem.Identifier("SwiraMac.viewSwitcher")
    static let editQuery    = NSToolbarItem.Identifier("SwiraMac.editQuery")
    static let refreshSidebar = NSToolbarItem.Identifier("SwiraMac.refreshSidebar")
}
#endif
