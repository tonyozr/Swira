import Foundation
import Testing

@testable import SwiraCore

/// The Data Center dialect, verified offline against recorded Server responses.
///
/// The invariant under test throughout: the services' public API behaves identically to Cloud —
/// only the wire traffic underneath differs.
@Suite("Data Center dialect")
struct DataCenterTests {
    @Test("Deployment follows the API version")
    func deploymentFollowsAPIVersion() throws {
        #expect(try JiraSite(urlString: "https://x.atlassian.net").deployment == .cloud)
        #expect(try JiraSite(urlString: "https://jira.internal", apiVersion: "2").deployment == .dataCenter)
    }

    @Test("A Server user without accountId still identifies by key")
    func decodesServerUser() throws {
        // The exact shape jira.atlassian.com returned during live probing.
        let body = Data(#"""
        {"self":"https://jira.example.com/rest/api/2/user?username=mia","key":"JIRAUSER10142168",
         "name":"mia","displayName":"Mia Krystof","active":true,"timeZone":"Europe/Stockholm"}
        """#.utf8)
        let user = try JSONCoding.makeDecoder().decode(JiraUser.self, from: body)
        #expect(user.accountId == "JIRAUSER10142168")
        #expect(user.timeZone == "Europe/Stockholm")
    }

    // MARK: - Issue search

    private func makeSearch(_ mock: MockTransport) -> SearchService {
        SearchService(
            client: JiraClient(transport: mock, auth: NoAuthProvider()),
            deployment: .dataCenter
        )
    }

    @Test("Issue search goes through legacy POST /search with offsets")
    func searchesThroughLegacyEndpoint() async throws {
        let body = Data(#"""
        {"startAt":0,"maxResults":2,"total":3,"issues":[
          {"id":"1","key":"SW-1","fields":{"summary":"a"}},
          {"id":"2","key":"SW-2","fields":{"summary":"b"}}
        ]}
        """#.utf8)
        let mock = MockTransport(stubs: [.ok(body)])
        let page = try await makeSearch(mock).search(jql: "project = SW", maxResults: 2)

        let request = try #require(await mock.recorded.first)
        #expect(request.path == "search")
        #expect(request.method == .post)

        // Offset pagination surfaces through the same token API the Cloud path uses.
        #expect(page.values.map(\.key) == ["SW-1", "SW-2"])
        #expect(page.nextPageToken == "2")
        #expect(page.hasMore)
    }

    @Test("The synthesized token feeds back in as the next offset")
    func tokenRoundTripsAsOffset() async throws {
        let last = Data(#"""
        {"startAt":2,"maxResults":2,"total":3,"issues":[
          {"id":"3","key":"SW-3","fields":{"summary":"c"}}
        ]}
        """#.utf8)
        let mock = MockTransport(stubs: [.ok(last)])
        let page = try await makeSearch(mock).search(jql: "project = SW", maxResults: 2, pageToken: "2")

        let request = try #require(await mock.recorded.first)
        let sent = try JSONDecoder().decode(JSONValue.self, from: try #require(request.body))
        #expect(sent["startAt"]?.intValue == 2)

        #expect(page.values.map(\.key) == ["SW-3"])
        #expect(page.nextPageToken == nil)
        #expect(!page.hasMore)
    }

    @Test("Walking all issues crosses page boundaries transparently")
    func walksLegacyPages() async throws {
        let first = Data(#"""
        {"startAt":0,"maxResults":2,"total":3,"issues":[
          {"id":"1","key":"SW-1"},{"id":"2","key":"SW-2"}]}
        """#.utf8)
        let second = Data(#"""
        {"startAt":2,"maxResults":2,"total":3,"issues":[{"id":"3","key":"SW-3"}]}
        """#.utf8)
        let mock = MockTransport(stubs: [.ok(first), .ok(second)])
        let service = makeSearch(mock)

        var keys: [String] = []
        for try await issue in service.all(jql: "project = SW", pageSize: 2) {
            keys.append(issue.key)
        }
        #expect(keys == ["SW-1", "SW-2", "SW-3"])
    }

    @Test("The count comes from a zero-result search's total")
    func countsThroughLegacySearch() async throws {
        let body = Data(#"{"startAt":0,"maxResults":0,"total":42,"issues":[]}"#.utf8)
        let mock = MockTransport(stubs: [.ok(body)])
        let count = try await makeSearch(mock).approximateCount(jql: "project = SW")

        #expect(count == 42)
        let request = try #require(await mock.recorded.first)
        let body2 = try #require(request.body)
        let sent = try JSONDecoder().decode(JSONValue.self, from: body2)
        #expect(sent["maxResults"]?.intValue == 0)
    }

    @Test("Bulk fetch becomes JQL `in` clauses, split by ids and keys")
    func fetchesThroughInClauses() async throws {
        let byId = Data(#"{"startAt":0,"total":1,"issues":[{"id":"7","key":"SW-7"}]}"#.utf8)
        let byKey = Data(#"{"startAt":0,"total":1,"issues":[{"id":"8","key":"SW-8"}]}"#.utf8)
        let mock = MockTransport(stubs: [.ok(byId), .ok(byKey)])

        let issues = try await makeSearch(mock).fetch(idsOrKeys: ["7", "SW-8"])

        #expect(issues.map(\.key).sorted() == ["SW-7", "SW-8"])
        let recorded = await mock.recorded
        let bodies = try recorded.compactMap(\.body).map {
            try JSONDecoder().decode(JSONValue.self, from: $0)
        }
        #expect(bodies.count == 2)
        #expect(bodies[0]["jql"]?.stringValue == "id in (7)")
        #expect(bodies[1]["jql"]?.stringValue == "key in (SW-8)")
    }

    // MARK: - JQL validation

    @Test("Validation runs as a dry search: success is valid, a 400 envelope is the verdict")
    func validatesThroughDrySearch() async throws {
        let ok = Data(#"{"startAt":0,"maxResults":0,"total":5,"issues":[]}"#.utf8)
        let bad = Data(#"""
        {"errorMessages":["Field 'foo' does not exist or you do not have permission to view it."],"errors":{}}
        """#.utf8)
        let mock = MockTransport(stubs: [.ok(ok), .status(400, body: bad)])
        let service = JQLService(
            client: JiraClient(transport: mock, auth: NoAuthProvider()),
            deployment: .dataCenter
        )

        let valid = try await service.validate("project = SW")
        #expect(valid.isValid)

        let invalid = try await service.validate("foo = bar")
        #expect(!invalid.isValid)
        #expect(invalid.errors.first?.contains("does not exist") == true)
    }

    @Test("A non-400 failure during validation propagates instead of reading as 'invalid JQL'")
    func validationDoesNotSwallowRealErrors() async throws {
        let mock = MockTransport(stubs: [.status(401)])
        let service = JQLService(
            client: JiraClient(transport: mock, auth: NoAuthProvider()),
            deployment: .dataCenter
        )
        await #expect(throws: SwiraError.unauthorized) {
            _ = try await service.validate("project = SW")
        }
    }

    // MARK: - Filters

    @Test("Filter search is served by favourites, filtered by name client-side")
    func searchesFiltersThroughFavourites() async throws {
        let favourites = Data(#"""
        [{"id":"1","name":"Open bugs","favourite":true},
         {"id":"2","name":"My work","favourite":true},
         {"id":"3","name":"Old bugs archive","favourite":true}]
        """#.utf8)
        let mock = MockTransport(stubs: [.ok(favourites)])
        let service = FiltersService(
            client: JiraClient(transport: mock, auth: NoAuthProvider()),
            deployment: .dataCenter
        )

        let page = try await service.search(FilterQuery(name: "bugs")).value

        #expect(try #require(await mock.recorded.first).path == "filter/favourite")
        #expect(page.values.map(\.name) == ["Open bugs", "Old bugs archive"])
        #expect(page.total == 2)
        #expect(page.isLast == true)
    }

    // MARK: - Reference data

    @Test("Projects come from the flat legacy list, paginated and filtered locally")
    func listsProjectsThroughLegacyEndpoint() async throws {
        let body = Data(#"""
        [{"id":"1","key":"SW","name":"Swira"},
         {"id":"2","key":"OPS","name":"Operations"},
         {"id":"3","key":"SWD","name":"Swira Docs"}]
        """#.utf8)
        let mock = MockTransport(stubs: [.ok(body)])
        let service = ReferenceService(
            client: JiraClient(transport: mock, auth: NoAuthProvider()),
            deployment: .dataCenter
        )

        let page = try await service.projects(matching: "swira", maxResults: 1).value

        #expect(try #require(await mock.recorded.first).path == "project")
        // Matched two by name, returned one page of one, and the totals say so.
        #expect(page.values.map(\.key) == ["SW"])
        #expect(page.total == 2)
        #expect(page.hasMore)
    }

    @Test("User search sends `username`, the parameter Server understands")
    func searchesUsersWithServerParameter() async throws {
        let mock = MockTransport(stubs: [.ok(Data("[]".utf8))])
        let service = ReferenceService(
            client: JiraClient(transport: mock, auth: NoAuthProvider()),
            deployment: .dataCenter
        )
        _ = try await service.searchUsers(matching: "mia")

        let request = try #require(await mock.recorded.first)
        #expect(request.queryItems.contains(URLQueryItem(name: "username", value: "mia")))
        #expect(!request.queryItems.contains(URLQueryItem(name: "query", value: "mia")))
    }
}
