import Foundation

/// Which kind of Jira is on the other end.
///
/// The two deployments share most of their API surface but diverge exactly where Swira lives:
/// Cloud has `filter/search`, `jql/parse`, and cursor-based `search/jql`; Server / Data Center
/// has none of those and answers the same questions through older endpoints. Services branch on
/// this so that their public API stays identical across deployments.
public enum JiraDeployment: Sendable, Hashable {
    case cloud
    case dataCenter
}

/// The address of a Jira instance plus the REST API version to talk to it with.
public struct JiraSite: Sendable, Hashable {
    public let baseURL: URL
    /// `3` for Jira Cloud, `2` for Data Center. Substituted into `/rest/api/{version}/...`.
    public let apiVersion: String

    public init(baseURL: URL, apiVersion: String = "3") {
        self.baseURL = baseURL
        self.apiVersion = apiVersion
    }

    /// Parses an address as a human would type it: no scheme, a trailing slash, stray whitespace.
    public init(urlString: String, apiVersion: String = "3") throws {
        var trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SwiraError.configuration(missing: "Jira site URL", searched: [])
        }
        if !trimmed.contains("://") {
            trimmed = "https://" + trimmed
        }
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        guard let url = URL(string: trimmed), url.host != nil else {
            throw SwiraError.configuration(
                missing: "a valid Jira site URL (got: \(urlString))",
                searched: []
            )
        }
        self.init(baseURL: url, apiVersion: apiVersion)
    }

    /// Derived from the API version: only Data Center serves v2, only Cloud serves v3.
    ///
    /// Anyone pointing Swira at a v2 API (`JIRA_API_VERSION=2`) is talking to Server / Data
    /// Center, and the services adjust their endpoint choices accordingly.
    public var deployment: JiraDeployment {
        apiVersion == "2" ? .dataCenter : .cloud
    }

    /// Builds the full URL for a REST API path.
    ///
    /// - Parameter path: the path after the version, e.g. `filter/search`.
    func apiURL(path: String, queryItems: [URLQueryItem] = []) -> URL? {
        let normalizedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let full = baseURL
            .appendingPathComponent("rest")
            .appendingPathComponent("api")
            .appendingPathComponent(apiVersion)
            .appendingPathComponent(normalizedPath)

        guard var components = URLComponents(url: full, resolvingAgainstBaseURL: false) else {
            return nil
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        return components.url
    }
}
