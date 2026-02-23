import SwiftUI

/// Second column: List of delta items filtered by selected category
struct ItemColumn: View {
    /// Binding to the currently selected delta item
    @Binding var selectedItem: Delta?

    /// Currently selected category filter (nil = show all)
    var selectedCategory: DeltaCategory?

    /// All deltas (filtered by category in body)
    var deltas: [Delta]

    /// Filtered deltas based on selected category
    private var filteredDeltas: [Delta] {
        guard let category = selectedCategory else {
            return deltas
        }
        return deltas.filter { DeltaCategory.categorize(path: $0.path) == category }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(headerText)
                .font(.headline)
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 8)

            if filteredDeltas.isEmpty {
                emptyState
            } else {
                List(filteredDeltas, id: \.id, selection: $selectedItem) { delta in
                    ItemRow(delta: delta)
                        .tag(delta)
                }
                .listStyle(.inset)
            }
        }
    }

    /// Header text showing category name or "All Items"
    private var headerText: String {
        if let category = selectedCategory {
            return category.displayName
        }
        return "All Items"
    }

    /// Empty state when no items match filter
    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("No items")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Row for a single delta item in the list
private struct ItemRow: View {
    let delta: Delta

    /// Smart path display: shows filename with truncated parent path
    private var displayPath: String {
        let url = URL(fileURLWithPath: delta.path)
        let filename = url.lastPathComponent
        let pathExcludingFile = url.deletingLastPathComponent().path

        // If path is short enough, show full path
        if delta.path.count <= 50 {
            return delta.path
        }

        // Show filename with some parent path context
        // Truncate the parent path to ~30 chars max
        if pathExcludingFile.count > 30 {
            let truncatedPath = "..." + pathExcludingFile.suffix(30)
            return truncatedPath + "/" + filename
        }

        return delta.path
    }

    /// Formatted size change with sign
    private var formattedChange: String {
        let absValue = abs(delta.changeBytes)
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.countStyle = .file
        let formatted = formatter.string(fromByteCount: absValue)
        return delta.isGrowth ? "+\(formatted)" : "-\(formatted)"
    }

    /// Color for size change indicator
    private var changeColor: Color {
        delta.isGrowth ? .green : .red
    }

    /// Percentage badge text
    private var percentBadge: String? {
        guard let percent = delta.percentChange else { return nil }
        return String(format: "%.0f%%", percent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Filename on its own line for better readability
            Text(URL(fileURLWithPath: delta.path).lastPathComponent)
                .font(.headline)
                .lineLimit(1)

            // Parent path (truncated)
            Text(URL(fileURLWithPath: delta.path).deletingLastPathComponent().path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack {
                // Size change with color
                Text(formattedChange)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(changeColor)

                // Percentage badge if available
                if let badge = percentBadge {
                    Text(badge)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(changeColor.opacity(0.15))
                        .foregroundStyle(changeColor)
                        .clipShape(Capsule())
                }

                Spacer()
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .help(delta.path)
    }
}

#Preview {
    ItemColumn(
        selectedItem: .constant(nil),
        selectedCategory: nil,
        deltas: [
            Delta(path: "/Users/merlinkramer/Projects/very/long/path/that/needs/truncation/file.txt", oldSizeBytes: 1000000, newSizeBytes: 1500000),
            Delta(path: "/Applications/Test.app", oldSizeBytes: 5000000, newSizeBytes: 4000000),
            Delta(path: "~/Library/Caches/app", oldSizeBytes: 100000, newSizeBytes: nil)
        ]
    )
}
