import Foundation
import Testing

@testable import SwiraCore

@Suite("IssueService")
struct IssueServiceTests {
    private func makeService(_ mock: MockTransport, deployment: JiraDeployment = .cloud) -> IssueService {
        IssueService(client: JiraClient(transport: mock, auth: NoAuthProvider()), deployment: deployment)
    }

    @Test("Setting text sends a plain string field, not an object")
    func setsTextField() async throws {
        let mock = MockTransport(stubs: [.status(204)])
        try await makeService(mock).setText(issueKey: "SW-1", fieldId: "summary", value: "New title")

        let request = try #require(await mock.recorded.first)
        #expect(request.method == .put)
        #expect(request.path == "issue/SW-1")
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(request.body))
        #expect(body.path("fields.summary") == .string("New title"))
    }

    @Test("Setting a number sends a JSON number, not a string")
    func setsNumberField() async throws {
        let mock = MockTransport(stubs: [.status(204)])
        try await makeService(mock).setNumber(issueKey: "SW-1", fieldId: "customfield_10050", value: 42)

        let request = try #require(await mock.recorded.first)
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(request.body))
        // A whole number decodes as .int, not .double — either way it's a plain JSON number,
        // never a string, which is the thing actually under test here.
        #expect(body.path("fields.customfield_10050")?.doubleValue == 42)
    }

    @Test("Priority is sent as a nested id object")
    func setsPriority() async throws {
        let mock = MockTransport(stubs: [.status(204)])
        try await makeService(mock).setPriority(issueKey: "SW-1", priorityId: "3")

        let request = try #require(await mock.recorded.first)
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(request.body))
        #expect(body.path("fields.priority.id") == .string("3"))
    }

    @Test("Assignee is keyed by accountId on Cloud")
    func setsAssigneeOnCloud() async throws {
        let mock = MockTransport(stubs: [.status(204)])
        try await makeService(mock, deployment: .cloud)
            .setAssignee(issueKey: "SW-1", accountId: "abc123")

        let request = try #require(await mock.recorded.first)
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(request.body))
        #expect(body.path("fields.assignee.accountId") == .string("abc123"))
        #expect(body.path("fields.assignee.name") == nil)
    }

    @Test("Assignee is keyed by name on Data Center — the dialect that bit /myself earlier")
    func setsAssigneeOnDataCenter() async throws {
        let mock = MockTransport(stubs: [.status(204)])
        try await makeService(mock, deployment: .dataCenter)
            .setAssignee(issueKey: "SW-1", accountId: "mia.krystof")

        let request = try #require(await mock.recorded.first)
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(request.body))
        #expect(body.path("fields.assignee.name") == .string("mia.krystof"))
        #expect(body.path("fields.assignee.accountId") == nil)
    }

    @Test("Unassigning sends an explicit null, on either deployment")
    func unassigns() async throws {
        let mock = MockTransport(stubs: [.status(204)])
        try await makeService(mock).setAssignee(issueKey: "SW-1", accountId: nil)

        let request = try #require(await mock.recorded.first)
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(request.body))
        #expect(body["fields"]?["assignee"]?.isNull == true)
    }

    @Test("Labels replace the full set as a plain string array")
    func setsLabels() async throws {
        let mock = MockTransport(stubs: [.status(204)])
        try await makeService(mock).setLabels(issueKey: "SW-1", labels: ["ui", "regression"])

        let request = try #require(await mock.recorded.first)
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(request.body))
        #expect(body["fields"]?["labels"]?.arrayValue == [.string("ui"), .string("regression")])
    }

    @Test("Fix versions are sent as an array of id objects, not names")
    func setsFixVersions() async throws {
        let mock = MockTransport(stubs: [.status(204)])
        try await makeService(mock).setFixVersions(issueKey: "SW-1", versionIds: ["10000", "10001"])

        let request = try #require(await mock.recorded.first)
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(request.body))
        let versions = try #require(body.path("fields.fixVersions")?.arrayValue)
        #expect(versions.map { $0["id"]?.stringValue } == ["10000", "10001"])
    }

    @Test("An empty fix-versions list clears the field rather than being a no-op")
    func clearsFixVersions() async throws {
        let mock = MockTransport(stubs: [.status(204)])
        try await makeService(mock).setFixVersions(issueKey: "SW-1", versionIds: [])

        let request = try #require(await mock.recorded.first)
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(request.body))
        #expect(body["fields"]?["fixVersions"]?.arrayValue == [])
    }

    @Test("A field update never touches fields the caller didn't mention")
    func onlyUpdatesGivenFields() async throws {
        let mock = MockTransport(stubs: [.status(204)])
        try await makeService(mock).setText(issueKey: "SW-1", fieldId: "summary", value: "x")

        let request = try #require(await mock.recorded.first)
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(request.body))
        #expect(body["fields"]?.objectValue?.count == 1)
    }

    @Test("Available transitions decode, including the status each one leads to")
    func readsTransitions() async throws {
        let body = Data(#"""
        {"transitions":[
          {"id":"11","name":"Start Progress","to":{"name":"In Progress","statusCategory":{"key":"indeterminate"}}},
          {"id":"21","name":"Done","to":{"name":"Done","statusCategory":{"key":"done"}}}
        ]}
        """#.utf8)
        let transitions = try await makeService(MockTransport(stubs: [.ok(body)]))
            .transitions(issueKey: "SW-1")

        #expect(transitions.map(\.name) == ["Start Progress", "Done"])
        #expect(transitions[0].to?.statusCategory?.key == "indeterminate")
    }

    @Test("Fetching transitions hits the transitions endpoint, not a plain issue read")
    func transitionsRequestShape() async throws {
        let mock = MockTransport(stubs: [.ok(Data(#"{"transitions":[]}"#.utf8))])
        _ = try await makeService(mock).transitions(issueKey: "SW-1")

        let request = try #require(await mock.recorded.first)
        #expect(request.method == .get)
        #expect(request.path == "issue/SW-1/transitions")
    }

    @Test("Applying a transition posts the transition id, addressing the issue in the path")
    func appliesTransition() async throws {
        let mock = MockTransport(stubs: [.status(204)])
        try await makeService(mock).transition(issueKey: "SW-1", transitionId: "21")

        let request = try #require(await mock.recorded.first)
        #expect(request.method == .post)
        #expect(request.path == "issue/SW-1/transitions")
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(request.body))
        #expect(body.path("transition.id") == .string("21"))
    }
}

@Suite("ReferenceService priorities")
struct ReferencePrioritiesTests {
    @Test("Priorities decode and are cacheable like other reference data")
    func readsPriorities() async throws {
        let body = Data(#"""
        [{"id":"1","name":"Highest"},{"id":"3","name":"Medium","iconUrl":"https://x/icon.png"}]
        """#.utf8)
        let mock = MockTransport(stubs: [.ok(body)])
        let service = ReferenceService(client: JiraClient(transport: mock, auth: NoAuthProvider()))

        let result = try await service.priorities()
        #expect(result.value.map(\.name) == ["Highest", "Medium"])
        #expect(result.value[1].iconUrl == "https://x/icon.png")

        let request = try #require(await mock.recorded.first)
        #expect(request.path == "priority")
    }

    @Test("Project versions decode, for a fixVersions picker")
    func readsProjectVersions() async throws {
        let body = Data(#"""
        [{"id":"10000","name":"1.0","released":true,"archived":false},
         {"id":"10001","name":"2.0","released":false}]
        """#.utf8)
        let mock = MockTransport(stubs: [.ok(body)])
        let service = ReferenceService(client: JiraClient(transport: mock, auth: NoAuthProvider()))

        let result = try await service.projectVersions(projectIdOrKey: "SWIRA")
        #expect(result.value.map(\.name) == ["1.0", "2.0"])
        #expect(result.value[0].released == true)
        #expect(result.value[1].released == false)

        let request = try #require(await mock.recorded.first)
        #expect(request.path == "project/SWIRA/versions")
    }
}
