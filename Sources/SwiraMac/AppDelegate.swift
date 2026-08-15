#if canImport(AppKit)
import AppKit
import SwiraCore
import Logging

/// Application delegate for the macOS AppKit client.
///
/// Builds `Swira` from the environment (same variables as the other clients — `JIRA_URL`,
/// `JIRA_EMAIL`, `JIRA_API_TOKEN`) and hands the assembled model to the window controller.
/// If credentials are absent the app launches into a "not configured" state that shows a
/// setup banner rather than crashing.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var windowController: MainWindowController?
    private var model: AppModel!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        var logger = Logger(label: "swira.mac")
        logger.logLevel = .info

        let swira: Swira?
        let configError: String?
        do {
            swira = try Swira.fromEnvironment()
            configError = nil
        } catch {
            swira = nil
            configError = (error as? SwiraError)?.errorDescription ?? "\(error)"
            logger.warning("SwiraCore not configured: \(configError!)")
        }

        model = AppModel(swira: swira, configurationError: configError, logger: logger)

        let wc = MainWindowController(model: model)
        wc.showWindow(nil)
        self.windowController = wc

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
#endif
