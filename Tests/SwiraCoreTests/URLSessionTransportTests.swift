import Foundation
import Testing

@testable import SwiraCore

@Suite("URLSessionTransport request building")
struct URLSessionTransportTests {
    private func makeTransport() -> URLSessionTransport {
        URLSessionTransport(
            configuration: SwiraConfiguration(
                site: try! JiraSite(urlString: "https://example.atlassian.net")
            )
        )
    }

    @Test("A request with a body and no explicit Content-Type defaults to JSON")
    func defaultsToJSON() async throws {
        let request = HTTPRequest(method: .post, path: "filter", body: Data("{}".utf8))
        let urlRequest = try await makeTransport().makeURLRequest(request)
        #expect(urlRequest.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test("An explicit Content-Type always wins over the JSON default")
    func explicitContentTypeWins() async throws {
        // The exact shape FilterEndpoints.setColumns sends — this is the case that actually
        // reached Jira as the wrong content type before this fix (415 Unsupported Media Type).
        let request = HTTPRequest(
            method: .put,
            path: "filter/10000/columns",
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: Data("columns=summary".utf8)
        )
        let urlRequest = try await makeTransport().makeURLRequest(request)
        #expect(urlRequest.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
    }

    @Test("A lowercase header key is still recognized as an explicit Content-Type")
    func recognizesContentTypeCaseInsensitively() async throws {
        let request = HTTPRequest(
            method: .put,
            path: "filter/10000/columns",
            headers: ["content-type": "application/x-www-form-urlencoded"],
            body: Data("columns=summary".utf8)
        )
        let urlRequest = try await makeTransport().makeURLRequest(request)
        #expect(urlRequest.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
    }

    @Test("A GET with no body gets no Content-Type at all")
    func noContentTypeWithoutBody() async throws {
        let request = HTTPRequest(method: .get, path: "myself")
        let urlRequest = try await makeTransport().makeURLRequest(request)
        #expect(urlRequest.value(forHTTPHeaderField: "Content-Type") == nil)
    }
}
