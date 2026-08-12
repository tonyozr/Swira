import Foundation
import Testing

@testable import SwiraCore

@Suite("JiraClient")
struct JiraClientTests {
    private func makeClient(_ mock: MockTransport, auth: AuthProvider = NoAuthProvider()) -> JiraClient {
        JiraClient(transport: mock, auth: auth)
    }

    @Test("A successful response decodes into a domain type")
    func decodesSuccess() async throws {
        let mock = MockTransport(stubs: [.ok(try Fixture.data("myself"))])
        let client = makeClient(mock)

        let user: JiraUser = try await client.send(HTTPRequest(method: .get, path: "myself"))

        #expect(user.accountId == "5b10a2844c20165700ede21g")
        #expect(user.displayName == "Mia Krystof")
        #expect(user.emailAddress == "mia@example.com")
        #expect(user.active)
        #expect(user.timeZone == "Australia/Sydney")
    }

    @Test("Unknown keys in a response are ignored rather than failing the request")
    func toleratesUnknownKeys() async throws {
        // The fixture carries `self` and `locale`, which `JiraUser` does not model.
        let mock = MockTransport(stubs: [.ok(try Fixture.data("myself"))])
        let client = makeClient(mock)

        let user: JiraUser = try await client.send(HTTPRequest(method: .get, path: "myself"))
        #expect(user.accountId == "5b10a2844c20165700ede21g")
    }

    @Test("The auth provider stamps every outgoing request")
    func appliesAuthorization() async throws {
        let mock = MockTransport(stubs: [.ok(try Fixture.data("myself"))])
        let auth = BasicAuthProvider(email: "mia@example.com", apiToken: Secret("token"))
        let client = makeClient(mock, auth: auth)

        let _: JiraUser = try await client.send(HTTPRequest(method: .get, path: "myself"))

        let recorded = try #require(await mock.recorded.first)
        let expected = Data("mia@example.com:token".utf8).base64EncodedString()
        #expect(recorded.headers["Authorization"] == "Basic \(expected)")
    }

    @Test("401 and 403 map to dedicated cases, not a generic Jira error")
    func mapsAuthFailures() async throws {
        let unauthorized = makeClient(MockTransport(stubs: [.status(401)]))
        await #expect(throws: SwiraError.unauthorized) {
            let _: JiraUser = try await unauthorized.send(HTTPRequest(method: .get, path: "myself"))
        }

