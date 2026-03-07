import SwiftUI

/// Finder-like file list view for a selected category
struct CategoryDetailView: View {
    /// Category filter for the displayed items
    let category: DeltaCategory

    /// All deltas to filter from
    let deltas: [Delta]

    /// Callback when back button is tapped
    let onBack: () -> Void

    /// Filtered deltas for this category, sorted by size
    private var filteredDeltas: [Delta] {
        deltas
            .filter { DeltaCategory.categorize(path: $0.path) == category }
            .sorted { ($0.newSizeBytes ?? 0) > ($1.newSizeBytes ?? 0) }
    }

    /// Total change for this category
    private var totalChange: Int64 {
        filteredDeltas.reduce(0) { $0 + $1.changeBytes }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with back button and category info
            header

            Divider()

            // File list
            if filteredDeltas.isEmpty {
                emptyState
            } else {
                fileList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            // Back button
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("Back")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Spacer()

            // Category info
            HStack(spacing: 8) {
                Image(systemName: category.icon)
                    .foregroundStyle(iconColor)
                Text(category.displayName)
                    .font(.headline)
                Text("·")
                    .foregroundStyle(.secondary)
                Text(formattedTotalChange)
                    .font(.subheadline)
                    .foregroundStyle(totalChange > 0 ? .red : totalChange < 0 ? .green : .secondary)
            }
        }
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - File List

    private var fileList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(filteredDeltas) { delta in
                    DeltaRow(delta: delta)
                    Divider()
                }
            }
        }
        .hiddenScrollIndicators()
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No items in this category")
                .font(.headline)
            Text("Items matching \(category.displayName) will appear here")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private var iconColor: Color {
        switch category {
        case .apps: return .blue
        case .packages: return .orange
        case .containers: return .purple
        case .caches: return .yellow
        case .developer: return .brown
        case .homebrew: return .cyan
        case .docker: return .blue
        case .npm: return .green
        case .media: return .pink
        case .other: return .gray
        }
    }

    private var formattedTotalChange: String {
        let absValue = abs(totalChange)
        let sign = totalChange > 0 ? "+" : totalChange < 0 ? "" : "±"
        return "\(sign)\(ByteCountFormatter.string(fromByteCount: absValue, countStyle: .file))"
    }
}

// MARK: - Delta Row

/// Single row in the file list showing delta information
private struct DeltaRow: View {
    let delta: Delta

    var body: some View {
        HStack(spacing: 12) {
            // File icon
            fileIcon
                .frame(width: 28)

            // File info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(fileName)
                        .font(.body)
                        .lineLimit(1)
                    if isNewFile {
                        newBadge
                    }
                }
                Text(parentPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Size info
            VStack(alignment: .trailing, spacing: 2) {
                Text(currentSize)
                    .font(.body)
                    .monospacedDigit()
                Text(changeInfo)
                    .font(.caption)
                    .foregroundStyle(changeColor)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .frame(minHeight: 44)
    }

    private var fileIcon: some View {
        Image(systemName: isNewFile ? "plus.circle.fill" : "doc.fill")
            .foregroundStyle(isNewFile ? .green : .secondary)
    }

    private var fileName: String {
        URL(fileURLWithPath: delta.path).lastPathComponent
    }

    private var parentPath: String {
        URL(fileURLWithPath: delta.path).deletingLastPathComponent().path
    }

    private var isNewFile: Bool {
        delta.oldSizeBytes == nil
    }

    private var currentSize: String {
        guard let size = delta.newSizeBytes else {
            return "deleted"
        }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    private var changeInfo: String {
        let absChange = abs(delta.changeBytes)
        let formatted = ByteCountFormatter.string(fromByteCount: absChange, countStyle: .file)
        if delta.changeBytes > 0 {
            return "+\(formatted)"
        } else if delta.changeBytes < 0 {
            return "-\(formatted)"
        } else {
            return "no change"
        }
    }

    private var changeColor: Color {
        delta.changeBytes > 0 ? .red : delta.changeBytes < 0 ? .green : .secondary
    }

    private var newBadge: some View {
        Text("NEW")
            .font(.caption2)
            .fontWeight(.bold)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(.green.opacity(0.2))
            .foregroundStyle(.green)
            .cornerRadius(3)
    }
}

#Preview {
    let sampleDeltas = [
        Delta(path: "/usr/local/Cellar/python/3.11", oldSizeBytes: 100_000_000, newSizeBytes: 150_000_000),
        Delta(path: "/usr/local/Cellar/node/20.0", oldSizeBytes: 80_000_000, newSizeBytes: 120_000_000),
        Delta(path: "/usr/local/Cellar/git/new", oldSizeBytes: nil, newSizeBytes: 25_000_000),
        Delta(path: "/Users/test/Pictures/video.mp4", oldSizeBytes: nil, newSizeBytes: 500_000_000),
        Delta(path: "/Users/test/Pictures/photo.jpg", oldSizeBytes: 10_000_000, newSizeBytes: 25_000_000),
    ]

    CategoryDetailView(
        category: .homebrew,
        deltas: sampleDeltas,
        onBack: {}
    )
    .frame(width: 600, height: 500)
}
