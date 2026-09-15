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
    /// Marks a request as a read worth caching despite not being GET.
    ///
    /// Some Jira reads (issue search) are POST-only, because the JQL in the body routinely
    /// exceeds what a URL can carry — see `SearchEndpoints`. Set only on endpoints that are
    /// genuinely read-only; `JiraClient.sendCached` trusts this flag without re-deriving it.
    public var isCacheableRead: Bool = false

    public init(
        method: HTTPMethod,
        path: String,
        queryItems: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: Data? = nil,
        isCacheableRead: Bool = false
    ) {
        self.method = method
        self.path = path
        self.queryItems = queryItems
        self.headers = headers
        self.body = body
        self.isCacheableRead = isCacheableRead
    }

    public mutating func setHeader(_ name: String, _ value: String) {
        headers[name] = value
    }

    /// Cache key: method, path, sorted query parameters, and — for a cacheable POST read — a
    /// fingerprint of the body, since that's where a search's JQL actually lives. Headers are
    /// always excluded.
    var cacheKey: String {
        let query = queryItems
            .sorted { $0.name < $1.name }
            .map { "\($0.name)=\($0.value ?? "")" }
            .joined(separator: "&")
        var key = query.isEmpty ? "\(method.rawValue) \(path)" : "\(method.rawValue) \(path)?\(query)"
        if method != .get, let body, !body.isEmpty {
            key += "#\(FingerprintHash.of(String(decoding: body, as: UTF8.self)))"
        }
        return key
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
