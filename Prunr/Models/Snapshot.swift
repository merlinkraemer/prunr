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

    init(id: Int64? = nil, trackedPathId: UUID, createdAt: Date = Date()) {
        self.id = id
        self.trackedPathId = trackedPathId
        self.createdAt = createdAt
    }

    /// Custom init for GRDB decoding that handles empty strings
    init(id: Int64? = nil, trackedPathIdString: String?, createdAt: Date) {
        self.id = id
        self.trackedPathId = UUID(uuidString: trackedPathIdString ?? "") ?? UUID()
        self.createdAt = createdAt
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
    }

    /// Decode from database row, handling UUID conversion
    init(row: Row) {
        id = row["id"]
        createdAt = row["createdAt"]

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
    }

    /// Auto-generate ID on insert
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
