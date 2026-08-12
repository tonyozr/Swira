import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The production transport, backed by `URLSession`.
///
/// An actor rather than a struct so `URLSession` — which is not `Sendable` in
/// swift-corelibs-foundation — stays isolated without resorting to `@unchecked Sendable`.
public actor URLSessionTransport: HTTPTransport {
    private let site: JiraSite
    private let userAgent: String
    private let session: URLSession

    public init(configuration: SwiraConfiguration) {
        self.site = configuration.site
        self.userAgent = configuration.userAgent

        let sessionConfiguration = URLSessionConfiguration.default
        sessionConfiguration.timeoutIntervalForRequest = configuration.timeout
        sessionConfiguration.timeoutIntervalForResource = configuration.timeout * 2
        // Jira responses are cached by Swira itself, with explicit policies and ETag handling.
        // Letting URLSession cache underneath would make that behaviour unobservable and untestable.
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.urlCache = nil
        self.session = URLSession(configuration: sessionConfiguration)
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try Task.checkCancellation()
        let urlRequest = try makeURLRequest(request)

        // The async `URLSession.data(for:)` overloads are unreliable in corelibs-foundation on
        // Windows, so everything funnels through the completion-handler API, which behaves
        // identically on every platform.
        return try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: urlRequest) { data, response, error in
                if let error {
                    let nsError = error as NSError
                    if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                        continuation.resume(throwing: SwiraError.cancelled)
                    } else {
                        continuation.resume(
                            throwing: SwiraError.transport(description: error.localizedDescription)
                        )
                    }
                    return
                }
                guard let httpResponse = response as? HTTPURLResponse else {
                    continuation.resume(
                        throwing: SwiraError.transport(description: "Response was not HTTP")
                    )
                    return
                }
                var headers: [String: String] = [:]
                for (key, value) in httpResponse.allHeaderFields {
                    if let key = key as? String, let value = value as? String {
                        headers[key] = value
                    }
                }
                continuation.resume(
                    returning: HTTPResponse(
                        status: httpResponse.statusCode,
                        headers: headers,
                        body: data ?? Data()
                    )
                )
            }
            task.resume()
        }
    }

    func makeURLRequest(_ request: HTTPRequest) throws -> URLRequest {
        guard let url = site.apiURL(path: request.path, queryItems: request.queryItems) else {
            throw SwiraError.transport(description: "Could not build a URL for \(request.path)")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        // Jira rejects non-GET requests from clients it suspects of CSRF unless this is present.
        urlRequest.setValue("no-check", forHTTPHeaderField: "X-Atlassian-Token")
        // A caller-supplied Content-Type (e.g. the form-encoded body `filter/{id}/columns`
        // requires) always wins — checked explicitly rather than relying on a later
        // `setValue` call to overwrite an earlier one, after exactly that ordering still sent
        // `application/json` for a form-encoded body in practice.
        let hasExplicitContentType = request.headers.keys.contains {
            $0.caseInsensitiveCompare("Content-Type") == .orderedSame
        }
        if request.body != nil, !hasExplicitContentType {
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        return urlRequest
    }
}
