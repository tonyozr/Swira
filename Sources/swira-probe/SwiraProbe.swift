import ArgumentParser
import Foundation
import SwiraCore

/// A deliberately plain CLI used to exercise `SwiraCore` against a live Jira site.
///
/// This is not `swira-cli`: it has no TUI and no ambitions. It exists so that every core
/// capability has a way to be confirmed by hand on a real instance, on every platform the core
/// claims to support.
@main
struct SwiraProbe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swira-probe",
        abstract: "Exercise SwiraCore against a live Jira site.",
        subcommands: [
            WhoAmI.self, Filters.self, JQL.self, Search.self,
            Get.self, Post.self, CacheCommand.self,
        ]
    )
}

/// Options shared by every subcommand that reads data.
struct CacheOptions: ParsableArguments {
    @Flag(name: .long, help: "Read only from the local cache; never touch the network.")
    var offline = false

    @Flag(name: .long, help: "Ignore the cache and go straight to Jira.")
    var fresh = false

    var policy: CachePolicy {
        if offline { return .cacheOnly }
        if fresh { return .networkOnly }
        return .default
    }
}

enum Probe {
    static func swira() throws -> Swira {
        try Swira.fromEnvironment()
    }

    /// Prints where a value came from, so cache behaviour is visible rather than inferred.
    static func report<T>(_ cached: Cached<T>) {
        switch cached.origin {
        case .network:
            print("[source: jira]")
        case .cache:
            let age = cached.storedAt.map { Int(Date().timeIntervalSince($0)) } ?? 0
            print("[source: cache, \(age)s old\(cached.isStale ? ", stale" : "")]")
        }
    }
}

struct WhoAmI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "whoami",
        abstract: "Fetch the authenticated account via /myself."
    )

    func run() async throws {
        let swira = try Probe.swira()
        let user = try await swira.verifyCredentials()

        print("Site:     \(swira.configuration.site.baseURL.absoluteString)")
        print("Account:  \(user.displayName) (\(user.accountId))")
        if let email = user.emailAddress {
            print("Email:    \(email)")
        }
        if let timeZone = user.timeZone {
            print("Timezone: \(timeZone)")
        }
    }
}

