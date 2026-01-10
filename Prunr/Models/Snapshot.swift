import Foundation
import GRDB

/// Represents a single storage scan snapshot
struct Snapshot: Codable, Identifiable, Equatable, Hashable {
    /// Auto-increment primary key
    var id: Int64?

    /// When the snapshot was created
    var createdAt: Date

    init(id: Int64? = nil, createdAt: Date = Date()) {
        self.id = id
        self.createdAt = createdAt
    }
}

// MARK: - GRDB Record Conformance

extension Snapshot: FetchableRecord, PersistableRecord {
    /// The table name in the database
    static let databaseTableName = "snapshot"

    /// Columns for type-safe SQL
    enum Columns {
        static let id = Column(CodingKeys.id)
        static let createdAt = Column(CodingKeys.createdAt)
    }

    /// Auto-generate ID on insert
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
