#if canImport(AppKit)
import AppKit
import SwiraCore

/// The right pane of the main split: holds either the table view or the split view (spec §3).
///
/// Acts as a container that swaps `TableViewController` / `SplitContentViewController`
/// in and out based on the current view mode. It also shows a "no filter selected" placeholder
/// and an error banner when needed.
final class ContentViewController: NSViewController {

    private let model: AppModel

    private var tableVC: TableViewController!
    private var splitVC: SplitContentViewController!
    private var currentChild: NSViewController?

    // Placeholder shown before any filter is selected.
    private var placeholderLabel: NSTextField!
    // Configuration error banner.
    private var errorBanner: NSTextField?

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        placeholderLabel = NSTextField(labelWithString: "Select a filter from the sidebar")
        placeholderLabel.font = .systemFont(ofSize: 16)
        placeholderLabel.textColor = .tertiaryLabelColor
        placeholderLabel.alignment = .center
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(placeholderLabel)

        NSLayoutConstraint.activate([
            placeholderLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        if let configError = model.configurationError {
            let banner = NSTextField(labelWithString: "⚠ Not configured: \(configError)")
            banner.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            banner.textColor = .white
            banner.backgroundColor = .systemOrange
            banner.isBezeled = false
            banner.drawsBackground = true
            banner.alignment = .center
            banner.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(banner)
            NSLayoutConstraint.activate([
                banner.topAnchor.constraint(equalTo: container.topAnchor),
                banner.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                banner.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                banner.heightAnchor.constraint(equalToConstant: 26),
            ])
            self.errorBanner = banner
        }

        self.view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableVC = TableViewController(model: model)
        splitVC = SplitContentViewController(model: model)
        installObservers()
    }

    // MARK: - Observers

    private func installObservers() {
        model.onSelectionChanged = { [weak self] in self?.handleSelectionChanged() }
        model.onContentChanged = { [weak self] in self?.handleContentChanged() }
    }

    private func handleSelectionChanged() {
        guard let filter = model.selectedFilter else {
            remove(child: currentChild)
            currentChild = nil
            placeholderLabel.isHidden = false
            return
        }
        placeholderLabel.isHidden = true
        applyViewMode(model.viewMode(for: filter.id))
    }

    private func handleContentChanged() {
        guard let filter = model.selectedFilter else { return }
        applyViewMode(model.viewMode(for: filter.id))
    }

    // MARK: - View mode switching

    func applyViewMode(_ mode: AppModel.ViewMode) {
        switch mode {
        case .table: show(child: tableVC)
        case .split: show(child: splitVC)
        }
    }

    private func show(child: NSViewController) {
        guard child !== currentChild else { return }
        remove(child: currentChild)
        addChild(child)

        let childView = child.view
        childView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(childView)

        let topAnchor: NSLayoutYAxisAnchor
        if let banner = errorBanner {
            topAnchor = banner.bottomAnchor
        } else {
            topAnchor = view.topAnchor
        }

        NSLayoutConstraint.activate([
            childView.topAnchor.constraint(equalTo: topAnchor),
            childView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            childView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            childView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        currentChild = child
    }

    private func remove(child: NSViewController?) {
        guard let child else { return }
        child.view.removeFromSuperview()
        child.removeFromParent()
    }
}
#endif
