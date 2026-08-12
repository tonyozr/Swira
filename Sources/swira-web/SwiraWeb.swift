import ArgumentParser
import Foundation
import Logging
import SwiraCore

/// The Swira web client: serves the browser UI and its JSON API on localhost.
///
/// This is the first client implementation of docs/CLIENT-SPEC.md (§4, Web). It binds
/// loopback only and reads Jira credentials from the same environment variables as every
/// other Swira component.
@main
struct SwiraWeb: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swira-web",
        abstract: "Serve the Swira web client on localhost."
    )

    @Option(name: .shortAndLong, help: "Port to listen on.")
    var port: UInt16 = 8787

    func run() throws {
        let logger = Logger(label: "swira.web")

        // A missing configuration must not prevent the server from starting: the UI comes up
        // and explains what to set, which beats a process that dies with a stack trace.
        var swira: Swira?
        var configurationError: String?
        do {
            swira = try Swira.fromEnvironment()
        } catch let error as SwiraError {
            configurationError = error.errorDescription
        }

        if let swira {
            logger.info(
                "Configured",
                metadata: ["site": "\(swira.configuration.site.baseURL.absoluteString)"]
            )
        } else {
            logger.warning("Starting unconfigured: \(configurationError ?? "unknown reason")")
        }

        let api = WebAPI(swira: swira, configurationError: configurationError)
        let server = HTTPServer(port: port, logger: logger) { request in
            await api.handle(request)
        }

        print("Swira web client: http://127.0.0.1:\(port)/")
        try server.run()
    }
}
