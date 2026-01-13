import SwiftUI
import AppKit

/// Category growth items for the main menu bar view

/// List view showing growth grouped by category with drill-down navigation
struct CategoryGrowthListView: View {
    /// Category growth items to display
    let categoryItems: [CategoryGrowthItem]

    /// Menu bar manager for drill-down state tracking (ISS-037)
    @Bindable var manager: MenuBarManager

    /// Callback when a big item is tapped (reveal in Finder)
    var onTapItem: (GrowthItem) -> Void = { _ in }

    /// Maximum height for the scrollable list
    var maxHeight: CGFloat = 360 // Increased from 300 to 360 for more space

    /// Forced category from external navigation (MenuBarView drill-down)
    var forcedCategory: CategoryGrowthItem? = nil

    /// Computed selected category - uses forced category if provided, otherwise internal selection
    private var computedSelectedCategory: CategoryGrowthItem? {
        forcedCategory ?? selectedCategory
    }

    var body: some View {
        // Conditional rendering: ONLY ONE view exists at a time for proper push animation
        ZStack {
            if computedSelectedCategory == nil {
                // Main list view - exits left when category selected
                categoryListView
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading),
                        removal: .move(edge: .leading)
                    ))
            } else {
                // Detail view - enters from right, exits left on back
                categoryDetailView(for: computedSelectedCategory!)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing),
                        removal: .move(edge: .leading)
                    ))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: computedSelectedCategory)
        .onChange(of: manager.isDrilledDown) { _, newValue in
            if !newValue {
                // External back button was pressed, reset internal selection
                withAnimation(.easeInOut(duration: 0.3)) {
                    selectedCategory = nil
                }
            }
        }
    }

    // MARK: - State

    @State private var selectedCategory: CategoryGrowthItem?
    @State private var expandedFolders: Set<String> = []

    
    // MARK: - Category List View

    private var categoryListView: some View {
        Group {
            if categoryItems.isEmpty {
                emptyStateView
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(categoryItems) { item in
                            VStack(spacing: 0) {
                                CategoryListRow(
                                    item: item,
                                    onTap: {
                                        withAnimation(.easeInOut(duration: 0.3)) {
                                            selectCategory(item)
                                        }
                                    }
                                )
                                .equatable() // Prevent unnecessary redraws

                                // Nested big files (max 3)
                                if !item.bigItems.isEmpty {
                                    ForEach(Array(item.bigItems.prefix(3).enumerated()), id: \.element.path) { index, bigItem in
                                        let isLastInList = (index == min(2, item.bigItems.count - 1)) && item.bigItems.count <= 3
                                        NestedBigItemRow(
                                            item: bigItem,
                                            isLastItem: isLastInList,
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
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: maxHeight)
            }
        }
    }

    // MARK: - Category Detail View

    private func categoryDetailView(for category: CategoryGrowthItem) -> some View {
        // List of items grouped by folder (header is in MenuBarView now)
        ScrollView {
            VStack(spacing: 8) {
                ForEach(sortedFolders(for: category), id: \.path) { folder in
                    VStack(spacing: 0) {
                        // Folder header (clickable to toggle expand/collapse)
                        FolderHeaderRow(
                            folderPath: folder.path,
                            items: folder.items,
                            isExpanded: expandedFolders.contains(folder.path),
                            onToggle: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    if expandedFolders.contains(folder.path) {
                                        expandedFolders.remove(folder.path)
                                    } else {
                                        expandedFolders.insert(folder.path)
                                    }
                                }
                            }
                        )

                        // Items (only if expanded)
                        if expandedFolders.contains(folder.path) {
                            VStack(spacing: 4) {
                                ForEach(folder.items, id: \.path) { item in
                                    ItemRow(
                                        item: item,
                                        onTap: { onTapItem(item) }
                                    )
                                }
                            }
                            .padding(.top, 4)
                            .padding(.bottom, 8)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: maxHeight)
    }

    /// All items in the selected category, sorted by size (largest first)
    private func sortedItems(for category: CategoryGrowthItem) -> [GrowthItem] {
        category.allItems.sorted { $0.growthBytes > $1.growthBytes }
    }

    /// Items grouped by their parent folder path
    private func itemsGroupedByFolder(for category: CategoryGrowthItem) -> [String: [GrowthItem]] {
        Dictionary(grouping: sortedItems(for: category)) { item in
            URL(fileURLWithPath: item.path)
                .deletingLastPathComponent()
                .path
        }
    }

    /// Folders sorted by total growth (largest first)
    private func sortedFolders(for category: CategoryGrowthItem) -> [(path: String, items: [GrowthItem])] {
        itemsGroupedByFolder(for: category)
            .map { (path, items) in
                (path, items.sorted { $0.growthBytes > $1.growthBytes })
            }
            .sorted {
                $0.items.reduce(0) { $0 + $1.growthBytes } >
                $1.items.reduce(0) { $0 + $1.growthBytes }
            }
    }

    // MARK: - Actions

    private func selectCategory(_ item: CategoryGrowthItem) {
        selectedCategory = item
        manager.isDrilledDown = true // Update drill-down state (ISS-037)
        manager.selectedCategoryForDrilldown = item // Update for external navigation (ISS-043 fix)
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

/// Static column widths for consistent layout across all views
private enum ColumnWidths {
    static let count: CGFloat = 70  // Fits "9999 items" with space
    static let size: CGFloat = 90   // Fits "+999.9 GB" with arrow icon
    // Note: name column is now flexible (maxWidth: .infinity) to prevent overflow
}

private struct CategoryListRow: View, Equatable {
    static func == (lhs: CategoryListRow, rhs: CategoryListRow) -> Bool {
        lhs.item.totalGrowthBytes == rhs.item.totalGrowthBytes &&
        lhs.item.bigItems.count == rhs.item.bigItems.count
    }
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
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Growth amount (static width)
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(growthSeverityColor)

                    Text(growthText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(growthSeverityColor)
                        .fixedSize()
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

// MARK: - Folder Header Row

private struct FolderHeaderRow: View {
    let folderPath: String
    let items: [GrowthItem]
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 10) {
                // Chevron (right when collapsed, down when expanded)
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)

                // Folder icon
                Image(systemName: "folder.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.blue.opacity(0.8))
                    .frame(width: 16, height: 16)

                // Folder name (flexible width, left-aligned, more space)
                Text(folderName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Total folder growth (static width)
                Text(totalGrowthText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hoverState ? Color.gray.opacity(0.12) : Color.gray.opacity(0.06))
            )
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

    private var folderName: String {
        URL(fileURLWithPath: folderPath).lastPathComponent
    }

    private var totalGrowthText: String {
        let total = items.reduce(0) { $0 + $1.growthBytes }
        return formattedBytes(total, prefix: "+")
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
    let item: GrowthItem
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                // File/folder icon
                Image(systemName: "doc.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(item.isBigFile ? .orange : .secondary)
                    .frame(width: 16, height: 16)

                // File name (flexible width, left-aligned)
                Text(fileName)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Size with percentage
                HStack(spacing: 4) {
                    Text(sizeText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize()

                    // Percentage badge
                    if item.percentOfParent > 0 {
                        let percent = String(format: "%.0f%%", item.percentOfParent * 100)
                        Text(percent)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }
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

// MARK: - Nested Big Item Row

private struct NestedBigItemRow: View {
    let item: GrowthItem
    let isLastItem: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 0) {
                // Tree view line and indent
                ZStack {
                    // Vertical line (tree connector)
                    Rectangle()
                        .fill(Color.orange.opacity(0.25))
                        .frame(width: 1)
                        .padding(.leading, 12)
                        .frame(maxHeight: .infinity)
                        .offset(y: isLastItem ? -8 : 8)

                    // Horizontal connector
                    Rectangle()
                        .fill(Color.orange.opacity(0.25))
                        .frame(width: 8, height: 1)
                        .padding(.leading, 12)
                }
                .frame(width: 24, height: 24)

                // Content
                HStack(spacing: 8) {
                    // File icon
                    Image(systemName: "doc.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .frame(width: 14, height: 14)

                    // File name (flexible width, left-aligned)
                    Text(fileName)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    // Size
                    Text(sizeText)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(hoverState ? Color.orange.opacity(0.1) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color.orange.opacity(0.2), lineWidth: 0.5)
                )
                .padding(.trailing, 12)
            }
            .padding(.vertical, 1)
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
            HStack(spacing: 0) {
                // Tree view line and indent
                ZStack {
                    // Vertical line (tree connector)
                    Rectangle()
                        .fill(Color.orange.opacity(0.25))
                        .frame(width: 1)
                        .padding(.leading, 12)
                        .frame(maxHeight: .infinity)
                        .offset(y: 8)

                    // Horizontal connector
                    Rectangle()
                        .fill(Color.orange.opacity(0.25))
                        .frame(width: 8, height: 1)
                        .padding(.leading, 12)
                }
                .frame(width: 24, height: 24)

                // Content
                HStack(spacing: 8) {
                    // Ellipsis icon
                    Image(systemName: "ellipsis")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange.opacity(0.7))
                        .frame(width: 14, height: 14)

                    Text("\(count) more large files")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(hoverState ? Color.orange.opacity(0.08) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color.orange.opacity(0.15), lineWidth: 0.5)
                )
                .padding(.trailing, 12)
            }
            .padding(.vertical, 1)
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
                        GrowthItem(
                            path: "/usr/local/Cellar/python@3.9",
                            growthBytes: 850_000_000,
                            currentSizeBytes: 1_200_000_000,
                            percentOfParent: 0.21
                        ),
                        GrowthItem(
                            path: "/usr/local/Cellar/node",
                            growthBytes: 650_000_000,
                            currentSizeBytes: 900_000_000,
                            percentOfParent: 0.16
                        )
                    ],
                    bigItems: [
                        GrowthItem(
                            path: "/usr/local/Cellar/python@3.9",
                            growthBytes: 850_000_000,
                            currentSizeBytes: 1_200_000_000,
                            percentOfParent: 0.21
                        ),
                        GrowthItem(
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
                        GrowthItem(
                            path: "/Users/test/project/node_modules",
                            growthBytes: 450_000_000,
                            currentSizeBytes: 650_000_000,
                            percentOfParent: 0.16
                        )
                    ],
                    bigItems: [
                        GrowthItem(
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
                        GrowthItem(
                            path: "/Users/test/Downloads/installer.pkg",
                            growthBytes: 450_000_000,
                            currentSizeBytes: 450_000_000,
                            percentOfParent: 0.53
                        )
                    ],
                    bigItems: [
                        GrowthItem(
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
    // Note: Preview not available without MenuBarManager instance
    Text("Preview requires MenuBarManager")
        .frame(width: 320, height: 400)
}
