import Foundation
import GRDB
@testable import Prunr

struct ReplaySlot: Codable, Equatable {
    let at: String
    let source: String
    let netBytes: Int64
    let grossBytes: Int64
}

struct ReplayChild: Codable, Equatable {
    let name: String
    let isFolder: Bool
    let totalBytes: Int64
    let fileCount: Int
}

struct ReplayRow: Codable, Equatable {
    let day: String
    let time: String
    let group: String
    let title: String
    let detail: String?
    let unitKey: String
    let rootPath: String?
    let netBytes: Int64
    let grossBytes: Int64
    let flags: [String]
    let slots: [ReplaySlot]
    let drilldown: [ReplayChild]
    let drilldownHasMore: Bool
}

struct ReplayReport: Codable, Equatable {
    let source: String
    let now: String
    let home: String
    let weekNetBytes: Int64
    let rows: [ReplayRow]
}

struct ReplayResult {
    let report: ReplayReport
    let feed: ChangeFeed
    let contentsByEpisodeID: [String: PlaceContentsPage]
    let trackedPathIds: [UUID]
    let home: String
    let now: Date
}

enum ReplayHarness {
    static let drilldownLimit = 50

    @MainActor
    static func run(
        source: String,
        trackedPathIds: [UUID],
        home: String,
        now: Date,
        catalog: AppCatalog? = nil
    ) async throws -> ReplayResult {
        let trackedPaths = trackedPathIds.map {
            TrackedPath(id: $0, url: URL(fileURLWithPath: home, isDirectory: true), displayName: "Home")
        }
        var feed = try await GrowthJournalService.shared.changeFeed(trackedPaths: trackedPaths, now: now, home: home)
        feed = feed.resolvingOwners(with: catalog ?? AppCatalogProvider.shared.catalog(resolving: feed.ownerAppIdentifiers))

        let since = EpisodeBuilder.windowStart(now: now, calendar: .current)
        let slots = try await DatabaseManager.shared.fetchJournalSlots(trackedPathIds: trackedPathIds, since: since)

        var rows: [ReplayRow] = []
        var contents: [String: PlaceContentsPage] = [:]
        for day in feed.days {
            for group in day.groups {
                for episode in group.episodes {
                    var page: PlaceContentsPage?
                    if let root = episode.rootPath {
                        page = try await DatabaseManager.shared.fetchPlaceContents(
                            unitRoot: root,
                            trackedPathIds: trackedPathIds,
                            limit: drilldownLimit
                        )
                        contents[episode.id] = page
                    }
                    rows.append(makeRow(episode, group: group, slots: slots, page: page))
                }
            }
        }

        let report = ReplayReport(
            source: source,
            now: stamp(now),
            home: home,
            weekNetBytes: feed.weekNetBytes,
            rows: rows
        )
        return ReplayResult(
            report: report,
            feed: feed,
            contentsByEpisodeID: contents,
            trackedPathIds: trackedPathIds,
            home: home,
            now: now
        )
    }

    static func unitKey(of episode: ChangeEpisode) -> String {
        guard let separator = episode.id.lastIndex(of: "@") else { return episode.id }
        return String(episode.id[..<separator])
    }

