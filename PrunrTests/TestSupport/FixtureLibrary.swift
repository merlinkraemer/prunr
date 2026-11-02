import Foundation
@testable import Prunr

enum FixtureLibrary {
    static let home = "/Users/tester"

    private static var productionHome: String?

    static func useSyntheticHome() {
        productionHome = productionHome ?? UnitResolver.defaultHome
        UnitResolver.defaultHome = home
    }

    static func restoreProductionHome() {
        if let productionHome {
            UnitResolver.defaultHome = productionHome
        }
    }

    static let catalog = AppCatalog(entries: [
        AppCatalogEntry(
            bundleIdentifier: "com.google.Chrome", name: "Google Chrome",
            names: ["Google Chrome", "Chrome"], path: "/Applications/Google Chrome.app"
        )
    ])

    static let now: Date = date(day: 28, hour: 16, minute: 0)

    static var metrics: PanelSnapshotMetrics {
        PanelSnapshotMetrics(home: home, now: now)
    }

    private static let gb: Int64 = 1_000_000_000

    private struct Change {
        let path: String
        let bytes: Int64
        let at: Date
        let source: GrowthJournalBucket.Source
    }

    private static let changes: [Change] = [
        Change(path: home + "/dev/game/Builds/mac/Game.bin", bytes: 32 * gb, at: date(day: 27, hour: 11, minute: 40), source: .scan),
        Change(path: home + "/dev/build/app-1/out.o", bytes: 6 * gb, at: date(day: 24, hour: 11, minute: 40), source: .scan),
        Change(path: home + "/dev/build/app-1/out.o", bytes: 5 * gb, at: date(day: 25, hour: 11, minute: 40), source: .scan),
        Change(path: home + "/dev/build/app-1/out.o", bytes: 8 * gb, at: date(day: 26, hour: 11, minute: 40), source: .scan),
        Change(path: home + "/dev/build/app-1/out.o", bytes: 8 * gb, at: date(day: 27, hour: 11, minute: 40), source: .scan),
        Change(path: home + "/Pictures/Photos Library.photoslibrary/originals/0/a.heic", bytes: 13 * gb, at: date(day: 28, hour: 10, minute: 5), source: .watch),
        Change(path: home + "/.cache/uv/archive-v0/x.whl", bytes: -11 * gb, at: date(day: 27, hour: 11, minute: 40), source: .scan),
        Change(path: home + "/Library/Caches/Google/Chrome/Default/Cache/f_1", bytes: -4 * gb, at: date(day: 26, hour: 11, minute: 40), source: .scan),
        Change(path: home + "/Library/Application Support/Steam/steamapps/common/TUNIC/data.bin", bytes: 2 * gb, at: date(day: 26, hour: 20, minute: 10), source: .watch),
        Change(path: home + "/Downloads/ubuntu-24.04.iso", bytes: 3 * gb, at: date(day: 28, hour: 9, minute: 30), source: .watch)
    ]

    private static let files: [ScanResult] = [
        ScanResult(path: home + "/dev/game/Assets/textures.pak", sizeBytes: 38 * gb),
        ScanResult(path: home + "/dev/game/Assets/audio.pak", sizeBytes: 6 * gb),
        ScanResult(path: home + "/dev/game/Library/Bee/artifacts.bin", sizeBytes: 12 * gb),
        ScanResult(path: home + "/dev/game/Builds/mac/Game.bin", sizeBytes: 30 * gb),
        ScanResult(path: home + "/dev/game/Builds/mac/Game.dSYM", sizeBytes: 2 * gb),
        ScanResult(path: home + "/dev/game/README.md", sizeBytes: 4_096),
        ScanResult(path: home + "/dev/build/app-1/out.o", sizeBytes: 27 * gb),
        ScanResult(path: home + "/dev/build/app-1/index.db", sizeBytes: 200_000_000),
        ScanResult(path: home + "/Pictures/Photos Library.photoslibrary/originals/0/a.heic", sizeBytes: 13 * gb),
        ScanResult(path: home + "/Pictures/Photos Library.photoslibrary/database/Photos.sqlite", sizeBytes: 300_000_000),
        ScanResult(path: home + "/.cache/uv/archive-v0/x.whl", sizeBytes: 2 * gb),
        ScanResult(path: home + "/Library/Caches/Google/Chrome/Default/Cache/f_1", sizeBytes: 3 * gb),
        ScanResult(path: home + "/Library/Caches/Google/Chrome/Default/Code Cache/js/a", sizeBytes: 400_000_000),
        ScanResult(path: home + "/Library/Application Support/Steam/steamapps/common/TUNIC/data.bin", sizeBytes: 2 * gb),
        ScanResult(path: home + "/Downloads/ubuntu-24.04.iso", sizeBytes: 3 * gb)
    ]

    static func seed(trackedPathId: UUID) async throws {
        _ = try await DatabaseManager.shared.replaceWorkingSetSubtree(
            trackedPathId: trackedPathId,
            rootPath: home,
            entries: files,
            updatedAt: now
        )
        let trackedPath = TrackedPath(id: trackedPathId, url: URL(fileURLWithPath: home, isDirectory: true), displayName: "Home")
        for change in changes {
            let key = UnitResolver.resolveKey(path: change.path, home: home)
            let name = UnitNamer.name(for: key, home: home)
            let deltaKey = DatabaseManager.JournalDeltaKey(category: name.category, subcategory: nil, unitKey: key.rawValue)
            try await GrowthJournalService.shared.recordDeltas(
                trackedPath: trackedPath,
                deltas: [deltaKey: change.bytes],
                at: change.at,
                source: change.source,
                observedSince: change.source == .scan ? change.at.addingTimeInterval(-24 * 3_600) : nil
            )
        }
    }

    private static func date(day: Int, hour: Int, minute: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute)) ?? Date()
    }
}
