import SwiftUI

/// A row displaying a single delta (size change) between snapshots
struct DeltaRowView: View {
    let delta: Delta

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                // Path (truncated from left if too long)
                Text(truncatedPath)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)

                // Old → New size on secondary line
                if let oldSize = delta.oldSizeBytes, let newSize = delta.newSizeBytes {
                    Text("\(formatBytes(oldSize)) → \(formatBytes(newSize))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                // Change amount with color coding
                Text(formattedChange)
                    .font(.body.weight(.semibold).monospaced())
                    .foregroundStyle(changeColor)

                // Percentage change
                if let percent = delta.percentChange {
                    Text(formattedPercent(percent))
                        .font(.caption)
                        .foregroundStyle(changeColor.opacity(0.8))
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Computed Properties

    /// Path truncated from left with ellipsis if too long
    private var truncatedPath: String {
        let maxLength = 50
        if delta.path.count <= maxLength {
            return delta.path
        }
        // Truncate from left, keep last maxLength characters
        let startIndex = delta.path.index(delta.path.endIndex, offsetBy: -maxLength)
        return "…" + String(delta.path[startIndex...])
    }

    /// Formatted change with sign prefix
    private var formattedChange: String {
        let absBytes = abs(delta.changeBytes)
        let formatted = formatBytes(absBytes)
        if delta.isGrowth {
            return "+\(formatted)"
        } else if delta.isShrinkage {
            return "-\(formatted)"
        }
        return formatted
    }

    /// Color based on growth/shrinkage
    private var changeColor: Color {
        if delta.isGrowth {
            return .green
        } else if delta.isShrinkage {
            return .red
        }
        return .secondary
    }

    // MARK: - Helpers

    /// Format bytes using ByteCountFormatter with file style
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        return formatter.string(fromByteCount: bytes)
    }

    /// Format percentage with sign
    private func formattedPercent(_ value: Double) -> String {
        let sign = value >= 0 ? "+" : ""
        return String(format: "%@%.1f%%", sign, value)
    }
}

// MARK: - Preview

#Preview {
    List {
        DeltaRowView(delta: Delta(
            path: "/Users/demo/Documents/LargeFolder",
            oldSizeBytes: 1_000_000_000,
            newSizeBytes: 1_500_000_000
        ))

        DeltaRowView(delta: Delta(
            path: "/Users/demo/Library/Caches/SomeApp/very/long/nested/path/to/cache/folder",
            oldSizeBytes: 500_000_000,
            newSizeBytes: 200_000_000
        ))

        DeltaRowView(delta: Delta(
            path: "/Users/demo/Downloads/NewFile",
            oldSizeBytes: nil,
            newSizeBytes: 100_000_000
        ))

        DeltaRowView(delta: Delta(
            path: "/Users/demo/Trash/Deleted",
            oldSizeBytes: 250_000_000,
            newSizeBytes: nil
        ))
    }
}
