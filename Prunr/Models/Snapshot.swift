import Foundation
import GRDB

/// Represents a single storage scan snapshot
struct Snapshot: Codable, Identifiable, Equatable, Hashable {
    /// Auto-increment primary key
    var id: Int64?

    /// The ID of the TrackedPath this snapshot belongs to
    var trackedPathId: UUID

    /// When the snapshot was created
    var createdAt: Date

    /// Volume free space at snapshot creation time (bytes)
    /// Nil for legacy snapshots before migration
    var freeBytes: Int64?

    init(id: Int64? = nil, trackedPathId: UUID, createdAt: Date = Date(), freeBytes: Int64? = nil) {
        self.id = id
        self.trackedPathId = trackedPathId
        self.createdAt = createdAt
        self.freeBytes = freeBytes
    }

    /// Custom init for GRDB decoding that handles empty strings
    init(id: Int64? = nil, trackedPathIdString: String?, createdAt: Date, freeBytes: Int64? = nil) {
        self.id = id
        self.trackedPathId = UUID(uuidString: trackedPathIdString ?? "") ?? UUID()
        self.createdAt = createdAt
        self.freeBytes = freeBytes
    }
}

// MARK: - GRDB Record Conformance

extension Snapshot: FetchableRecord, MutablePersistableRecord {
    /// The table name in the database
    static let databaseTableName = "snapshot"

    /// Columns for type-safe SQL
    enum Columns {
        static let id = Column(CodingKeys.id)
        static let trackedPathId = Column(CodingKeys.trackedPathId)
        static let createdAt = Column(CodingKeys.createdAt)
        static let freeBytes = Column(CodingKeys.freeBytes)
    }

    /// Decode from database row, handling UUID conversion
    init(row: Row) {
        id = row["id"]
        createdAt = row["createdAt"]
        freeBytes = row["freeBytes"]

        // Handle trackedPathId - may be empty string for old snapshots
        if let pathIdString: String = row["trackedPathId"], !pathIdString.isEmpty {
            trackedPathId = UUID(uuidString: pathIdString) ?? UUID()
        } else {
            trackedPathId = UUID()
        }
    }

    /// Encode to database row
    func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["createdAt"] = createdAt
        container["trackedPathId"] = trackedPathId.uuidString
        container["freeBytes"] = freeBytes
    }

    /// Auto-generate ID on insert
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
