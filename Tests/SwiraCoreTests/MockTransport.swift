import Foundation
import Testing

@testable import SwiraCore

/// A transport that replays canned responses and records what it was asked for.
///
/// Responses are queued rather than keyed by path so that retry behaviour — the same request
/// answered differently on successive attempts — can be expressed directly.
actor MockTransport: HTTPTransport {
    struct Stub {
        var response: HTTPResponse?
        var error: SwiraError?

        static func ok(_ body: Data, headers: [String: String] = [:]) -> Stub {
            Stub(response: HTTPResponse(status: 200, headers: headers, body: body), error: nil)
        }

        static func status(
            _ status: Int,
            body: Data = Data(),
            headers: [String: String] = [:]
        ) -> Stub {
            Stub(response: HTTPResponse(status: status, headers: headers, body: body), error: nil)
        }

        static func failure(_ error: SwiraError) -> Stub {
            Stub(response: nil, error: error)
        }
    }

    private var stubs: [Stub]
    private(set) var recorded: [HTTPRequest] = []

    init(stubs: [Stub]) {
        self.stubs = stubs
    }

    init(json: String, status: Int = 200) {
        self.stubs = [.status(status, body: Data(json.utf8))]
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        recorded.append(request)
        guard !stubs.isEmpty else {
            Issue.record("MockTransport ran out of stubs for \(request.method.rawValue) \(request.path)")
            return HTTPResponse(status: 500)
        }
        let stub = stubs.removeFirst()
        if let error = stub.error {
            throw error
        }
        return stub.response ?? HTTPResponse(status: 500)
    }

    var requestCount: Int { recorded.count }
    var remainingStubs: Int { stubs.count }
}

/// A transport whose responses wait behind a gate until the test opens it.
///
/// For tests that need a request to be provably in flight — coalescing, cancellation — where
/// an instant mock reply would make the interesting window unobservably short.
actor GatedTransport: HTTPTransport {
    private let response: HTTPResponse
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    private(set) var requestCount = 0

    init(response: HTTPResponse) {
        self.response = response
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requestCount += 1
        if !isOpen {
            await withCheckedContinuation { waiters.append($0) }
        }
        return response
    }

    func open() {
        isOpen = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters.removeAll()
    }
}

/// Loads a JSON fixture bundled with the test target.
enum Fixture {
    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Fixtures"
        ) else {
            throw FixtureError.missing(name)
        }
        return try Data(contentsOf: url)
    }

    enum FixtureError: Error, CustomStringConvertible {
        case missing(String)

        var description: String {
            switch self {
            case .missing(let name): return "Fixture not found: \(name).json"
            }
        }
    }
}
