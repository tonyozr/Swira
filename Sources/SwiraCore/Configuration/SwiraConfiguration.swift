import Foundation

/// Everything the core needs in order to talk to a Jira site.
public struct SwiraConfiguration: Sendable {
    public var site: JiraSite
    /// Per-request timeout, in seconds.
    public var timeout: TimeInterval
    /// How many times a failed request may be retried before the error propagates.
    public var maxRetries: Int
    /// Directory for the on-disk cache.
    public var cacheDirectory: URL
    /// User-Agent sent with every request. Jira support asks for a recognizable one.
    public var userAgent: String

    public init(
        site: JiraSite,
        timeout: TimeInterval = 30,
        maxRetries: Int = 3,
        cacheDirectory: URL = CacheLocation.default(),
        userAgent: String = "swira/0.1"
    ) {
        self.site = site
        self.timeout = timeout
        self.maxRetries = maxRetries
        self.cacheDirectory = cacheDirectory
        self.userAgent = userAgent
    }
}

// MARK: - Environment

extension SwiraConfiguration {
    /// Environment variables consulted for the site URL, in priority order.
    public static let urlVariables = ["SWIRA_JIRA_URL", "JIRA_URL", "JIRA_BASE_URL"]
    /// Environment variables consulted for the login email, in priority order.
    public static let emailVariables = ["JIRA_EMAIL", "JIRA_USER"]
    /// Environment variables consulted for the API token, in priority order.
    public static let tokenVariables = ["JIRA_API_TOKEN", "JIRA_TOKEN", "JIRA_PAT"]
    /// Overrides the REST API version. `2` targets Jira Data Center; Cloud uses the default `3`.
    public static let apiVersionVariables = ["JIRA_API_VERSION"]

    /// Builds a configuration and a matching auth provider from the environment.
    ///
    /// If a token is present but no email is, the bearer scheme is used — that is the shape Jira
    /// Data Center personal access tokens take, and guessing wrong here produces a confusing 401
    /// rather than an honest configuration error.
    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> (configuration: SwiraConfiguration, auth: AuthProvider) {
        guard let urlString = firstValue(of: urlVariables, in: environment) else {
            throw SwiraError.configuration(missing: "Jira site URL", searched: urlVariables)
        }
        guard let token = firstValue(of: tokenVariables, in: environment) else {
            throw SwiraError.configuration(missing: "Jira API token", searched: tokenVariables)
        }

        let apiVersion = firstValue(of: apiVersionVariables, in: environment) ?? "3"
        let site = try JiraSite(urlString: urlString, apiVersion: apiVersion)
        let configuration = SwiraConfiguration(site: site)

        let auth: AuthProvider
        if let email = firstValue(of: emailVariables, in: environment) {
            auth = BasicAuthProvider(email: email, apiToken: Secret(token))
        } else {
            auth = BearerAuthProvider(token: Secret(token))
        }

        return (configuration, auth)
    }

    private static func firstValue(of names: [String], in environment: [String: String]) -> String? {
        for name in names {
            if let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }
}
