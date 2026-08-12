import Foundation
import Testing

@testable import SwiraCore

@Suite("JQLService")
struct JQLServiceTests {
    private func makeService(_ mock: MockTransport) -> JQLService {
        JQLService(client: JiraClient(transport: mock, auth: NoAuthProvider()))
    }

    @Test("A valid query reports no errors")
    func validatesGoodQuery() async throws {
        let body = Data(#"""
        {"queries":[{"query":"project = SWIRA","structure":{"where":{"field":{"name":"project"}}}}]}
        """#.utf8)
        let result = try await makeService(MockTransport(stubs: [.ok(body)]))
            .validate("project = SWIRA")

        #expect(result.isValid)
        #expect(result.errors.isEmpty)
        #expect(result.query == "project = SWIRA")
        #expect(result.structure?.path("where.field.name")?.stringValue == "project")
    }

    @Test("A bad query surfaces Jira's message instead of a bare 400")
    func reportsValidationErrors() async throws {
        let body = Data(#"""
        {"queries":[{"query":"project = ","errors":["Expecting a value after 'project ='."]}]}
        """#.utf8)
        let result = try await makeService(MockTransport(stubs: [.ok(body)]))
            .validate("project = ")

        #expect(!result.isValid)
        #expect(result.errors == ["Expecting a value after 'project ='."])
    }

    @Test("Validation level is passed through as a query parameter")
    func passesValidationLevel() async throws {
        let mock = MockTransport(stubs: [.ok(Data(#"{"queries":[{"query":"a"}]}"#.utf8))])
        _ = try await makeService(mock).validate("a", level: .warn)

        let request = try #require(await mock.recorded.first)
        #expect(request.method == .post)
        #expect(request.path == "jql/parse")
        #expect(request.queryItems.contains(URLQueryItem(name: "validation", value: "warn")))

        let sent = try JSONDecoder().decode(JSONValue.self, from: try #require(request.body))
        #expect(sent["queries"]?.arrayValue == [.string("a")])
    }

    @Test("Several queries are checked in one round trip")
    func validatesInBatch() async throws {
        let body = Data(#"""
        {"queries":[{"query":"a","errors":["bad"]},{"query":"b"}]}
        """#.utf8)
        let results = try await makeService(MockTransport(stubs: [.ok(body)]))
            .validate(["a", "b"])

        #expect(results.count == 2)
        #expect(!results[0].isValid)
        #expect(results[1].isValid)
    }

    @Test("Validating nothing does not hit the network")
    func skipsEmptyBatch() async throws {
        let mock = MockTransport(stubs: [])
        #expect(try await makeService(mock).validate([]).isEmpty)
        #expect(await mock.requestCount == 0)
    }

    @Test("A response with no result is an error, not a silent success")
    func rejectsEmptyResponse() async throws {
        let mock = MockTransport(stubs: [.ok(Data(#"{"queries":[]}"#.utf8))])
        await #expect(throws: SwiraError.self) {
            _ = try await makeService(mock).validate("project = SWIRA")
        }
    }

    @Test("Autocomplete data decodes Jira's string-typed booleans")
    func decodesAutocompleteData() async throws {
        let body = Data(#"""
        {
          "visibleFieldNames": [
            {"value":"status","displayName":"Status","orderable":"true","searchable":"true",
             "auto":"true","operators":["=","!=","in"],"types":["java.lang.String"]},
            {"value":"cf[10001]","displayName":"Team - cf[10001]","cfid":"cf[10001]",
             "orderable":"true","searchable":"true","auto":"false","operators":["="],"types":[]}
          ],
          "visibleFunctionNames": [
            {"value":"currentUser()","displayName":"currentUser()","isList":"false","types":[]},
            {"value":"membersOf(group)","displayName":"membersOf(group)","isList":"true","types":[]}
          ],
          "jqlReservedWords": ["and","or","not"]
        }
        """#.utf8)
        let data = try await makeService(MockTransport(stubs: [.ok(body)])).autocompleteData()

        #expect(data.visibleFieldNames.count == 2)
        // Jira sends these as the strings "true"/"false", not JSON booleans.
        #expect(data.visibleFieldNames[0].isSearchable)
        #expect(data.visibleFieldNames[0].supportsAutocomplete)
        #expect(!data.visibleFieldNames[0].isCustomField)
        #expect(data.visibleFieldNames[1].isCustomField)
        #expect(!data.visibleFieldNames[1].supportsAutocomplete)

        #expect(!data.visibleFunctionNames[0].isList)
        #expect(data.visibleFunctionNames[1].isList)
        #expect(data.jqlReservedWords.contains("and"))
    }

    @Test("Project ids narrow the autocomplete vocabulary")
    func narrowsAutocompleteByProject() async throws {
        let mock = MockTransport(stubs: [.ok(Data("{}".utf8))])
        _ = try await makeService(mock).autocompleteData(projectIds: [10100, 10200])

        let request = try #require(await mock.recorded.first)
        let ids = request.queryItems.filter { $0.name == "projectIds" }.compactMap(\.value)
        #expect(ids == ["10100", "10200"])
    }

    @Test("Suggestions unwrap the results envelope and strip highlight markup")
    func decodesSuggestions() async throws {
        let body = Data(#"""
        {"results":[{"value":"In Progress","displayName":"In <b>Prog</b>ress"}]}
        """#.utf8)
        let mock = MockTransport(stubs: [.ok(body)])
        let suggestions = try await makeService(mock)
            .suggestions(fieldName: "status", fieldValue: "Prog")

        #expect(suggestions.count == 1)
        #expect(suggestions[0].value == "In Progress")
        // Jira marks the matched substring with <b> tags, which no terminal wants verbatim.
        #expect(suggestions[0].plainDisplayName == "In Progress")

        let request = try #require(await mock.recorded.first)
        #expect(request.path == "jql/autocompletedata/suggestions")
        #expect(request.queryItems.contains(URLQueryItem(name: "fieldName", value: "status")))
        #expect(request.queryItems.contains(URLQueryItem(name: "fieldValue", value: "Prog")))
    }

    @Test("Sanitizing returns the query with invisible clauses removed")
    func sanitizesQuery() async throws {
        let body = Data(#"""
        {"queries":[{"initialQuery":"project = SECRET","sanitizedQuery":"project = 10100","errors":[]}]}
        """#.utf8)
        let mock = MockTransport(stubs: [.ok(body)])
        let result = try await makeService(mock)
            .sanitize("project = SECRET", forAccountId: "abc123")

        #expect(result.sanitizedQuery == "project = 10100")

        let request = try #require(await mock.recorded.first)
        let sent = try JSONDecoder().decode(JSONValue.self, from: try #require(request.body))
        #expect(sent.path("queries.0.accountId") == nil)
        let first = try #require(sent["queries"]?.arrayValue?.first)
        #expect(first["accountId"]?.stringValue == "abc123")
        #expect(first["query"]?.stringValue == "project = SECRET")
    }
}

@Suite("ReferenceService")
struct ReferenceServiceTests {
    private func makeService(_ mock: MockTransport) -> ReferenceService {
        ReferenceService(client: JiraClient(transport: mock, auth: NoAuthProvider()))
    }

    @Test("The current user comes from /myself")
    func readsCurrentUser() async throws {
        let mock = MockTransport(stubs: [.ok(try Fixture.data("myself"))])
        let user = try await makeService(mock).currentUser().value

        #expect(user.accountId == "5b10a2844c20165700ede21g")
        #expect(try #require(await mock.recorded.first).path == "myself")
    }

    @Test("Projects arrive as an offset page")
    func readsProjects() async throws {
        let body = Data(#"""
        {"startAt":0,"maxResults":50,"total":2,"isLast":true,"values":[
          {"id":"10100","key":"SWIRA","name":"Swira","projectTypeKey":"software"},
          {"id":"10200","key":"OPS","name":"Operations"}
        ]}
        """#.utf8)
        let page = try await makeService(MockTransport(stubs: [.ok(body)])).projects().value

        #expect(page.values.map(\.key) == ["SWIRA", "OPS"])
        #expect(page.values[0].numericId == 10100)
        #expect(!page.hasMore)
    }

    @Test("Fields expose their type and JQL clause names")
    func readsFields() async throws {
        let body = Data(#"""
        [
          {"id":"summary","name":"Summary","custom":false,"searchable":true,"navigable":true,
           "clauseNames":["summary"],"schema":{"type":"string","system":"summary"}},
          {"id":"customfield_10001","name":"Team","custom":true,"searchable":true,
           "clauseNames":["cf[10001]","Team"],"schema":{"type":"user","customId":10001}}
        ]
        """#.utf8)
        let fields = try await makeService(MockTransport(stubs: [.ok(body)])).fields().value

        #expect(fields.count == 2)
        #expect(fields[0].type == "string")
        #expect(!fields[0].custom)
        #expect(fields[1].custom)
        #expect(fields[1].type == "user")
        #expect(fields[1].clauseNames.contains("cf[10001]"))
    }

    @Test("Group search unwraps the picker envelope")
    func readsGroups() async throws {
        let body = Data(#"""
        {"header":"Showing 2 of 2","total":2,"groups":[
          {"name":"jira-users","groupId":"276f955c"},
          {"name":"jira-admins","groupId":"99a1b2c3"}
        ]}
        """#.utf8)
        let groups = try await makeService(MockTransport(stubs: [.ok(body)]))
            .searchGroups(matching: "jira")

        #expect(groups.map(\.name) == ["jira-users", "jira-admins"])
    }

    @Test("An empty picker query does not hit the network")
    func skipsEmptyPickerQueries() async throws {
        let mock = MockTransport(stubs: [])
        #expect(try await makeService(mock).searchUsers(matching: "").isEmpty)
        #expect(try await makeService(mock).searchGroups(matching: "").isEmpty)
        #expect(await mock.requestCount == 0)
    }
}
