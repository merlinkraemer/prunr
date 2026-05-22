import Foundation
import os

/// Single source of truth for paths owned by Prunr's own operational state — DB file,
/// SQLite WAL/SHM/journal companions, and any future on-disk caches.
///
/// Every filter on the FSEvents and scan hot paths consults this helper, so the app
/// cannot account for or react to its own writes. The cache is lock-protected and
/// refreshed whenever the database path changes (initialize, close, switch).
enum PrunrInternalPaths {

    // MARK: - Cache

    private struct Cache {
        var directoryPaths: [String]
        var directoryURLs: [URL]
    }

    /// Eagerly initialized with the standard Application Support directory so that
    /// callers running before the DB connects still get safe filtering.
    private static let cacheLock: OSAllocatedUnfairLock<Cache> = {
        let standard = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Prunr", isDirectory: true)
            .standardizedFileURL
        return OSAllocatedUnfairLock(initialState: Cache(
            directoryPaths: [standard.path],
            directoryURLs: [standard]
        ))
    }()

    /// Re-evaluate Prunr-owned directories. Call after the DB initializes or moves.
    static func refreshCache() {
        let standardSupportDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Prunr", isDirectory: true)
            .standardizedFileURL

        var directories: [URL] = [standardSupportDir]

        if let dbPath = DatabaseManager.shared.databasePath {
            let dbDir = URL(fileURLWithPath: dbPath)
                .deletingLastPathComponent()
                .standardizedFileURL
            directories.append(dbDir)
        }

        let unique: [URL] = {
            var seen = Set<String>()
            var result: [URL] = []
            for url in directories where seen.insert(url.path).inserted {
                result.append(url)
            }
            return result
        }()

        let paths = unique.map(\.path)
        cacheLock.withLock {
            $0.directoryURLs = unique
            $0.directoryPaths = paths
        }
    }

    /// Snapshot of Prunr-owned directory URLs. Safe to call from any thread.
    static func directoryURLs() -> [URL] {
        cacheLock.withLock { $0.directoryURLs }
    }

    /// Returns true when `path` falls inside any Prunr-owned directory, or has a
    /// SQLite-companion suffix (-wal/-shm/-journal). Hot path: prefix checks only.
    static func isInternalPath(_ path: String) -> Bool {
        // SQLite write-ahead and shared-memory files appear next to the DB file
        // even when callers pass an alias to the parent directory. Filter by
        // suffix as a defense layer in case prefix matching misses an edge case.
        if path.hasSuffix("-wal") || path.hasSuffix("-shm") || path.hasSuffix("-journal") {
            // Only swallow these when they live inside a Prunr-owned directory —
            // unrelated apps may legitimately have similarly named files.
            let directories = cacheLock.withLock { $0.directoryPaths }
            for dir in directories where path.hasPrefix(dir + "/") {
                return true
            }
        }

        let directories = cacheLock.withLock { $0.directoryPaths }
        for dir in directories {
            if path == dir { return true }
            if path.hasPrefix(dir + "/") { return true }
        }
        return false
    }
}
