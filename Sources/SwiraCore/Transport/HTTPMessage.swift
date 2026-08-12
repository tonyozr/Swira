import Foundation

public enum HTTPMethod: String, Sendable, Hashable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"

    /// Idempotent methods are safe to repeat after a network failure; POST is not.
    var isIdempotent: Bool {
        self != .post
    }
}

/// A request expressed in Jira REST terms: a path relative to `/rest/api/{version}/`, no host.
///
/// The host and authorization headers are filled in further down the stack, which keeps this
/// structure directly comparable in tests without dragging configuration along.
public struct HTTPRequest: Sendable, Hashable {
    public var method: HTTPMethod
    public var path: String
    public var queryItems: [URLQueryItem]
    public var headers: [String: String]
    public var body: Data?

    public init(
        method: HTTPMethod,
        path: String,
        queryItems: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: Data? = nil
    ) {
        self.method = method
        self.path = path
        self.queryItems = queryItems
        self.headers = headers
        self.body = body
    }

    public mutating func setHeader(_ name: String, _ value: String) {
        headers[name] = value
    }

    /// Cache key: method, path, and sorted query parameters. Headers and body are excluded —
    /// only GET requests are ever cached.
    var cacheKey: String {
        let query = queryItems
            .sorted { $0.name < $1.name }
            .map { "\($0.name)=\($0.value ?? "")" }
            .joined(separator: "&")
        return query.isEmpty ? "\(method.rawValue) \(path)" : "\(method.rawValue) \(path)?\(query)"
    }
}

public struct HTTPResponse: Sendable, Hashable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public var isSuccess: Bool {
        (200..<300).contains(status)
    }

    /// HTTP header names are case-insensitive, and servers and `URLSession` normalize them
    /// differently across platforms — so look them up case-insensitively.
    public func header(_ name: String) -> String? {
        if let exact = headers[name] {
            return exact
        }
        let lowered = name.lowercased()
        return headers.first { $0.key.lowercased() == lowered }?.value
    }
}