struct Filters: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "filters",
        abstract: "List, inspect, create, and delete filters.",
        subcommands: [List.self, Show.self, Create.self, Delete.self]
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List filters.")

        @Option(name: .long, help: "Match filter names containing this text.")
        var name: String?

        @Option(name: .long, help: "Maximum number of filters to print.")
        var limit = 25

        @Flag(name: .long, help: "List only filters you own.")
        var mine = false

        @OptionGroup var cache: CacheOptions

        func run() async throws {
            let swira = try Probe.swira()

            let filters: [JiraFilter]
            if mine {
                let result = try await swira.filters.mine(policy: cache.policy)
                Probe.report(result)
                filters = Array(result.value.prefix(limit))
            } else {
                var query = FilterQuery(maxResults: limit)
                query.name = name
                let result = try await swira.filters.search(query, policy: cache.policy)
                Probe.report(result)
                let total = result.value.total.map { " of \($0)" } ?? ""
                print("Showing \(result.value.values.count)\(total)\n")
                filters = result.value.values
            }

            for filter in filters {
                let star = filter.favourite ? "*" : " "
                print("\(star) \(filter.id.padded(to: 8)) \(filter.name)")
                if let jql = filter.jql {
                    print("           \(jql)")
                }
                if filter.isShared {
                    let shares = filter.sharePermissions.map(\.scope.displayName)
                    print("           shared: \(shares.joined(separator: ", "))")
                }
            }
        }
    }

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show one filter in detail.")

        @Argument(help: "Filter id.")
        var id: String

        @Option(name: .long, help: "Also run the filter and print this many issues.")
        var preview = 0

        @OptionGroup var cache: CacheOptions

        func run() async throws {
            let swira = try Probe.swira()
            let result = try await swira.filters.get(id: id, policy: cache.policy)
            Probe.report(result)

            let filter = result.value
            print("Name:      \(filter.name)")
            print("Id:        \(filter.id)")
            if let owner = filter.owner {
                print("Owner:     \(owner.displayName)")
            }
            if let description = filter.description {
                print("About:     \(description)")
            }
            print("JQL:       \(filter.jql ?? "-")")
            print("Favourite: \(filter.favourite) (\(filter.favouritedCount ?? 0) users)")
            print("Writable:  \(filter.isWritable.map(String.init) ?? "unknown")")

            if filter.sharePermissions.isEmpty {
                print("Shared:    private")
            } else {
                print("Shared:")
                for permission in filter.sharePermissions {
                    print("  - \(permission.scope.displayName) [\(permission.scope.typeName)]")
                }
            }

            guard preview > 0 else { return }
            print("\nPreview:")
            let issues = try await swira.search.preview(filterId: id, limit: preview)
            for issue in issues.values {
                print("  \(issue.key.padded(to: 12)) \(issue.summary ?? "")  (\(issue.status ?? "?"))")
            }
        }
    }

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create a filter. Non-favourite unless --favourite is passed."
        )

        @Option(name: .long, help: "Filter name.")
        var name: String

        @Option(name: .long, help: "The JQL the filter runs.")
        var jql: String

        @Option(name: .long, help: "Optional description.")
        var description: String?

        @Flag(name: .long, help: "Mark the new filter as a favourite.")
        var favourite = false

        func run() async throws {
            let swira = try Probe.swira()
            let created = try await swira.filters.create(
                FilterInput(
                    name: name,
                    jql: jql,
                    description: description,
                    // `false` stays nil-equivalent semantics-wise: the service pins it to false.
                    favourite: favourite ? true : nil
                )
            )

            print("Created:   \(created.name)")
            print("Id:        \(created.id)")
            print("JQL:       \(created.jql ?? "-")")
            print("Favourite: \(created.favourite)")
            if let viewUrl = created.viewUrl {
                print("View:      \(viewUrl)")
            }
        }
    }

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Delete a filter by id."
        )

        @Argument(help: "Filter id.")
        var id: String

        /// Deleting is irreversible, so the command shows what it is about to remove and
        /// requires the flag rather than acting on a bare id.
        @Flag(name: .long, help: "Actually delete. Without this, only shows what would be deleted.")
        var yes = false

        func run() async throws {
            let swira = try Probe.swira()
            let filter = try await swira.filters.get(id: id, policy: .networkOnly).value

            print("Filter:    \(filter.name) (id \(filter.id))")
            print("JQL:       \(filter.jql ?? "-")")

            guard yes else {
                print("\nDry run. Pass --yes to delete.")
                return
            }
            try await swira.filters.delete(id: id)
            print("\nDeleted.")
        }
    }
}

struct JQL: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "jql",
        abstract: "Validate JQL and ask Jira for completions.",
        subcommands: [Validate.self, Suggest.self]
    )

    struct Validate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Validate a JQL query.")

        @Argument(help: "The query to check.")
        var query: String

        func run() async throws {
            let result = try await Probe.swira().jql.validate(query)

            if result.isValid {
                print("Valid.")
            } else {
                print("Invalid:")
                for error in result.errors {
                    print("  - \(error)")
                }
            }
            for warning in result.warnings {
                print("  ! \(warning)")
            }
            throw result.isValid ? ExitCode.success : ExitCode.failure
        }
    }

    struct Suggest: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Suggest values for a field.")

        @Argument(help: "Field name, e.g. 'status'.")
        var field: String

        @Argument(help: "Partial value typed so far.")
        var value: String?

        func run() async throws {
            let suggestions = try await Probe.swira().jql
                .suggestions(fieldName: field, fieldValue: value)

            for suggestion in suggestions {
                print("  \(suggestion.plainDisplayName)")
            }
            if suggestions.isEmpty {
                print("No suggestions.")
            }
        }
    }
}

