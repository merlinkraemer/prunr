import SwiftUI
import AppKit

/// List view showing inventory grouped by category with growth indicators and drill-down navigation
struct CategoryGrowthListView: View {
    private let pageTopInset: CGFloat = 6

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
    @State private var navigationTask: Task<Void, Never>? = nil
    @State private var transitionDirection: NavigationDirection = .forward
    @State private var displayedScreen: DrilldownScreen? = nil // nil until first appear
    @State private var outgoingScreen: DrilldownScreen? = nil
    @State private var pageOffset: CGFloat = 0
    @State private var pageWidth: CGFloat = 0
    @State private var pendingTransition: PendingNavigationTransition? = nil
    @State private var hasInitializedDisplay = false
    @State private var loadedContributorTaskID: String? = nil

    private enum DrilldownLevel: Int {
        case main
        case subcategories
        case files
    }

    private enum NavigationDirection {
        case forward
        case backward
    }

    private struct PendingNavigationTransition {
        let from: DrilldownScreen
        let to: DrilldownScreen
        let direction: NavigationDirection
    }

    private struct DrilldownScreen: Equatable {
        let level: DrilldownLevel
        let category: CategoryInventoryItem?
        let subcategory: SubcategoryGroup?

        static let main = DrilldownScreen(level: .main, category: nil, subcategory: nil)

        static func == (lhs: DrilldownScreen, rhs: DrilldownScreen) -> Bool {
            lhs.id == rhs.id
        }

        var id: String {
            switch level {
            case .main:
                return "main"
            case .subcategories:
                return "subcategories-\(category?.category.rawValue ?? "none")"
            case .files:
                return "files-\(category?.category.rawValue ?? "none")-\(subcategory?.id ?? "none")"
            }
        }
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

