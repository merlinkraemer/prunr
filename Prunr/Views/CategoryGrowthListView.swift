import SwiftUI
import AppKit

/// List view showing inventory grouped by category with growth indicators and drill-down navigation
struct CategoryGrowthListView: View {
    /// Growing categories with active growth trends
    let growingCategories: [CategoryInventoryItem]

    /// Stable categories without growth
    let stableCategories: [CategoryInventoryItem]

    /// Supplemental rows for storage that appears in the drive bar but has no category drill-down
    let supplementalItems: [SupplementalInventoryItem]

    /// Total size of all stable categories
    let stableTotalBytes: Int64

    /// Menu bar manager for drill-down state tracking
    @Bindable var manager: MenuBarManager

    /// Shared hover state between the list and the drive bar
    @Binding var highlightedSegmentID: String?

    /// Callback when an item is tapped (reveal in Finder)
    var onTapItem: (String) -> Void = { _ in }

    /// Maximum height for the scrollable list
    var maxHeight: CGFloat = 360

    @State private var isLoadingSubcategories = false
    @State private var isLoadingMoreFiles = false
    @State private var subcategoryLoadTask: Task<Void, Never>? = nil
    @State private var subcategoryLoadToken = UUID()
    @State private var transitionDirection: NavigationDirection = .forward

    private enum DrilldownLevel: Int {
        case main
        case subcategories
        case files
    }

    private enum NavigationDirection {
        case forward
        case backward
    }

    private var drilldownLevel: DrilldownLevel {
        guard manager.isDrilledDown, manager.selectedInventoryCategory != nil else {
            return .main
        }

        if manager.isSubcategoryDrillDown, manager.selectedSubcategory != nil {
            return .files
        }

        return .subcategories
    }

    var body: some View {
        ZStack {
            currentLevelView
                .id(viewIdentity)
                .transition(transitionForCurrentDirection)
        }
        .clipped()
        .animation(.snappy(duration: 0.22, extraBounce: 0), value: viewIdentity)
        .onChange(of: drilldownLevel) { oldValue, newValue in
            guard oldValue != newValue else { return }
            transitionDirection = newValue.rawValue >= oldValue.rawValue ? .forward : .backward
        }
        .onChange(of: growingCategories.map(\.id) + stableCategories.map(\.id)) { _, _ in
            if manager.isDrilledDown, manager.selectedInventoryCategory == nil {
                manager.isDrilledDown = false
                manager.isSubcategoryDrillDown = false
                manager.selectedSubcategory = nil
            }
        }
    }

    @ViewBuilder
    private var currentLevelView: some View {
        switch drilldownLevel {
        case .main:
            categoryListView

        case .subcategories:
            if let selected = manager.selectedInventoryCategory {
                subcategoryListView(for: selected)
            }

        case .files:
            fileListView
        }
    }

    private var viewIdentity: String {
        switch drilldownLevel {
        case .main:
            return "main"
        case .subcategories:
            return "subcategories-\(manager.selectedInventoryCategory?.id.rawValue ?? "none")"
        case .files:
            return "files-\(manager.selectedSubcategory?.id.uuidString ?? "none")"
        }
    }

    private var transitionForCurrentDirection: AnyTransition {
        let distance: CGFloat = 18

        switch transitionDirection {
        case .forward:
            return .asymmetric(
                insertion: .offset(x: distance).combined(with: .opacity),
                removal: .offset(x: -distance).combined(with: .opacity)
            )
        case .backward:
            return .asymmetric(
                insertion: .offset(x: -distance).combined(with: .opacity),
                removal: .offset(x: distance).combined(with: .opacity)
            )
        }
    }

    // MARK: - Category List View

