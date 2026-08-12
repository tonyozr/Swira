import Foundation
import Logging

/// A cache that keeps one JSON file per entry under a directory.
///
/// Files rather than SQLite: the volumes involved are small, and a native database dependency
/// would be the one thing standing between this core and a clean build on Windows.
public actor FileSystemCacheStore: CacheStore {
    private let directory: URL
    private let logger: Logger
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var directoryPrepared = false

    public init(
        directory: URL = CacheLocation.default(),
        logger: Logger = Logger(label: "swira.cache")
    ) {
        self.directory = directory
        self.logger = logger
    }

    public func load(_ key: String) async -> CacheEntry? {
        let url = fileURL(for: key)
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        guard let entry = try? decoder.decode(CacheEntry.self, from: data) else {
            // A corrupt or outdated entry is not worth diagnosing: drop it and take the miss.
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        // Guard against the (unlikely) filename collision handing back someone else's response.
        guard entry.key == key else {
            return nil
        }
        return entry
    }

    public func store(_ entry: CacheEntry) async {
        do {
            try prepareDirectory()
            let data = try encoder.encode(entry)
            try data.write(to: fileURL(for: entry.key), options: .atomic)
        } catch {
            // A cache that cannot write is a slow cache, not a broken client — never propagate.
            logger.debug("Could not write cache entry", metadata: ["error": "\(error)"])
        }
    }

    public func remove(_ key: String) async {
        try? FileManager.default.removeItem(at: fileURL(for: key))
    }

    public func removeAll(withPrefix prefix: String) async {
        for url in entryFiles() {
            guard let data = try? Data(contentsOf: url),
                  let entry = try? decoder.decode(CacheEntry.self, from: data) else {
                continue
            }
            if entry.key.hasPrefix(prefix) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    public func clear() async {
        for url in entryFiles() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Layout

    private func entryFiles() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ))?.filter { $0.pathExtension == "json" } ?? []
    }

    private func prepareDirectory() throws {
        guard !directoryPrepared else { return }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        directoryPrepared = true
    }

    /// Maps a cache key to a filename that is readable, filesystem-safe, and short enough for
    /// Windows' path limits.
    ///
    /// The readable prefix is there so the cache directory can be inspected by eye; the hash
    /// suffix is what actually keeps entries distinct. Note this is FNV-1a, not a cryptographic
    /// hash — nothing here is a security boundary, and requiring swift-crypto (and BoringSSL)
    /// for a filename would be a poor trade on Windows.
    private func fileURL(for key: String) -> URL {
        let readable = key
            .map { character -> Character in
                character.isLetter || character.isNumber ? character : "-"
            }
            .prefix(80)
        return directory
            .appendingPathComponent("\(String(readable))-\(FingerprintHash.of(key)).json")
    }
}
