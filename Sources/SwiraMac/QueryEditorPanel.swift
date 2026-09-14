#if canImport(AppKit)
import AppKit
import SwiraCore

/// Sheet-style JQL query editor (spec §3.3).
///
/// Slides down from the top of the window. Shows the filter's JQL, validates before saving,
/// and surfaces errors inline. Cmd+Enter applies; Escape cancels.
final class QueryEditorPanel: NSWindowController {

    private let model: AppModel
    private let filter: JiraFilter

    private var textView: NSTextView!
    private var errorLabel: NSTextField!
    private var applyButton: NSButton!
    private var cancelButton: NSButton!
    private var spinner: NSProgressIndicator!

    init(model: AppModel, filter: JiraFilter) {
        self.model = model
        self.filter = filter
        let window = QueryEditorPanel.makePanel()
        super.init(window: window)
        buildUI()
        populateJQL()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - UI construction

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 260),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Edit Query"
        panel.isFloatingPanel = false
        return panel
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        // JQL text view
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        textView = NSTextView()
        textView.isEditable = true
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.delegate = self
        scrollView.documentView = textView
        contentView.addSubview(scrollView)

        // Error label
        errorLabel = NSTextField(labelWithString: "")
        errorLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(errorLabel)

        // Buttons
        applyButton = NSButton(title: "Apply", target: self, action: #selector(apply(_:)))
        applyButton.bezelStyle = .rounded
        applyButton.keyEquivalent = "\r"
        applyButton.keyEquivalentModifierMask = .command
        applyButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(applyButton)

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
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: errorLabel.topAnchor, constant: -6),

            errorLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            errorLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            errorLabel.bottomAnchor.constraint(equalTo: applyButton.topAnchor, constant: -8),

            applyButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            applyButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            applyButton.widthAnchor.constraint(equalToConstant: 80),

            cancelButton.trailingAnchor.constraint(equalTo: applyButton.leadingAnchor, constant: -8),
            cancelButton.centerYAnchor.constraint(equalTo: applyButton.centerYAnchor),
            cancelButton.widthAnchor.constraint(equalToConstant: 80),

            spinner.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -8),
            spinner.centerYAnchor.constraint(equalTo: applyButton.centerYAnchor),
        ])
    }

    private func populateJQL() {
        let jql = filter.jql ?? ""
        textView.string = jql
        applyJQLHighlighting()
    }

    // MARK: - Basic syntax highlighting

    /// Very light-touch highlighting: keywords in one colour, strings in another.
    /// A full incremental highlighter is out of scope for a prototype.
    private func applyJQLHighlighting() {
        let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
        let storage = textView.textStorage!
        storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: fullRange)

        let jql = textView.string
        // Keywords: AND OR NOT IN ORDER BY ASC DESC
        let keywordPattern = #"\b(AND|OR|NOT|IN|ORDER\s+BY|ASC|DESC|IS|EMPTY|NULL|WAS|CHANGED|DURING|AFTER|BEFORE|ON|FROM|TO)\b"#
        if let regex = try? NSRegularExpression(pattern: keywordPattern, options: .caseInsensitive) {
            for match in regex.matches(in: jql, range: NSRange(jql.startIndex..., in: jql)) {
                storage.addAttribute(.foregroundColor, value: NSColor.systemPurple, range: match.range)
            }
        }
        // Quoted strings
        if let regex = try? NSRegularExpression(pattern: #""[^"]*"|'[^']*'"#) {
            for match in regex.matches(in: jql, range: NSRange(jql.startIndex..., in: jql)) {
                storage.addAttribute(.foregroundColor, value: NSColor.systemGreen, range: match.range)
            }
        }
    }

    // MARK: - Actions

    @objc private func apply(_ sender: Any?) {
        let jql = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        setLoading(true)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.model.updateJQL(jql, for: self.filter)
                await MainActor.run {
                    self.closeSheet()
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
        applyButton.isEnabled = !loading
        cancelButton.isEnabled = !loading
        textView.isEditable = !loading
        spinner.isHidden = !loading
        if loading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    private func showError(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        errorLabel.stringValue = message
        errorLabel.isHidden = false
    }
}

// MARK: - NSTextViewDelegate

extension QueryEditorPanel: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        errorLabel.isHidden = true
        applyJQLHighlighting()
    }
}
#endif
