import SwiftUI
import AppKit

/// List view showing inventory grouped by category with growth indicators and drill-down navigation
struct CategoryGrowthListView: View {
    private let pageTopInset: CGFloat = 2

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

    /// Shared slide coordinator (header + list use the same offset and timing).
    var drillTransitionCoordinator: DrilldownTransitionCoordinator

    /// Prepares the header strip for the same outgoing/incoming panes as the list.
    var onPrepareHeaderTransition: ((DrilldownListPane, DrilldownListPane, Bool) -> Void)?

    /// Stabilizes the header when interrupting or finishing an in-flight slide.
    var onStabilizeHeaderTransition: (() -> Void)?

    /// Commits the header to match the list after a slide completes.
    var onCompleteHeaderTransition: ((DrilldownListPane) -> Void)?

    /// Keeps the header aligned when the list jumps to current manager state (e.g. popover reopen).
    var onSyncHeaderToListPane: ((DrilldownListPane) -> Void)?

    /// Callback when an item is tapped (reveal in Finder)
    var onTapItem: (String) -> Void = { _ in }

    /// Maximum height for the scrollable list
    var maxHeight: CGFloat = 360

    @State private var isLoadingSubcategories = false
    @State private var isLoadingMoreFiles = false
    @State private var subcategoryLoadTask: Task<Void, Never>? = nil
    @State private var subcategoryLoadToken = UUID()
    @State private var displayedScreen: DrilldownListPane? = nil // nil until first appear
    @State private var activeTransition: ActiveTransition? = nil
    @State private var pageWidth: CGFloat = 0
    @State private var pendingTransition: PendingNavigationTransition? = nil
    @State private var hasInitializedDisplay = false
    @State private var loadedContributorTaskID: String? = nil
    @State private var isDataReady = false
    @State private var contributorPrefetchTask: Task<Void, Never>? = nil

    private enum NavigationDirection {
        case forward
        case backward
    }

    private struct ActiveTransition {
        let outgoing: DrilldownListPane
        let incoming: DrilldownListPane
        let direction: NavigationDirection
    }

    private struct PendingNavigationTransition {
        let from: DrilldownListPane
        let to: DrilldownListPane
        let direction: NavigationDirection
    }

    private var drilldownLevel: DrilldownListLevel {
        guard manager.isDrilledDown, manager.selectedInventoryCategory != nil else {
            return .main
        }

        if manager.isSubcategoryDrillDown, manager.selectedSubcategory != nil {
            return .files
        }

        return .subcategories
    }

    private var currentScreen: DrilldownListPane {
        DrilldownListPane(
            level: drilldownLevel,
            category: manager.selectedInventoryCategory,
            subcategory: manager.selectedSubcategory
        )
    }

    private var leftScreen: DrilldownListPane {
        if let activeTransition {
            return activeTransition.direction == .forward ? activeTransition.outgoing : activeTransition.incoming
        }
        return displayedScreen ?? currentScreen
    }

    private var rightScreen: DrilldownListPane {
        if let activeTransition {
            return activeTransition.direction == .forward ? activeTransition.incoming : activeTransition.outgoing
        }
        return displayedScreen ?? currentScreen
    }

