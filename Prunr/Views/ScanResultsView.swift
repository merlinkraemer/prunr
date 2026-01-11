import SwiftUI

/// DaisyDisk-style scan results view showing categories with growth bars
struct ScanResultsView: View {
    /// Deltas to display and group by category (comparison mode)
    let deltas: [Delta]

    /// Currently selected category (for navigation to detail)
    @Binding var selectedCategory: DeltaCategory?

    /// Optional comparison summary text (e.g., "Now vs 2 days ago")
    var comparisonSummary: String?

    /// Current snapshot entries for current-only mode display
    var currentSnapshotEntries: [SnapshotEntry] = []

    /// Whether we're in current-only mode (no historical data)
    var currentOnlyMode: Bool = false

    /// Grouped deltas by category
    private var groupedDeltas: [DeltaCategory: [Delta]] {
        Dictionary(grouping: deltas) { delta in
            DeltaCategory.categorize(path: delta.path)
        }
    }

    /// Categories sorted by total growth (largest first)
    private var sortedCategories: [(category: DeltaCategory, totalChange: Int64, itemCount: Int)] {
        groupedDeltas.map { (category, items) in
            let totalChange = items.reduce(0) { $0 + $1.changeBytes }
            return (category, totalChange, items.count)
        }
        .sorted { $0.totalChange > $1.totalChange }
        .filter { $0.totalChange != 0 }  // Hide categories with no change
    }

    /// Maximum change for bar scaling
    private var maxChange: Int64 {
        sortedCategories.map(\.totalChange).map { abs($0) }.max() ?? 1
    }

    /// Current-only categories (grouped snapshot entries)
    private var currentOnlyCategories: [(category: DeltaCategory, totalSize: Int64, itemCount: Int)] {
        let grouped = Dictionary(grouping: currentSnapshotEntries) { entry in
            DeltaCategory.categorize(path: entry.path)
        }
        return grouped.map { (category, entries) in
            let totalSize = entries.reduce(0) { $0 + $1.sizeBytes }
            return (category, totalSize, entries.count)
        }
        .sorted { $0.totalSize > $1.totalSize }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if currentOnlyMode {
                    // Current-only mode header
                    currentOnlyHeader

                    // Current-only category cards
                    ForEach(currentOnlyCategories, id: \.category) { item in
                        CurrentOnlyCategoryCard(
                            category: item.category,
                            totalSize: item.totalSize,
                            itemCount: item.itemCount
                        ) {
                            selectedCategory = item.category
                        }
                    }
                } else {
                    // Comparison mode
                    // Comparison summary header
                    if let summary = comparisonSummary {
                        comparisonSummaryHeader(summary)
                    }

                    // Category cards with growth bars
                    ForEach(sortedCategories, id: \.category) { item in
                        CategoryCard(
                            category: item.category,
                            totalChange: item.totalChange,
                            itemCount: item.itemCount,
                            maxChange: maxChange
                        ) {
                            selectedCategory = item.category
                        }
                    }
                }
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    /// Current-only mode header
    private var currentOnlyHeader: some View {
        HStack {
            Image(systemName: "info.circle.fill")
                .font(.caption)
                .foregroundStyle(.blue)
            Text("Current disk usage (no historical comparison)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }

    /// Comparison summary header showing what's being compared
    @ViewBuilder
    private func comparisonSummaryHeader(_ summary: String) -> some View {
        HStack {
            Image(systemName: "clock.arrow.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }
}

// MARK: - Category Card

/// Card displaying a single category's growth information
private struct CategoryCard: View {
    let category: DeltaCategory
    let totalChange: Int64
    let itemCount: Int
    let maxChange: Int64
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Icon
                Image(systemName: category.icon)
                    .font(.system(size: 20))
                    .foregroundStyle(iconColor)
                    .frame(width: 32, height: 32)

                // Name and growth info
                VStack(alignment: .leading, spacing: 4) {
                    Text(category.displayName)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    HStack(spacing: 8) {
                        Text(formattedChange)
                            .font(.subheadline)
                            .foregroundStyle(changeColor)
                        Text("·")
                            .foregroundStyle(.secondary)
                        Text("\(itemCount) item\(itemCount == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // Growth bar
                GrowthBarView(
                    changeBytes: totalChange,
                    maxBytes: maxChange
                )
                .frame(width: 80, height: 6)
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }

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

    private var changeColor: Color {
        totalChange > 0 ? .red : totalChange < 0 ? .green : .secondary
    }

    private var formattedChange: String {
        let absValue = abs(totalChange)
        let sign = totalChange > 0 ? "+" : totalChange < 0 ? "" : "±"
        return "\(sign)\(ByteCountFormatter.string(fromByteCount: absValue, countStyle: .file))"
    }
}

// MARK: - Current-Only Category Card

/// Card displaying a single category's current size (no growth/shrinkage data)
/// Used in current-only mode when only one snapshot exists
private struct CurrentOnlyCategoryCard: View {
    let category: DeltaCategory
    let totalSize: Int64
    let itemCount: Int
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Icon
                Image(systemName: category.icon)
                    .font(.system(size: 20))
                    .foregroundStyle(iconColor)
                    .frame(width: 32, height: 32)

                // Name and size info
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(category.displayName)
                            .font(.headline)
                            .foregroundStyle(.primary)

                        // "NEW" badge
                        Text("NEW")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.2))
                            .foregroundStyle(.blue)
                            .cornerRadius(4)
                    }

                    HStack(spacing: 8) {
                        Text(formattedSize)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                        Text("·")
                            .foregroundStyle(.secondary)
                        Text("\(itemCount) item\(itemCount == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }

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

    private var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }
}

#Preview {
    let sampleDeltas = [
        Delta(path: "/usr/local/Cellar/python", oldSizeBytes: 100_000_000, newSizeBytes: 150_000_000),
        Delta(path: "/usr/local/Cellar/node", oldSizeBytes: 80_000_000, newSizeBytes: 120_000_000),
        Delta(path: "/Users/test/node_modules/lodash", oldSizeBytes: nil, newSizeBytes: 50_000_000),
        Delta(path: "/Users/test/node_modules/react", oldSizeBytes: nil, newSizeBytes: 30_000_000),
        Delta(path: "/Users/test/Pictures/photo.jpg", oldSizeBytes: nil, newSizeBytes: 25_000_000),
        Delta(path: "/Users/test/Pictures/video.mp4", oldSizeBytes: nil, newSizeBytes: 500_000_000),
        Delta(path: "/Users/test/DerivedData", oldSizeBytes: 200_000_000, newSizeBytes: 400_000_000),
        Delta(path: "/Library/Caches/app", oldSizeBytes: 50_000_000, newSizeBytes: 75_000_000),
        Delta(path: "/var/lib/docker/image", oldSizeBytes: nil, newSizeBytes: 1_000_000_000),
    ]

    ScanResultsView(
        deltas: sampleDeltas,
        selectedCategory: .constant(nil)
    )
    .frame(width: 500, height: 600)
}
