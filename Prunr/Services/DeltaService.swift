import Foundation

/// Actor that orchestrates delta calculations between snapshots
///
/// Provides a single entry point for comparing two snapshots and
/// returning the differences. Delegates actual computation to
/// DatabaseManager for SQL-based performance.
actor DeltaService {

    // MARK: - Properties

    /// Shared singleton instance
    static let shared = DeltaService()

    /// Database manager reference
    private let db = DatabaseManager.shared

    private init() {}

    // MARK: - Public API

    /// Compares two snapshots and returns sorted deltas
    ///
    /// Uses SQL FULL OUTER JOIN for efficient comparison of large snapshots.
    /// Results are sorted by absolute change magnitude (largest changes first).
    /// Unchanged paths are filtered out at the SQL level.
    ///
    /// - Parameters:
    ///   - beforeId: The earlier snapshot ID
    ///   - afterId: The later snapshot ID
    /// - Returns: Array of Deltas sorted by |changeBytes| descending
    /// - Throws: DatabaseManager.DatabaseError if database not initialized
    func compare(beforeId: Int64, afterId: Int64) async throws -> [Delta] {
        // Delegate to DatabaseManager for SQL execution
        // Results are already sorted by SQL ORDER BY ABS(changeBytes) DESC
        return try await db.calculateDeltas(beforeId: beforeId, afterId: afterId)
    }
}
