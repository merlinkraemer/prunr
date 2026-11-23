import Foundation
import Darwin
import OSLog

actor RecentChangeService {
    static let shared = RecentChangeService()

    private let scanner = FileScanner()
    private let db = DatabaseManager.shared
    private let logger = Logger(subsystem: "com.prunr.app", category: "RecentChanges")

    private init() {}

    private static let stagingBatchSize = 1000

    enum RefreshResult: Sendable {
        case noChanges
        case updated(deltas: [DatabaseManager.JournalDeltaKey: Int64])
        case needsFullScan
    }

    enum PathState: Equatable {
        case file
        case directory
        case gone
        case unreadable
    }

    static func pathState(at path: String) -> PathState {
        var pathStat = stat()
        guard lstat(path, &pathStat) == 0 else {
            return errno == ENOENT || errno == ENOTDIR ? .gone : .unreadable
        }
        return (pathStat.st_mode & S_IFMT) == S_IFDIR ? .directory : .file
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
            logger.error("Failed checking snapshot history: \(error.localizedDescription, privacy: .public)")
            return .noChanges
        }

        if changedPaths.count > 25_000 {
            return .needsFullScan
        }

        let ignoredNames = ScanSkipRules.normalizedIgnoredNames(
            await MainActor.run { SettingsStore.shared.allScanIgnoreNames }
        )
        let targets = refreshTargets(from: changedPaths, trackedPath: trackedPath, ignoredNames: ignoredNames)
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

        let scanTimestamp = Date()
        var mergedDeltas: [DatabaseManager.JournalDeltaKey: Int64] = [:]

        var pointChanges: [DatabaseManager.WorkingSetPointChange] = []

        for target in targets {
            switch target {
            case .file(let result):
                let counted: ScanResult
                do {
                    counted = try await applyingHardLinkRule(to: [result], trackedPathId: trackedPath.id)[0]
                } catch {
                    logger.error("Failed reading link state for \(result.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    continue
                }
                pointChanges.append(.file(counted))
            case .removal(let path):
                pointChanges.append(.removal(path))
            case .subtree(let root):
                do {
                    let deltas = try await applySubtreeRefresh(
                        for: root,
                        trackedPath: trackedPath,
                        ignoredNames: ignoredNames,
                        updatedAt: scanTimestamp
                    )
                    for (key, delta) in deltas where delta != 0 {
                        mergedDeltas[key, default: 0] += delta
                    }
                } catch {
                    logger.error("Failed refreshing target \(root.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        guard !pointChanges.isEmpty || !mergedDeltas.isEmpty else { return .noChanges }

        do {
            let result = try await db.applyWorkingSetPointChanges(
                trackedPathId: trackedPath.id,
                changes: pointChanges,
                extraDeltas: mergedDeltas,
                journalBucketStart: GrowthJournalService.bucketStart(for: scanTimestamp),
                updatedAt: scanTimestamp
            )
            for failure in result.failures {
                logger.error("Failed refreshing target \(failure.rootPath, privacy: .public): \(failure.message, privacy: .public)")
            }
            guard !result.deltas.isEmpty else { return .noChanges }
            return .updated(deltas: result.deltas)
        } catch {
            logger.error("Failed applying refresh batch: \(error.localizedDescription, privacy: .public)")
            return .noChanges
        }
    }

    private func applySubtreeRefresh(
        for root: URL,
        trackedPath: TrackedPath,
        ignoredNames: Set<String>,
        updatedAt: Date
    ) async throws -> [DatabaseManager.JournalDeltaKey: Int64] {
        switch Self.pathState(at: root.path) {
        case .unreadable:
            return [:]
        case .directory:
            break
        case .file, .gone:
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

            let skipLog = ScanSkipLog()
            let stream = scanner.scan(root, ignoredNames: ignoredNames, skipLog: skipLog, priority: .background)
            for try await result in stream {
                batch.append(result)
                if batch.count >= Self.stagingBatchSize {
                    try await db.appendWorkingSetRefreshStaging(
                        sessionId: stagingSessionId,
                        entries: try await applyingHardLinkRule(to: batch, trackedPathId: trackedPath.id)
                    )
                    batch.removeAll(keepingCapacity: true)
                }
            }

            if !batch.isEmpty {
                try await db.appendWorkingSetRefreshStaging(
                    sessionId: stagingSessionId,
                    entries: try await applyingHardLinkRule(to: batch, trackedPathId: trackedPath.id)
                )
            }

            try await carryDeniedRowsForward(
                deniedPaths: skipLog.skippedPaths,
                trackedPathId: trackedPath.id,
                stagingSessionId: stagingSessionId
            )

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

    private func applyingHardLinkRule(to results: [ScanResult], trackedPathId: UUID) async throws -> [ScanResult] {
        let linkedPaths = results.filter { $0.linkedDiskBytes != nil }.map(\.path)
        guard !linkedPaths.isEmpty else { return results }

        let existingSizes = try await db.fetchWorkingSetSizes(trackedPathId: trackedPathId, paths: linkedPaths)
        return results.map { result in
            guard let linkedDiskBytes = result.linkedDiskBytes else { return result }
            var counted = result
            counted.sizeBytes = FileScanner.linkedFileBytes(
                linkedDiskBytes: linkedDiskBytes,
                existingBytes: existingSizes[DatabaseManager.normalizePath(result.path)]
            )
            return counted
        }
    }

    private func carryDeniedRowsForward(
        deniedPaths: [String],
        trackedPathId: UUID,
        stagingSessionId: String
    ) async throws {
        for deniedRoot in ScanService.outermostPaths(deniedPaths) {
            var afterPath: String?
            while true {
                let page = try await db.fetchWorkingSetEntries(
                    trackedPathId: trackedPathId,
                    atOrBelow: deniedRoot,
                    afterPath: afterPath,
                    limit: Self.stagingBatchSize
                )
                try await db.appendWorkingSetRefreshStaging(sessionId: stagingSessionId, entries: page)
                guard page.count == Self.stagingBatchSize, let last = page.last else { break }
                afterPath = last.path
            }
        }
    }

    private static let maxRefreshTargets = 192

    private func refreshTargets(
        from changedPaths: Set<URL>,
        trackedPath: TrackedPath,
        ignoredNames: Set<String>
    ) -> [RefreshTarget] {
        let trackedRoot = trackedPath.url.standardizedFileURL
        var filesByPath: [String: ScanResult] = [:]
        var subtreeRoots = Set<String>()
        var removals = Set<String>()

        for url in changedPaths {
            let standardized = url.standardizedFileURL
            guard isWithinTrackedRoot(standardized.path, trackedRoot: trackedRoot.path) else { continue }

            let state = Self.pathState(at: standardized.path)
            if state == .unreadable { continue }

            if ScanSkipRules.shouldSkip(
                path: standardized.path,
                isDirectory: state == .directory,
                belowRoot: trackedRoot.path,
                ignoredNames: ignoredNames
            ) {
                continue
            }

            switch state {
            case .file:
                if let fileResult = scanResult(forFileAt: standardized) {
                    filesByPath[fileResult.path] = fileResult
                }
            case .directory:
                subtreeRoots.insert(standardized.path)
            case .gone:
                removals.insert(standardized.path)
            case .unreadable:
                break
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
        var fileStat = stat()
        guard lstat(url.path, &fileStat) == 0 else { return nil }
        let sizeBytes = FileScanner.diskUsageBytes(for: fileStat)
        let path = url.path
        let (category, subcategory) = GrowthCategory.classify(path: path)
        return ScanResult(
            path: path,
            sizeBytes: sizeBytes,
            category: category,
            subcategory: subcategory,
            linkedDiskBytes: fileStat.st_nlink > 1 ? sizeBytes : nil
        )
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
