import Foundation
import GRDB

/// Represents a single folder/file entry within a snapshot
struct SnapshotEntry: Codable, Identifiable {
    /// Auto-increment primary key
    var id: Int64?

    /// Foreign key to the parent snapshot
    var snapshotId: Int64

    /// Foreign key to paths table
    var pathId: Int64

    /// Size in bytes
    var sizeBytes: Int64

    init(id: Int64? = nil, snapshotId: Int64, pathId: Int64, sizeBytes: Int64) {
        self.id = id
        self.snapshotId = snapshotId
        self.pathId = pathId
        self.sizeBytes = sizeBytes
    }
}

// MARK: - GRDB Record Conformance

extension SnapshotEntry: FetchableRecord, MutablePersistableRecord {
    /// The table name in the database
    static let databaseTableName = "snapshotEntry"

    /// Columns for type-safe SQL
    enum Columns {
        static let id = Column(CodingKeys.id)
        static let snapshotId = Column(CodingKeys.snapshotId)
        static let pathId = Column(CodingKeys.pathId)
        static let sizeBytes = Column(CodingKeys.sizeBytes)
    }

    /// Auto-generate ID on insert
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Associations

extension SnapshotEntry {
    /// Relationship to parent snapshot
    static let snapshot = belongsTo(Snapshot.self)

    var snapshot: QueryInterfaceRequest<Snapshot> {
        request(for: SnapshotEntry.snapshot)
    }
}

extension Snapshot {
    /// Relationship to entries
    static let entries = hasMany(SnapshotEntry.self)

    var entries: QueryInterfaceRequest<SnapshotEntry> {
        request(for: Snapshot.entries)
    }
}

struct SnapshotEntryWithPath: Codable, Identifiable, FetchableRecord {
    var id: Int64?
    var snapshotId: Int64
    var path: String
    var sizeBytes: Int64
}
