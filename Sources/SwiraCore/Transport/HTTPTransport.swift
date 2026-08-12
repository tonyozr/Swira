import Foundation

/// Carries a request to the network and brings a response back.
///
/// Everything above this protocol is pure logic, which is what makes the whole core testable
/// offline: tests swap in a transport that replays recorded fixtures.
public protocol HTTPTransport: Sendable {
    /// Performs the request.
    ///
    /// Implementations return the response for *any* HTTP status, including 4xx and 5xx —
    /// interpreting status codes is `JiraClient`'s job. Only genuine network failures throw.
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}