    private var currentScreen: DrilldownScreen {
        DrilldownScreen(
            level: drilldownLevel,
            category: manager.selectedInventoryCategory,
            subcategory: manager.selectedSubcategory
        )
    }

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let outgoingScreen {
                    slidingPages(width: geometry.size.width, outgoingScreen: outgoingScreen)
                } else if let displayed = displayedScreen {
                    screenPage(for: displayed, width: geometry.size.width)
                } else {
                    // Placeholder while initializing
                    screenPage(for: currentScreen, width: geometry.size.width)
                }
            }
            .clipped()
            .onAppear {
                pageWidth = geometry.size.width
                // Initialize displayedScreen on first appear without animation
                if !hasInitializedDisplay {
                    hasInitializedDisplay = true
                    displayedScreen = currentScreen
                }
            }
            .onChange(of: geometry.size.width) { _, newWidth in
                guard newWidth > 0 else { return }
                pageWidth = newWidth

                guard let pendingTransition else { return }
                self.pendingTransition = nil
                transitionDirection = pendingTransition.direction
                startNavigationTransition(from: pendingTransition.from, to: pendingTransition.to, width: newWidth)
            }
            .onChange(of: currentScreen) { oldValue, newValue in
                guard oldValue != newValue else { return }

                // Skip transition if we haven't initialized yet
                guard hasInitializedDisplay else {
                    displayedScreen = newValue
                    return
                }

                let direction: NavigationDirection = newValue.level.rawValue >= oldValue.level.rawValue ? .forward : .backward
                transitionDirection = direction
                let resolvedWidth = geometry.size.width > 0 ? geometry.size.width : pageWidth

                guard resolvedWidth > 0 else {
                    pendingTransition = PendingNavigationTransition(from: oldValue, to: newValue, direction: direction)
                    return
                }

                pendingTransition = nil
                startNavigationTransition(from: oldValue, to: newValue, width: resolvedWidth)
            }
        }
        .frame(maxHeight: maxHeight)
        .onChange(of: growingCategories.map(\.id) + stableCategories.map(\.id)) { _, _ in
            if manager.isDrilledDown, manager.selectedInventoryCategory == nil {
                manager.isDrilledDown = false
                manager.isSubcategoryDrillDown = false
                manager.selectedSubcategory = nil
            }
        }
        .onDisappear {
            navigationTask?.cancel()
            navigationTask = nil
            outgoingScreen = nil
            pageOffset = 0
            pendingTransition = nil
        }
    }

    @ViewBuilder
    private func screenView(for screen: DrilldownScreen) -> some View {
        switch screen.level {
        case .main:
            categoryListView

        case .subcategories:
            if let category = screen.category {
                subcategoryListView(for: category)
            } else {
                Color.clear
            }

        case .files:
            fileListView(for: resolvedSubcategory(for: screen))
        }
    }

    private func resolvedSubcategory(for screen: DrilldownScreen) -> SubcategoryGroup? {
        guard screen.level == .files else { return screen.subcategory }

        guard let selectedSubcategory = manager.selectedSubcategory else {
            return screen.subcategory
        }

        guard let screenSubcategory = screen.subcategory else {
            return selectedSubcategory
        }

        return selectedSubcategory.id == screenSubcategory.id ? selectedSubcategory : screenSubcategory
    }

    private func screenPage(for screen: DrilldownScreen, width: CGFloat) -> some View {
        screenView(for: screen)
            .frame(width: width)
            .id(screen.id)
    }

    @ViewBuilder
    private func slidingPages(width: CGFloat, outgoingScreen: DrilldownScreen) -> some View {
        HStack(spacing: 0) {
            if transitionDirection == .forward {
                screenPage(for: outgoingScreen, width: width)
                screenPage(for: displayedScreen ?? currentScreen, width: width)
            } else {
                screenPage(for: displayedScreen ?? currentScreen, width: width)
                screenPage(for: outgoingScreen, width: width)
            }
        }
        .offset(x: pageOffset)
    }

    private func startNavigationTransition(from previousScreen: DrilldownScreen, to newScreen: DrilldownScreen, width: CGFloat) {
        navigationTask?.cancel()

        guard width > 0 else {
            outgoingScreen = nil
            displayedScreen = newScreen
            pageOffset = 0
            return
        }

        let direction = transitionDirection
        displayedScreen = newScreen
        outgoingScreen = previousScreen
        pageOffset = direction == .forward ? 0 : -width

        navigationTask = Task { @MainActor in
            withAnimation(.snappy(duration: 0.28, extraBounce: 0)) {
                pageOffset = direction == .forward ? -width : 0
            }

            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }

            outgoingScreen = nil
            pageOffset = 0
        }
    }

    // MARK: - Category List View

    private var categoryListView: some View {
        Group {
            if growingCategories.isEmpty && stableCategories.isEmpty {
                emptyStateView
            } else {
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(growingCategories) { item in
                                CategoryInventoryRow(
                                    item: item,
                                    isHighlightedFromBar: highlightedSegmentID == item.category.rawValue,
                                    highlightedSegmentID: $highlightedSegmentID,
                                    onTap: { selectCategory(item) }
                                )
                                .equatable()
                            }

                            ForEach(stableCategories) { item in
                                CategoryInventoryRow(
                                    item: item,
                                    isHighlightedFromBar: highlightedSegmentID == item.category.rawValue,
                                    highlightedSegmentID: $highlightedSegmentID,
                                    onTap: { selectCategory(item) }
                                )
                                .equatable()
                            }
                        }
                        .padding(.top, pageTopInset)
                        .padding(.bottom, supplementalItems.isEmpty ? pageTopInset : 0)
                    }
                    .scrollIndicators(.hidden)
                    .hiddenScrollIndicators()
                    .frame(maxHeight: .infinity)

                    if !supplementalItems.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(supplementalItems) { item in
                                SupplementalInventoryRow(
                                    item: item,
                                    isHighlightedFromBar: highlightedSegmentID == item.id,
                                    highlightedSegmentID: $highlightedSegmentID
                                )
                            }
                        }
                        .padding(.top, 6)
                    }
                }
                .frame(maxHeight: maxHeight, alignment: .bottom)
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
                                manager.selectedSubcategory = group
                                manager.isSubcategoryDrillDown = true
                            }
                        }
                    }
                    .padding(.top, pageTopInset)
                    .padding(.bottom, pageTopInset)
                }
                .scrollIndicators(.hidden)
                .hiddenScrollIndicators()
                .frame(maxHeight: maxHeight)
            }
        }
    }

    @State private var growthContributors: [GrowthContributor] = []
    @State private var isLoadingContributors = false

    // MARK: - File List View

    private func fileListView(for group: SubcategoryGroup?) -> some View {
        guard let group else {
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

        let loadedFiles = group.topFiles.sorted { $0.currentSizeBytes > $1.currentSizeBytes }
        let loadedBytes = loadedFiles.reduce(Int64(0)) { $0 + $1.currentSizeBytes }
        let remainingCount = max(0, group.fileCount - loadedFiles.count)
        let remainingBytes = max(0, group.totalBytes - loadedBytes)
        let hasMoreFiles = group.hasMoreFiles
        let canLoadMore = hasMoreFiles && group.loadedFileCount < SubcategoryGroup.maxLoadableFiles
        let selectedCategory = manager.selectedInventoryCategory?.category
        let contributorTaskID = selectedCategory.map {
            contributorTaskKey(for: group, category: $0)
        } ?? "contributors-\(group.id)"
        let visibleGrowthContributors = loadedContributorTaskID == contributorTaskID ? growthContributors : []

        // Filter out growth contributors from the "all files" list to avoid duplicates
        let contributorPaths = Set(visibleGrowthContributors.map(\.path))
        let nonGrowthFiles = loadedFiles.filter { !contributorPaths.contains($0.path) }

        return AnyView(
            ScrollView {
                VStack(spacing: 0) {
                    if loadedFiles.isEmpty && remainingCount == 0 {
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
                        // Growth contributors section
                        if !visibleGrowthContributors.isEmpty {
                            ForEach(visibleGrowthContributors) { contributor in
                                DrilldownGrowthRow(contributor: contributor, onTap: {
                                    onTapItem(contributor.path)
                                })
                            }

                            // Visual separator between growth and all files
                            HStack {
                                Rectangle()
                                    .fill(Color.primary.opacity(0.06))
                                    .frame(height: 1)
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 4)
                        }

                        // All files section
                        ForEach(nonGrowthFiles) { item in
                            DrilldownFileRow(item: item, onTap: {
                                onTapItem(item.path)
                            })
                        }

                        if remainingCount > 0 {
                            HStack(spacing: 10) {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(remainingCount) more files not loaded")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.secondary)

                                    Text("Load more to page in the next batch")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                }

                                Spacer()

                                Text(formattedBytes(remainingBytes))
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
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
                .padding(.top, pageTopInset)
                .padding(.bottom, pageTopInset)
            }
            .scrollIndicators(.hidden)
            .hiddenScrollIndicators()
            .frame(maxHeight: maxHeight)
            .task(id: contributorTaskID) {
                loadedContributorTaskID = nil
                growthContributors = []
                guard let category = selectedCategory else {
                    isLoadingContributors = false
                    return
                }
                isLoadingContributors = true
                let contributors = await manager.loadGrowthContributors(for: group, category: category)
                guard !Task.isCancelled else { return }
                growthContributors = contributors
                loadedContributorTaskID = contributorTaskID
                isLoadingContributors = false
            }
        )
    }

    private func contributorTaskKey(for group: SubcategoryGroup, category: GrowthCategory) -> String {
        [
            "contributors",
            String(manager.growthContributorCacheGeneration),
            category.rawValue,
            group.id
        ].joined(separator: ":")
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
        let needsSubcategoryLoad = manager.subcategoryGroupsByCategory[item.category] == nil

        isLoadingSubcategories = needsSubcategoryLoad

        manager.selectedInventoryCategory = item
        manager.selectedSubcategory = nil
        manager.isDrilledDown = true
        manager.isSubcategoryDrillDown = false

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

}

// MARK: - Category Inventory Row

private struct CategoryInventoryRow: View, Equatable {
    static func == (lhs: CategoryInventoryRow, rhs: CategoryInventoryRow) -> Bool {
        lhs.item.id == rhs.item.id &&
        lhs.item.currentSizeBytes == rhs.item.currentSizeBytes &&
        lhs.item.recentGrowthStory == rhs.item.recentGrowthStory &&
        lhs.item.growthTrend == rhs.item.growthTrend &&
        lhs.isHighlightedFromBar == rhs.isHighlightedFromBar
    }

    let item: CategoryInventoryItem
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
                .font(.system(size: 15))
                .foregroundStyle(item.category.color)
                .frame(width: 18, height: 18)

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

                if let story = item.recentGrowthStory {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .semibold))
                        Text("+\(formattedBytes(story.deltaBytes)) · \(story.displayLabel)")
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
                } else if let trend = item.growthTrend {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .semibold))
                        Text("+\(formattedBytes(trend.growthBytes)) · \(trend.growthSpanDays)d")
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(minHeight: 34)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill((hoverState || isHighlightedFromBar) ? Color.gray.opacity(0.1) : Color.clear)
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }

}

