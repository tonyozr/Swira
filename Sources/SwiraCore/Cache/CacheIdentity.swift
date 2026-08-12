import Foundation

/// Keeps the on-disk cache from ever serving one account's data under another's identity.
///
/// The cache directory is keyed by request (method, path, query) only, not by which Jira site
/// or account produced the response — switching credentials without this reconciliation would
/// let a stale response fetched under one account keep answering requests made under a
/// different one, for as long as its TTL allows.
enum CacheIdentity {
    private static let markerFilename = ".identity"

    /// A fingerprint identifying "this site, this API version, these credentials" — everything
    /// that determines what a cached response means. Built from public data plus each
    /// `AuthProvider`'s own non-secret fingerprint (see `AuthProvider.identityFingerprint`).
    static func fingerprint(site: JiraSite, auth: AuthProvider) -> String {
        "\(site.baseURL.absoluteString)|\(site.apiVersion)|\(auth.identityFingerprint)"
    }

    /// Ensures `directory` only ever holds cache entries for `fingerprint`.
    ///
    /// If the directory's recorded identity matches, entries are left untouched. Otherwise —
    /// including the very first run, when there is no record to compare against — every entry
    /// is wiped before the new identity is recorded. Treating "unknown" the same as "different"
    /// is deliberate: a cache directory left over from before this mechanism existed carries no
    /// proof of whose data it holds, and the cost of an unnecessary refetch is far cheaper than
    /// the cost of leaking one account's filters into another's session.
    ///
    /// Synchronous, plain file I/O: this runs once at startup, not on the request path, so it
    /// does not need `FileSystemCacheStore`'s actor.
    static func reconcile(directory: URL, fingerprint: String) {
        let marker = directory.appendingPathComponent(markerFilename)
        let recorded = try? String(contentsOf: marker, encoding: .utf8)

        guard recorded != fingerprint else { return }

        if let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) {
            for entry in entries {
                try? FileManager.default.removeItem(at: entry)
            }
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fingerprint.write(to: marker, atomically: true, encoding: .utf8)
    }
}
