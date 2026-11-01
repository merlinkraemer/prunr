import XCTest
import GRDB
@testable import Prunr

/// Per-child journal detail (L1): what each writer records, and the row page
/// that reads it back for a row's span or falls back to sizes now.
final class GrowthJournalDetailTests: PrunrTestCase {
    private let db = DatabaseManager.shared
    private static let mb: Int64 = 1_000_000
    private static let place = "/Data/Place"

    private func utc() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        utc().date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private func file(_ relative: String, _ bytes: Int64) -> ScanResult {
        ScanResult(path: Self.place + "/" + relative, sizeBytes: bytes, category: .other, subcategory: nil)
    }

    private func child(_ name: String, folder: Bool = true) -> PlaceChildKey {
        PlaceChildKey(unitRoot: Self.place, name: name, isFolder: folder)
    }

    private func detailRows() async throws -> [(name: String, source: String, bucketStart: Date, deltaBytes: Int64)] {
        let dbPool = try XCTUnwrap(db.dbPool)
        return try await dbPool.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT name, source, bucketStart, deltaBytes FROM growthJournalDetail ORDER BY bucketStart, name"
            ).map { row -> (name: String, source: String, bucketStart: Date, deltaBytes: Int64) in
                let name: String = row["name"] ?? ""
                let source: String = row["source"] ?? ""
                let bucketStart: Date = row["bucketStart"]
                let deltaBytes: Int64 = row["deltaBytes"] ?? 0
                return (name: name, source: source, bucketStart: bucketStart, deltaBytes: deltaBytes)
            }
        }
    }

    // MARK: - Bounding

    func testBoundedKeepsTheLargestChildrenAndFoldsTheRestIntoOneRow() {
        var deltas: [PlaceChildKey: Int64] = [:]
        for index in 0..<25 {
            deltas[child("c\(index)")] = Int64(index + 1) * (index.isMultiple(of: 2) ? 1 : -1)
        }
        deltas[child("zero")] = 0
        deltas[GrowthJournalDetail.other(unitRoot: Self.place)] = 100
        deltas[PlaceChildKey(unitRoot: "/Data/Other", name: "x", isFolder: false)] = 7

        let bounded = GrowthJournalDetail.bounded(deltas)

        let named = bounded.keys.filter { $0.unitRoot == Self.place && !GrowthJournalDetail.isOther($0) }
        XCTAssertEqual(named.count, GrowthJournalDetail.topChildren)
        XCTAssertEqual(Set(named.map(\.name)), Set((5..<25).map { "c\($0)" }), "largest absolute moves kept")
        XCTAssertEqual(bounded[GrowthJournalDetail.other(unitRoot: Self.place)], 100 + 1 - 2 + 3 - 4 + 5)
        XCTAssertEqual(bounded[PlaceChildKey(unitRoot: "/Data/Other", name: "x", isFolder: false)], 7)
        XCTAssertNil(bounded[child("zero")])
        XCTAssertEqual(bounded.values.reduce(0, +), deltas.values.reduce(0, +), "bounding never drops bytes")
    }

    func testResidualIsAuthoritativeMinusRecordedPerChild() {
        let residual = GrowthJournalDetail.residual(
            authoritative: [child("a"): 12, child("b"): 5],
            recorded: [child("a"): 10, child("b"): 5, child("c"): 3]
        )
        XCTAssertEqual(residual, [child("a"): 2, child("c"): -3])
    }

    // MARK: - Writers

    func testWatcherWriteRecordsPerChildDetailInItsMinute() async throws {
        try await withEmptyTemporaryDatabase { [self] id in
            let seededAt = date(29, 8, 0)
            _ = try await db.replaceWorkingSetSubtree(trackedPathId: id, rootPath: Self.place, entries: [
                file("Photos/a.jpg", 3 * Self.mb),
                file("Docs/x.txt", 2 * Self.mb)
            ], updatedAt: seededAt)
            let grewAt = date(29, 10, 15).addingTimeInterval(42)
            _ = try await db.replaceWorkingSetFile(trackedPathId: id, entry: file("Photos/b.jpg", 4 * Self.mb), updatedAt: grewAt)
            _ = try await db.removeWorkingSetPathOrSubtree(trackedPathId: id, rootPath: Self.place + "/Docs/x.txt", updatedAt: grewAt)

            let rows = try await detailRows()
            XCTAssertTrue(rows.allSatisfy { $0.source == GrowthJournalBucket.Source.watch.rawValue })
            let later = rows.filter { $0.bucketStart == GrowthJournalService.bucketStart(for: grewAt) }
            XCTAssertEqual(Dictionary(uniqueKeysWithValues: later.map { ($0.name, $0.deltaBytes) }), [
                "Photos": 4 * Self.mb,
                "Docs": -2 * Self.mb
            ])

            let totals = try await db.fetchJournalDetailTotals(trackedPathId: id, from: seededAt.addingTimeInterval(-1), to: grewAt)
            XCTAssertEqual(totals[child("Photos")], 7 * Self.mb)
            XCTAssertEqual(totals[child("Docs")], 0)
        }
    }

    func testFullScanRecordsThePerChildResidual() async throws {
        try await withEmptyTemporaryDatabase { trackedPathId in
            let directory = try self.createTrackedPathDirectory(named: "PrunrDetailResidual")
            defer { try? FileManager.default.removeItem(at: directory) }
            let folder = directory.appendingPathComponent("sub", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("blob.bin")
            try Data(repeating: 0xAB, count: 4_096).write(to: file)
            try self.dateBeforeHistory(file)
            let trackedPath = TrackedPath(id: trackedPathId, url: directory, displayName: "Temp")

            let s0 = try await BaselineService.shared.createBaseline(trackedPath: trackedPath)
            let windowStart = Date(timeIntervalSinceReferenceDate: floor(Date().timeIntervalSinceReferenceDate) - 7_200)
            let s0Id = try XCTUnwrap(s0.id)
            let dbPool = try XCTUnwrap(self.db.dbPool)
            try await dbPool.write { db in
                try db.execute(sql: "UPDATE snapshot SET createdAt = ? WHERE id = ?", arguments: [windowStart, s0Id])
                try db.execute(sql: "DELETE FROM growthJournalDetail")
            }

            let key = try XCTUnwrap(PlaceChildKey(path: file.path, unitKey: UnitResolver.resolve(path: file.path)))
            let watchAt = GrowthJournalService.bucketStart(for: Date().addingTimeInterval(-3_600))
            try await self.db.upsertJournalDetail(
                trackedPathId: trackedPathId,
                deltasByBucketStart: [watchAt: [key: 10 * 1_024 * 1_024]],
                source: .watch
            )

            let sizeBefore = try self.diskUsageBytes(at: file)
            try Data(repeating: 0xAB, count: 4_096 + 12 * 1_024 * 1_024).write(to: file)
            let authoritative = try self.diskUsageBytes(at: file) - sizeBefore

            let s1 = try await BaselineService.shared.createBaseline(trackedPath: trackedPath)

            let scanRows = try await self.detailRows().filter { $0.source == GrowthJournalBucket.Source.scan.rawValue }
            XCTAssertEqual(scanRows.map(\.name), [key.name])
            XCTAssertEqual(scanRows.first?.deltaBytes, authoritative - 10 * 1_024 * 1_024)
            XCTAssertEqual(scanRows.first?.bucketStart, GrowthJournalService.bucketStart(for: s1.createdAt))

            let window = try await self.db.fetchJournalDetailTotals(trackedPathId: trackedPathId, from: windowStart, to: s1.createdAt)
            XCTAssertEqual(window.values.reduce(0, +), authoritative, "the window sums to the snapshot delta")
        }
    }

    func testFileDateHistoryKeepsChildrenPerSlot() {
        let calendar = utc()
        var history = FileDateHistory(scanStart: date(29, 16), calendar: calendar)
        let birth = date(28, 9, 10).timeIntervalSince1970
        for (relative, bytes) in [("Photos/a.jpg", Int64(300)), ("Photos/b.jpg", 200), ("big.iso", 500)] {
            let path = Self.place + "/" + relative
            history.add(
                path: path,
                unitKey: UnitResolver.resolve(path: path),
                sizeBytes: bytes,
                category: .other,
                subcategory: nil,
                dates: FileDates(birth: birth, modified: birth + 60)
            )
        }

        let slotStart = date(28, 9, 0)
        XCTAssertEqual(history.childDeltasByBucketStart, [slotStart: [
            child("Photos"): 500,
            child("big.iso", folder: false): 500
        ]])
        XCTAssertEqual(Set(history.deltasByBucketStart.keys), [slotStart])
    }

    // MARK: - Row page

    func testPlaceChangesListSpanDeltasRemovedChildrenAndFallBackBeforeRecording() async throws {
        try await withEmptyTemporaryDatabase { [self] id in
            _ = try await db.replaceWorkingSetSubtree(trackedPathId: id, rootPath: Self.place, entries: [
                file("Photos/a.jpg", 30 * Self.mb),
                file("Docs/x.txt", 20 * Self.mb),
                file("big.iso", 50 * Self.mb)
            ], updatedAt: date(28, 8))
            _ = try await db.replaceWorkingSetFile(trackedPathId: id, entry: file("Photos/b.jpg", 40 * Self.mb), updatedAt: date(29, 10))
            _ = try await db.removeWorkingSetPathOrSubtree(trackedPathId: id, rootPath: Self.place + "/Docs", updatedAt: date(29, 11))

            let day = try await db.fetchPlaceChanges(unitRoot: Self.place, trackedPathIds: [id], from: date(29, 0), to: date(30, 0))
            let children = try XCTUnwrap(day.children)
            XCTAssertEqual(children.map(\.name), ["Photos", "Docs"], "largest change first; big.iso did not move that day")
            XCTAssertEqual(children.map(\.deltaBytes), [40 * Self.mb, -20 * Self.mb])
            XCTAssertEqual(children.map(\.currentBytes), [70 * Self.mb, nil], "a removed child is listed as gone")
            XCTAssertEqual(children.first?.path, Self.place + "/Photos")
            XCTAssertEqual(day.currentBytes, 120 * Self.mb)

            let before = try await db.fetchPlaceChanges(unitRoot: Self.place, trackedPathIds: [id], from: date(27, 0), to: date(30, 0))
            XCTAssertNil(before.children, "the detail started after the span did")
            XCTAssertEqual(before.currentBytes, 120 * Self.mb)

            let quiet = try await db.fetchPlaceChanges(unitRoot: Self.place, trackedPathIds: [id], from: date(30, 0), to: date(31, 0))
            XCTAssertNil(quiet.children, "no detail for the place in the span")
        }
    }

    func testSmallChangesFoldIntoOtherChanges() async throws {
        try await withEmptyTemporaryDatabase { [self] id in
            _ = try await db.replaceWorkingSetSubtree(trackedPathId: id, rootPath: Self.place, entries: [
                file("Big/a.bin", 5 * Self.mb),
                file("tiny1.txt", 1_000),
                file("tiny2.txt", 2_000)
            ], updatedAt: date(29, 8))

            let page = try await db.fetchPlaceChanges(unitRoot: Self.place, trackedPathIds: [id], from: date(29, 8), to: date(30, 0))
            let children = try XCTUnwrap(page.children)
            XCTAssertEqual(children.map(\.name), ["Big", PlacePageNotes.otherChangesTitle])
            XCTAssertEqual(children.last?.deltaBytes, 3_000)
            XCTAssertNil(children.last?.path)
            XCTAssertNil(children.last.flatMap(PlacePageNotes.currentText))
        }
    }

    // MARK: - Notes and page model

    private func episode(netBytes: Int64, day: Date, buildingSince: Date? = nil) -> ChangeEpisode {
        ChangeEpisode(
            id: "place|\(Self.place)@\(Int64(day.timeIntervalSince1970))",
            title: "Place",
            detail: nil,
            category: .other,
            rootPath: Self.place,
            netBytes: netBytes,
            grossBytes: abs(netBytes),
            day: day,
            time: day,
            isApproximateTime: true,
            buildingSince: buildingSince
        )
    }

    func testSpanCoversTheRowsDays() {
        let calendar = utc()
        let oneDay = PlaceChangeSpan(episode: episode(netBytes: 1, day: date(29, 0)), calendar: calendar)
        XCTAssertEqual(oneDay.start, date(29, 0))
        XCTAssertEqual(oneDay.end, date(30, 0))
        XCTAssertEqual(oneDay.daysText(calendar: calendar), "on Thu 29 Oct")

        let building = PlaceChangeSpan(episode: episode(netBytes: 1, day: date(26, 0), buildingSince: date(18, 0)), calendar: calendar)
        XCTAssertEqual(building.start, date(18, 0))
        XCTAssertEqual(building.end, date(27, 0))
        XCTAssertEqual(building.daysText(calendar: calendar), "from Sun 18 Oct to Mon 26 Oct")
    }

    func testNotesSayWhatTheListShows() {
        let calendar = utc()
        let gb: Int64 = 1_000_000_000
        let grew = PlaceChangeSpan(episode: episode(netBytes: 27 * gb, day: date(29, 0)), calendar: calendar)
        let shrank = PlaceChangeSpan(episode: episode(netBytes: -7_300_000_000, day: date(26, 0)), calendar: calendar)
        let detail = PlaceChanges(children: [], currentBytes: 400 * gb)

        XCTAssertEqual(PlacePageNotes.lines(span: grew, changes: detail, calendar: calendar), ["Changes on Thu 29 Oct"])
        XCTAssertEqual(
            PlacePageNotes.lines(span: grew, changes: PlaceChanges(children: nil, currentBytes: 400 * gb), calendar: calendar),
            ["Now \(formattedBytes(400 * gb)) \u{00B7} grew \(formattedBytes(27 * gb)) on Thu 29 Oct", "Size now"]
        )
        XCTAssertEqual(
            PlacePageNotes.lines(span: shrank, changes: PlaceChanges(children: nil, currentBytes: 0), calendar: calendar),
            ["Gone, was about 7.3 GB"]
        )
        XCTAssertEqual(
            PlacePageNotes.lines(span: grew, changes: PlaceChanges(children: nil, currentBytes: 0), calendar: calendar),
            ["Gone now \u{00B7} grew \(formattedBytes(27 * gb)) on Thu 29 Oct"]
        )
    }

    @MainActor
    func testPageShowsChangesWhenRecordedElseSizesNow() async {
        let change = PlaceChildChange(name: "Photos", path: Self.place + "/Photos", isFolder: true, deltaBytes: 40, currentBytes: 70)
        var sizeReads = 0
        let sizes: PlaceContentsModel.Loader = { _ in
            sizeReads += 1
            return PlaceContentsPage(
                children: [PlaceChild(name: "Photos", path: Self.place + "/Photos", isFolder: true, totalBytes: 70, fileCount: 2)],
                hasMore: false
            )
        }

        let recorded = PlaceContentsModel(
            loader: sizes,
            changesLoader: { PlaceChanges(children: [change], currentBytes: 70) },
            notes: { $0.children == nil ? ["sizes"] : ["changes"] }
        )
        await recorded.load()
        XCTAssertEqual(recorded.changes, [change])
        XCTAssertEqual(recorded.notes, ["changes"])
        XCTAssertNil(recorded.inlineStatus)
        XCTAssertEqual(sizeReads, 0)

        let old = PlaceContentsModel(
            loader: sizes,
            changesLoader: { PlaceChanges(children: nil, currentBytes: 70) },
            notes: { $0.children == nil ? ["sizes"] : ["changes"] }
        )
        await old.load()
        XCTAssertNil(old.changes)
        XCTAssertEqual(old.notes, ["sizes"])
        XCTAssertEqual(old.children.map(\.name), ["Photos"])
        XCTAssertEqual(sizeReads, 1)
    }

    // MARK: - Migration

    func testJournalDetailMigrationAddsTheTableAndKeepsHistory() throws {
        let directory = try createTrackedPathDirectory(named: "PrunrJournalDetailMigration")
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try DatabaseQueue(path: directory.appendingPathComponent("prunr.sqlite").path)
        let migrator = DatabaseManager.makeMigrator()
        try migrator.migrate(queue, upTo: DatabaseManager.ownerGroupsMigrationIdentifier)
        try queue.write { db in
            XCTAssertFalse(try db.tableExists("growthJournalDetail"))
            try db.execute(
                sql: """
                    INSERT INTO growthJournalBucket (trackedPathId, bucketStart, category, subcategory, deltaBytes, unitKey)
                    VALUES ('t', ?, 'other', '', 1000, 'place|/x')
                    """,
                arguments: [Date()]
            )
        }

        try migrator.migrate(queue)

        try queue.read { db in
            XCTAssertTrue(try db.tableExists("growthJournalDetail"))
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM growthJournalBucket"), 1, "history is kept")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM growthJournalDetail"), 0, "no back-fill")
        }
    }
}
