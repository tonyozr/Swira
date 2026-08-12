import Foundation
import Testing

@testable import SwiraCore

@Suite("Filter decoding")
struct FilterDecodingTests {
    private func loadFilter() throws -> JiraFilter {
        try JSONCoding.makeDecoder().decode(JiraFilter.self, from: try Fixture.data("filter"))
    }

    @Test("Core fields decode")
    func decodesCoreFields() throws {
        let filter = try loadFilter()
        #expect(filter.id == "10000")
        #expect(filter.name == "Open bugs")
        #expect(filter.description == "Everything still broken")
        #expect(filter.jql == "project = SWIRA AND type = Bug AND status != Done")
        #expect(filter.favourite)
        #expect(filter.favouritedCount == 7)
        #expect(filter.isWritable == true)
        #expect(filter.owner?.displayName == "Mia Krystof")
        #expect(filter.isShared)
    }

    @Test("Every share type decodes, including ones Swira does not know")
    func decodesAllShareTypes() throws {
        let scopes = try loadFilter().sharePermissions.map(\.scope)

        #expect(scopes[0] == .global)
        // Jira v2 spells "authenticated" as "loggedin"; both must land in the same case.
        #expect(scopes[1] == .authenticated)
        #expect(scopes[2] == .project(
            id: "10100", name: "Swira", roleId: "10360", roleName: "Developers"
        ))
        #expect(scopes[3] == .group(name: "jira-users", groupId: "276f955c"))
        #expect(scopes[4] == .user(accountId: "5b10a2844c20165700ede21g", displayName: "Mia Krystof"))
        // A project share whose project the caller cannot browse.
        #expect(scopes[5] == .projectUnknown)
        // An unrecognized type must degrade, not throw: one unknown share should never make an
        // otherwise readable filter undecodable.
        #expect(scopes[6] == .unknown("somethingAtlassianAddedLater"))
    }

    @Test("Edit permissions are kept separate from view permissions")
    func separatesEditPermissions() throws {
        let filter = try loadFilter()
        #expect(filter.editPermissions.count == 1)
        #expect(filter.editPermissions[0].scope == .group(name: "jira-admins", groupId: "99a1b2c3"))
    }

    @Test("Subscriptions decode whether Jira wraps them or not")
    func decodesWrappedSubscriptions() throws {
        // The fixture uses the wrapped {"size":n,"items":[…]} shape.
        let wrapped = try loadFilter()
        #expect(wrapped.subscriptions.count == 1)
        #expect(wrapped.subscriptions[0].user?.displayName == "Mia Krystof")

        // The same field also arrives as a bare array on other endpoints.
        let bare = Data(#"""
        {"id":"1","name":"F","subscriptions":[{"id":5}]}
        """#.utf8)
        let filter = try JSONCoding.makeDecoder().decode(JiraFilter.self, from: bare)
        #expect(filter.subscriptions.count == 1)
        #expect(filter.subscriptions[0].id == 5)
    }

    @Test("A filter with no shares is private, and missing optional fields are tolerated")
    func decodesMinimalFilter() throws {
        let minimal = Data(#"{"id":"10","name":"Scratch"}"#.utf8)
        let filter = try JSONCoding.makeDecoder().decode(JiraFilter.self, from: minimal)

        #expect(filter.id == "10")
        #expect(!filter.favourite)
        #expect(!filter.isShared)
        #expect(filter.sharePermissions.isEmpty)
        #expect(filter.subscriptions.isEmpty)
        #expect(filter.isWritable == nil)
    }

    @Test("Share display names are readable without further lookups")
    func rendersShareLabels() throws {
        let scopes = try loadFilter().sharePermissions.map(\.scope)
        #expect(scopes[0].displayName == "Public")
        #expect(scopes[1].displayName == "Any logged-in user")
        #expect(scopes[2].displayName == "Swira (Developers)")
        #expect(scopes[3].displayName == "jira-users")
        #expect(scopes[4].displayName == "Mia Krystof")
    }
}

@Suite("Filter endpoints")
struct FilterEndpointTests {
    private func url(_ request: HTTPRequest) throws -> String {
        let site = try JiraSite(urlString: "https://example.atlassian.net")
        let url = site.apiURL(path: request.path, queryItems: request.queryItems)
        return try #require(url?.absoluteString)
    }

    @Test("Search maps query criteria onto Jira's parameter names")
    func buildsSearchRequest() throws {
        var query = FilterQuery(expand: [.jql, .owner])
        query.name = "bugs"
        query.ownerAccountId = "abc123"
        query.projectId = 10100
        query.maxResults = 25
        query.startAt = 50

        let request = FilterEndpoints.search(query)
        let built = try url(request)

        #expect(request.method == .get)
        #expect(built.contains("/rest/api/3/filter/search?"))
        // Jira calls the name parameter `filterName` and the owner one `accountId`.
        #expect(built.contains("filterName=bugs"))
        #expect(built.contains("accountId=abc123"))
        #expect(built.contains("projectId=10100"))
        #expect(built.contains("startAt=50"))
        #expect(built.contains("maxResults=25"))
        #expect(built.contains("expand=jql,owner") || built.contains("expand=jql%2Cowner"))
    }

    @Test("Filter ids are repeated rather than joined")
    func repeatsIDParameters() throws {
        let request = FilterEndpoints.search(FilterQuery(ids: ["1", "2"], expand: []))
        let ids = request.queryItems.filter { $0.name == "id" }.compactMap(\.value)
        #expect(ids == ["1", "2"])
    }

    @Test("Toggling a favourite switches the HTTP method, not the path")
    func favouriteUsesMethodToExpressIntent() {
        #expect(FilterEndpoints.setFavourite(id: "10", true).method == .put)
        #expect(FilterEndpoints.setFavourite(id: "10", false).method == .delete)
        #expect(FilterEndpoints.setFavourite(id: "10", true).path == "filter/10/favourite")
    }

    @Test("Columns are sent form-encoded, with the key repeated per field")
    func encodesColumnsAsForm() throws {
        // Data Center: matches its documented shape, and is unaffected by the Cloud edge bug
        // (no CloudFront-style gateway in front of it to inject a charset).
        let request = FilterEndpoints.setColumns(
            id: "10",
            fieldIds: ["summary", "status", "customfield_10001"],
            deployment: .dataCenter
        )

        #expect(request.method == .put)
        #expect(request.headers["Content-Type"] == "application/x-www-form-urlencoded")

        let body = String(decoding: try #require(request.body), as: UTF8.self)
        #expect(body == "columns=summary&columns=status&columns=customfield_10001")
    }

    @Test("Column field ids are percent-encoded, so odd custom fields cannot corrupt the body")
    func escapesColumnValues() throws {
        let request = FilterEndpoints.setColumns(
            id: "10", fieldIds: ["a&b=c", "d e"], deployment: .dataCenter
        )
        let body = String(decoding: try #require(request.body), as: UTF8.self)
        #expect(body == "columns=a%26b%3Dc&columns=d%20e")
    }

    @Test("Cloud carries no body of its own — the caller attaches it as JSON")
    func cloudColumnsRequestIsBareForCallerToFill() {
        let request = FilterEndpoints.setColumns(id: "10", fieldIds: ["summary"], deployment: .cloud)
        #expect(request.method == .put)
        #expect(request.body == nil)
        #expect(request.headers["Content-Type"] == nil)
    }

    @Test("Permission removal addresses the permission, not the filter")
    func buildsPermissionPaths() {
        #expect(FilterEndpoints.permissions(id: "10").path == "filter/10/permission")
        #expect(FilterEndpoints.addPermission(id: "10").method == .post)

        let remove = FilterEndpoints.removePermission(id: "10", permissionId: 42)
        #expect(remove.method == .delete)
        #expect(remove.path == "filter/10/permission/42")
    }
}

@Suite("Share permission input")
struct SharePermissionInputTests {
    private func encode(_ input: SharePermissionInput) throws -> [String: JSONValue] {
        let data = try JSONCoding.makeEncoder().encode(input)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        return try #require(value.objectValue)
    }

    @Test("Writes use Jira's flat shape, which differs from what reads return")
    func encodesFlatShape() throws {
        let project = try encode(.project(id: "10100", roleId: "10360"))
        #expect(project["type"]?.stringValue == "project")
        // Reads come back as {"project": {"id": …}}; writes must be flat or Jira rejects them.
        #expect(project["projectId"]?.stringValue == "10100")
        #expect(project["projectRoleId"]?.stringValue == "10360")
        #expect(project["project"] == nil)

        let group = try encode(.group(name: "jira-users"))
        #expect(group["type"]?.stringValue == "group")
        #expect(group["groupname"]?.stringValue == "jira-users")

        let user = try encode(.user(accountId: "abc"))
        #expect(user["type"]?.stringValue == "user")
        #expect(user["accountId"]?.stringValue == "abc")

        #expect(try encode(.global)["type"]?.stringValue == "global")
        #expect(try encode(.authenticated)["type"]?.stringValue == "authenticated")
    }
}

@Suite("FiltersService")
struct FiltersServiceTests {
    private func makeService(_ mock: MockTransport) -> FiltersService {
        FiltersService(client: JiraClient(transport: mock, auth: NoAuthProvider()))
    }

    @Test("A search page decodes with its pagination metadata intact")
    func decodesSearchPage() async throws {
        let mock = MockTransport(stubs: [.ok(try Fixture.data("filter-search-page1"))])
        let result = try await makeService(mock).search()
        let page = result.value

        #expect(result.origin == .network)
        #expect(!result.isStale)
        #expect(page.values.count == 2)
        #expect(page.total == 3)
        #expect(page.startAt == 0)
        #expect(page.hasMore)
        #expect(page.nextStartAt == 2)
        #expect(page.values[0].name == "Open bugs")
    }

    @Test("Walking all filters follows the offset cursor and stops at the last page")
    func walksEveryPage() async throws {
        let mock = MockTransport(stubs: [
            .ok(try Fixture.data("filter-search-page1")),
            .ok(try Fixture.data("filter-search-page2")),
        ])
        let service = makeService(mock)

        var names: [String] = []
        for try await filter in service.all(FilterQuery(maxResults: 2)) {
            names.append(filter.name)
        }

        #expect(names == ["Open bugs", "My work", "Recently updated"])
        #expect(await mock.requestCount == 2)

        // The second request must ask for the offset the first page ended at.
        let second = try #require(await mock.recorded.last)
        #expect(second.queryItems.contains(URLQueryItem(name: "startAt", value: "2")))
    }

    @Test("Creating a filter posts the input and returns what Jira stored")
    func createsFilter() async throws {
        let mock = MockTransport(stubs: [.ok(try Fixture.data("filter"))])
        let service = makeService(mock)

        let created = try await service.create(
            FilterInput(
                name: "Open bugs",
                jql: "type = Bug",
                sharePermissions: [.group(name: "jira-users")]
            )
        )

        #expect(created.id == "10000")

        let request = try #require(await mock.recorded.first)
        #expect(request.method == .post)
        #expect(request.path == "filter")

        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(request.body))
        #expect(body["name"]?.stringValue == "Open bugs")
        #expect(body["jql"]?.stringValue == "type = Bug")
        #expect(body.path("sharePermissions.0.groupname") == nil)
        #expect(body["sharePermissions"]?.arrayValue?.first?["groupname"]?.stringValue == "jira-users")
    }

    @Test("A standalone name defaults to favourite — it's the only way it stays visible")
    func createsStandaloneFilterAsFavourite() async throws {
        let mock = MockTransport(stubs: [.ok(try Fixture.data("filter"))])
        let service = makeService(mock)

        // "A" has no hierarchy separator: the sidebar shows plain names only in Favourites
        // (spec §2.1), so leaving this false would make the filter disappear on creation.
        _ = try await service.create(FilterInput(name: "A", jql: "type = Bug"))
        let request = try #require(await mock.recorded.first)
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(request.body))
        #expect(body["favourite"]?.boolValue == true)
    }

    @Test("A hierarchical name defaults to non-favourite — it's already visible in the tree")
    func createsHierarchicalFilterAsNonFavourite() async throws {
        let mock = MockTransport(stubs: [.ok(try Fixture.data("filter"))])
        let service = makeService(mock)

        _ = try await service.create(FilterInput(name: "Swira: Bugs", jql: "type = Bug"))
        let request = try #require(await mock.recorded.first)
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(request.body))
        #expect(body["favourite"]?.boolValue == false)
    }

    @Test("An explicit favourite choice is never overridden by the name-shape default")
    func explicitFavouriteChoiceWins() async throws {
        let mock = MockTransport(stubs: [.ok(try Fixture.data("filter")), .ok(try Fixture.data("filter"))])
        let service = makeService(mock)

        _ = try await service.create(FilterInput(name: "A", jql: "type = Bug", favourite: false))
        let first = try #require(await mock.recorded.first)
        let firstBody = try JSONDecoder().decode(JSONValue.self, from: try #require(first.body))
        #expect(firstBody["favourite"]?.boolValue == false)

        _ = try await service.create(FilterInput(name: "Swira: Bugs", jql: "type = Bug", favourite: true))
        let second = try #require(await mock.recorded.last)
        let secondBody = try JSONDecoder().decode(JSONValue.self, from: try #require(second.body))
        #expect(secondBody["favourite"]?.boolValue == true)
    }

    @Test("Deleting tolerates the empty 204 body Jira answers with")
    func deletesFilter() async throws {
        let mock = MockTransport(stubs: [.status(204)])
        try await makeService(mock).delete(id: "10000")

        let request = try #require(await mock.recorded.first)
        #expect(request.method == .delete)
        #expect(request.path == "filter/10000")
    }

    @Test("The default share scope unwraps Jira's single-key envelope")
    func readsDefaultShareScope() async throws {
        let mock = MockTransport(stubs: [.ok(Data(#"{"scope":"AUTHENTICATED"}"#.utf8))])
        let scope = try await makeService(mock).defaultShareScope()
        #expect(scope == .authenticated)
    }

    @Test("Columns come back as label/value pairs ready for a picker")
    func readsColumns() async throws {
        let body = Data(#"""
        [{"label":"Key","value":"issuekey"},{"label":"Summary","value":"summary"}]
        """#.utf8)
        let columns = try await makeService(MockTransport(stubs: [.ok(body)])).columns(id: "10")

        #expect(columns.map(\.value) == ["issuekey", "summary"])
        #expect(columns.first?.label == "Key")
    }

    @Test("Setting columns on Cloud sends a JSON body — the only shape that endpoint accepts")
    func setsColumnsOnCloud() async throws {
        // The documented `application/x-www-form-urlencoded` shape is unusable here: Cloud's
        // edge appends `;charset=UTF-8` to any Content-Type unconditionally (confirmed live,
        // independent of this client, via curl), and the endpoint then 415s on that charset.
        // Verified live against a real filter that this JSON body is what Jira actually accepts.
        let mock = MockTransport(stubs: [.status(204)])
        let service = FiltersService(
            client: JiraClient(transport: mock, auth: NoAuthProvider()),
            deployment: .cloud
        )

        try await service.setColumns(id: "10", fieldIds: ["summary", "status"])

        let request = try #require(await mock.recorded.first)
        #expect(request.method == .put)
        #expect(request.path == "filter/10/columns")
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(request.body))
        #expect(body["columns"]?.arrayValue == [.string("summary"), .string("status")])
    }

    @Test("Setting columns on Data Center sends the documented form-encoded body")
    func setsColumnsOnDataCenter() async throws {
        let mock = MockTransport(stubs: [.status(204)])
        let service = FiltersService(
            client: JiraClient(transport: mock, auth: NoAuthProvider()),
            deployment: .dataCenter
        )

        try await service.setColumns(id: "10", fieldIds: ["summary", "status"])

        let request = try #require(await mock.recorded.first)
        #expect(request.headers["Content-Type"] == "application/x-www-form-urlencoded")
        let body = String(decoding: try #require(request.body), as: UTF8.self)
        #expect(body == "columns=summary&columns=status")
    }
}

@Suite("Pagination")
struct PaginationTests {
    @Test("hasMore prefers isLast, then total, then a full page")
    func decidesWhenMorePagesExist() {
        #expect(!OffsetPage<JiraUser>(values: [], startAt: 0, maxResults: 50, total: 100, isLast: true).hasMore)
        #expect(OffsetPage<JiraUser>(values: [], startAt: 0, maxResults: 50, total: 100, isLast: false).hasMore)

        let byTotal = OffsetPage<FilterColumn>(
            values: [FilterColumn(label: "a", value: "a")],
            startAt: 0, maxResults: 1, total: 3, isLast: nil
        )
        #expect(byTotal.hasMore)

        let lastByTotal = OffsetPage<FilterColumn>(
            values: [FilterColumn(label: "a", value: "a")],
            startAt: 2, maxResults: 1, total: 3, isLast: nil
        )
        #expect(!lastByTotal.hasMore)

        // With neither signal, a page that came back full is assumed to have a successor.
        let full = OffsetPage<FilterColumn>(
            values: [FilterColumn(label: "a", value: "a")],
            startAt: 0, maxResults: 1, total: nil, isLast: nil
        )
        #expect(full.hasMore)
    }

    @Test("A server that never stops handing out cursors cannot spin the loop forever")
    func enforcesPageLimit() async throws {
        let sequence = PagedSequence<Int>(pageLimit: 5) { cursor in
            let start: Int
            if case .offset(let value) = cursor { start = value } else { start = 0 }
            // Deliberately pathological: always another page.
            return ([start], .offset(start + 1))
        }

        var collected: [Int] = []
        for try await value in sequence {
            collected.append(value)
        }
        #expect(collected == [0, 1, 2, 3, 4])
    }

    @Test("An empty page ends the walk even if the server still offers a cursor")
    func stopsOnEmptyPage() async throws {
        let sequence = PagedSequence<Int> { cursor in
            cursor == nil ? ([1, 2], .offset(2)) : ([], .offset(4))
        }

        var collected: [Int] = []
        for try await value in sequence {
            collected.append(value)
        }
        #expect(collected == [1, 2])
    }
}