    private var categoryListView: some View {
        Group {
            if growingCategories.isEmpty && stableCategories.isEmpty {
                emptyStateView
            } else {
                VStack(spacing: 0) {
                    // Main categories - scrollable
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(growingCategories) { item in
                                CategoryInventoryRow(
                                    item: item,
                                    showsStableBadge: false,
                                    isHighlightedFromBar: highlightedSegmentID == item.category.rawValue,
                                    highlightedSegmentID: $highlightedSegmentID,
                                    onTap: { selectCategory(item) }
                                )
                                .equatable()
                            }

                            ForEach(stableCategories) { item in
                                CategoryInventoryRow(
                                    item: item,
                                    showsStableBadge: true,
                                    isHighlightedFromBar: highlightedSegmentID == item.category.rawValue,
                                    highlightedSegmentID: $highlightedSegmentID,
                                    onTap: { selectCategory(item) }
                                )
                                .equatable()
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .frame(maxHeight: maxHeight - 36) // Reserve space for supplemental item

                    // Supplemental items - fixed at bottom
                    ForEach(supplementalItems) { item in
                        SupplementalInventoryRow(
                            item: item,
                            isHighlightedFromBar: highlightedSegmentID == item.id,
                            highlightedSegmentID: $highlightedSegmentID
                        )
                    }
                }
            }
        }
    }

    // MARK: - Subcategory List View

    private func subcategoryListView(for category: CategoryInventoryItem) -> some View {
        let groups = manager.subcategoryGroupsByCategory[category.category] ?? []

        return Group {
            if isLoadingSubcategories {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Loading \(category.category.displayName.lowercased()) breakdown…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: maxHeight)
            } else if groups.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .foregroundStyle(.secondary)
                    Text("No files found")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: maxHeight)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(groups) { group in
                            SubcategoryRow(group: group) {
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    manager.selectedSubcategory = group
                                    manager.isSubcategoryDrillDown = true
                                }
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(maxHeight: maxHeight)
            }
        }
    }

    // MARK: - File List View

    private var fileListView: some View {
        // Always read from manager.selectedSubcategory to get the latest state
        guard let group = manager.selectedSubcategory else {
            return AnyView(
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text("No folder selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: maxHeight)
            )
        }

        let bigFiles = group.topFiles.filter { $0.currentSizeBytes >= bigFileThreshold }
        let bigBytes = bigFiles.reduce(Int64(0)) { $0 + $1.currentSizeBytes }
        let smallCount = max(0, group.fileCount - bigFiles.count)
        let smallBytes = max(0, group.totalBytes - bigBytes)
        let hasMoreFiles = group.hasMoreFiles
        let canLoadMore = hasMoreFiles && group.loadedFileCount < SubcategoryGroup.maxLoadableFiles

        return AnyView(
            ScrollView {
                VStack(spacing: 0) {
                    if bigFiles.isEmpty && smallCount == 0 {
                        VStack(spacing: 8) {
                            Image(systemName: "tray")
                                .foregroundStyle(.secondary)
                            Text("No files found")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 120)
                        .padding(.top, 12)
                    } else {
                        ForEach(bigFiles) { item in
                            Button {
                                onTapItem(item.path)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "doc.fill")
                                        .font(.system(size: 14))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 18)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(URL(fileURLWithPath: item.path).lastPathComponent)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text(item.path)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }

                                    Spacer()

                                    Text(formattedBytes(item.currentSizeBytes))
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.primary)
                                        .fixedSize()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .frame(minHeight: 34)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 6)
                        }

                        if smallCount > 0 {
                            HStack(spacing: 10) {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18)

                                Text("\(smallCount) files under 100MB")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)

                                Spacer()

                                Text(formattedBytes(smallBytes))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .frame(minHeight: 34)
                            .padding(.horizontal, 6)
                        }
                        
                        // Load More button
                        if canLoadMore {
                            loadMoreButton(totalFiles: group.fileCount)
                        } else if hasMoreFiles {
                            // Show "max reached" message if there are more files but we hit the limit
                            maxFilesReachedView(loadedCount: group.loadedFileCount)
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: maxHeight)
        )
    }
    
    // MARK: - Load More Button
    
    private func loadMoreButton(totalFiles: Int) -> some View {
        Button {
            Task {
                // Read the current group from manager at button press time
                guard let currentGroup = manager.selectedSubcategory else { return }
                isLoadingMoreFiles = true
                _ = await manager.loadMoreFiles(for: currentGroup)
                isLoadingMoreFiles = false
            }
        } label: {
            HStack(spacing: 8) {
                if isLoadingMoreFiles {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 14))
                }
                
                // Read remaining count from current manager state
                let remaining = manager.selectedSubcategory.map { totalFiles - $0.loadedFileCount } ?? 0
                Text("Load more (\(remaining) remaining)")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .disabled(isLoadingMoreFiles)
        .padding(.horizontal, 6)
        .padding(.top, 8)
    }
    
    // MARK: - Max Files Reached View
    
    private func maxFilesReachedView(loadedCount: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
            Text("Showing \(loadedCount) of \(SubcategoryGroup.maxLoadableFiles) max files")
                .font(.system(size: 11))
        }
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
    }

    // MARK: - Actions

    private func selectCategory(_ item: CategoryInventoryItem) {
        subcategoryLoadTask?.cancel()
        let token = UUID()
        subcategoryLoadToken = token
        manager.selectedInventoryCategory = item
        manager.selectedSubcategory = nil
        manager.isDrilledDown = true
        manager.isSubcategoryDrillDown = false
        isLoadingSubcategories = true

        let selectedCategory = item.category
        let loadTask = Task { @MainActor in
            let groups = await manager.loadSubcategoryBreakdown(for: selectedCategory)

            guard subcategoryLoadToken == token else {
                return
            }

            if Task.isCancelled {
                isLoadingSubcategories = false
                subcategoryLoadTask = nil
                return
            }

            guard manager.selectedInventoryCategory?.category == selectedCategory else {
                isLoadingSubcategories = false
                subcategoryLoadTask = nil
                return
            }

            isLoadingSubcategories = false
            subcategoryLoadTask = nil

            if !selectedCategory.supportsSubcategories {
                manager.selectedSubcategory = groups.first(where: { $0.subcategory == nil }) ?? groups.first
                manager.isSubcategoryDrillDown = true
            }
        }
        subcategoryLoadTask = loadTask
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
                Text("Your disk is stable")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)

                Text("Nothing significant has changed recently")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: maxHeight)
        .padding(.vertical, 20)
    }

    // MARK: - Helper Methods

    private func formattedBytes(_ bytes: Int64) -> String {
        let kb = Double(bytes) / 1_000
        let mb = kb / 1_000
        let gb = mb / 1_000

        if abs(gb) >= 1 {
            return "\(String(format: "%.1f", gb)) GB"
        } else if abs(mb) >= 1 {
            return "\(String(format: "%.0f", mb)) MB"
        } else if abs(kb) >= 1 {
            return "\(String(format: "%.0f", kb)) KB"
        } else {
            return "\(bytes) B"
        }
    }
}

