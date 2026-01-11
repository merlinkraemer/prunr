import SwiftUI
import AppKit

/// List view showing growth grouped by category with expandable sections
struct CategoryGrowthListView: View {
    /// Category growth items to display
    let categoryItems: [CategoryGrowthItem]

    /// Callback when a big item is tapped (reveal in Finder)
    var onTapItem: (BaselineService.GrowthItem) -> Void = { _ in }

    /// Maximum height for the scrollable list
    var maxHeight: CGFloat = 300

    var body: some View {
        Group {
            if categoryItems.isEmpty {
                emptyStateView
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(categoryItems) { item in
                            CategorySection(
                                item: item,
                                isExpanded: expandedCategories.contains(item.id),
                                smallItemsExpanded: expandedSmallItems.contains(item.id),
                                onToggleExpand: { toggleCategory(item.id) },
                                onToggleSmallItems: { toggleSmallItems(item.id) },
                                onTapItem: onTapItem
                            )
                        }
                    }
                }
                .frame(maxHeight: maxHeight)
            }
        }
    }

    // MARK: - State

    @State private var expandedCategories: Set<String> = []
    @State private var expandedSmallItems: Set<String> = []

    // MARK: - Actions

    private func toggleCategory(_ categoryId: String) {
        if expandedCategories.contains(categoryId) {
            expandedCategories.remove(categoryId)
        } else {
            expandedCategories.insert(categoryId)
        }
    }

    private func toggleSmallItems(_ categoryId: String) {
        if expandedSmallItems.contains(categoryId) {
            expandedSmallItems.remove(categoryId)
        } else {
            expandedSmallItems.insert(categoryId)
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.1))
                    .frame(width: 64, height: 64)

                Image(systemName: "checkmark")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.green)
            }

            VStack(spacing: 4) {
                Text("No Growth Detected")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)

                Text("Create a baseline to track changes")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: maxHeight)
        .padding(.vertical, 20)
    }
}

// MARK: - Category Section

private struct CategorySection: View {
    let item: CategoryGrowthItem
    let isExpanded: Bool
    let smallItemsExpanded: Bool
    let onToggleExpand: () -> Void
    let onToggleSmallItems: () -> Void
    let onTapItem: (BaselineService.GrowthItem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Category row
            CategoryRow(
                item: item,
                isExpanded: isExpanded,
                onTap: onToggleExpand
            )

            // Expanded content
            if isExpanded {
                // Big items
                ForEach(item.bigItems) { bigItem in
                    BigItemRow(
                        item: bigItem,
                        onTap: { onTapItem(bigItem) }
                    )
                }

                // Small items collapsible row
                if item.hasSmallItems {
                    SmallItemsRow(
                        item: item,
                        isExpanded: smallItemsExpanded,
                        onTap: onToggleSmallItems
                    )

                    // Expanded small items
                    if smallItemsExpanded {
                        // Note: We don't have individual small items in CategoryGrowthItem
                        // This is deferred for future phase
                    }
                }
            }
        }
    }
}

// MARK: - Category Row

private struct CategoryRow: View {
    let item: CategoryGrowthItem
    let isExpanded: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                // Category icon
                Image(systemName: item.category.icon)
                    .font(.system(size: 16))
                    .foregroundStyle(growthSeverityColor)
                    .frame(width: 20, height: 20)

                // Category name
                Text(item.category.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()

                // Growth amount
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(growthSeverityColor)

                    Text(growthText)
                        .font(.system(size: 12))
                        .foregroundStyle(growthSeverityColor)
                }

                // Chevron
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minHeight: 32)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hoverState ? Color.gray.opacity(0.1) : Color.clear)
            )
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                hoverState = hovering
            }
        }
    }

    @State private var hoverState = false

    private var growthText: String {
        formattedBytes(item.totalGrowthBytes, prefix: "+")
    }

    private var growthSeverityColor: Color {
        let gb = Double(item.totalGrowthBytes) / 1_000_000_000
        if gb >= 5 {
            return .red
        } else if gb >= 1 {
            return .orange
        } else {
            return .green
        }
    }

    private func formattedBytes(_ bytes: Int64, prefix: String = "") -> String {
        let kb = Double(bytes) / 1_000
        let mb = kb / 1_000
        let gb = mb / 1_000

        if abs(gb) >= 1 {
            return "\(prefix)\(String(format: "%.1f", gb)) GB"
        } else if abs(mb) >= 1 {
            return "\(prefix)\(String(format: "%.0f", mb)) MB"
        } else if abs(kb) >= 1 {
            return "\(prefix)\(String(format: "%.0f", kb)) KB"
        } else {
            return "\(prefix)\(bytes) B"
        }
    }
}

// MARK: - Big Item Row

private struct BigItemRow: View {
    let item: BaselineService.GrowthItem
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                // Indent for hierarchy
                Spacer()
                    .frame(width: 24)

