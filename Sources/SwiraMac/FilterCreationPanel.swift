#if canImport(AppKit)
import AppKit
import SwiraCore

/// Sheet for creating a new filter (spec §2.3).
///
/// Asks for a path (pre-filled with `defaultPath`) and JQL. Enter submits from the name field;
/// in the JQL text view it inserts a newline instead (spec §2.3: "Enter MUST behave as a plain
/// newline instead in a multi-line field"). After creation the model selects the new filter
/// and, if JQL was left empty, the model caller is expected to open the query editor.
final class FilterCreationPanel: NSWindowController {

    private let model: AppModel
    private let defaultPath: [String]

    private var pathField: NSTextField!       // Joined path, e.g. "Swira: Versions: Current"
    private var jqlView: NSTextView!
    private var errorLabel: NSTextField!
    private var createButton: NSButton!
    private var cancelButton: NSButton!
    private var spinner: NSProgressIndicator!

    init(model: AppModel, defaultPath: [String]) {
        self.model = model
        self.defaultPath = defaultPath
        super.init(window: FilterCreationPanel.makePanel())
        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 300),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "New Filter"
        return panel
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        // Path label + field
        let pathLabel = NSTextField(labelWithString: "Name / path:")
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(pathLabel)

        pathField = NSTextField(string: defaultPath.joined(separator: FilterPath.separator))
        pathField.translatesAutoresizingMaskIntoConstraints = false
        pathField.placeholderString = "e.g. Swira: MyFilter"
        pathField.delegate = self
        contentView.addSubview(pathField)

        // JQL label + text view
        let jqlLabel = NSTextField(labelWithString: "JQL (optional):")
        jqlLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(jqlLabel)

        let jqlScroll = NSScrollView()
        jqlScroll.hasVerticalScroller = true
        jqlScroll.autohidesScrollers = true
        jqlScroll.borderType = .bezelBorder
        jqlScroll.translatesAutoresizingMaskIntoConstraints = false

        jqlView = NSTextView()
        jqlView.isEditable = true
        jqlView.isRichText = false
        jqlView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        jqlView.isAutomaticQuoteSubstitutionEnabled = false
        jqlView.isAutomaticDashSubstitutionEnabled = false
        jqlView.textContainerInset = NSSize(width: 4, height: 4)
        jqlScroll.documentView = jqlView
        contentView.addSubview(jqlScroll)

        // Error label
        errorLabel = NSTextField(labelWithString: "")
        errorLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(errorLabel)

        // Buttons
        createButton = NSButton(title: "Create", target: self, action: #selector(create(_:)))
        createButton.bezelStyle = .rounded
        createButton.keyEquivalent = "\r"
        createButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(createButton)

        cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(cancelButton)

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isHidden = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(spinner)

        NSLayoutConstraint.activate([
            pathLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            pathLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),

            pathField.topAnchor.constraint(equalTo: pathLabel.bottomAnchor, constant: 4),
            pathField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            pathField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),

            jqlLabel.topAnchor.constraint(equalTo: pathField.bottomAnchor, constant: 10),
            jqlLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),

            jqlScroll.topAnchor.constraint(equalTo: jqlLabel.bottomAnchor, constant: 4),
            jqlScroll.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            jqlScroll.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            jqlScroll.heightAnchor.constraint(equalToConstant: 90),

            errorLabel.topAnchor.constraint(equalTo: jqlScroll.bottomAnchor, constant: 4),
            errorLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            errorLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            errorLabel.bottomAnchor.constraint(lessThanOrEqualTo: createButton.topAnchor, constant: -4),

            createButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            createButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            createButton.widthAnchor.constraint(equalToConstant: 80),

            cancelButton.trailingAnchor.constraint(equalTo: createButton.leadingAnchor, constant: -8),
            cancelButton.centerYAnchor.constraint(equalTo: createButton.centerYAnchor),
            cancelButton.widthAnchor.constraint(equalToConstant: 80),

            spinner.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -8),
            spinner.centerYAnchor.constraint(equalTo: createButton.centerYAnchor),
        ])
    }

    // MARK: - Actions

    @objc private func create(_ sender: Any?) {
        errorLabel.isHidden = true
        let rawPath = pathField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !rawPath.isEmpty else {
            showError("Please enter a name or path for the filter.")
            return
        }
        let segments = rawPath
            .components(separatedBy: FilterPath.separator)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !segments.isEmpty else {
            showError("Invalid filter path.")
            return
        }
        let jql = jqlView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        setLoading(true)

        Task { [weak self] in
            guard let self else { return }
            do {
                let created = try await self.model.createFilter(
                    segments: segments,
                    jql: jql,
                    description: nil
                )
                await MainActor.run {
                    self.closeSheet()
                    // Select the new filter (spec §2.3: client MUST select and open immediately).
                    self.model.select(created)
                    // If JQL was empty, open the query editor (spec §2.3).
                    if jql.isEmpty {
                        if let window = NSApp.mainWindow,
                           let wc = window.windowController as? MainWindowController {
                            wc.perform(Selector(("editQuery:")), with: nil, afterDelay: 0.2)
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.setLoading(false)
                    self.showError(error)
                }
            }
        }
    }

    @objc private func cancel(_ sender: Any?) {
        closeSheet()
    }

    private func closeSheet() {
        guard let sheet = window, let parent = sheet.sheetParent else { return }
        parent.endSheet(sheet)
    }

    private func setLoading(_ loading: Bool) {
        createButton.isEnabled = !loading
        cancelButton.isEnabled = !loading
        pathField.isEnabled = !loading
        jqlView.isEditable = !loading
        spinner.isHidden = !loading
        if loading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    private func showError(_ error: Error) {
        showError((error as? LocalizedError)?.errorDescription ?? "\(error)")
    }

    private func showError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
    }
}

// MARK: - NSTextFieldDelegate

extension FilterCreationPanel: NSTextFieldDelegate {
    // Enter in the path field submits (spec §2.3: "Enter MUST submit from any single-line field").
    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            create(nil)
            return true
        }
        return false
    }
}
#endif
