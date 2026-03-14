import Foundation

actor RecentChangeService {
    static let shared = RecentChangeService()

    private let scanner = FileScanner()
    private let db = DatabaseManager.shared
    private let growthJournalService = GrowthJournalService.shared

    private init() {}

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
            guard !snapshots.isEmpty else {
                return .noChanges
            }
        } catch {
            print("[RecentChangeService] Failed checking baseline state: \(error)")
            return .noChanges
        }

        let targets = refreshTargets(from: changedPaths, trackedPath: trackedPath)
        guard !targets.isEmpty else { return .noChanges }

        let ignoredNames = await MainActor.run { SettingsStore.shared.allScanIgnoreNames }
        let scanTimestamp = Date()
        var mergedDeltas: [DatabaseManager.JournalDeltaKey: Int64] = [:]

        for target in targets {
            let entries: [ScanResult]
            switch target {
            case .file(let result):
                entries = [result]
            case .subtree(let root):
                entries = await scanResults(for: root, ignoredNames: ignoredNames)
            case .removal:
                entries = []
            }

            do {
                let deltas = try await db.replaceWorkingSetSubtree(
                    trackedPathId: trackedPath.id,
                    rootPath: target.rootPath,
                    entries: entries,
                    updatedAt: scanTimestamp
                )
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

    private func scanResults(for root: URL, ignoredNames: Set<String>) async -> [ScanResult] {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory)
        guard exists else { return [] }

        if !isDirectory.boolValue {
            return []
        }

        var results: [ScanResult] = []
        let stream = scanner.scan(root, ignoredNames: ignoredNames)
        do {
            for try await result in stream {
                results.append(result)
            }
        } catch {
            print("[RecentChangeService] Subtree scan failed for \(root.path): \(error)")
        }

        return results
    }

    /// Maximum number of individual refresh targets before coalescing to a single tracked-root rescan.
    /// Prevents unbounded incremental work from bulk operations (e.g., unpacking archives, npm install).
    private static let maxRefreshTargets = 500

    private func refreshTargets(from changedPaths: Set<URL>, trackedPath: TrackedPath) -> [RefreshTarget] {
        let trackedRoot = trackedPath.url.standardizedFileURL
        let fileManager = FileManager.default
        var filesByPath: [String: ScanResult] = [:]
        var subtreeRoots = Set<String>()
        var removals = Set<String>()

        for url in changedPaths {
            let standardized = url.standardizedFileURL
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

        // If too many targets, coalesce to a single tracked-root rescan to avoid saturating I/O
        if targets.count > Self.maxRefreshTargets {
            print("[RecentChangeService] \(targets.count) targets exceed cap (\(Self.maxRefreshTargets)) — coalescing to tracked root rescan")
            return [.subtree(trackedRoot)]
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
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let sizeBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let path = url.path
            return ScanResult(
                path: path,
                sizeBytes: sizeBytes,
                category: GrowthCategory.categorize(path: path),
                subcategory: GrowthCategory.subcategorize(path: path)
            )
        } catch {
            print("[RecentChangeService] Failed reading file size for \(url.path): \(error)")
            return nil
        }
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
