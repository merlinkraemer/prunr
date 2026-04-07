import Foundation
import Darwin

actor RecentChangeService {
    static let shared = RecentChangeService()

    private let scanner = FileScanner()
    private let db = DatabaseManager.shared
    private let growthJournalService = GrowthJournalService.shared

    private init() {}

    /// App-internal locations that must never feed incremental growth deltas.
    private let internalPathFragments: [String] = [
        "/Library/Application Support/Prunr/",
        "/.build/derivedData/"
    ]
    private static let stagingBatchSize = 1000

    enum RefreshResult: Sendable {
        case noChanges
        case updated(deltas: [DatabaseManager.JournalDeltaKey: Int64])
        case needsFullScan
    }

    private enum RefreshTarget {
        case file(ScanResult)
        case subtree(URL)
        case removal(String)

        var rootPath: String {
            switch self {
            case .file(let result):
                result.path
            case .subtree(let url):
                url.path
            case .removal(let path):
                path
            }
        }
    }

    func refreshChangedPaths(
        _ changedPaths: Set<URL>,
        trackedPath: TrackedPath
    ) async -> RefreshResult {
        do {
            let snapshots = try await db.fetchRecentSnapshots(trackedPathId: trackedPath.id, limit: 1)
            guard !snapshots.isEmpty else { return .noChanges }
        } catch {
            print("[RecentChangeService] Failed checking snapshot history: \(error)")
            return .noChanges
        }

        // If there are an insane number of events (e.g. 50k+ from a git checkout or npm install),
        // trying to coalesce them with lstat calls will take too long. Fall back to a full scan.
        if changedPaths.count > 25_000 {
            return .needsFullScan
        }

        let targets = refreshTargets(from: changedPaths, trackedPath: trackedPath)
        guard !targets.isEmpty else { return .noChanges }

        if targets.count > Self.maxRefreshTargets {
            return .needsFullScan
        }

        if targets.contains(where: {
            if case .subtree(let url) = $0 {
                return url.standardizedFileURL == trackedPath.url.standardizedFileURL
            }
            return false
        }) {
            return .needsFullScan
        }

        let ignoredNames = await MainActor.run { SettingsStore.shared.allScanIgnoreNames }
        let scanTimestamp = Date()
        var mergedDeltas: [DatabaseManager.JournalDeltaKey: Int64] = [:]

        for target in targets {
            do {
                let deltas: [DatabaseManager.JournalDeltaKey: Int64]
                switch target {
                case .file(let result):
                    deltas = try await db.replaceWorkingSetSubtree(
                        trackedPathId: trackedPath.id,
                        rootPath: target.rootPath,
                        entries: [result],
                        updatedAt: scanTimestamp
                    )
                case .subtree(let root):
                    deltas = try await applySubtreeRefresh(
                        for: root,
                        trackedPath: trackedPath,
                        ignoredNames: ignoredNames,
                        updatedAt: scanTimestamp
                    )
                case .removal:
                    deltas = try await db.replaceWorkingSetSubtree(
                        trackedPathId: trackedPath.id,
                        rootPath: target.rootPath,
                        entries: [],
                        updatedAt: scanTimestamp
                    )
                }
                for (key, delta) in deltas where delta != 0 {
                    mergedDeltas[key, default: 0] += delta
                }
            } catch {
                print("[RecentChangeService] Failed refreshing target \(target.rootPath): \(error)")
            }
        }

        guard !mergedDeltas.isEmpty else { return .noChanges }

        do {
            try await growthJournalService.recordDeltas(
                trackedPath: trackedPath,
                deltas: mergedDeltas,
                at: scanTimestamp
            )
            return .updated(deltas: mergedDeltas)
        } catch {
            print("[RecentChangeService] Failed recording journal deltas: \(error)")
            return .noChanges
        }
    }

    private func applySubtreeRefresh(
        for root: URL,
        trackedPath: TrackedPath,
        ignoredNames: Set<String>,
        updatedAt: Date
    ) async throws -> [DatabaseManager.JournalDeltaKey: Int64] {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory)
        guard exists, isDirectory.boolValue else {
            return try await db.replaceWorkingSetSubtree(
                trackedPathId: trackedPath.id,
                rootPath: root.path,
                entries: [],
                updatedAt: updatedAt
            )
        }

        let stagingSessionId = UUID().uuidString
        try await db.clearWorkingSetRefreshStaging(sessionId: stagingSessionId)

        do {
            var batch: [ScanResult] = []
            batch.reserveCapacity(Self.stagingBatchSize)

            let stream = scanner.scan(root, ignoredNames: ignoredNames)
            for try await result in stream {
                batch.append(result)
                if batch.count >= Self.stagingBatchSize {
                    try await db.appendWorkingSetRefreshStaging(
                        sessionId: stagingSessionId,
                        entries: batch
                    )
                    batch.removeAll(keepingCapacity: true)
                }
            }

            if !batch.isEmpty {
                try await db.appendWorkingSetRefreshStaging(
                    sessionId: stagingSessionId,
                    entries: batch
                )
            }

            return try await db.replaceWorkingSetSubtree(
                trackedPathId: trackedPath.id,
                rootPath: root.path,
                stagingSessionId: stagingSessionId,
                updatedAt: updatedAt
            )
        } catch {
            try? await db.clearWorkingSetRefreshStaging(sessionId: stagingSessionId)
            throw error
        }
    }

    /// Maximum number of individual refresh targets before coalescing to a single tracked-root rescan.
    /// Prevents unbounded incremental work from bulk operations (e.g., unpacking archives, npm install).
    private static let maxRefreshTargets = 192

    private func refreshTargets(from changedPaths: Set<URL>, trackedPath: TrackedPath) -> [RefreshTarget] {
        let trackedRoot = trackedPath.url.standardizedFileURL
        let fileManager = FileManager.default
        var filesByPath: [String: ScanResult] = [:]
        var subtreeRoots = Set<String>()
        var removals = Set<String>()

        for url in changedPaths {
            let standardized = url.standardizedFileURL
            if shouldIgnoreInternalPath(standardized.path) {
                continue
            }
            guard isWithinTrackedRoot(standardized.path, trackedRoot: trackedRoot.path) else { continue }

            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: standardized.path, isDirectory: &isDirectory)

            if exists, !isDirectory.boolValue {
                if let fileResult = scanResult(forFileAt: standardized) {
                    filesByPath[fileResult.path] = fileResult
                }
            } else if exists {
                subtreeRoots.insert(standardized.path)
            } else {
                removals.insert(standardized.path)
            }
        }

        let subtreeRootsWithDescendantsRemoved = subtreeRoots.filter { rootPath in
            !hasMoreSpecificChange(under: rootPath, subtreeRoots: subtreeRoots, filePaths: Set(filesByPath.keys), removals: removals)
        }
        let coalescedSubtreeRoots = coalescedPaths(subtreeRootsWithDescendantsRemoved)
        let coalescedRemovals = coalescedPaths(removals).filter { removalPath in
            !coalescedSubtreeRoots.contains(where: { isDescendantOrSame(removalPath, ancestorPath: $0) })
        }
        let filteredFiles = filesByPath.values.filter { result in
            !coalescedSubtreeRoots.contains(where: { isDescendantOrSame(result.path, ancestorPath: $0) })
                && !coalescedRemovals.contains(where: { isDescendantOrSame(result.path, ancestorPath: $0) })
        }

        let targets = coalescedSubtreeRoots.map {
            RefreshTarget.subtree(URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL)
        } + coalescedRemovals.map {
            RefreshTarget.removal($0)
        } + filteredFiles.sorted {
            $0.path < $1.path
        }.map {
            RefreshTarget.file($0)
        }

        return targets
    }

    private func hasMoreSpecificChange(
        under rootPath: String,
        subtreeRoots: Set<String>,
        filePaths: Set<String>,
        removals: Set<String>
    ) -> Bool {
        let hasDescendantSubtree = subtreeRoots.contains { candidate in
            candidate != rootPath && isDescendantOrSame(candidate, ancestorPath: rootPath)
        }
        if hasDescendantSubtree {
            return true
        }

        let hasDescendantFile = filePaths.contains { candidate in
            candidate != rootPath && isDescendantOrSame(candidate, ancestorPath: rootPath)
        }
        if hasDescendantFile {
            return true
        }

        return removals.contains { candidate in
            candidate != rootPath && isDescendantOrSame(candidate, ancestorPath: rootPath)
        }
    }

    private func scanResult(forFileAt url: URL) -> ScanResult? {
        if shouldIgnoreInternalPath(url.standardizedFileURL.path) {
            return nil
        }
        var fileStat = stat()
        guard lstat(url.path, &fileStat) == 0 else { return nil }
        let sizeBytes = FileScanner.diskUsageBytes(for: fileStat)
        let path = url.path
        let (category, subcategory) = GrowthCategory.classify(path: path)
        return ScanResult(
            path: path,
            sizeBytes: sizeBytes,
            category: category,
            subcategory: subcategory
        )
    }

    private func shouldIgnoreInternalPath(_ path: String) -> Bool {
        for fragment in internalPathFragments where path.contains(fragment) {
            return true
        }
        return false
    }

    private func coalescedPaths(_ paths: Set<String>) -> [String] {
        let unique = Array(paths).sorted { lhs, rhs in
            if lhs.count == rhs.count {
                return lhs < rhs
            }
            return lhs.count < rhs.count
        }

        var roots: [String] = []
        for path in unique {
            if roots.contains(where: { isDescendantOrSame(path, ancestorPath: $0) }) {
                continue
            }
            roots.append(path)
        }
        return roots
    }

    private func isWithinTrackedRoot(_ path: String, trackedRoot: String) -> Bool {
        path == trackedRoot || path.hasPrefix(trackedRoot + "/")
    }

    private func isDescendantOrSame(_ path: String, ancestorPath: String) -> Bool {
        path == ancestorPath || path.hasPrefix(ancestorPath + "/")
    }

}