private struct SupplementalInventoryRow: View {
    let item: SupplementalInventoryItem
    let isHighlightedFromBar: Bool
    @Binding var highlightedSegmentID: String?

    @State private var hoverState = false

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
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill((hoverState || isHighlightedFromBar) ? Color.gray.opacity(0.1) : Color.clear)
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                hoverState = hovering
                highlightedSegmentID = hovering ? item.id : nil
            }
        }
    }

}

private struct DrilldownFileRow: View {
    let item: GrowthItem
    let onTap: () -> Void

    @State private var hoverState = false

    private var isLargeFile: Bool {
        item.currentSizeBytes >= bigFileThreshold
    }

    private var parentPath: String {
        let fileURL = URL(fileURLWithPath: item.path)
        let path = fileURL.deletingLastPathComponent().path
        return (path as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: isLargeFile ? "doc.fill" : "doc")
                    .font(.system(size: 14))
                    .foregroundStyle(isLargeFile ? .secondary : .tertiary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(URL(fileURLWithPath: item.path).lastPathComponent)
                        .font(.system(size: 12, weight: isLargeFile ? .medium : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(parentPath)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                Text(formattedBytes(item.currentSizeBytes))
                    .font(.system(size: isLargeFile ? 11 : 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(isLargeFile ? .secondary : .tertiary)
                    .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(minHeight: 34)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(hoverState ? Color.gray.opacity(0.1) : Color.clear)
            )
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.path)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                hoverState = hovering
            }
        }
    }

}

private struct DrilldownGrowthRow: View {
    let contributor: GrowthContributor
    let onTap: () -> Void

