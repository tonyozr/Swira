import Foundation
import Testing

@testable import SwiraCore

@Suite("SearchService")
struct SearchServiceTests {
    private func makeService(_ mock: MockTransport) -> SearchService {
        SearchService(client: JiraClient(transport: mock, auth: NoAuthProvider()))
    }

    @Test("A page of issues decodes along with its cursor")
    func decodesSearchPage() async throws {
        let mock = MockTransport(stubs: [.ok(try Fixture.data("search-page1"))])
        let page = try await makeService(mock).search(jql: "project = SWIRA")

        #expect(page.values.count == 2)
        #expect(page.nextPageToken == "CAEaAggD")
        #expect(page.hasMore)
        #expect(page.values[0].key == "SWIRA-1")
    }

    @Test("Search is a POST — filter JQL routinely outgrows a URL")
    func searchesWithPost() async throws {
        let mock = MockTransport(stubs: [.ok(try Fixture.data("search-page1"))])
        _ = try await makeService(mock).search(jql: "project = SWIRA", maxResults: 10)

        let request = try #require(await mock.recorded.first)
        #expect(request.method == .post)
        #expect(request.path == "search/jql")

        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(request.body))
        #expect(body["jql"]?.stringValue == "project = SWIRA")
        #expect(body["maxResults"]?.intValue == 10)
        #expect(body["fields"]?.arrayValue?.contains(.string("summary")) == true)
    }

    @Test("Walking every page follows nextPageToken and stops on isLast")
    func walksTokenPages() async throws {
        let mock = MockTransport(stubs: [
            .ok(try Fixture.data("search-page1")),
            .ok(try Fixture.data("search-page2")),
        ])
        let service = makeService(mock)

        var keys: [String] = []
        for try await issue in service.all(jql: "project = SWIRA") {
            keys.append(issue.key)
        }

        #expect(keys == ["SWIRA-1", "SWIRA-2", "SWIRA-3"])
        #expect(await mock.requestCount == 2)

        let second = try #require(await mock.recorded.last)
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(second.body))
        #expect(body["nextPageToken"]?.stringValue == "CAEaAggD")
    }

    @Test("isLast overrides a token Jira should not have sent")
    func isLastWinsOverToken() throws {
        let body = Data(#"{"isLast":true,"nextPageToken":"more","issues":[]}"#.utf8)
        let response = try JSONCoding.makeDecoder().decode(IssueSearchResponse.self, from: body)

        // Following the token here would fetch an empty page forever.
        #expect(response.page.nextPageToken == nil)
        #expect(!response.page.hasMore)
    }

    @Test("Previewing a filter runs it by id, not by copying its JQL")
    func previewsByFilterID() async throws {
        let mock = MockTransport(stubs: [.ok(try Fixture.data("search-page1"))])
        _ = try await makeService(mock).preview(filterId: "10000", limit: 5)

        let request = try #require(await mock.recorded.first)
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(request.body))
        #expect(body["jql"]?.stringValue == "filter = 10000")
        #expect(body["maxResults"]?.intValue == 5)
    }

    @Test("The approximate count unwraps Jira's envelope")
    func readsApproximateCount() async throws {
        let mock = MockTransport(stubs: [.ok(Data(#"{"count":1337}"#.utf8))])
        let count = try await makeService(mock).approximateCount(jql: "project = SWIRA")

        #expect(count == 1337)
        #expect(try #require(await mock.recorded.first).path == "search/approximate-count")
    }

    @Test("Fetching nothing does not hit the network")
    func skipsEmptyBulkFetch() async throws {
        let mock = MockTransport(stubs: [])
        let issues = try await makeService(mock).fetch(idsOrKeys: [])

        #expect(issues.isEmpty)
        #expect(await mock.requestCount == 0)
    }
}

@Suite("JiraIssue")
struct IssueTests {
    private func loadIssues() throws -> [JiraIssue] {
        try JSONCoding.makeDecoder()
            .decode(IssueSearchResponse.self, from: try Fixture.data("search-page1"))
            .issues
    }

    @Test("Common fields are reachable without touching raw JSON")
    func exposesCommonFields() throws {
        let issue = try #require(try loadIssues().first)

        #expect(issue.key == "SWIRA-1")
        #expect(issue.summary == "Filter list does not refresh")
        #expect(issue.status == "In Progress")
        #expect(issue.issueType == "Bug")
        #expect(issue.priority == "High")
        #expect(issue.projectKey == "SWIRA")
        #expect(issue.labels == ["ui", "regression"])
        #expect(issue.assignee?.displayName == "Mia Krystof")
    }

    @Test("Status category is available, since status names differ per workflow")
    func exposesStatusCategory() throws {
        let issues = try loadIssues()
        #expect(issues[0].statusCategory == "indeterminate")
        #expect(issues[1].statusCategory == "new")
    }

    @Test("An explicitly null assignee reads as unassigned, not as an empty user")
    func handlesNullAssignee() throws {
        let issue = try loadIssues()[1]
        #expect(issue.assignee == nil)
        #expect(issue.priority == nil)
    }

    @Test("Timestamps parse despite Jira's non-standard offset format")
    func parsesTimestamps() throws {
        // Jira sends "+0000", which ISO 8601 decoders reject for lacking the colon.
        let updated = try #require(try loadIssues().first?.updated)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: updated)

        #expect(parts.year == 2026)
        #expect(parts.month == 3)
        #expect(parts.day == 14)
        #expect(parts.hour == 9)
        #expect(parts.minute == 41)
    }

    @Test("Unknown custom fields survive as raw JSON")
    func keepsUnknownFields() throws {
        let body = Data(#"""
        {"id":"1","key":"X-1","fields":{"customfield_10001":{"value":"Team A"},"summary":"s"}}
        """#.utf8)
        let issue = try JSONCoding.makeDecoder().decode(JiraIssue.self, from: body)

        #expect(issue.fields["customfield_10001"]?["value"]?.stringValue == "Team A")
        #expect(issue.summary == "s")
    }
}
