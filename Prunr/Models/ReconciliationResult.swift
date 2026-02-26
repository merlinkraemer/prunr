import Foundation

/// Result of reconciling free-space delta with detected file-level changes.
///
/// This model ties together the actual free-space delta (from volume capacity)
/// with the sum of detected category/file deltas from BaselineService.
/// The difference represents "unexplained" storage changes such as:
/// - macOS system files outside scan scope
/// - APFS snapshots
/// - Swap/VM overhead
/// - Inter-scan transient files
struct ReconciliationResult: Sendable, Equatable {
    /// Free space delta in bytes (negative means space was consumed)
    let freeSpaceDelta: Int64?

    /// Previous free space in bytes
    let previousFreeSpace: Int64?

    /// Current free space in bytes
    let currentFreeSpace: Int64?

    /// Sum of all detected file-level growth from BaselineService (positive = growth)
    let explainedDelta: Int64

    /// The difference: abs(freeSpaceDelta) - explainedDelta
    /// Represents APFS snapshots, swap, VM overhead, inter-scan transient files, etc.
    /// Nil if freeSpaceDelta is nil (legacy snapshots without freeBytes)
    let unexplainedDelta: Int64?

    /// The existing category deltas from BaselineService (unchanged)
    let categoryDeltas: [CategoryGrowthItem]

    /// Threshold for showing "Out of scope" pill in UI (10 MB)
    static let unexplainedThreshold: Int64 = 10 * 1024 * 1024

    /// Whether the unexplained delta is meaningful enough to show in UI
    var shouldShowUnexplained: Bool {
        guard let unexplained = unexplainedDelta else { 
            print("[ReconciliationResult] shouldShowUnexplained: false (unexplainedDelta is nil)")
            return false 
        }
        let result = unexplained >= Self.unexplainedThreshold
        print("[ReconciliationResult] shouldShowUnexplained: \(result) (unexplained=\(unexplained), threshold=\(Self.unexplainedThreshold))")
        return result
    }

    /// Human-readable free space delta string with direction
    var formattedFreeSpaceDelta: String? {
        guard let delta = freeSpaceDelta else { return nil }
        let absValue = abs(delta)
        let formatted = ByteCountFormatter.string(fromByteCount: absValue, countStyle: .file)
        if delta < 0 {
            return "↓ \(formatted)"
        } else if delta > 0 {
            return "↑ \(formatted)"
        } else {
            return "No change"
        }
    }

    /// Human-readable current free space
    var formattedCurrentFreeSpace: String? {
        guard let free = currentFreeSpace else { return nil }
        return ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
    }

    /// Human-readable unexplained delta
    var formattedUnexplainedDelta: String? {
        guard let unexplained = unexplainedDelta else { return nil }
        return ByteCountFormatter.string(fromByteCount: unexplained, countStyle: .file)
    }

    /// Creates an updated copy with new current free space (for real-time updates)
    func withUpdatedFreeSpace(_ newFreeSpace: Int64) -> ReconciliationResult {
        let newDelta: Int64?
        let newUnexplained: Int64?

        if let prev = previousFreeSpace {
            let delta = newFreeSpace - prev
            newDelta = delta

            let absFreeDelta = abs(delta)
            if absFreeDelta > explainedDelta {
                newUnexplained = absFreeDelta - explainedDelta
            } else {
                newUnexplained = 0
            }
        } else {
            newDelta = nil
            newUnexplained = nil
        }

        return ReconciliationResult(
            freeSpaceDelta: newDelta,
            previousFreeSpace: previousFreeSpace,
            currentFreeSpace: newFreeSpace,
            explainedDelta: explainedDelta,
            unexplainedDelta: newUnexplained,
            categoryDeltas: categoryDeltas
        )
    }
}
