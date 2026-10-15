import SwiftUI
import AppKit

/// The categories view: storage by category, biggest first, sizes only.
/// Category → subcategories by size → files.
struct CategoryGrowthListView: View {
    private let pageTopInset: CGFloat = 2

    /// Categories by size, biggest first (`MenuBarManager.sortedCategories`).
    let categories: [CategoryInventoryItem]

    /// Supplemental rows for storage that appears in the drive bar but has no category drill-down
    let supplementalItems: [SupplementalInventoryItem]

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

    @State private var isLoadingMoreFiles = false
    @State private var displayedScreen: DrilldownListPane? = nil // nil until first appear
    @State private var activeTransition: ActiveTransition? = nil
    @State private var pageWidth: CGFloat = 0
    @State private var pendingTransition: PendingNavigationTransition? = nil
    @State private var hasInitializedDisplay = false
    @State private var isDataReady = false

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
                if !categories.isEmpty {
                    isDataReady = true
                }
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
        .onChange(of: categories.map(\.id)) { _, ids in
            // Mark data as ready once we have content
            if !ids.isEmpty {
                isDataReady = true
            }
        }
        .onChange(of: manager.isPopoverShown) { _, isShown in
            guard isShown else { return }
            synchronizeVisibleScreenToCurrent()
        }
        .onDisappear {
            activeTransition = nil
            pendingTransition = nil
            drillTransitionCoordinator.cancelAndReset()
            manager.isDrillDownTransitionAnimating = false
            displayedScreen = currentScreen
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
            fileListView(for: resolvedSubcategory(for: screen), category: screen.category?.category)
                .transition(.identity)
        }
    }

    private func resolvedSubcategory(for screen: DrilldownListPane) -> SubcategoryGroup? {
        guard screen.level == .files, let category = screen.category?.category else { return screen.subcategory }
        let shown = screen.subcategory ?? manager.selectedSubcategory
        return shown.map { manager.drilldownFileGroup($0, in: category) }
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
            if !isDataReady && categories.isEmpty {
                categoryListSkeletonView
            } else {
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(categories) { item in
                                CategoryInventoryRow(
                                    item: item,
                                    isNavigationReady: true,
                                    isPreparing: false,
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
        let groups = CategorySizes.subcategoriesBySize(manager.subcategoryGroupsByCategory[category.category] ?? [])
        let store = manager.drilldownStore

        return ScrollView {
            VStack(spacing: 0) {
                if let status = CategorySizes.groupsStatus(
                    isEmpty: groups.isEmpty,
                    isPending: store.isGroupsPending(for: category.category),
                    readFailed: store.groupsReadFailed || store.failedFileCategories.contains(category.category)
                ) {
                    InlineStatusRow(status: status, onRetry: { manager.retryDrilldownRead(for: category.category) })
                } else {
                    ForEach(groups) { group in
                        SubcategoryRow(group: group) {
                            selectSubcategory(group)
                        }
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
    }

    // MARK: - File List View

    private func fileListView(for group: SubcategoryGroup?, category: GrowthCategory?) -> some View {
        let store = manager.drilldownStore
        let files = (group?.topFiles ?? []).sorted { lhs, rhs in
            if lhs.currentSizeBytes != rhs.currentSizeBytes {
                return lhs.currentSizeBytes > rhs.currentSizeBytes
            }
            return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
        let status = CategorySizes.filesStatus(
            hasGroup: group != nil,
            hasFiles: !files.isEmpty,
            isPending: category.map { store.isGroupsPending(for: $0) } ?? false,
            isLoaded: category.map { store.isFilesLoaded(for: $0) } ?? false,
            readFailed: category.map { store.failedFileCategories.contains($0) } ?? false
        )
        let remainingCount = CategorySizes.remainingFileCount(group)

        return ScrollView {
            VStack(spacing: 0) {
                if let status {
                    InlineStatusRow(status: status, onRetry: { manager.retryDrilldownRead(for: category) })
                } else {
                    ForEach(files, id: \.path) { file in
                        DrilldownFileRow(path: file.path, sizeBytes: file.currentSizeBytes, onTap: { onTapItem(file.path) })
                            .pathContextMenu(file.path, onShowInFinder: onTapItem)
                    }
                    if remainingCount > 0, let group {
                        ShowMoreRow(title: "Show more (\(remainingCount.formatted()))", isEnabled: !isLoadingMoreFiles) {
                            loadMoreFiles(of: group)
                        }
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
    }

    // MARK: - Actions

    private var canNavigate: Bool {
        !manager.isDrillDownTransitionAnimating && activeTransition == nil && pendingTransition == nil
    }

    private func selectCategory(_ item: CategoryInventoryItem) {
        guard canNavigate else { return }
        manager.drillIntoCategory(item, reveal: onTapItem)
    }

    private func selectSubcategory(_ group: SubcategoryGroup) {
        guard canNavigate else { return }
        manager.drillIntoSubcategory(group, reveal: onTapItem)
    }

    private func loadMoreFiles(of group: SubcategoryGroup) {
        guard !isLoadingMoreFiles else { return }
        isLoadingMoreFiles = true
        Task {
            _ = await manager.loadMoreFiles(for: group)
            isLoadingMoreFiles = false
        }
    }

    // MARK: - Skeletons

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
}

// MARK: - Category Inventory Row

private struct CategoryInventoryRow: View, Equatable {
    static func == (lhs: CategoryInventoryRow, rhs: CategoryInventoryRow) -> Bool {
        lhs.item.id == rhs.item.id &&
        lhs.item.currentSizeBytes == rhs.item.currentSizeBytes &&
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

            Text(CategorySizes.sizeText(item.currentSizeBytes))
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(.primary)
                .fixedSize()
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
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(CategorySizes.sizeText(item.currentSizeBytes))
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()

            Color.clear
                .frame(width: 12, height: 12)
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
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                hoverState = hovering
                highlightedSegmentID = hovering ? item.id : nil
            }
        }
    }

}

private struct DrilldownFileRow: View {
    let path: String
    let sizeBytes: Int64
    let onTap: () -> Void

    @State private var isHovering = false

    private var parentPath: String {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        return (parent as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        Button(action: onTap) {
            content
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .help(path)
        .accessibilityHint("Shows it in Finder")
    }

    private var content: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(URL(fileURLWithPath: path).lastPathComponent)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(parentPath)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(CategorySizes.sizeText(sizeBytes))
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(ListRowHoverBackground(isHovering: isHovering))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }
}

enum CategorySizes {
    static func sizeText(_ bytes: Int64) -> String {
        formattedBytes(bytes)
    }

    static func fileCountText(_ count: Int) -> String {
        count == 1 ? "1 file" : "\(count.formatted()) files"
    }

    static func groupsStatus(isEmpty: Bool, isPending: Bool, readFailed: Bool) -> InlineStatus? {
        guard isEmpty, !isPending else { return nil }
        return readFailed ? .failed : .empty
    }

    static func filesStatus(hasGroup: Bool, hasFiles: Bool, isPending: Bool, isLoaded: Bool, readFailed: Bool) -> InlineStatus? {
        guard hasGroup else { return isPending ? nil : .empty }
        guard !hasFiles else { return nil }
        if readFailed { return .failed }
        return isLoaded ? .empty : nil
    }

    static func remainingFileCount(_ group: SubcategoryGroup?) -> Int {
        guard let group, group.loadedFileCount < SubcategoryGroup.maxLoadableFiles else { return 0 }
        return max(0, group.fileCount - group.loadedFileCount)
    }

    static func subcategoriesBySize(_ groups: [SubcategoryGroup]) -> [SubcategoryGroup] {
        DrilldownStore.sorted(groups)
    }
}

private struct SubcategoryRow: View {
    let group: SubcategoryGroup
    let onTap: () -> Void

    @State private var hoverState = false
    @State private var nativeApplicationIcon: NSImage?

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                applicationIcon
                    .frame(width: 18, height: 18)

                VStack(alignment: .leading, spacing: 1) {
                    Text(group.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(CategorySizes.fileCountText(group.fileCount))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(CategorySizes.sizeText(group.totalBytes))
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(.primary)
                    .fixedSize()

                ListChevron()
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(ListRowHoverBackground(isHovering: hoverState))
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                hoverState = hovering
            }
        }
        .task(id: group.ownerIcon) {
            nativeApplicationIcon = group.ownerIcon.flatMap { UnitIconResolver.shared.icon(for: $0) }
        }
    }

    @ViewBuilder
    private var applicationIcon: some View {
        if let nativeApplicationIcon {
            Image(nsImage: nativeApplicationIcon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .accessibilityHidden(true)
        } else {
            Image(systemName: group.icon)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
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
