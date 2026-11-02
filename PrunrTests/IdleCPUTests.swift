import XCTest
import Darwin
@testable import Prunr

@MainActor
final class IdleCPUTests: PrunrTestCase {
    private static let idleWindowSeconds: TimeInterval = 30
    private static let sampleIntervalSeconds: TimeInterval = 5
    private static let maximumAverageCPUPercent = 5.0

    func testIdleManagerWithBaselineStaysNearZeroCPU() async throws {
        let trackedRoot = try createTrackedPathDirectory(named: "PrunrIdleCPU")
        defer { try? FileManager.default.removeItem(at: trackedRoot) }

        try await withEmptyTemporaryDatabase { _ in
            try await self.withMainPathOnly(trackedRoot) {
                let trackedPath = SettingsStore.shared.mainTrackedPath
                let snapshot = try await DatabaseManager.shared.createSnapshot(trackedPathId: trackedPath.id)
                let snapshotId = try XCTUnwrap(snapshot.id)
                try await DatabaseManager.shared.addEntries(
                    to: snapshotId,
                    entries: [
                        ScanResult(path: trackedRoot.appendingPathComponent("existing.bin").path, sizeBytes: 1_000_000)
                    ]
                )
                try await DatabaseManager.shared.rebuildWorkingSet(
                    from: snapshotId,
                    trackedPathId: trackedPath.id,
                    updatedAt: snapshot.createdAt
                )

                let manager = MenuBarManager()
                await manager.checkBaseline()
                try await Task.sleep(for: .seconds(3))

                var samples: [Double] = []
                let windowStart = Date()
                var lastCPUSeconds = Self.processCPUSeconds()
                var lastWall = windowStart
                while Date().timeIntervalSince(windowStart) < Self.idleWindowSeconds {
                    try await Task.sleep(for: .seconds(Self.sampleIntervalSeconds))
                    let cpu = Self.processCPUSeconds()
                    let now = Date()
                    samples.append((cpu - lastCPUSeconds) / now.timeIntervalSince(lastWall) * 100)
                    lastCPUSeconds = cpu
                    lastWall = now
                }

                let average = samples.reduce(0, +) / Double(samples.count)
                let line = "IDLE-CPU window=\(Int(Self.idleWindowSeconds))s samples=\(samples.map { String(format: "%.2f", $0) }) avg=\(String(format: "%.2f", average))% rss=\(ProcessCPU.residentMemoryBytes() / 1_048_576)MB"
                print(line)
                XCTAssertLessThan(average, Self.maximumAverageCPUPercent, line)
                XCTAssertEqual(manager.consecutiveFailedFullScans, 0)
            }
        }
    }

    private func withMainPathOnly(_ root: URL, _ body: () async throws -> Void) async throws {
        let settings = SettingsStore.shared
        let originalMainBasePath = settings.mainBasePath
        let originalEnabledPathIDs = Set(settings.allTrackedPaths.filter { settings.isPathEnabled($0) }.map(\.id))
        defer {
            settings.setMainBasePath(URL(fileURLWithPath: originalMainBasePath, isDirectory: true))
            for path in settings.allTrackedPaths {
                settings.setPathEnabled(path, enabled: originalEnabledPathIDs.contains(path.id))
            }
            settings.hasPendingScopeChanges = false
        }
        settings.setMainBasePath(root)
        for path in settings.allTrackedPaths {
            settings.setPathEnabled(path, enabled: path.id == settings.mainTrackedPath.id)
        }
        settings.hasPendingScopeChanges = false
        try await body()
    }

    private static func processCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }
}