struct Search: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Run a JQL query."
    )

    @Argument(help: "The JQL to run.")
    var jql: String

    @Option(name: .shortAndLong, help: "Maximum number of issues to print.")
    var limit = 10

    @Flag(name: .long, help: "Also ask Jira for the approximate match count.")
    var count = false

    func run() async throws {
        let swira = try Probe.swira()

        if count {
            let total = try await swira.search.approximateCount(jql: jql)
            // Approximate by design: the cursor-based search endpoint stopped returning an exact
            // total, so presenting this as exact would be a lie.
            print("About \(total) matching issues.\n")
        }

        let page = try await swira.search.search(jql: jql, maxResults: limit)
        for issue in page.values {
            print("\(issue.key.padded(to: 12)) \(issue.summary ?? "")")
            print("\(String(repeating: " ", count: 12)) \(issue.status ?? "?") · \(issue.issueType ?? "?") · \(issue.assignee?.displayName ?? "unassigned")")
        }
        if page.hasMore {
            print("\n(more pages available)")
        }
    }
}

struct CacheCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cache",
        abstract: "Inspect or clear the local cache."
    )

    @Flag(name: .long, help: "Delete every cached response.")
    var clear = false

    func run() async throws {
        let swira = try Probe.swira()
        let directory = swira.configuration.cacheDirectory

        if clear {
            await swira.clearCache()
            print("Cleared \(directory.path)")
            return
        }

        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        print("Cache: \(directory.path)")
        print("Entries: \(files.count)")
    }
}

/// Fetches an arbitrary REST path and prints the JSON.
///
/// Indispensable when Jira's actual response disagrees with its documentation — which it does,
/// often enough that guessing from a decoding error is a waste of an afternoon.
struct Get: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "GET an arbitrary REST path and print the raw JSON."
    )

    @Argument(help: "Path after /rest/api/{version}/, e.g. 'myself' or 'filter/search'.")
    var path: String

    @Option(name: .shortAndLong, help: "Query parameter as name=value. Repeatable.")
    var query: [String] = []

    func run() async throws {
        let (configuration, auth) = try SwiraConfiguration.fromEnvironment()
        let client = JiraClient(
            transport: RetryingTransport(
                wrapping: URLSessionTransport(configuration: configuration),
                maxRetries: configuration.maxRetries
            ),
            auth: auth
        )

        let queryItems = query.compactMap { pair -> URLQueryItem? in
            guard let separator = pair.firstIndex(of: "=") else { return nil }
            return URLQueryItem(
                name: String(pair[pair.startIndex..<separator]),
                value: String(pair[pair.index(after: separator)...])
            )
        }

        let value: JSONValue = try await client.send(
            HTTPRequest(method: .get, path: path, queryItems: queryItems)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    }
}

/// POSTs a JSON body to an arbitrary path and dumps the raw response: status, headers, body.
///
/// The transport-level view `get` cannot give — for diagnosing responses that fail before
/// decoding even starts.
struct Post: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "post",
        abstract: "Send a raw body to a REST path and dump status, headers, and body."
    )

    @Argument(help: "Path after /rest/api/{version}/.")
    var path: String

    @Option(name: .long, help: "Body to send.")
    var body: String

    @Option(name: .long, help: "HTTP method.")
    var method: String = "POST"

    @Option(name: .long, help: "Content-Type header to send. Omit to use the transport's default.")
    var contentType: String?

    func run() async throws {
        let (configuration, auth) = try SwiraConfiguration.fromEnvironment()
        // Deliberately no RetryingTransport: diagnostics want the first response, not the best.
        let transport = URLSessionTransport(configuration: configuration)

        let httpMethod = HTTPMethod(rawValue: method.uppercased()) ?? .post
        var headers: [String: String] = [:]
        if let contentType {
            headers["Content-Type"] = contentType
        }
        var request = HTTPRequest(
            method: httpMethod, path: path, headers: headers, body: Data(body.utf8)
        )
        try await auth.authorize(&request)
        let response = try await transport.send(request)

        print("Status: \(response.status)")
        for (name, value) in response.headers.sorted(by: { $0.key < $1.key }) {
            print("  \(name): \(value)")
        }
        print("Body (\(response.body.count) bytes):")
        print(String(decoding: response.body.prefix(600), as: UTF8.self))
    }
}

extension String {
    /// Pads to a fixed width so columns line up without a table library.
    func padded(to width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}