        let forbidden = makeClient(MockTransport(stubs: [.status(403)]))
        await #expect(throws: SwiraError.forbidden) {
            let _: JiraUser = try await forbidden.send(HTTPRequest(method: .get, path: "myself"))
        }
    }

    @Test("404 names the resource that was missing")
    func mapsNotFound() async throws {
        let client = makeClient(MockTransport(stubs: [.status(404)]))

        do {
            let _: JiraUser = try await client.send(HTTPRequest(method: .get, path: "filter/999"))
            Issue.record("Expected a not-found error")
        } catch let error as SwiraError {
            guard case .notFound(let resource) = error else {
                Issue.record("Expected .notFound, got \(error)")
                return
            }
            #expect(resource == "filter/999")
            #expect(!error.isRetryable)
        }
    }

    @Test("429 carries Retry-After through to the caller")
    func mapsRateLimiting() async throws {
        let client = makeClient(
            MockTransport(stubs: [.status(429, headers: ["Retry-After": "17"])])
        )

        do {
            let _: JiraUser = try await client.send(HTTPRequest(method: .get, path: "myself"))
            Issue.record("Expected a rate-limit error")
        } catch let error as SwiraError {
            guard case .rateLimited(let retryAfter) = error else {
                Issue.record("Expected .rateLimited, got \(error)")
                return
            }
            #expect(retryAfter == 17)
            #expect(error.isRetryable)
        }
    }

    @Test("Jira's error envelope becomes the message the user reads")
    func mapsErrorEnvelope() async throws {
        let body = Data(#"""
        {"errorMessages":["The filter name is already in use."],"errors":{"jql":"Field 'foo' does not exist."}}
        """#.utf8)
        let client = makeClient(MockTransport(stubs: [.status(400, body: body)]))

        do {
            let _: JiraUser = try await client.send(HTTPRequest(method: .post, path: "filter"))
            Issue.record("Expected a Jira error")
        } catch let error as SwiraError {
            guard case .jira(let status, let messages, let fieldErrors) = error else {
                Issue.record("Expected .jira, got \(error)")
                return
            }
            #expect(status == 400)
            #expect(messages == ["The filter name is already in use."])
            #expect(fieldErrors["jql"] == "Field 'foo' does not exist.")
            #expect(error.errorDescription?.contains("already in use") == true)
            #expect(error.errorDescription?.contains("jql:") == true)
        }
    }

    @Test("A CDN bot challenge is named, not misread as an empty Jira response")
    func detectsWAFChallenge() async throws {
        // AWS WAF answers 202 — a success status — with an empty body; the header is the tell.
        let client = makeClient(
            MockTransport(stubs: [
                .status(202, headers: ["x-amzn-waf-action": "challenge"])
            ])
        )

        do {
            let _: JiraFilter = try await client.send(HTTPRequest(method: .post, path: "filter"))
            Issue.record("Expected a transport error")
        } catch let error as SwiraError {
            guard case .transport(let description) = error else {
                Issue.record("Expected .transport, got \(error)")
                return
            }
            #expect(description.contains("bot protection"))
            #expect(description.contains("challenge"))
        }
    }

    @Test("An empty body says so, instead of blaming malformed JSON")
    func reportsEmptyBodyPlainly() async throws {
        let client = makeClient(MockTransport(stubs: [.ok(Data())]))

        do {
            let _: JiraUser = try await client.send(HTTPRequest(method: .get, path: "myself"))
            Issue.record("Expected a decoding error")
        } catch let error as SwiraError {
            guard case .decoding(_, let snippet) = error else {
                Issue.record("Expected .decoding, got \(error)")
                return
            }
            #expect(snippet == "the response body was empty")
        }
    }

    @Test("An empty body is valid when nothing was expected back")
    func acceptsEmptyBodyForEmptyType() async throws {
        let client = makeClient(MockTransport(stubs: [.status(204)]))
        let result: Empty = try await client.send(HTTPRequest(method: .delete, path: "filter/1"))
        #expect(result == Empty())
    }

    @Test("A decoding failure points at the offending key and shows the body")
    func reportsDecodingPath() async throws {
        let body = Data(#"{"accountId":"abc","displayName":42}"#.utf8)
        let client = makeClient(MockTransport(stubs: [.ok(body)]))

        do {
            let _: JiraUser = try await client.send(HTTPRequest(method: .get, path: "myself"))
            Issue.record("Expected a decoding error")
        } catch let error as SwiraError {
            guard case .decoding(let path, let snippet) = error else {
                Issue.record("Expected .decoding, got \(error)")
                return
            }
            #expect(path.contains("displayName"))
            #expect(snippet.contains("accountId"))
        }
    }
}

@Suite("JSONValue")
struct JSONValueTests {
    @Test("Nested values are reachable by subscript and by dot path")
    func navigatesNestedValues() throws {
        let data = Data(#"""
        {"fields":{"summary":"Fix login","status":{"name":"In Progress","id":3},"labels":["a","b"]}}
        """#.utf8)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)

        #expect(value["fields"]?["summary"]?.stringValue == "Fix login")
        #expect(value.path("fields.status.name")?.stringValue == "In Progress")
        #expect(value.path("fields.status.id")?.intValue == 3)
        #expect(value.path("fields.labels")?.arrayValue?.count == 2)
        #expect(value.path("fields.missing") == nil)
    }

    @Test("A decoded value re-encodes to the same JSON")
    func roundTrips() throws {
        let original = Data(#"{"a":[1,2.5,null,true,"x"],"b":{"c":"d"}}"#.utf8)
        let value = try JSONDecoder().decode(JSONValue.self, from: original)
        let reencoded = try JSONEncoder().encode(value)
        let again = try JSONDecoder().decode(JSONValue.self, from: reencoded)
        #expect(value == again)
    }
}
