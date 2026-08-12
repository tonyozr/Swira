import Foundation

/// Adds the authorization header to an outgoing request.
///
/// Asynchronous so that future schemes involving token refresh (OAuth 2.0 3LO) fit here without
/// touching any calling code.
public protocol AuthProvider: Sendable {
    func authorize(_ request: inout HTTPRequest) async throws

    /// A non-secret fingerprint of which credentials this is.
    ///
    /// Used only to notice that the account changed between runs — e.g. to invalidate an
    /// on-disk cache built under a different identity (see `CacheIdentity`) — never to
    /// authenticate with, compare credentials for equality, or otherwise treat as anything
    /// more than "did this change". Two different secrets are expected to produce different
    /// fingerprints; the fingerprint itself must not make recovering the secret any easier
    /// than guessing it outright, which is why it goes through `FingerprintHash` rather than
    /// storing anything resembling the credential.
    var identityFingerprint: String { get }
}

/// Jira Cloud basic authentication: `email` plus an API token.
public struct BasicAuthProvider: AuthProvider {
    private let email: String
    private let apiToken: Secret

    public init(email: String, apiToken: Secret) {
        self.email = email
        self.apiToken = apiToken
    }

    public func authorize(_ request: inout HTTPRequest) async throws {
        let pair = "\(email):\(apiToken.reveal())"
        guard let encoded = pair.data(using: .utf8)?.base64EncodedString() else {
            throw SwiraError.configuration(missing: "encodable credentials", searched: [])
        }
        request.setHeader("Authorization", "Basic \(encoded)")
    }

    public var identityFingerprint: String {
        // The email alone would already distinguish most account switches, but folding in the
        // token catches the same email re-authenticated with a rotated token too.
        "basic:" + FingerprintHash.of("\(email)\u{0}\(apiToken.reveal())")
    }
}

/// The bearer scheme: a Jira Data Center personal access token, and later an OAuth access token.
public struct BearerAuthProvider: AuthProvider {
    private let token: Secret

    public init(token: Secret) {
        self.token = token
    }

    public func authorize(_ request: inout HTTPRequest) async throws {
        request.setHeader("Authorization", "Bearer \(token.reveal())")
    }

    public var identityFingerprint: String {
        "bearer:" + FingerprintHash.of(token.reveal())
    }
}

/// Adds nothing. For tests and for anonymous endpoints.
public struct NoAuthProvider: AuthProvider {
    public init() {}
    public func authorize(_ request: inout HTTPRequest) async throws {}
    public var identityFingerprint: String { "none" }
}
