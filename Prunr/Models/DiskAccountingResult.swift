import Foundation

/// Result of disk accounting that ties together free-space tracking with scan coverage.
///
/// This model tracks free space changes and provides diagnostics for accounting
/// discrepancies such as:
/// - macOS system files outside scan scope
/// - APFS snapshots
/// - Swap/VM overhead
/// - Inter-scan transient files
struct DiskAccountingResult: Sendable, Equatable {
    /// Free space delta in bytes (negative means space was consumed)
    let freeSpaceDelta: Int64?

    /// Previous free space in bytes
    let previousFreeSpace: Int64?

    /// Current free space in bytes
    let currentFreeSpace: Int64?

    /// Sum of all detected file-level changes from BaselineService (positive = growth)
    let explainedDelta: Int64

    /// The difference between free space change and explained changes
    /// Represents APFS snapshots, swap, VM overhead, inter-scan transient files, etc.
    /// Nil if freeSpaceDelta is nil (legacy snapshots without freeBytes)
    let unexplainedDelta: Int64?

    /// Threshold for considering unexplained delta significant (10 MB)
    static let unexplainedThreshold: Int64 = 10 * 1024 * 1024

    /// Whether the unexplained delta is meaningful enough for diagnostics
    var shouldShowUnexplained: Bool {
        guard let unexplained = unexplainedDelta else {
            return false
        }
        return unexplained >= Self.unexplainedThreshold
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
    func withUpdatedFreeSpace(_ newFreeSpace: Int64) -> DiskAccountingResult {
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

        return DiskAccountingResult(
            freeSpaceDelta: newDelta,
            previousFreeSpace: previousFreeSpace,
            currentFreeSpace: newFreeSpace,
            explainedDelta: explainedDelta,
            unexplainedDelta: newUnexplained
        )
    }
}

// MARK: - Deprecated Type Alias

/// Deprecated: Use `DiskAccountingResult` instead
@available(*, deprecated, renamed: "DiskAccountingResult")
typealias ReconciliationResult = DiskAccountingResult