    var body: some View {
        GeometryReader { geometry in
            let resolvedWidth = max(geometry.size.width, pageWidth)

            HStack(spacing: 0) {
                screenPage(for: leftScreen, width: resolvedWidth)
                screenPage(for: rightScreen, width: resolvedWidth)
            }
            .offset(x: drillTransitionCoordinator.slideOffset)
            .frame(width: resolvedWidth, alignment: .leading)
            .clipped()
            .onAppear {
                if geometry.size.width > 0 {
                    pageWidth = geometry.size.width
                }
                // Initialize displayedScreen on first appear without animation
                if !hasInitializedDisplay {
                    hasInitializedDisplay = true
                    displayedScreen = currentScreen
                }
                if !growingCategories.isEmpty || !stableCategories.isEmpty {
                    isDataReady = true
                }
                preloadVisibleCategoriesIfNeeded()
            }
            .onChange(of: geometry.size.width) { _, newWidth in
                guard newWidth > 0 else { return }
                pageWidth = newWidth

                guard let pendingTransition else { return }
                self.pendingTransition = nil
                startNavigationTransition(from: pendingTransition.from, to: pendingTransition.to, direction: pendingTransition.direction, width: newWidth)
            }
            .onChange(of: currentScreen) { oldValue, newValue in
                guard oldValue != newValue else { return }

                // Skip transition if we haven't initialized yet
                guard hasInitializedDisplay else {
                    displayedScreen = newValue
                    return
                }

                let sourceScreen = activeTransition?.incoming ?? displayedScreen ?? oldValue
                let direction: NavigationDirection = newValue.level.rawValue >= sourceScreen.level.rawValue ? .forward : .backward
                let resolvedWidth = geometry.size.width > 0 ? geometry.size.width : pageWidth

                guard resolvedWidth > 0 else {
                    pendingTransition = PendingNavigationTransition(from: sourceScreen, to: newValue, direction: direction)
                    return
                }

                if activeTransition != nil {
                    pendingTransition = PendingNavigationTransition(from: sourceScreen, to: newValue, direction: direction)
                    return
                }

                pendingTransition = nil
                startNavigationTransition(from: sourceScreen, to: newValue, direction: direction, width: resolvedWidth)
            }
        }
        .frame(maxHeight: maxHeight)
        .onChange(of: growingCategories.map(\.id) + stableCategories.map(\.id)) { _, categories in
            // Mark data as ready once we have content
            if !categories.isEmpty {
                isDataReady = true
            }
            preloadVisibleCategoriesIfNeeded()
        }
        .onChange(of: manager.isPopoverShown) { _, isShown in
            guard isShown else { return }
            synchronizeVisibleScreenToCurrent()
            preloadVisibleCategoriesIfNeeded()
        }
        .onChange(of: manager.isAnalyzingChanges) { _, isAnalyzing in
            guard !isAnalyzing else { return }
            preloadVisibleCategoriesIfNeeded()
        }
        .onChange(of: startupWarmupSignature) { _, _ in
            updateStartupWarmupStateIfNeeded()
        }
        .onDisappear {
            subcategoryLoadTask?.cancel()
            subcategoryLoadTask = nil
            isLoadingSubcategories = false
            contributorPrefetchTask?.cancel()
            contributorPrefetchTask = nil
            activeTransition = nil
            pendingTransition = nil
            drillTransitionCoordinator.cancelAndReset()
            manager.isDrillDownTransitionAnimating = false
            displayedScreen = currentScreen
        }
        // Always-present pre-warm — no onAppear, no flags, no async
        // Keeps all branch types materialized in the view tree permanently
        .background {
            ZStack {
                categoryListView
                if let firstCategory = GrowthCategory.allCases.first {
                    subcategoryListView(for: CategoryInventoryItem(
                        category: firstCategory,
                        currentSizeBytes: 0
                    ))
                }
                fileListView(for: nil)
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func screenView(for screen: DrilldownListPane) -> some View {
        switch screen.level {
        case .main:
            categoryListView
                .transition(.identity)
        case .subcategories:
            if let category = screen.category {
                subcategoryListView(for: category)
                    .transition(.identity)
            } else {
                Color.clear
            }
        case .files:
            fileListView(for: resolvedSubcategory(for: screen))
                .transition(.identity)
        }
    }

    private func resolvedSubcategory(for screen: DrilldownListPane) -> SubcategoryGroup? {
        guard screen.level == .files else { return screen.subcategory }

        guard let selectedSubcategory = manager.selectedSubcategory else {
            return screen.subcategory
        }

        guard let screenSubcategory = screen.subcategory else {
            return selectedSubcategory
        }

        return selectedSubcategory.id == screenSubcategory.id ? selectedSubcategory : screenSubcategory
    }

    private func screenPage(for screen: DrilldownListPane, width: CGFloat) -> some View {
        screenView(for: screen)
            .frame(width: width)
    }

    private func synchronizeVisibleScreenToCurrent() {
        drillTransitionCoordinator.cancelAndReset()

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            pendingTransition = nil
            activeTransition = nil
            displayedScreen = currentScreen
            hasInitializedDisplay = true
            manager.isDrillDownTransitionAnimating = false
        }
        onSyncHeaderToListPane?(currentScreen)
    }

    private func stabilizeInFlightNavigationIfNeeded() {
        guard let activeTransition else { return }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            displayedScreen = activeTransition.incoming
            self.activeTransition = nil
            manager.isDrillDownTransitionAnimating = false
        }
    }

    private func startNavigationTransition(
        from previousScreen: DrilldownListPane,
        to newScreen: DrilldownListPane,
        direction: NavigationDirection,
        width: CGFloat
    ) {
        let forward = direction == .forward

        drillTransitionCoordinator.performCoordinatedSlide(
            width: width,
            forward: forward,
            stabilize: {
                stabilizeInFlightNavigationIfNeeded()
                onStabilizeHeaderTransition?()
            },
            phase1: {
                manager.isDrillDownTransitionAnimating = true
                activeTransition = ActiveTransition(
                    outgoing: previousScreen,
                    incoming: newScreen,
                    direction: direction
                )
                onPrepareHeaderTransition?(previousScreen, newScreen, forward)
            },
            phase3: {
                displayedScreen = newScreen
                activeTransition = nil
                manager.isDrillDownTransitionAnimating = false
                onCompleteHeaderTransition?(newScreen)
            },
            afterTeardown: {
                guard let queued = self.pendingTransition else { return }
                self.pendingTransition = nil
                guard queued.to != displayedScreen else { return }
                startNavigationTransition(
                    from: displayedScreen ?? queued.from,
                    to: queued.to,
                    direction: queued.direction,
                    width: max(pageWidth, width)
                )
            }
        )
    }

    // MARK: - Category List View

    private var categoryListView: some View {
        Group {
            if !isDataReady && growingCategories.isEmpty && stableCategories.isEmpty {
                categoryListSkeletonView
            } else if growingCategories.isEmpty && stableCategories.isEmpty {
                emptyStateView
            } else {
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(growingCategories) { item in
                                let isReady = manager.isSubcategoryBreakdownReady(for: item.category)
                                let isPreparing = !manager.hasCompletedInitialSubcategoryWarmup &&
                                    manager.isSubcategoryBreakdownLoading(for: item.category)
                                CategoryInventoryRow(
                                    item: item,
                                    isNavigationReady: manager.hasCompletedInitialSubcategoryWarmup || isReady,
                                    isPreparing: isPreparing,
                                    isHighlightedFromBar: highlightedSegmentID == item.category.rawValue,
                                    highlightedSegmentID: $highlightedSegmentID,
                                    onTap: { selectCategory(item) }
                                )
                                .equatable()
                            }

                            ForEach(stableCategories) { item in
                                let isReady = manager.isSubcategoryBreakdownReady(for: item.category)
                                let isPreparing = !manager.hasCompletedInitialSubcategoryWarmup &&
                                    manager.isSubcategoryBreakdownLoading(for: item.category)
                                CategoryInventoryRow(
                                    item: item,
                                    isNavigationReady: manager.hasCompletedInitialSubcategoryWarmup || isReady,
                                    isPreparing: isPreparing,
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
        .transaction { $0.disablesAnimations = true }
    }

    // MARK: - Subcategory List View

    private func subcategoryListView(for category: CategoryInventoryItem) -> some View {
        let groups = manager.subcategoryGroupsByCategory[category.category] ?? []
        let isLoading = isLoadingSubcategories ||
            (manager.isSubcategoryBreakdownLoading(for: category.category) && groups.isEmpty)

        if isLoading {
            return AnyView(
                subcategorySkeletonView
                .transaction { $0.disablesAnimations = true }
            )
        }

        if groups.isEmpty {
            return AnyView(
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .foregroundStyle(.secondary)
                    Text("No files found")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: maxHeight)
                .transaction { $0.disablesAnimations = true }
            )
        }

        return AnyView(
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(groups) { group in
                        SubcategoryRow(group: group) {
                            selectSubcategory(group, category: category.category)
                        }
                    }
                }
                .padding(.top, pageTopInset)
                .padding(.bottom, pageTopInset)
            }
            .scrollIndicators(.hidden)
            .hiddenScrollIndicators()
            .frame(maxHeight: maxHeight)
            .transaction { $0.disablesAnimations = true }
        )
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
                .transaction { $0.disablesAnimations = true }
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
        let showFileSkeleton = isLoadingContributors && loadedFiles.isEmpty

        // Filter out growth contributors from the "all files" list to avoid duplicates
        let contributorPaths = Set(visibleGrowthContributors.map(\.path))
        let nonGrowthFiles = loadedFiles.filter { !contributorPaths.contains($0.path) }

        return AnyView(
            ScrollView {
                VStack(spacing: 0) {
                    if showFileSkeleton {
                        fileListSkeletonView
                    } else if loadedFiles.isEmpty && remainingCount == 0 {
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
                guard let category = selectedCategory else {
                    loadedContributorTaskID = nil
                    growthContributors = []
                    isLoadingContributors = false
                    return
                }

                if let cachedContributors = manager.cachedGrowthContributors(for: group, category: category) {
                    growthContributors = cachedContributors
                    loadedContributorTaskID = contributorTaskID
                    isLoadingContributors = false
                    return
                }

                loadedContributorTaskID = nil
                growthContributors = []
                isLoadingContributors = true
                let contributors = await manager.loadGrowthContributors(for: group, category: category)
                guard !Task.isCancelled else { return }
                growthContributors = contributors
                loadedContributorTaskID = contributorTaskID
                isLoadingContributors = false
            }
            .transaction { $0.disablesAnimations = true }
        )
    }

    private var contributorLoadingRow: some View {
        HStack(spacing: 10) {
            SkeletonBlock(width: 18, height: 18, cornerRadius: 5)

            VStack(alignment: .leading, spacing: 2) {
                SkeletonBlock(width: 136, height: 11, cornerRadius: 4)
                SkeletonBlock(width: 164, height: 9, cornerRadius: 4)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(minHeight: 34)
        .padding(.horizontal, 6)
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
        guard isDataReady else { return }
        contributorPrefetchTask?.cancel()
        contributorPrefetchTask = nil
        let needsSubcategoryLoad = !manager.isSubcategoryBreakdownReady(for: item.category)

        guard manager.hasCompletedInitialSubcategoryWarmup || !needsSubcategoryLoad else {
            manager.preloadSubcategoryBreakdowns(for: [item.category])
            return
        }

        subcategoryLoadTask?.cancel()
        let token = UUID()
        subcategoryLoadToken = token

        let groups = manager.subcategoryGroupsByCategory[item.category] ?? []
        let selectedSubcategory = needsSubcategoryLoad || item.category.supportsSubcategories
            ? nil
            : groups.first(where: { $0.subcategory == nil }) ?? groups.first
        let isSubcategoryDrillDown = !needsSubcategoryLoad && selectedSubcategory != nil

        // Suppress implicit animations from state mutations so only the
        // explicit slide animation in startNavigationTransition runs.
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            isLoadingSubcategories = needsSubcategoryLoad
            manager.selectedInventoryCategory = item
            manager.selectedSubcategory = selectedSubcategory
            manager.isDrilledDown = true
            manager.isSubcategoryDrillDown = isSubcategoryDrillDown
        }

        guard needsSubcategoryLoad else {
            subcategoryLoadTask = nil
            let groups = manager.subcategoryGroupsByCategory[item.category] ?? []
            prefetchGrowthContributors(for: groups, category: item.category)
            return
        }

        let selectedCategory = item.category
        let loadTask = Task { @MainActor in
            let groups = await manager.loadSubcategoryBreakdown(for: selectedCategory)

            guard subcategoryLoadToken == token else {
                return
            }

            if Task.isCancelled {
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) {
                    isLoadingSubcategories = false
                    subcategoryLoadTask = nil
                }
                return
            }

            guard manager.selectedInventoryCategory?.category == selectedCategory else {
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) {
                    isLoadingSubcategories = false
                    subcategoryLoadTask = nil
                }
                return
            }

            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                isLoadingSubcategories = false
                subcategoryLoadTask = nil

                if !selectedCategory.supportsSubcategories {
                    manager.selectedSubcategory = groups.first(where: { $0.subcategory == nil }) ?? groups.first
                    manager.isSubcategoryDrillDown = manager.selectedSubcategory != nil
                }
            }
            prefetchGrowthContributors(for: groups, category: selectedCategory)
        }
        subcategoryLoadTask = loadTask
    }

    private func selectSubcategory(_ group: SubcategoryGroup, category: GrowthCategory) {
        contributorPrefetchTask?.cancel()

        var transaction = Transaction()
        transaction.disablesAnimations = true

        let cached = manager.cachedGrowthContributors(for: group, category: category)

        withTransaction(transaction) {
            manager.selectedSubcategory = group
            manager.isSubcategoryDrillDown = true

            if let cached {
                growthContributors = cached
                loadedContributorTaskID = contributorTaskKey(for: group, category: category)
                isLoadingContributors = false
            } else {
                loadedContributorTaskID = nil
                growthContributors = []
                isLoadingContributors = true
            }
        }

        if cached == nil {
            contributorPrefetchTask = Task { @MainActor in
                _ = await manager.loadGrowthContributors(for: group, category: category)
            }
        }
    }

    private func prefetchGrowthContributors(for groups: [SubcategoryGroup], category: GrowthCategory) {
        contributorPrefetchTask?.cancel()
        guard !groups.isEmpty else { return }
        contributorPrefetchTask = Task { @MainActor in
            for group in groups {
                guard !Task.isCancelled else { return }
                _ = await manager.loadGrowthContributors(for: group, category: category)
            }
        }
    }

    private var visibleCategories: [CategoryInventoryItem] {
        growingCategories + stableCategories
    }

    private var startupWarmupSignature: [String] {
        visibleCategories.map { item in
            let category = item.category
            return "\(category.rawValue):\(manager.isSubcategoryBreakdownReady(for: category)):\(manager.isSubcategoryBreakdownLoading(for: category))"
        }
    }

    private func preloadVisibleCategoriesIfNeeded() {
        guard !manager.hasCompletedInitialSubcategoryWarmup else { return }
        guard !manager.isAnalyzingChanges else { return }
        let categories = visibleCategories.map(\.category)
        guard !categories.isEmpty else { return }

        guard !categories.allSatisfy({ manager.isSubcategoryBreakdownReady(for: $0) }) else {
            manager.completeInitialSubcategoryWarmup()
            return
        }

        manager.preloadSubcategoryBreakdowns(for: categories)
    }

    private func updateStartupWarmupStateIfNeeded() {
        guard !manager.hasCompletedInitialSubcategoryWarmup else { return }
        let categories = visibleCategories.map(\.category)
        guard !categories.isEmpty else { return }
        guard categories.allSatisfy({ manager.isSubcategoryBreakdownReady(for: $0) }) else { return }
        manager.completeInitialSubcategoryWarmup()
    }

    // MARK: - Empty State

    private var categoryListSkeletonView: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { _ in
                    SkeletonListRow(style: .category)
                }
            }
            .padding(.top, pageTopInset)
            .padding(.bottom, pageTopInset)
        }
        .scrollIndicators(.hidden)
        .hiddenScrollIndicators()
        .frame(maxHeight: maxHeight)
    }

    private var subcategorySkeletonView: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(0..<6, id: \.self) { _ in
                    SkeletonListRow(style: .subcategory)
                }
            }
            .padding(.top, pageTopInset)
            .padding(.bottom, pageTopInset)
        }
        .scrollIndicators(.hidden)
        .hiddenScrollIndicators()
        .frame(maxHeight: maxHeight)
    }

    private var fileListSkeletonView: some View {
        VStack(spacing: 0) {
            ForEach(0..<6, id: \.self) { _ in
                SkeletonListRow(style: .file)
            }
        }
        .padding(.top, pageTopInset)
        .padding(.bottom, pageTopInset)
    }

    private var emptyStateView: some View {
        stableEmptyStateView
    }

    private var stableEmptyStateView: some View {
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
        lhs.isNavigationReady == rhs.isNavigationReady &&
        lhs.isPreparing == rhs.isPreparing &&
        lhs.isHighlightedFromBar == rhs.isHighlightedFromBar
    }

    let item: CategoryInventoryItem
    let isNavigationReady: Bool
    let isPreparing: Bool
    let isHighlightedFromBar: Bool
    @Binding var highlightedSegmentID: String?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            rowContent
        }
        .buttonStyle(.plain)
        .disabled(!isNavigationReady)
        .opacity(isNavigationReady ? 1 : 0.78)
        .onHover { hovering in
            guard isNavigationReady else {
                hoverState = false
                return
            }
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
                }
            }
            .opacity(isPreparing ? 0.55 : 1)

            Group {
                if isPreparing {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                        .tint(.secondary)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 12, height: 12)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(minHeight: 34)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(((isNavigationReady && hoverState) || isHighlightedFromBar) ? Color.gray.opacity(0.1) : Color.clear)
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
                .frame(width: 12, height: 12)
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

struct SkeletonBlock: View {
    var width: CGFloat? = nil
    var height: CGFloat
    var cornerRadius: CGFloat = 8

    @State private var isAnimating = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color.primary.opacity(0.06),
                        Color.primary.opacity(0.11),
                        Color.primary.opacity(0.06)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(width: width, height: height)
            .opacity(isAnimating ? 0.62 : 0.92)
            .onAppear {
                guard !isAnimating else { return }
                withAnimation(.easeInOut(duration: 1.05).repeatForever(autoreverses: true)) {
                    isAnimating = true
                }
            }
    }
}