    private static func makeRow(
        _ episode: ChangeEpisode,
        group: ChangeGroup,
        slots: [JournalSlot],
        page: PlaceContentsPage?
    ) -> ReplayRow {
        let key = unitKey(of: episode)
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: episode.day) ?? episode.day
        let ownSlots = slots
            .filter { $0.unitKey == key && $0.firstAt >= episode.day && $0.firstAt < dayEnd }
            .sorted { $0.firstAt < $1.firstAt }
            .map {
                ReplaySlot(at: stamp($0.firstAt), source: $0.source.rawValue, netBytes: $0.netBytes, grossBytes: $0.grossBytes)
            }
        var flags: [String] = []
        if episode.isEstimated { flags.append("estimated") }
        if episode.isApproximateTime { flags.append("approximate-time") }
        if episode.isMovedToTrash { flags.append("moved-to-trash") }
        if episode.isLargeGrowth { flags.append("large") }
        if episode.buildingSince != nil { flags.append("building") }
        return ReplayRow(
            day: stamp(episode.day, dateOnly: true),
            time: stamp(episode.time),
            group: group.owner.displayName,
            title: episode.title,
            detail: episode.detail,
            unitKey: key,
            rootPath: episode.rootPath,
            netBytes: episode.netBytes,
            grossBytes: episode.grossBytes,
            flags: flags,
            slots: ownSlots,
            drilldown: (page?.children ?? []).map {
                ReplayChild(name: $0.name, isFolder: $0.isFolder, totalBytes: $0.totalBytes, fileCount: $0.fileCount)
            },
            drilldownHasMore: page?.hasMore ?? false
        )
    }

    static func text(_ report: ReplayReport) -> String {
        var lines = [
            "replay of \(report.source)",
            "now \(report.now), home \(report.home), week net \(bytes(report.weekNetBytes)), \(report.rows.count) rows",
            ""
        ]
        var currentDay = ""
        for row in report.rows {
            if row.day != currentDay {
                currentDay = row.day
                lines.append("== \(row.day)")
            }
            let flags = row.flags.isEmpty ? "" : "  [\(row.flags.joined(separator: ", "))]"
            lines.append("\(bytes(row.netBytes))  \(row.title)  (\(row.group), \(row.time))\(flags)")
            lines.append("    unit \(row.unitKey)")
            if let root = row.rootPath { lines.append("    root \(root)") }
            for slot in row.slots {
                lines.append("    journal \(slot.at) \(slot.source) \(bytes(slot.netBytes)) moved \(bytes(slot.grossBytes))")
            }
            if row.drilldown.isEmpty {
                lines.append("    drilldown: empty")
            } else {
                lines.append("    drilldown (\(row.drilldown.count)\(row.drilldownHasMore ? "+" : "")), size order, totals not growth:")
                for child in row.drilldown {
                    let kind = child.isFolder ? "dir " : "file"
                    lines.append("      \(kind) \(bytes(child.totalBytes))  \(child.name)  (\(child.fileCount) files)")
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func write(_ result: ReplayResult, named name: String, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result.report).write(to: directory.appendingPathComponent(name + ".json"))
        try text(result.report).write(to: directory.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
    }

    static func trackedPathIds(inDatabaseAt path: String) throws -> [UUID] {
        try readOnlyQueue(path).read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT trackedPathId FROM growthJournalBucket")
        }.compactMap(UUID.init(uuidString:))
    }

    static func newestBucketTime(inDatabaseAt path: String) throws -> Date? {
        try readOnlyQueue(path).read { db in
            try Date.fetchOne(db, sql: "SELECT MAX(bucketStart) FROM growthJournalBucket")
        }
    }

    static func detectHome(inDatabaseAt path: String) throws -> String? {
        let keys = try readOnlyQueue(path).read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT unitKey FROM growthJournalBucket LIMIT 400")
        }
        var counts: [String: Int] = [:]
        for key in keys {
            guard let range = key.range(of: "/Users/") else { continue }
            let name = key[range.upperBound...].prefix { $0 != "/" }
            counts["/Users/" + name, default: 0] += 1
        }
        return counts.max { $0.value < $1.value }?.key
    }

    private static func readOnlyQueue(_ path: String) throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.readonly = true
        return try DatabaseQueue(path: path, configuration: configuration)
    }

    static func bytes(_ value: Int64) -> String {
        let sign = value < 0 ? "-" : "+"
        let gb = Double(abs(value)) / 1_000_000_000
        if gb >= 1 { return String(format: "%@%.2f GB", sign, gb) }
        return String(format: "%@%.1f MB", sign, Double(abs(value)) / 1_000_000)
    }

    private static func stamp(_ date: Date, dateOnly: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = dateOnly ? "yyyy-MM-dd EEE" : "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
