import Foundation

actor RecentChangeService {
    static let shared = RecentChangeService()

    private let scanner = FileScanner()
    private let db = DatabaseManager.shared
    private let growthJournalService = GrowthJournalService.shared
    private let maxRootsPerBatch = 24

    private init() {}

    enum RefreshResult: Sendable {
        case noChanges
        case updated
        case needsFullScan
    }

    func refreshChangedPaths(
        _ changedPaths: Set<URL>,
        trackedPath: TrackedPath
    ) async -> RefreshResult {
        let roots = coalescedRoots(from: changedPaths, trackedPath: trackedPath)
        guard !roots.isEmpty else { return .noChanges }

        let trackedRoot = trackedPath.url.standardizedFileURL.path
        if roots.contains(where: { $0.path == trackedRoot }) || roots.count > maxRootsPerBatch {
            print("[RecentChangeService] Too many roots (\(roots.count)) or tracked root changed — needs full scan")
            return .needsFullScan
        }

        let ignoredNames = await MainActor.run { SettingsStore.shared.allScanIgnoreNames }
        let scanTimestamp = Date()
        var mergedDeltas: [DatabaseManager.JournalDeltaKey: Int64] = [:]

        for root in roots {
            let scanResults = await scanResults(for: root, ignoredNames: ignoredNames)

            do {
                let deltas = try await db.replaceWorkingSetSubtree(
                    trackedPathId: trackedPath.id,
                    rootPath: root.path,
                    entries: scanResults,
                    updatedAt: scanTimestamp
                )
                for (key, delta) in deltas where delta != 0 {
                    mergedDeltas[key, default: 0] += delta
                }
            } catch {
                print("[RecentChangeService] Failed refreshing subtree \(root.path): \(error)")
            }
        }

        guard !mergedDeltas.isEmpty else { return .noChanges }

        do {
            try await growthJournalService.recordDeltas(
                trackedPath: trackedPath,
                deltas: mergedDeltas,
                at: scanTimestamp
            )
            return .updated
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
        let stream = await scanner.scan(root, ignoredNames: ignoredNames)
        do {
            for try await result in stream {
                results.append(result)
            }
        } catch {
            print("[RecentChangeService] Subtree scan failed for \(root.path): \(error)")
        }

        return results
    }

    private func coalescedRoots(from changedPaths: Set<URL>, trackedPath: TrackedPath) -> [URL] {
        let trackedRoot = trackedPath.url.standardizedFileURL
        let fileManager = FileManager.default
        var candidates: [URL] = []

        func nearestExistingAncestor(for url: URL) -> URL {
            var candidate = url.standardizedFileURL

            while candidate.path != trackedRoot.deletingLastPathComponent().path {
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory) {
                    return isDirectory.boolValue
                        ? candidate
                        : candidate.deletingLastPathComponent().standardizedFileURL
                }

                let parent = candidate.deletingLastPathComponent().standardizedFileURL
                if parent.path == candidate.path {
                    break
                }
                candidate = parent
            }

            return trackedRoot
        }

        for url in changedPaths {
            let standardized = url.standardizedFileURL
            guard standardized.path.hasPrefix(trackedRoot.path) else { continue }

            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: standardized.path, isDirectory: &isDirectory)

            let candidate: URL
            if exists, !isDirectory.boolValue {
                candidate = standardized.deletingLastPathComponent().standardizedFileURL
            } else if exists {
                candidate = standardized
            } else {
                candidate = nearestExistingAncestor(for: standardized)
            }

            guard candidate.path.hasPrefix(trackedRoot.path) else { continue }
            candidates.append(candidate)
        }

        let unique = Array(Set(candidates.map(\.path))).sorted { $0.count < $1.count }
        var roots: [URL] = []

        for path in unique {
            if roots.contains(where: { path == $0.path || path.hasPrefix($0.path + "/") }) {
                continue
            }
            roots.append(URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL)
        }

        return roots
    }
}
