import SwiftUI
import AppKit

/// List view showing growth grouped by category with drill-down navigation
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
            } else if selectedCategory == nil {
                // Category list view
                categoryListView
            } else {
                // Category detail view (drill-down)
                categoryDetailView
            }
        }
    }

    // MARK: - State

    @State private var selectedCategory: CategoryGrowthItem?

    // MARK: - Category List View

    private var categoryListView: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(categoryItems) { item in
                    VStack(spacing: 0) {
                        CategoryListRow(
                            item: item,
                            onTap: { selectCategory(item) }
                        )

                        // Nested big files (max 3)
                        if !item.bigItems.isEmpty {
                            ForEach(item.bigItems.prefix(3), id: \.path) { bigItem in
                                NestedBigItemRow(
                                    item: bigItem,
                                    onTap: { onTapItem(bigItem) }
                                )
                            }

                            // Show "X more" if there are more than 3 big items
                            if item.bigItems.count > 3 {
                                MoreIndicatorRow(
                                    count: item.bigItems.count - 3,
                                    onTap: { selectCategory(item) }
                                )
                            }

                            // Visual separator
                            SeparatorRow()
                        }
                    }
                }
            }
        }
        .frame(maxHeight: maxHeight)
    }

    // MARK: - Category Detail View

    private var categoryDetailView: some View {
        VStack(spacing: 0) {
            // Header with back button
            CategoryDetailHeader(
                category: selectedCategory!,
                onBack: { selectedCategory = nil }
            )

            // List of all items in this category
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(sortedItems) { item in
                        ItemRow(
                            item: item,
                            onTap: { onTapItem(item) }
                        )
                    }
                }
            }
        }
        .frame(maxHeight: maxHeight)
    }

    /// All items in the selected category, sorted by size (largest first)
    private var sortedItems: [BaselineService.GrowthItem] {
        selectedCategory?.allItems.sorted { $0.growthBytes > $1.growthBytes } ?? []
    }

    // MARK: - Actions

    private func selectCategory(_ item: CategoryGrowthItem) {
        selectedCategory = item
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

// MARK: - Category List Row

private struct CategoryListRow: View {
    let item: CategoryGrowthItem
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                // Category icon
                Image(systemName: item.category.icon)
                    .font(.system(size: 16))
                    .foregroundStyle(item.category.color ?? .secondary)
                    .frame(width: 20, height: 20)

                // Category name
                Text(item.category.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()

                // Item count
                Text("\(item.itemCount) items")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                // Growth amount
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(growthSeverityColor)

                    Text(growthText)
                        .font(.system(size: 12))
                        .foregroundStyle(growthSeverityColor)
                }
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

// MARK: - Category Detail Header

private struct CategoryDetailHeader: View {
    let category: CategoryGrowthItem
    let onBack: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Back button
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))

                    Text("Back")
                        .font(.system(size: 12))
                }
                .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)

            Spacer()

            // Category name and icon
            HStack(spacing: 6) {
                Image(systemName: category.category.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(growthSeverityColor)

                Text(category.category.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
            }

            Spacer()

            // Total growth
            Text(growthText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(growthSeverityColor)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.gray.opacity(0.05))
    }

    private var growthText: String {
        formattedBytes(category.totalGrowthBytes, prefix: "+")
    }

    private var growthSeverityColor: Color {
        let gb = Double(category.totalGrowthBytes) / 1_000_000_000
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

// MARK: - Item Row (for detail view)

private struct ItemRow: View {
    let item: BaselineService.GrowthItem
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                // File/folder icon
                Image(systemName: "doc.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(item.isBigFile ? .orange : .secondary)
                    .frame(width: 16, height: 16)

                // File name
                Text(fileName)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()

                // Size
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

// MARK: - Nested Big Item Row

private struct NestedBigItemRow: View {
    let item: BaselineService.GrowthItem
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                // Indentation spacer
                Spacer()
                    .frame(width: 32)

                // File icon
                Image(systemName: "doc.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .frame(width: 14, height: 14)

                // File name
                Text(fileName)
                    .font(.system(size: 10))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()

                // Size
                Text(sizeText)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .frame(minHeight: 24)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(hoverState ? Color.gray.opacity(0.08) : Color.clear)
            )
            .padding(.horizontal, 6)
            .padding(.leading, 32)
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
        formattedBytes(item.growthBytes, prefix: "+")
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

// MARK: - More Indicator Row

private struct MoreIndicatorRow: View {
    let count: Int
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                // Indentation spacer
                Spacer()
                    .frame(width: 32)

                Text("\(count) more")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .italic()

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .frame(minHeight: 24)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(hoverState ? Color.gray.opacity(0.08) : Color.clear)
            )
            .padding(.horizontal, 6)
            .padding(.leading, 32)
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
}

// MARK: - Separator Row

private struct SeparatorRow: View {
    var body: some View {
        Rectangle()
            .fill(Color.gray.opacity(0.15))
            .frame(height: 1)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
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
                    allItems: [
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
                    allItems: [
                        BaselineService.GrowthItem(
                            path: "/Users/test/project/node_modules",
                            growthBytes: 450_000_000,
                            currentSizeBytes: 650_000_000,
                            percentOfParent: 0.16
                        )
                    ],
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
                    allItems: [],
                    bigItems: [],
                    smallItemCount: 89,
                    smallItemTotalBytes: 1_500_000_000,
                    percentOfTotal: 0.16
                ),
                CategoryGrowthItem(
                    category: .downloads,
                    totalGrowthBytes: 850_000_000,
                    currentSizeBytes: 1_200_000_000,
                    allItems: [
                        BaselineService.GrowthItem(
                            path: "/Users/test/Downloads/installer.pkg",
                            growthBytes: 450_000_000,
                            currentSizeBytes: 450_000_000,
                            percentOfParent: 0.53
                        )
                    ],
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