struct SkeletonListRow: View {
    enum Style {
        case category
        case subcategory
        case file
    }

    let style: Style

    var body: some View {
        HStack(spacing: 10) {
            SkeletonBlock(width: 18, height: 18, cornerRadius: 5)

            VStack(alignment: .leading, spacing: 5) {
                SkeletonBlock(width: titleWidth, height: 12, cornerRadius: 4)
                SkeletonBlock(width: subtitleWidth, height: 9, cornerRadius: 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                VStack(alignment: .trailing, spacing: 5) {
                    SkeletonBlock(width: 56, height: 11, cornerRadius: 4)
                    if trailingSubtitleWidth > 0 {
                        SkeletonBlock(width: trailingSubtitleWidth, height: 9, cornerRadius: 4)
                    }
                }

                SkeletonBlock(width: 10, height: 10, cornerRadius: 3)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(minHeight: 34)
        .padding(.horizontal, 6)
    }

    private var titleWidth: CGFloat {
        switch style {
        case .category:
            return 96
        case .subcategory:
            return 112
        case .file:
            return 138
        }
    }

    private var subtitleWidth: CGFloat {
        switch style {
        case .category:
            return 64
        case .subcategory:
            return 74
        case .file:
            return 110
        }
    }

    private var trailingSubtitleWidth: CGFloat {
        switch style {
        case .category, .subcategory:
            return 48
        case .file:
            return 0
        }
    }
}