    @State private var hoverState = false

    private var fileName: String {
        URL(fileURLWithPath: contributor.path).lastPathComponent
    }

    private var parentPath: String {
        let fileURL = URL(fileURLWithPath: contributor.path)
        let path = fileURL.deletingLastPathComponent().path
        return (path as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: "doc.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.orange)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(fileName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(parentPath)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(formattedBytes(contributor.currentSizeBytes))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary)
                        .fixedSize()

                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 8, weight: .semibold))
                        Text("+\(formattedBytes(contributor.growthBytes))")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(minHeight: 34)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(hoverState ? Color.gray.opacity(0.1) : Color.clear)
            )
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(contributor.path)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                hoverState = hovering
            }
        }
    }

}

private struct SubcategoryRow: View {
    let group: SubcategoryGroup
    let onTap: () -> Void

    @State private var hoverState = false

    private var positiveGrowthBytes: Int64? {
        guard let growthBytes = group.growthBytes, growthBytes > 0 else {
            return nil
        }

        return growthBytes
    }

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

                VStack(alignment: .trailing, spacing: 2) {
                    Text(formattedBytes(group.totalBytes))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize()

                    if let positiveGrowthBytes {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 8, weight: .semibold))
                            Text("+\(formattedBytes(positiveGrowthBytes))")
                        }
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.orange)
                    }
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(minHeight: 34)
            .background(
                RoundedRectangle(cornerRadius: 8)
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

}

#Preview {
    Text("Preview requires MenuBarManager")
        .frame(width: 320, height: 400)
}