// MARK: - Category Inventory Row

private struct CategoryInventoryRow: View, Equatable {
    static func == (lhs: CategoryInventoryRow, rhs: CategoryInventoryRow) -> Bool {
        lhs.item.id == rhs.item.id &&
        lhs.item.currentSizeBytes == rhs.item.currentSizeBytes &&
        lhs.item.growthTrend == rhs.item.growthTrend &&
        lhs.showsStableBadge == rhs.showsStableBadge &&
        lhs.isHighlightedFromBar == rhs.isHighlightedFromBar
    }

    let item: CategoryInventoryItem
    let showsStableBadge: Bool
    let isHighlightedFromBar: Bool
    @Binding var highlightedSegmentID: String?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            rowContent
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                hoverState = hovering
                highlightedSegmentID = hovering ? item.category.rawValue : nil
            }
        }
    }

    @State private var hoverState = false

    private var rowContent: some View {
        HStack(spacing: 10) {
            Image(systemName: item.category.icon)
                .font(.system(size: 16))
                .foregroundStyle(item.category.color)
                .frame(width: 20, height: 20)

            Text(item.category.displayName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 2) {
                Text(formattedBytes(item.currentSizeBytes))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .fixedSize()

                if let trend = item.growthTrend {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .semibold))
                        Text("+\(formattedBytes(trend.growthBytes)) · \(trend.growthSpanDays)d")
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color.orange.opacity(0.12))
                    )
                } else if showsStableBadge {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Stable")
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color.green.opacity(0.12))
                    )
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(minHeight: 36)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill((hoverState || isHighlightedFromBar) ? Color.gray.opacity(0.1) : Color.clear)
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        let kb = Double(bytes) / 1_000
        let mb = kb / 1_000
        let gb = mb / 1_000

        if abs(gb) >= 1 {
            return "\(String(format: "%.1f", gb)) GB"
        } else if abs(mb) >= 1 {
            return "\(String(format: "%.0f", mb)) MB"
        } else if abs(kb) >= 1 {
            return "\(String(format: "%.0f", kb)) KB"
        } else {
            return "\(bytes) B"
        }
    }
}

private struct SupplementalInventoryRow: View {
    let item: SupplementalInventoryItem
    let isHighlightedFromBar: Bool
    @Binding var highlightedSegmentID: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon)
                .font(.system(size: 14))
                .foregroundStyle(.tertiary)
                .frame(width: 18, height: 18)

            Text(item.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 2) {
                Text(formattedBytes(item.currentSizeBytes))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(minHeight: 28)
        .background(Color.clear) // No hover effect
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        let kb = Double(bytes) / 1_000
        let mb = kb / 1_000
        let gb = mb / 1_000

        if abs(gb) >= 1 {
            return "\(String(format: "%.1f", gb)) GB"
        } else if abs(mb) >= 1 {
            return "\(String(format: "%.0f", mb)) MB"
        } else if abs(kb) >= 1 {
            return "\(String(format: "%.0f", kb)) KB"
        } else {
            return "\(bytes) B"
        }
    }
}

private struct SubcategoryRow: View {
    let group: SubcategoryGroup
    let onTap: () -> Void

    @State private var hoverState = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: group.subcategory?.icon ?? "folder.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)

                Text(group.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(formattedBytes(group.totalBytes))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .fixedSize()

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(minHeight: 34)
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

    private func formattedBytes(_ bytes: Int64) -> String {
        let kb = Double(bytes) / 1_000
        let mb = kb / 1_000
        let gb = mb / 1_000

        if abs(gb) >= 1 {
            return "\(String(format: "%.1f", gb)) GB"
        } else if abs(mb) >= 1 {
            return "\(String(format: "%.0f", mb)) MB"
        } else if abs(kb) >= 1 {
            return "\(String(format: "%.0f", kb)) KB"
        } else {
            return "\(bytes) B"
        }
    }
}

#Preview {
    Text("Preview requires MenuBarManager")
        .frame(width: 320, height: 400)
}
