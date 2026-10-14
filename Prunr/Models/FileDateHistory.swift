import Foundation
import Darwin

/// When a file was created and last written, in seconds since 1970.
struct FileDates: Sendable, Equatable {
    let birth: TimeInterval
    let modified: TimeInterval

    init(birth: TimeInterval, modified: TimeInterval) {
        self.birth = birth
        self.modified = modified
    }

    init(_ fileStat: stat) {
        self.init(
            birth: Self.seconds(fileStat.st_birthtimespec),
            modified: Self.seconds(fileStat.st_mtimespec)
        )
    }

    /// Written once: last written within `FileDateHistory.writtenOnceTolerance`
    /// of its creation. A file that kept changing (a VM disk, a database, a
    /// growing log) is not: its size today says nothing about its birth day.
    var isWrittenOnce: Bool {
        modified - birth <= FileDateHistory.writtenOnceTolerance
    }

    private static func seconds(_ time: timespec) -> TimeInterval {
        TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000
    }
}

/// The history before the first scan, rebuilt from file dates: every file
/// written once and born inside the shown history adds its size at its birth
/// time, per place and category, in the journal's 30-minute slots.
///
/// Fed one file at a time while the first scan streams, so memory grows with
/// slots × places, never with the file count.
struct FileDateHistory: Sendable {
    static let writtenOnceTolerance: TimeInterval = 60 * 60

    /// Start of the oldest day the change list shows.
    let windowStart: Date
    /// When the first scan started. Anything born later is the watcher's.
    let windowEnd: Date

    private var bytesBySlot: [Int64: [DatabaseManager.JournalDeltaKey: Int64]] = [:]
    private(set) var fileCount = 0
    private(set) var totalBytes: Int64 = 0

    init(scanStart: Date, calendar: Calendar = .current) {
        windowStart = GrowthJournalService.historyStart(now: scanStart, calendar: calendar)
        windowEnd = scanStart
    }

    var isEmpty: Bool { bytesBySlot.isEmpty }

    var bucketCount: Int { bytesBySlot.count }

    /// Trash is left out: Trash growth is a move, never a row, so it must not
    /// reach the header either.
    mutating func add(
        path: String,
        sizeBytes: Int64,
        category: GrowthCategory,
        subcategory: GrowthSubcategory?,
        dates: FileDates,
        home: String = UnitResolver.defaultHome
    ) {
        guard sizeBytes > 0,
              category != .trash,
              dates.isWrittenOnce,
              dates.birth >= windowStart.timeIntervalSince1970,
              dates.birth < windowEnd.timeIntervalSince1970 else {
            return
        }
        let slot = Int64(floor(dates.birth / TimeInterval(JournalSlot.slotSeconds)))
        let key = DatabaseManager.JournalDeltaKey(
            category: category,
            subcategory: subcategory,
            unitKey: UnitResolver.resolve(path: path, home: home)
        )
        bytesBySlot[slot, default: [:]][key, default: 0] += sizeBytes
        fileCount += 1
        totalBytes += sizeBytes
    }

    /// Journal deltas per bucket start: each slot's start, never before
    /// `windowStart` (a local midnight need not fall on a slot boundary).
    var deltasByBucketStart: [Date: [DatabaseManager.JournalDeltaKey: Int64]] {
        var result: [Date: [DatabaseManager.JournalDeltaKey: Int64]] = [:]
        for (slot, deltas) in bytesBySlot {
            let slotStart = Date(timeIntervalSince1970: TimeInterval(slot * JournalSlot.slotSeconds))
            result[max(slotStart, windowStart), default: [:]].merge(deltas, uniquingKeysWith: +)
        }
        return result
    }
}
