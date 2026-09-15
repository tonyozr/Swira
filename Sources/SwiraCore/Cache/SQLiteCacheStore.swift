import Foundation
import Logging
import SwiftToolchainCSQLite

/// A cache backed by a single SQLite database file, as an alternative to `FileSystemCacheStore`.
///
/// Uses `swift-toolchain-sqlite`, not GRDB or SQLite.swift: those link a `.systemLibrary` — on
/// macOS/Linux that's free (already in the OS, or one `apt`/`brew` install away), but Windows has
/// no OS-provided SQLite, so it would mean a separate install (typically vcpkg) plus wiring
/// SwiftPM's system-library target to find `sqlite3.h`/`.lib` — exactly the kind of step beyond
/// `swift build` this core has otherwise avoided (see `FileSystemCacheStore`'s own doc comment).
/// `swift-toolchain-sqlite` instead vendors the SQLite amalgamation as plain C source compiled
/// straight into the package, so it needs nothing installed on any platform, Windows included —
/// confirmed by building it here. The trade is a raw C API rather than an ORM's ergonomics, which
/// is a fine trade for what this store actually does: single-table key→blob lookups with prefix
/// invalidation, not relational queries.
///
/// One SQLite connection, opened lazily and kept for the actor's lifetime; the actor already
/// serializes every call, so nothing here needs SQLite's own thread-safety modes.
public actor SQLiteCacheStore: CacheStore {
    private let path: String
    private let logger: Logger
    private var db: OpaquePointer?

    public init(
        directory: URL = CacheLocation.default(),
        logger: Logger = Logger(label: "swira.cache")
    ) {
        self.path = directory.appendingPathComponent("cache.sqlite").path
        self.logger = logger
    }

    public func load(_ key: String) async -> CacheEntry? {
        guard let db = openIfNeeded() else { return nil }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db, "SELECT data, etag, storedAt, expired FROM cache_entries WHERE key = ?", -1, &statement, nil
        ) == SQLITE_OK else {
            logSQLiteError("preparing a read")
            return nil
        }
        bindText(statement, 1, key)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }

        let data = columnBlob(statement, 0)
        let etag = columnText(statement, 1)
        let storedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
        let expired = sqlite3_column_int(statement, 3) != 0
        return CacheEntry(key: key, data: data, etag: etag, storedAt: storedAt, expired: expired)
    }

    public func store(_ entry: CacheEntry) async {
        guard let db = openIfNeeded() else { return }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            """
            INSERT INTO cache_entries (key, data, etag, storedAt, expired) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET data = excluded.data, etag = excluded.etag,
                storedAt = excluded.storedAt, expired = excluded.expired
            """,
            -1, &statement, nil
        ) == SQLITE_OK else {
            logSQLiteError("preparing a write")
            return
        }
        bindText(statement, 1, entry.key)
        bindBlob(statement, 2, entry.data)
        if let etag = entry.etag {
            bindText(statement, 3, etag)
        } else {
            sqlite3_bind_null(statement, 3)
        }
        sqlite3_bind_double(statement, 4, entry.storedAt.timeIntervalSince1970)
        sqlite3_bind_int(statement, 5, entry.expired ? 1 : 0)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            // A cache that cannot write is a slow cache, not a broken client — never propagate.
            logSQLiteError("writing a cache entry")
            return
        }
    }

    public func remove(_ key: String) async {
        guard let db = openIfNeeded() else { return }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "DELETE FROM cache_entries WHERE key = ?", -1, &statement, nil)
            == SQLITE_OK else {
            logSQLiteError("preparing a delete")
            return
        }
        bindText(statement, 1, key)
        sqlite3_step(statement)
    }

    /// Drops every entry whose key starts with `prefix`.
    ///
    /// `LIKE` with the prefix as a pattern would need escaping `%`/`_` inside a real key first —
    /// simpler and just as cheap at this table's size (see the type doc comment) to read every
    /// key and filter in Swift, the same approach `FileSystemCacheStore.removeAll` takes over its
    /// files.
    public func removeAll(withPrefix prefix: String) async {
        guard let db = openIfNeeded() else { return }
        let matching = allKeys(db).filter { $0.hasPrefix(prefix) }
        guard !matching.isEmpty else { return }

        sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "DELETE FROM cache_entries WHERE key = ?", -1, &statement, nil)
            == SQLITE_OK else {
            logSQLiteError("preparing a prefix delete")
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            return
        }
        for key in matching {
            sqlite3_reset(statement)
            bindText(statement, 1, key)
            sqlite3_step(statement)
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    public func clear() async {
        guard let db = openIfNeeded() else { return }
        sqlite3_exec(db, "DELETE FROM cache_entries", nil, nil, nil)
    }

    /// Sets `expired`, leaving `storedAt` alone — see the doc comment on `CacheStore.expireAll`
    /// and on `CacheEntry.expired` for why not just backdating `storedAt` matters.
    public func expireAll(withPrefix prefix: String) async {
        guard let db = openIfNeeded() else { return }
        guard !prefix.isEmpty else {
            sqlite3_exec(db, "UPDATE cache_entries SET expired = 1", nil, nil, nil)
            return
        }
        let matching = allKeys(db).filter { $0.hasPrefix(prefix) }
        guard !matching.isEmpty else { return }

        sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db, "UPDATE cache_entries SET expired = 1 WHERE key = ?", -1, &statement, nil
        ) == SQLITE_OK else {
            logSQLiteError("preparing a prefix expire")
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            return
        }
        for key in matching {
            sqlite3_reset(statement)
            bindText(statement, 1, key)
            sqlite3_step(statement)
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    // MARK: - Connection

    private func openIfNeeded() -> OpaquePointer? {
        if let db { return db }

        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            logger.debug("Could not open the SQLite cache", metadata: ["path": "\(path)"])
            if let handle { sqlite3_close(handle) }
            return nil
        }
        // WAL: readers (a background `staleWhileRevalidate` refresh alongside an ordinary read)
        // don't block each other. `busy_timeout` absorbs the brief contention that's left instead
        // of failing a call outright with `SQLITE_BUSY`.
        sqlite3_exec(handle, "PRAGMA journal_mode = WAL", nil, nil, nil)
        sqlite3_busy_timeout(handle, 2000)
        guard sqlite3_exec(
            handle,
            """
            CREATE TABLE IF NOT EXISTS cache_entries (
                key TEXT PRIMARY KEY,
                data BLOB NOT NULL,
                etag TEXT,
                storedAt REAL NOT NULL,
                expired INTEGER NOT NULL DEFAULT 0
            )
            """,
            nil, nil, nil
        ) == SQLITE_OK else {
            logger.debug("Could not prepare the SQLite cache schema", metadata: ["path": "\(path)"])
            sqlite3_close(handle)
            return nil
        }
        // Migration for a database created before `expired` existed: `CREATE TABLE IF NOT
        // EXISTS` above is a no-op against an already-existing table, so a pre-existing one needs
        // the column added explicitly. Errors (column already there) are expected and ignored —
        // there's no cheap "does this column exist" check worth doing first.
        sqlite3_exec(handle, "ALTER TABLE cache_entries ADD COLUMN expired INTEGER NOT NULL DEFAULT 0", nil, nil, nil)
        db = handle
        return handle
    }

    private func allKeys(_ db: OpaquePointer) -> [String] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT key FROM cache_entries", -1, &statement, nil) == SQLITE_OK
        else {
            return []
        }
        var keys: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let key = columnText(statement, 0) {
                keys.append(key)
            }
        }
        return keys
    }

    // MARK: - Binding / reading helpers

    /// `SQLITE_TRANSIENT`: not imported as a usable value (it's a C macro casting `-1` to a
    /// destructor function pointer), so SQLite is told to copy the bytes itself rather than trust
    /// them to outlive the call — the alternative, `SQLITE_STATIC`, would be a use-after-free the
    /// moment the `String`/`Data` argument is deallocated.
    private static let sqliteTransient = unsafeBitCast(
        -1, to: (@convention(c) (UnsafeMutableRawPointer?) -> Void).self
    )

    private func bindText(_ statement: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, -1, Self.sqliteTransient)
    }

    private func bindBlob(_ statement: OpaquePointer?, _ index: Int32, _ value: Data) {
        let result: Int32 = value.withUnsafeBytes { buffer in
            if let base = buffer.baseAddress, buffer.count > 0 {
                return sqlite3_bind_blob(statement, index, base, Int32(buffer.count), Self.sqliteTransient)
            }
            // An empty blob: passing a null pointer with length 0 is what SQLite documents for
            // this case — the alternative crashes on some builds when count is 0.
            return sqlite3_bind_zeroblob(statement, index, 0)
        }
        if result != SQLITE_OK {
            logSQLiteError("binding a blob")
        }
    }

    private func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    private func columnBlob(_ statement: OpaquePointer?, _ index: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    private func logSQLiteError(_ context: String) {
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "no connection"
        logger.debug("SQLite cache error \(context)", metadata: ["message": "\(message)"])
    }
}