                // File icon
                Image(systemName: "doc.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)

                // File name
                Text(fileName)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()

                // Size with percentage
                Text(sizeText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .frame(minHeight: 28)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hoverState ? Color.gray.opacity(0.1) : Color.clear)
            )
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                hoverState = hovering
            }
        }
    }

    @State private var hoverState = false

    private var fileName: String {
        URL(fileURLWithPath: item.path).lastPathComponent
    }

    private var sizeText: String {
        let size = formattedBytes(item.growthBytes, prefix: "+")
        let percent = String(format: "%.0f%%", item.percentOfParent * 100)
        return "\(size) (\(percent))"
    }

    private func formattedBytes(_ bytes: Int64, prefix: String = "") -> String {
        let kb = Double(bytes) / 1_000
        let mb = kb / 1_000
        let gb = mb / 1_000

        if abs(gb) >= 1 {
            return "\(prefix)\(String(format: "%.1f", gb)) GB"
        } else if abs(mb) >= 1 {
            return "\(prefix)\(String(format: "%.0f", mb)) MB"
        } else if abs(kb) >= 1 {
            return "\(prefix)\(String(format: "%.0f", kb)) KB"
        } else {
            return "\(prefix)\(bytes) B"
        }
    }
}

// MARK: - Small Items Row

private struct SmallItemsRow: View {
    let item: CategoryGrowthItem
    let isExpanded: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                // Indent for hierarchy
                Spacer()
                    .frame(width: 24)

                // Small files icon
                Image(systemName: "doc.on.doc.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)

                // Count and size
                Text("\(item.smallItemCount) files < 100MB")
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)

                Spacer()

                // Total size
                Text(smallSizeText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .frame(minHeight: 28)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hoverState ? Color.gray.opacity(0.1) : Color.clear)
            )
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                hoverState = hovering
            }
        }
    }

    @State private var hoverState = false

    private var smallSizeText: String {
        formattedBytes(item.smallItemTotalBytes, prefix: "+")
    }

    private func formattedBytes(_ bytes: Int64, prefix: String = "") -> String {
        let kb = Double(bytes) / 1_000
        let mb = kb / 1_000
        let gb = mb / 1_000

        if abs(gb) >= 1 {
            return "\(prefix)\(String(format: "%.1f", gb)) GB"
        } else if abs(mb) >= 1 {
            return "\(prefix)\(String(format: "%.0f", mb)) MB"
        } else if abs(kb) >= 1 {
            return "\(prefix)\(String(format: "%.0f", kb)) KB"
        } else {
            return "\(prefix)\(bytes) B"
        }
    }
}

// MARK: - Sample Data

extension CategoryGrowthListView {
    enum PreviewData {
        static var sampleItems: [CategoryGrowthItem] {
            [
                CategoryGrowthItem(
                    category: .homebrew,
                    totalGrowthBytes: 4_100_000_000,
                    currentSizeBytes: 8_500_000_000,
                    bigItems: [
                        BaselineService.GrowthItem(
                            path: "/usr/local/Cellar/python@3.9",
                            growthBytes: 850_000_000,
                            currentSizeBytes: 1_200_000_000,
                            percentOfParent: 0.21
                        ),
                        BaselineService.GrowthItem(
                            path: "/usr/local/Cellar/node",
                            growthBytes: 650_000_000,
                            currentSizeBytes: 900_000_000,
                            percentOfParent: 0.16
                        )
                    ],
                    smallItemCount: 42,
                    smallItemTotalBytes: 2_600_000_000,
                    percentOfTotal: 0.45
                ),
                CategoryGrowthItem(
                    category: .nodeModules,
                    totalGrowthBytes: 2_800_000_000,
                    currentSizeBytes: 5_200_000_000,
                    bigItems: [
                        BaselineService.GrowthItem(
                            path: "/Users/test/project/node_modules",
                            growthBytes: 450_000_000,
                            currentSizeBytes: 650_000_000,
                            percentOfParent: 0.16
                        )
                    ],
                    smallItemCount: 156,
                    smallItemTotalBytes: 2_350_000_000,
                    percentOfTotal: 0.31
                ),
                CategoryGrowthItem(
                    category: .libraryCaches,
                    totalGrowthBytes: 1_500_000_000,
                    currentSizeBytes: 3_100_000_000,
                    bigItems: [],
                    smallItemCount: 89,
                    smallItemTotalBytes: 1_500_000_000,
                    percentOfTotal: 0.16
                ),
                CategoryGrowthItem(
                    category: .downloads,
                    totalGrowthBytes: 850_000_000,
                    currentSizeBytes: 1_200_000_000,
                    bigItems: [
                        BaselineService.GrowthItem(
                            path: "/Users/test/Downloads/installer.pkg",
                            growthBytes: 450_000_000,
                            currentSizeBytes: 450_000_000,
                            percentOfParent: 0.53
                        )
                    ],
                    smallItemCount: 8,
                    smallItemTotalBytes: 400_000_000,
                    percentOfTotal: 0.08
                )
            ]
        }
    }
}

#Preview {
    VStack {
        Text("Category Growth List")
            .font(.headline)

        Divider()

        CategoryGrowthListView(categoryItems: CategoryGrowthListView.PreviewData.sampleItems) { item in
            print("Tapped: \(item.path)")
        }
    }
    .frame(width: 320, height: 400)
    .padding()
}
