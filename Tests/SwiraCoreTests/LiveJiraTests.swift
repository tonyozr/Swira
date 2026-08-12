import Foundation
import Testing

@testable import SwiraCore

/// Integration tests against a real Jira site.
///
/// The whole suite is skipped unless the standard environment variables (`JIRA_URL`,
/// `JIRA_API_TOKEN`, …) are set, so `swift test` stays green on a machine with no credentials.
/// Every test here is read-only: nothing is created, changed, or deleted on the site.
enum LiveJira {
    static var isConfigured: Bool {
        (try? SwiraConfiguration.fromEnvironment()) != nil
    }

    /// A fresh core with caching disabled, so tests exercise the live API rather than each
    /// other's leftovers — and leave no files behind.
    static func make() throws -> Swira {
        try Swira.fromEnvironment(cache: NullCacheStore())
    }
}

@Suite(
    "Live Jira",
    .enabled(if: LiveJira.isConfigured, "Set JIRA_URL / JIRA_EMAIL / JIRA_API_TOKEN to run"),
    .serialized
)
struct LiveJiraTests {
    @Test("Credentials are accepted and /myself decodes")
    func verifiesCredentials() async throws {
        let user = try await LiveJira.make().verifyCredentials()
        #expect(!user.accountId.isEmpty)
        #expect(!user.displayName.isEmpty)
    }

    @Test("The filter search endpoint answers and decodes")
    func searchesFilters() async throws {
        let page = try await LiveJira.make().filters.search(FilterQuery(maxResults: 10)).value
        // The site may legitimately have no filters; the assertions are about shape, not content.
        #expect(page.values.count <= 10)
        for filter in page.values {
            #expect(!filter.id.isEmpty)
            #expect(!filter.name.isEmpty)
        }
    }

    @Test("My filters and favourites decode")
    func listsOwnFilters() async throws {
        let swira = try LiveJira.make()
        _ = try await swira.filters.mine().value
        _ = try await swira.filters.favourites().value
    }

    @Test("Share permissions on real filters decode into known scopes")
    func decodesRealSharePermissions() async throws {
        let swira = try LiveJira.make()
        let page = try await swira.filters.search(FilterQuery(maxResults: 25)).value

        for filter in page.values {
            for permission in filter.sharePermissions + filter.editPermissions {
                // .unknown is legal, but on today's Jira Cloud it would mean a share type this
                // core has not modeled yet — worth failing loudly here, in the one test with
                // real data, rather than discovering it in a UI.
                if case .unknown(let type) = permission.scope {
                    Issue.record("Unmodeled share type '\(type)' on filter \(filter.id)")
                }
            }
        }
    }

    @Test("Valid JQL passes validation; broken JQL reports errors")
    func validatesJQL() async throws {
        let jql = try LiveJira.make().jql

        let good = try await jql.validate("order by created DESC")
        #expect(good.isValid)

        let bad = try await jql.validate("project = ")
        #expect(!bad.isValid)
        #expect(!bad.errors.isEmpty)
    }

    @Test("Autocomplete data is populated")
    func fetchesAutocompleteData() async throws {
        let data = try await LiveJira.make().jql.autocompleteData()
        // Any Jira site has built-in fields and functions.
        #expect(!data.visibleFieldNames.isEmpty)
        #expect(!data.visibleFunctionNames.isEmpty)
        #expect(data.visibleFieldNames.contains { $0.value == "status" })
    }

    @Test("Issue search returns a decodable page with cursor pagination")
    func searchesIssues() async throws {
        // Cloud now rejects a bare `ORDER BY` with no restriction ("Unbounded JQL queries are
        // not allowed here") — this bound is required, not decorative.
        let page = try await LiveJira.make().search
            .search(jql: "created >= -365d order by created DESC", maxResults: 5)
        // An empty site is legal; if issues came back, their core fields must have survived.
        for issue in page.values {
            #expect(!issue.key.isEmpty)
        }
        #expect(page.values.count <= 5)
    }

    @Test("The approximate count endpoint answers")
    func countsIssues() async throws {
        let count = try await LiveJira.make().search
            .approximateCount(jql: "created >= -30d")
        #expect(count >= 0)
    }

    @Test("Reference data decodes: projects and fields")
    func fetchesReferenceData() async throws {
        let swira = try LiveJira.make()

        let projects = try await swira.reference.projects().value
        for project in projects.values {
            #expect(!project.key.isEmpty)
        }

        let fields = try await swira.reference.fields().value
        #expect(fields.contains { $0.id == "summary" })
    }
}
