import Foundation

/// The single error type the core surfaces to its callers.
///
/// Clients (AppKit alerts, CLI output) render `errorDescription` without any mapping of their own,
/// while `isRetryable` / `suggestsReauth` let the UI pick a reaction without matching on cases.
public enum SwiraError: Error, Sendable, Equatable {
    /// Configuration is incomplete. `searched` lists the environment variables that were consulted.
    case configuration(missing: String, searched: [String])
    /// The network failed: connection reset, timeout, DNS. The text is already human-readable.
    case transport(description: String)
    /// 401 — the token is wrong, expired, or does not belong to this site.
    case unauthorized
    /// 403 — the token is valid but lacks permission.
    case forbidden
    /// 404.
    case notFound(resource: String)
    /// 429. `retryAfter` comes from the header of the same name, when Jira sends one.
    case rateLimited(retryAfter: TimeInterval?)
    /// Jira's error envelope: `{"errorMessages": [...], "errors": {...}}`.
    case jira(status: Int, messages: [String], fieldErrors: [String: String])
    /// The response did not decode. `path` is the offending key path, `snippet` the start of the body.
    case decoding(path: String, snippet: String)
    /// Cached data was requested exclusively, and none was usable.
    case offline(hasStaleCache: Bool)
    case cancelled

    /// Whether retrying the request as-is could succeed, without the user changing anything.
    public var isRetryable: Bool {
        switch self {
        case .transport, .rateLimited:
            return true
        case .jira(let status, _, _):
            return status >= 500
        case .configuration, .unauthorized, .forbidden, .notFound,
             .decoding, .offline, .cancelled:
            return false
        }
    }

    /// Whether the user should be prompted to update their credentials.
    public var suggestsReauth: Bool {
        switch self {
        case .unauthorized, .configuration:
            return true
        default:
            return false
        }
    }
}

extension SwiraError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .configuration(let missing, let searched):
            if searched.isEmpty {
                return "Missing configuration: \(missing)."
            }
            return "Missing configuration: \(missing). Checked environment variables: \(searched.joined(separator: ", "))."
        case .transport(let description):
            return "Network error: \(description)"
        case .unauthorized:
            return "Jira rejected the credentials (401). Check the email and API token."
        case .forbidden:
            return "Not enough permissions for this operation (403)."
        case .notFound(let resource):
            return "Not found: \(resource)"
        case .rateLimited(let retryAfter):
            if let retryAfter {
                return "Jira rate limit exceeded. Retry in \(Int(retryAfter))s."
            }
            return "Jira rate limit exceeded."
        case .jira(let status, let messages, let fieldErrors):
            var parts = messages
            for (field, message) in fieldErrors.sorted(by: { $0.key < $1.key }) {
                parts.append("\(field): \(message)")
            }
            if parts.isEmpty {
                return "Jira returned error \(status) with no description."
            }
            return parts.joined(separator: "; ")
        case .decoding(let path, let snippet):
            return "Could not decode the Jira response (\(path)). Response starts with: \(snippet)"
        case .offline(let hasStaleCache):
            return hasStaleCache
                ? "Offline; only stale data is available in the cache."
                : "Offline, and nothing cached."
        case .cancelled:
            return "The operation was cancelled."
        }
    }
}
