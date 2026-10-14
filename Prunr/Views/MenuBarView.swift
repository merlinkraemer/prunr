import SwiftUI
import AppKit

private func menuBarViewDirectoryExists(at url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
}

struct MenuBarView: View {
    @Bindable var manager: MenuBarManager

    @State private var settingsStore = SettingsStore.shared
    @State private var devMode = DevMode.shared
    @State private var settingsHover = false
    @State private var refreshHover = false
    @State private var hasRequiredScanAccess: Bool? = nil
    @State private var blockedScanAccessLocations: [String] = []
    @State private var isBootstrapping = true
    @State private var permissionsService = PermissionsService.shared
    @State private var highlightedStorageSegmentID: String? = nil
    @State private var customOnboardingFolderPath: URL? = {
        if let pathString = UserDefaults.standard.string(forKey: "onboardingChosenFolderPath") {
            return URL(fileURLWithPath: pathString, isDirectory: true)
        }
        return nil
    }()
    @State private var onboardingChosenFolderPath: URL? = {
        if let pathString = UserDefaults.standard.string(forKey: "onboardingChosenFolderPath") {
            return URL(fileURLWithPath: pathString, isDirectory: true)
        }
        return nil
    }()
    @State private var drillTransitionCoordinator = DrilldownTransitionCoordinator()
    @State private var displayedHeader = HeaderScreen.feed
    /// The change list is the root page; the category overview and its drill
    /// sit one level below it.
    @State private var showsCategoryOverview = false
    @State private var feedPage = FeedPage.feed
    @State private var feedSlidesForward = true
    @State private var expandedFeedDays: Set<Date> = []
    @State private var feedScrollAnchor: Date? = nil
    @State private var activeHeaderTransition: ActiveHeaderTransition? = nil
    @State private var headerWidth: CGFloat = 0
    @State private var onboardingTransitionTask: Task<Void, Never>? = nil
    @State private var scanAccessRefreshTask: Task<Void, Never>? = nil
    @State private var onboardingTransitionDirection: OnboardingNavigationDirection = .forward
    @State private var selectedOnboardingPage = OnboardingPage.folder
    @State private var displayedOnboardingPage = OnboardingPage.folder
    @State private var outgoingOnboardingPage: OnboardingPage? = nil
    @State private var onboardingOffset: CGFloat = 0
    @State private var onboardingWidth: CGFloat = 0
    @State private var pendingOnboardingTransition: PendingOnboardingTransition? = nil
    @State private var folderValidationTask: Task<Void, Never>? = nil
    @State private var selectedScanFolderExists = {
        let path = SettingsStore.shared.mainBasePath
        return menuBarViewDirectoryExists(at: URL(fileURLWithPath: path, isDirectory: true))
    }()
    @State private var onboardingChosenFolderExists = {
        if let pathString = UserDefaults.standard.string(forKey: "onboardingChosenFolderPath") {
            return menuBarViewDirectoryExists(at: URL(fileURLWithPath: pathString, isDirectory: true))
        }
        return false
    }()
    @State private var skippedFullDiskAccess = false
    @State private var previewOnboardingPage = OnboardingPage.folder
    @State private var isRefreshRequested = false
    @State private var footerNotice: String? = nil
    @State private var footerNoticeTask: Task<Void, Never>? = nil

    private let outsideScopeSegmentID = "outside-scan-scope"

    private enum HeaderNavigationDirection {
        case forward
        case backward
    }

    private struct ActiveHeaderTransition {
        let outgoing: HeaderScreen
        let incoming: HeaderScreen
        let direction: HeaderNavigationDirection
    }

    private enum OnboardingNavigationDirection {
        case forward
        case backward
    }

    private struct PendingOnboardingTransition {
        let from: OnboardingPage
        let to: OnboardingPage
        let direction: OnboardingNavigationDirection
    }

    private struct FolderAvailabilitySnapshot: Sendable {
        let selectedScanFolderExists: Bool
        let onboardingChosenFolderExists: Bool
    }

    private enum HeaderLevel: Int {
        case feed
        case overview
        case category
        case files
    }

    private struct HeaderScreen: Equatable {
        let level: HeaderLevel
        let category: CategoryInventoryItem?
        let subcategory: SubcategoryGroup?

        static let feed = HeaderScreen(level: .feed, category: nil, subcategory: nil)
        static let overview = HeaderScreen(level: .overview, category: nil, subcategory: nil)

        static func == (lhs: HeaderScreen, rhs: HeaderScreen) -> Bool {
            lhs.id == rhs.id
        }

        var id: String {
            switch level {
            case .feed:
                return "feed"
            case .overview:
                return "overview"
            case .category:
                return "category-\(category?.category.rawValue ?? "none")"
            case .files:
                return "files-\(category?.category.rawValue ?? "none")-\(subcategory?.id ?? "none")"
            }
        }
    }

    private func headerScreen(for pane: DrilldownListPane) -> HeaderScreen {
        switch pane.level {
        case .main:
            return .overview
        case .subcategories:
            guard let category = pane.category else { return .overview }
            return HeaderScreen(level: .category, category: category, subcategory: nil)
        case .files:
            guard let category = pane.category else { return .overview }
            return HeaderScreen(level: .files, category: category, subcategory: pane.subcategory)
        }
    }

    private var hasEnabledScanPath: Bool {
        settingsStore.isPathEnabled(settingsStore.mainTrackedPath)
    }

    private var scanFileCountLabel: String? {
        guard manager.filesScanned > 0 else { return nil }
        return "\(manager.filesScanned.formatted()) files scanned"
    }

    private var scanPathLabel: String {
        manager.scanCurrentPathDisplay.isEmpty ? "Preparing scan..." : manager.scanCurrentPathDisplay
    }

    private var selectedScanFolderURL: URL {
        URL(fileURLWithPath: settingsStore.mainBasePath, isDirectory: true)
    }

    private var onboardingFolderStepComplete: Bool {
        hasEnabledScanPath && selectedScanFolderExists && onboardingChosenFolderExists
    }

    private var onboardingPermissionSatisfied: Bool {
        hasRequiredScanAccess == true
    }

    private var onboardingCanStartScan: Bool {
        OnboardingPage.canStartScan(accessGranted: onboardingPermissionSatisfied, accessSkipped: skippedFullDiskAccess)
    }

    private var maxUnlockedOnboardingPage: OnboardingPage {
        OnboardingPage.maxUnlocked(
            folderChosen: onboardingFolderStepComplete,
            accessGranted: onboardingPermissionSatisfied,
            accessSkipped: skippedFullDiskAccess
        )
    }

    private var isOnboardingPreview: Bool {
        devMode.panelPreview == .onboarding
    }

    private var accessCheckRoots: [URL] {
        let enabledRoots = settingsStore.enabledTrackedPaths.map(\.url.standardizedFileURL)
        if manager.noBaseline || enabledRoots.isEmpty {
            return [selectedScanFolderURL]
        }
        return enabledRoots
    }

    private var currentOnboardingPage: OnboardingPage {
        if isOnboardingPreview {
            return previewOnboardingPage
        }
        guard selectedOnboardingPage.rawValue <= maxUnlockedOnboardingPage.rawValue else {
            return maxUnlockedOnboardingPage
        }
        return selectedOnboardingPage
    }

    private func onboardingStepIsComplete(_ page: OnboardingPage) -> Bool {
        if isOnboardingPreview {
            return page.rawValue < previewOnboardingPage.rawValue
        }
        if page == .permissions && !onboardingPermissionSatisfied {
            return false
        }
        return page.rawValue < maxUnlockedOnboardingPage.rawValue
    }

    private func onboardingStepIsUnlocked(_ page: OnboardingPage) -> Bool {
        if isOnboardingPreview {
            return true
        }
        if currentOnboardingPage == .scan {
            if manager.isLoading || manager.isAutoScanning {
                return page == .scan
            }
            return page.rawValue <= currentOnboardingPage.rawValue
        }
        return page.rawValue <= maxUnlockedOnboardingPage.rawValue
    }

    private var canNavigateBackInOnboarding: Bool {
        guard currentOnboardingPage != .folder else { return false }
        guard let previousPage = OnboardingPage(rawValue: currentOnboardingPage.rawValue - 1) else { return false }
        return onboardingStepIsUnlocked(previousPage)
    }

    private var selectedScanFolderLabel: String {
        shortDisplayPath(for: selectedScanFolderURL)
    }

    private func refreshFolderAvailability() {
        let selectedFolderURL = selectedScanFolderURL.standardizedFileURL
        let chosenFolderURL = onboardingChosenFolderPath?.standardizedFileURL

        folderValidationTask?.cancel()
        folderValidationTask = Task {
            let snapshot = await Task.detached(priority: .utility) {
                FolderAvailabilitySnapshot(
                    selectedScanFolderExists: menuBarViewDirectoryExists(at: selectedFolderURL),
                    onboardingChosenFolderExists: chosenFolderURL.map { menuBarViewDirectoryExists(at: $0) } ?? false
                )
            }.value

            guard !Task.isCancelled else { return }

            await MainActor.run {
                selectedScanFolderExists = snapshot.selectedScanFolderExists
                onboardingChosenFolderExists = snapshot.onboardingChosenFolderExists
            }
        }
    }

    private var scanFolderOptions: [OnboardingFolderOption] {
        OnboardingFolderOption.options(
            home: FileManager.default.homeDirectoryForCurrentUser,
            custom: customOnboardingFolderPath
        )
    }

    private var highlightedOnboardingFolderURL: URL {
        if !isOnboardingPreview, let chosen = onboardingChosenFolderPath {
            return chosen.standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
    }

    private func closePopoverAndOpenFolderSettings() {
        manager.closePopover()
        SettingsWindowController.shared.showFolder()
    }

    private func closePopoverAndOpenSettings() {
        // Close the popover first via manager to ensure state sync
        manager.closePopover()

        // Set settings tab to "Paths" before opening (ISS-034)
        // Paths tab is tag 1 in SettingsView
        UserDefaults.standard.set(1, forKey: "settingsSelectedTab")

        // Use manager's programmatic settings opener (SwiftUI \.openSettings is
        // unavailable because we use a pure AppKit entry point without a Settings scene).
        manager.openSettings()

        // Ensure Settings window is focused immediately - ISS-024
        // Same improved logic as MenuBarManager.openSettings with faster 50ms delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NSApp.activate()

            if let settingsWindow = NSApp.windows.first(where: {
                $0.title.contains("Settings")
            }) {
                // Ensure window behavior is correct
                settingsWindow.hidesOnDeactivate = false

                // Temporarily elevate window level to bring to front
                let originalLevel = settingsWindow.level
                settingsWindow.level = .floating
                settingsWindow.makeKeyAndOrderFront(nil)
                settingsWindow.orderFrontRegardless()

                // Reset to normal level immediately after focusing (no delay)
                settingsWindow.level = originalLevel
            } else {
                // If window not found yet, try once more with a longer delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NSApp.activate()
                    if let settingsWindow = NSApp.windows.first(where: { $0.title.contains("Settings") }) {
                        settingsWindow.hidesOnDeactivate = false
                        settingsWindow.level = .floating
                        settingsWindow.makeKeyAndOrderFront(nil)
                        settingsWindow.orderFrontRegardless()
                        settingsWindow.level = .normal
                    }
                }
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch devMode.panelPreview {
                case .live:
                    liveContent
                case .onboarding:
                    setupOnboardingView
                case .scanning:
                    scanningPreviewView
                        .allowsHitTesting(false)
                case .dayOne, .error:
                    mainCategoryView
                case .sample:
                    PanelSamplePreview()
                }
            }
        }
        .frame(width: 320, height: 480)
        .onAppear {
            selectedOnboardingPage = maxUnlockedOnboardingPage
            refreshFolderAvailability()
        }
        .onDisappear {
            scanAccessRefreshTask?.cancel()
            folderValidationTask?.cancel()
            onboardingTransitionTask?.cancel()
            drillTransitionCoordinator.cancelAndReset()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshScanAccess()
        }
        .onChange(of: settingsStore.mainBasePath) { _, _ in
            refreshFolderAvailability()
            refreshScanAccess()
        }
        .onChange(of: onboardingChosenFolderPath) { _, _ in
            refreshFolderAvailability()
        }
        .onChange(of: devMode.panelPreview) { _, _ in
            previewOnboardingPage = .folder
            synchronizeVisibleOnboardingToCurrent()
        }
        .onChange(of: manager.noBaseline) { _, _ in
            refreshScanAccess()
        }
        .onChange(of: manager.runtimeBlockedLocations) { _, newValue in
            guard !newValue.isEmpty else { return }
            blockedScanAccessLocations = Array(Set(blockedScanAccessLocations + newValue)).sorted()
        }
        .onChange(of: manager.isPopoverShown) { _, isShown in
            guard isShown else { return }
            synchronizeVisibleHeaderToCurrent()
            synchronizeVisibleOnboardingToCurrent()
            Task { await manager.refreshChangeFeed() }
        }
        .task {
            if manager.hasDisplayableInventory {
                isBootstrapping = false
            }

            let accessReport = await refreshScanAccessNow()

            if !accessReport.isGranted {
                await manager.checkBaseline(trackedPathsOverride: [settingsStore.mainTrackedPath])
                isBootstrapping = false
                return
            }

            // Phase 1: Fast — show categories instantly from pre-computed totals
            let hasQuickData = await manager.loadQuickInventory()
            if !hasQuickData {
                isBootstrapping = true
            }
            defer { isBootstrapping = false }

            // Phase 2: Background — enrich with growth stories, trends, disk accounting
            await manager.checkBaseline()
            manager.updateFreeSpaceIfNeeded()
            await manager.updatePathSize()

            if !manager.noBaseline {
                await manager.loadInventoryFromLatestSnapshotIfStale()
                await manager.refreshChangeFeed()
            }
        }
        .onChange(of: maxUnlockedOnboardingPage) { _, newValue in
            guard selectedOnboardingPage != .folder || newValue == .folder else { return }
            selectedOnboardingPage = newValue
        }
    }

    @ViewBuilder
    private var liveContent: some View {
        // A manual scan takes over the panel with its progress card and
        // Stop. The change list is kept underneath, never cleared, so it
        // returns with the same or newer rows once the scan ends.
        if manager.isLoading && !manager.isAutoScanning {
            manualScanLoadingView
        } else if isBootstrapping && !manager.hasDisplayableInventory {
            initialLoadView
        } else if manager.noBaseline {
            setupOnboardingView
        } else {
            mainCategoryView
        }
    }

    private var shownChangeFeed: ChangeFeedResult? {
        devMode.panelPreview.changeFeed(over: manager.changeFeed)
    }

    private var shownErrorMessage: String? {
        devMode.panelPreview.errorMessage(over: manager.errorMessage)
    }

    private var scanFolderName: ScanFolderName {
        ScanFolderName(path: settingsStore.mainBasePath)
    }

    private var scanningPreviewView: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            scanStatusCard(clampedProgress: 0.42, showStopButton: true)
                .padding(.horizontal, 16)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 18)
    }

    private var initialLoadView: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    SkeletonBlock(width: 132, height: 12, cornerRadius: 4)
                    SkeletonBlock(width: 176, height: 9, cornerRadius: 4)
                }

                VStack(spacing: 0) {
                    ForEach(0..<4, id: \.self) { _ in
                        SkeletonListRow(style: .category)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 18)
            .padding(.vertical, 22)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.08), radius: 16, x: 0, y: 10)
            .padding(.horizontal, 16)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 18)
    }

    private var manualScanLoadingView: some View {
        let clampedProgress = max(0.0, min(1.0, manager.scanProgressPercentage))

        return VStack(spacing: 0) {
            Spacer(minLength: 0)

            scanStatusCard(clampedProgress: clampedProgress, showStopButton: true)
                .padding(.horizontal, 16)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 18)
    }

    // MARK: - Main Category View

    private var mainCategoryView: some View {
        VStack(spacing: 0) {
            changesHeader
            Divider()

            pageNavigationContent
                .padding(.bottom, -SoftBottomEdge.footerHeight)

            Spacer(minLength: 0)

            footerButtons
        }
    }

    private var leftOnboardingPage: OnboardingPage {
        if let outgoingOnboardingPage {
            return onboardingTransitionDirection == .forward ? outgoingOnboardingPage : displayedOnboardingPage
        }
        return displayedOnboardingPage
    }

    private var rightOnboardingPage: OnboardingPage {
        if let outgoingOnboardingPage {
            return onboardingTransitionDirection == .forward ? displayedOnboardingPage : outgoingOnboardingPage
        }
        return displayedOnboardingPage
    }

    private var setupOnboardingView: some View {
        VStack(spacing: 0) {
            onboardingProgressHeader

            GeometryReader { geometry in
                let resolvedWidth = max(geometry.size.width, onboardingWidth)
                let pageSize = CGSize(width: resolvedWidth, height: geometry.size.height)

                HStack(spacing: 0) {
                    onboardingPage(for: leftOnboardingPage, size: pageSize)
                    onboardingPage(for: rightOnboardingPage, size: pageSize)
                }
                .offset(x: onboardingOffset)
                .frame(width: resolvedWidth, alignment: .leading)
                .clipped()
                .onAppear {
                    if geometry.size.width > 0 {
                        onboardingWidth = geometry.size.width
                    }
                    if pendingOnboardingTransition == nil && outgoingOnboardingPage == nil {
                        displayedOnboardingPage = currentOnboardingPage
                    }
                }
                .onChange(of: geometry.size.width) { _, newWidth in
                    guard newWidth > 0 else { return }
                    onboardingWidth = newWidth

                    guard let pendingOnboardingTransition else { return }
                    self.pendingOnboardingTransition = nil
                    onboardingTransitionDirection = pendingOnboardingTransition.direction
                    startOnboardingTransition(
                        from: pendingOnboardingTransition.from,
                        to: pendingOnboardingTransition.to,
                        width: newWidth
                    )
                }
                .onChange(of: currentOnboardingPage) { oldValue, newValue in
                    guard oldValue != newValue else { return }
                    let sourcePage = outgoingOnboardingPage == nil ? displayedOnboardingPage : displayedOnboardingPage
                    let resolvedSourcePage = sourcePage
                    let direction: OnboardingNavigationDirection = newValue.rawValue >= resolvedSourcePage.rawValue ? .forward : .backward
                    onboardingTransitionDirection = direction
                    let resolvedWidth = geometry.size.width > 0 ? geometry.size.width : onboardingWidth

                    guard resolvedWidth > 0 else {
                        pendingOnboardingTransition = PendingOnboardingTransition(from: resolvedSourcePage, to: newValue, direction: direction)
                        return
                    }

                    if outgoingOnboardingPage != nil {
                        pendingOnboardingTransition = PendingOnboardingTransition(from: resolvedSourcePage, to: newValue, direction: direction)
                        return
                    }

                    pendingOnboardingTransition = nil
                    startOnboardingTransition(from: resolvedSourcePage, to: newValue, width: resolvedWidth)
                }
            }
            .background {
                ZStack {
                    ForEach(OnboardingPage.allCases, id: \.rawValue) { page in
                        onboardingPage(for: page, size: .zero)
                    }
                }
                .frame(width: 0, height: 0)
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDisappear {
            onboardingTransitionTask?.cancel()
            synchronizeVisibleOnboardingToCurrent()
        }
    }

    private var onboardingProgressHeader: some View {
        ZStack(alignment: .top) {
            Text("Setup")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.top, 14)

            HStack(spacing: 8) {
                ForEach(OnboardingPage.allCases, id: \.rawValue) { page in
                    onboardingStepPill(for: page)
                }
            }
            .padding(.top, 42)

            if canNavigateBackInOnboarding {
                HStack {
                    Button {
                        let prevIndex = max(0, currentOnboardingPage.rawValue - 1)
                        if let prevPage = OnboardingPage(rawValue: prevIndex) {
                            goToOnboardingPage(prevPage)
                        }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back")

                    Spacer()
                }
                .padding(.leading, 16)
                .padding(.top, 12)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 82, maxHeight: 82, alignment: .top)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.09))
                .frame(height: 1)
        }
    }

    private func onboardingStepPill(for page: OnboardingPage) -> some View {
        let isComplete = onboardingStepIsComplete(page)
        let isActive = page == currentOnboardingPage
        let isUnlocked = onboardingStepIsUnlocked(page)
        let pillFill: Color = isActive
            ? Color.accentColor.opacity(0.22)
            : Color.primary.opacity(isComplete ? 0.06 : 0.03)
        let badgeFill: Color = isComplete
            ? Color.green.opacity(0.16)
            : (isActive ? Color.accentColor.opacity(0.20) : Color.primary.opacity(0.06))

        return Button {
            guard isUnlocked else { return }
            goToOnboardingPage(page)
        } label: {
            HStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(badgeFill)
                        .frame(width: 20, height: 20)

                    if isComplete {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.green)
                    } else {
                        Text("\(page.number)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    }
                }

                Text(page.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isActive ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            }
            .padding(.leading, 3)
            .padding(.trailing, 10)
            .frame(height: 26)
            .background(Capsule().fill(pillFill))
        }
        .buttonStyle(.plain)
        .disabled(!isUnlocked)
    }

    private func onboardingPage(for page: OnboardingPage, size: CGSize) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            onboardingPageCard(for: page)

            Spacer(minLength: 0)

            onboardingButtons(for: page)
                .padding(.vertical, 16)
        }
        .padding(.horizontal, 16)
        .frame(width: size.width, height: size.height)
        .transition(.identity)
    }

    @ViewBuilder
    private func onboardingPageCard(for page: OnboardingPage) -> some View {
        switch page {
        case .folder:
            onboardingCard(title: "Choose a folder", subtitle: "Prunr scans it once, then keeps watch.") {
                VStack(spacing: 0) {
                    ForEach(scanFolderOptions) { option in
                        onboardingFolderRow(option)
                    }
                }
                .padding(.top, 12)

                onboardingHairline
                    .padding(.top, 6)

                Button {
                    chooseCustomOnboardingFolder()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 16)
                        Text("Choose custom folder…")
                            .font(.system(size: 13, weight: .medium))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.primary)
                    .frame(height: 40)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.bottom, -6)
            }

        case .permissions:
            onboardingCard(
                title: "Allow access to your files",
                subtitle: "So Prunr can measure every folder.",
                icon: "lock.shield"
            ) {
                VStack(spacing: 0) {
                    onboardingNumberedStep(1, "Open System Settings")
                    onboardingNumberedStep(2, "Allow Prunr in Full Disk Access")
                }
                .padding(.top, 10)
            }

        case .scan:
            onboardingCard(title: "Run first scan", subtitle: "Takes a few minutes.") {
                onboardingHairline
                    .padding(.top, 12)

                onboardingSummaryRow(icon: "folder", label: scanFolderName.title) {
                    Text(selectedScanFolderLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                onboardingHairline

                onboardingSummaryRow(icon: "lock.shield", label: "Full Disk Access") {
                    if onboardingPermissionSatisfied || isOnboardingPreview {
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.green)
                            Text("On")
                        }
                    } else {
                        Text("Off")
                    }
                }
                .padding(.bottom, -6)
            }
        }
    }

    @ViewBuilder
    private func onboardingButtons(for page: OnboardingPage) -> some View {
        switch page {
        case .folder:
            onboardingButton("Continue", style: .primary) {
                continueFromOnboardingFolder()
            }

        case .permissions:
            if onboardingPermissionSatisfied && !isOnboardingPreview {
                onboardingButton("Continue", style: .primary) {
                    goToOnboardingPage(.scan)
                }
            } else {
                HStack(spacing: 8) {
                    onboardingButton("Not Now", style: .secondary) {
                        skipOnboardingAccess()
                    }
                    .frame(width: 104)

                    onboardingButton("Open System Settings", style: .primary) {
                        guard !isOnboardingPreview else { return }
                        openScanAccessSettings()
                    }
                }
            }

        case .scan:
            onboardingButton(
                "Start Scan",
                style: .primary,
                isDisabled: !onboardingCanStartScan && !isOnboardingPreview
            ) {
                guard !isOnboardingPreview else { return }
                startOnboardingFirstScan()
            }
        }
    }

    private func onboardingFolderRow(_ option: OnboardingFolderOption) -> some View {
        let isSelected = highlightedOnboardingFolderURL == option.url.standardizedFileURL

        return Button {
            guard !isOnboardingPreview else { return }
            applyOnboardingScanFolder(option.url)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(option.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)

                        if let badge = option.badge {
                            Text(badge)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                        }
                    }

                    Text(option.subtitle)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                onboardingRadio(isSelected: isSelected)
            }
            .padding(.horizontal, 8)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.primary.opacity(0.06) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -8)
    }

    @ViewBuilder
    private func onboardingRadio(isSelected: Bool) -> some View {
        if isSelected {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 16, height: 16)
                .overlay(
                    Circle()
                        .fill(Color.white)
                        .frame(width: 6, height: 6)
                )
        } else {
            Circle()
                .strokeBorder(Color.primary.opacity(0.32), lineWidth: 1.5)
                .frame(width: 16, height: 16)
        }
    }

    private func onboardingNumberedStep(_ number: Int, _ text: String) -> some View {
        HStack(spacing: 10) {
            Text("\(number)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.primary.opacity(0.10)))

            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .frame(height: 30)
    }

    private var onboardingHairline: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
    }

    private func onboardingSummaryRow<Value: View>(
        icon: String,
        label: String,
        @ViewBuilder value: () -> Value
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 8)

            value()
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(height: 36)
    }

    private func onboardingCard<Content: View>(
        title: String,
        subtitle: String,
        icon: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }

                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private enum OnboardingButtonStyle {
        case primary
        case secondary
    }

    private func onboardingButton(
        _ title: String,
        style: OnboardingButtonStyle,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: style == .primary ? .semibold : .medium))
                .lineLimit(1)
                .foregroundStyle(style == .primary ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .background(
                    Capsule()
                        .fill(style == .primary ? Color.accentColor : Color.primary.opacity(0.08))
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1.0)
    }

    private func goToOnboardingPage(_ page: OnboardingPage) {
        if isOnboardingPreview {
            previewOnboardingPage = page
        } else {
            selectedOnboardingPage = page
        }
    }

    private func continueFromOnboardingFolder() {
        if !isOnboardingPreview && onboardingChosenFolderPath == nil {
            applyOnboardingScanFolder(highlightedOnboardingFolderURL)
        }
        goToOnboardingPage(onboardingPermissionSatisfied && !isOnboardingPreview ? .scan : .permissions)
    }

    private func skipOnboardingAccess() {
        if !isOnboardingPreview {
            skippedFullDiskAccess = true
        }
        goToOnboardingPage(.scan)
    }

    private func chooseCustomOnboardingFolder() {
        guard !isOnboardingPreview else { return }
        manager.showOnboardingFolderPicker { url in
            if let url = url {
                customOnboardingFolderPath = url
                applyOnboardingScanFolder(url)
            }
        }
    }

    private func startOnboardingTransition(from previousPage: OnboardingPage, to newPage: OnboardingPage, width: CGFloat) {
        onboardingTransitionTask?.cancel()
        stabilizeInFlightOnboardingTransitionIfNeeded()

        guard width > 0 else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                outgoingOnboardingPage = nil
                displayedOnboardingPage = newPage
                onboardingOffset = 0
            }
            return
        }

        let initialOffset = onboardingTransitionDirection == .forward ? 0 : -width
        let targetOffset = onboardingTransitionDirection == .forward ? -width : 0

        var setupTransaction = Transaction()
        setupTransaction.disablesAnimations = true
        withTransaction(setupTransaction) {
            displayedOnboardingPage = newPage
            outgoingOnboardingPage = previousPage
            onboardingOffset = initialOffset
        }

        onboardingTransitionTask = Task { @MainActor in
            await withCheckedContinuation { continuation in
                RunLoop.main.perform { continuation.resume() }
            }
            guard !Task.isCancelled else { return }

            withAnimation(.snappy(duration: 0.28, extraBounce: 0)) {
                onboardingOffset = targetOffset
            }

            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }

            var cleanupTransaction = Transaction()
            cleanupTransaction.disablesAnimations = true
            withTransaction(cleanupTransaction) {
                displayedOnboardingPage = newPage
                outgoingOnboardingPage = nil
                onboardingOffset = 0
            }

            guard let pendingOnboardingTransition else { return }
            self.pendingOnboardingTransition = nil
            guard pendingOnboardingTransition.to != displayedOnboardingPage else { return }
            onboardingTransitionDirection = pendingOnboardingTransition.direction
            startOnboardingTransition(
                from: displayedOnboardingPage,
                to: pendingOnboardingTransition.to,
                width: max(onboardingWidth, width)
            )
        }
    }

    private func synchronizeVisibleOnboardingToCurrent() {
        onboardingTransitionTask?.cancel()

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            pendingOnboardingTransition = nil
            outgoingOnboardingPage = nil
            onboardingOffset = 0
            displayedOnboardingPage = currentOnboardingPage
        }
    }

    private func stabilizeInFlightOnboardingTransitionIfNeeded() {
        guard outgoingOnboardingPage != nil else { return }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            outgoingOnboardingPage = nil
            onboardingOffset = 0
        }
    }

    // MARK: - Header (Always Visible)

    /// Clicking the bar area opens the categories view; once it is open the
    /// bar's segments hover and drill into their category as before. The row
    /// under the bar is "This week" on the change list, else a title row.
    private var changesHeader: some View {
        ChangesHeaderView(
            onOpenBar: showsCategoryOverview ? nil : { setShowsCategoryOverview(true) }
        ) {
            driveBar
        } row: {
            if showsCategoryOverview {
                headerNavigationView
            } else if let place = shownPlace {
                HeaderTitleRow(
                    title: EpisodeBuilder.rowTitle(for: place),
                    category: place.category,
                    iconSource: place.iconSource,
                    backHint: feedPage.parent == .feed
                        ? "Return to the change list"
                        : "Return to this day's \(place.category.displayName) changes",
                    onBack: navigateFeedBack
                )
            } else if let group = shownGroup {
                HeaderTitleRow(
                    title: group.category.displayName,
                    category: group.category,
                    backHint: "Return to the change list",
                    onBack: navigateFeedBack
                )
            } else {
                switch changeListHeaderRow {
                case .thisWeek(let weekly):
                    WeeklyChangeRow(weekly: weekly)
                case .balance(let balance):
                    StorageBalanceRow(balance: balance, onNow: scrollFeedToTop)
                }
            }
        }
    }

    private var changeListHeaderRow: ChangeListHeaderRow {
        ChangeListHeaderRow.make(
            showsBalance: devMode.showsBalanceHeader,
            feedResult: manager.changeFeed,
            scrollAnchor: feedScrollAnchor,
            history: manager.storageHistory,
            usedBytes: manager.usedBytes,
            capacityBytes: manager.totalBytes
        )
    }

    /// The bar shows a past date's level only under that date's header row.
    private var driveBarHistoricUsedBytes: Int64? {
        guard !showsCategoryOverview, feedPage == .feed else { return nil }
        return changeListHeaderRow.historicUsedBytes
    }

    private func scrollFeedToTop() {
        guard let feed = manager.changeFeed?.feed else { return }
        withAnimation(.easeInOut(duration: 0.3)) {
            feedScrollAnchor = ChangeFeedRows.topAnchor(for: feed, now: Date())
        }
    }

    private var driveBar: some View {
        DriveBarView(
            totalBytes: manager.totalBytes,
            usedBytes: manager.usedBytes,
            freeBytes: manager.freeBytes,
            categorySegments: driveBarSegments,
            highlightedSegmentID: $highlightedStorageSegmentID,
            onTapSegment: navigateFromDriveBar,
            focusedSegmentID: focusedDriveBarCategory?.category.rawValue,
            focusedLabel: focusedDriveBarLabel,
            focusedIcon: focusedDriveBarCategory?.category.icon,
            focusedIconColor: focusedDriveBarCategory?.category.color ?? .secondary,
            disableHover: shouldDisableDriveBarHover,
            historicUsedBytes: driveBarHistoricUsedBytes
        )
    }

    private var driveBarSegments: [DriveBarSegment] {
        var segments = manager.sortedCategories
            .filter { $0.currentSizeBytes > 0 }
            .sorted { $0.currentSizeBytes > $1.currentSizeBytes }
            .map {
                DriveBarSegment(
                    id: $0.category.rawValue,
                    bytes: $0.currentSizeBytes,
                    color: $0.category.color
                )
            }

        if outsideScanScopeBytes > 0 {
            segments.append(
                DriveBarSegment(
                    id: outsideScopeSegmentID,
                    bytes: outsideScanScopeBytes,
                    color: Color.gray.opacity(0.55)
                )
            )
        }

        return segments
    }

    private var trackedInventoryBytes: Int64 {
        manager.sortedCategories.reduce(Int64(0)) { $0 + $1.currentSizeBytes }
    }

    private var outsideScanScopeBytes: Int64 {
        max(0, manager.usedBytes - trackedInventoryBytes)
    }

    // Supplemental rows render after the regular categories, keeping this
    // outside-scope total in the final spot of the inventory list.
    private var supplementalInventoryItems: [SupplementalInventoryItem] {
        guard outsideScanScopeBytes > 0 else { return [] }

        return [
            SupplementalInventoryItem(
                id: outsideScopeSegmentID,
                title: "Not watched",
                icon: "square.dashed",
                currentSizeBytes: outsideScanScopeBytes,
                badgeText: "Not scanned"
            )
        ]
    }

    private var currentHeaderScreen: HeaderScreen {
        guard showsCategoryOverview else {
            return .feed
        }

        guard let category = manager.selectedInventoryCategory, manager.isDrilledDown else {
            return .overview
        }

        if manager.isSubcategoryDrillDown, let subcategory = manager.selectedSubcategory {
            return HeaderScreen(level: .files, category: category, subcategory: subcategory)
        }

        return HeaderScreen(level: .category, category: category, subcategory: nil)
    }

    private var focusedDriveBarCategory: CategoryInventoryItem? {
        guard manager.isDrilledDown, let selectedCategory = manager.selectedInventoryCategory else {
            return nil
        }

        return manager.sortedCategories
            .first { $0.category == selectedCategory.category } ?? selectedCategory
    }

    private var focusedDriveBarLabel: String? {
        focusedDriveBarCategory.map { formattedBytes($0.currentSizeBytes) }
    }

    private var shouldDisableDriveBarHover: Bool {
        !showsCategoryOverview || focusedDriveBarCategory != nil
    }

    private func refreshScanAccess() {
        let roots = accessCheckRoots
        scanAccessRefreshTask?.cancel()
        scanAccessRefreshTask = Task {
            let report = await permissionsService.evaluateScanScopeAccessAsync(scanRootURLs: roots)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                hasRequiredScanAccess = report.isGranted
                blockedScanAccessLocations = Array(Set(report.blockedLocations + manager.runtimeBlockedLocations)).sorted()
                manager.isPermissionConfirmedForProtectedTraversal = report.isGranted
            }
        }
    }

    @discardableResult
    private func refreshScanAccessNow() async -> PermissionsService.ScanScopeAccessReport {
        let report = await permissionsService.evaluateScanScopeAccessAsync(scanRootURLs: accessCheckRoots)
        hasRequiredScanAccess = report.isGranted
        blockedScanAccessLocations = Array(Set(report.blockedLocations + manager.runtimeBlockedLocations)).sorted()
        manager.isPermissionConfirmedForProtectedTraversal = report.isGranted
        return report
    }

    private func openScanAccessSettings() {
        Task {
            await permissionsService.requestFullDiskAccess()
        }
    }

    // MARK: - Page Navigation Content

    private var pageNavigationContent: some View {
        ZStack(alignment: .top) {
            shownPage
                .id(shownPageID)
                .transition(PushTransition.transition(forward: feedSlidesForward))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
        .background(
            DrilldownBackSwipeBridge(
                isEnabled: canNavigateBackFromDrilldown || isShowingGroup,
                onSwipeBack: {
                    if isShowingGroup {
                        navigateFeedBack()
                    } else {
                        navigateBackFromDrilldown()
                    }
                }
            )
        )
        .frame(maxHeight: .infinity, alignment: .top)
        .onDisappear {
            drillTransitionCoordinator.cancelAndReset()
        }
    }

    private var shownPageID: String {
        showsCategoryOverview ? "categories" : feedPage.id
    }

    @ViewBuilder
    private var shownPage: some View {
        if showsCategoryOverview {
            categoryListView
                .clearOfFooter()
        } else if let place = shownPlace, let unitRoot = place.rootPath {
            PlaceContentsView(
                category: place.category,
                isIndexing: manager.drilldownStore.isBuilding,
                onReveal: revealPlace,
                loader: { offset in try await manager.loadPlaceContents(unitRoot: unitRoot, offset: offset) }
            )
        } else if let group = shownGroup {
            ChangeGroupView(group: group, onOpenPlace: openPlace, onReveal: revealPlace)
        } else {
            changeFeedView
        }
    }

    private var leftHeaderScreen: HeaderScreen {
        if let activeHeaderTransition {
            return activeHeaderTransition.direction == .forward ? activeHeaderTransition.outgoing : activeHeaderTransition.incoming
        }
        return displayedHeader
    }

    private var rightHeaderScreen: HeaderScreen {
        if let activeHeaderTransition {
            return activeHeaderTransition.direction == .forward ? activeHeaderTransition.incoming : activeHeaderTransition.outgoing
        }
        return displayedHeader
    }

    private var headerNavigationView: some View {
        GeometryReader { geometry in
            let resolvedWidth = max(geometry.size.width, headerWidth)

            HStack(spacing: 0) {
                headerPage(for: leftHeaderScreen, width: resolvedWidth)
                headerPage(for: rightHeaderScreen, width: resolvedWidth)
            }
            .offset(x: drillTransitionCoordinator.slideOffset)
            .frame(width: resolvedWidth, alignment: .leading)
            .clipped()
            .onAppear {
                if geometry.size.width > 0 {
                    headerWidth = geometry.size.width
                }
                if activeHeaderTransition == nil {
                    displayedHeader = currentHeaderScreen
                } else {
                    synchronizeVisibleHeaderToCurrent()
                }
            }
            .onChange(of: geometry.size.width) { _, newWidth in
                guard newWidth > 0 else { return }
                headerWidth = newWidth
            }
        }
        .onDisappear {
            synchronizeVisibleHeaderToCurrent()
        }
        .frame(height: HeaderRowMetrics.height)
    }

    @ViewBuilder
    private func headerView(for screen: HeaderScreen) -> some View {
        switch screen.level {
        case .feed, .overview:
            // `.feed` only renders while the categories page slides out, so it
            // keeps the categories header instead of going blank.
            categoriesHeader
                .transition(.identity)
        case .category, .files:
            if let category = resolvedHeaderCategory(for: screen) {
                drillDownHeader(category: category, subcategory: resolvedHeaderSubcategory(for: screen))
                    .transition(.identity)
            } else {
                Color.clear
            }
        }
    }

    private func resolvedHeaderCategory(for screen: HeaderScreen) -> CategoryInventoryItem? {
        guard let screenCategory = screen.category else {
            return manager.selectedInventoryCategory
        }

        guard let selectedCategory = manager.selectedInventoryCategory else {
            return screenCategory
        }

        return selectedCategory.category == screenCategory.category ? selectedCategory : screenCategory
    }

    private func resolvedHeaderSubcategory(for screen: HeaderScreen) -> SubcategoryGroup? {
        guard screen.level == .files else { return screen.subcategory }

        guard let selectedSubcategory = manager.selectedSubcategory else {
            return screen.subcategory
        }

        guard let screenSubcategory = screen.subcategory else {
            return selectedSubcategory
        }

        return selectedSubcategory.id == screenSubcategory.id ? selectedSubcategory : screenSubcategory
    }

    private func synchronizeVisibleHeaderToCurrent() {
        drillTransitionCoordinator.cancelAndReset()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            activeHeaderTransition = nil
            displayedHeader = currentHeaderScreen
        }
    }

    private func stabilizeInFlightHeaderTransitionIfNeeded() {
        guard let activeHeaderTransition else { return }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            displayedHeader = activeHeaderTransition.incoming
            self.activeHeaderTransition = nil
        }
    }

    private func headerPage(for screen: HeaderScreen, width: CGFloat) -> some View {
        headerView(for: screen)
            .frame(width: width, height: HeaderRowMetrics.height, alignment: .center)
    }

    /// The categories view's own header: a back arrow to the change list.
    private var categoriesHeader: some View {
        navigationHeader(
            title: "Categories",
            backHint: "Return to the change list",
            onBack: { setShowsCategoryOverview(false) }
        )
    }

    private func drillDownHeader(category: CategoryInventoryItem, subcategory: SubcategoryGroup?) -> some View {
        HeaderTitleRow(
            title: subcategory?.displayName ?? category.category.displayName,
            category: category.category,
            backHint: "Return to category overview",
            onBack: navigateBackFromDrilldown
        )
    }

    private func navigationHeader(title: String, backHint: String, onBack: @escaping () -> Void) -> some View {
        HeaderTitleRow(title: title, backHint: backHint, onBack: onBack)
    }

    // MARK: - Change Feed

    private var changeFeedView: some View {
        Group {
            if let error = shownErrorMessage {
                scanErrorView(error)
                    .clearOfFooter()
            } else {
                ChangeFeedView(
                    result: shownChangeFeed,
                    scanFolder: scanFolderName,
                    expandedDays: $expandedFeedDays,
                    scrollAnchor: $feedScrollAnchor,
                    onOpenGroup: openChangeGroup,
                    onRetry: { Task { await manager.refreshChangeFeed() } }
                )
            }
        }
    }

    private var shownGroup: ChangeGroup? {
        guard let openGroup = feedPage.group else { return nil }
        let fresh = shownChangeFeed?.feed?.days
            .first { $0.day == openGroup.day }?
            .groups.first { $0.id == openGroup.id }
        return fresh ?? openGroup
    }

    private var shownPlace: ChangeEpisode? {
        guard let place = feedPage.place else { return nil }
        return shownGroup?.episodes.first { $0.id == place.id } ?? place
    }

    private var isShowingGroup: Bool {
        feedPage != .feed && !showsCategoryOverview
    }

    private func openChangeGroup(_ group: ChangeGroup) {
        navigateFeed(to: feedPage.opening(group))
    }

    private func openPlace(_ place: ChangeEpisode) {
        navigateFeed(to: feedPage.opening(place))
    }

    private func navigateFeedBack() {
        navigateFeed(to: feedPage.parent)
    }

    private func navigateFeed(to page: FeedPage) {
        guard page != feedPage else { return }
        slidePage(forward: page.depth > feedPage.depth) {
            withAnimation(DrilldownTransitionCoordinator.slideAnimation) {
                feedPage = page
            }
        }
    }

    private func slidePage(forward: Bool, _ change: @escaping () -> Void) {
        guard forward != feedSlidesForward else {
            change()
            return
        }
        feedSlidesForward = forward
        DispatchQueue.main.async(execute: change)
    }

    private func setShowsCategoryOverview(_ shows: Bool) {
        guard showsCategoryOverview != shows else { return }
        if !shows {
            drillTransitionCoordinator.cancelAndReset()
            manager.selectedSubcategory = nil
            manager.selectedInventoryCategory = nil
            manager.isSubcategoryDrillDown = false
            manager.isDrilledDown = false
        }
        slidePage(forward: shows) {
            withAnimation(DrilldownTransitionCoordinator.slideAnimation) {
                showsCategoryOverview = shows
                feedPage = .feed
                highlightedStorageSegmentID = nil
            }
            synchronizeVisibleHeaderToCurrent()
        }
    }

    private func scanErrorView(_ error: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24))
                .foregroundStyle(.orange)
            Text(error)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task {
                    await manager.loadInventory()
                }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Category List View

    private var categoryListView: some View {
        Group {
            if let error = shownErrorMessage {
                scanErrorView(error)
            } else {
                CategoryGrowthListView(
                    categories: manager.sortedCategories,
                    supplementalItems: supplementalInventoryItems,
                    manager: manager,
                    highlightedSegmentID: $highlightedStorageSegmentID,
                    drillTransitionCoordinator: drillTransitionCoordinator,
                    onPrepareHeaderTransition: { listOut, listIn, forward in
                        let direction: HeaderNavigationDirection = forward ? .forward : .backward
                        activeHeaderTransition = ActiveHeaderTransition(
                            outgoing: headerScreen(for: listOut),
                            incoming: headerScreen(for: listIn),
                            direction: direction
                        )
                    },
                    onStabilizeHeaderTransition: {
                        stabilizeInFlightHeaderTransitionIfNeeded()
                    },
                    onCompleteHeaderTransition: { pane in
                        displayedHeader = headerScreen(for: pane)
                        activeHeaderTransition = nil
                    },
                    onSyncHeaderToListPane: { pane in
                        displayedHeader = headerScreen(for: pane)
                        activeHeaderTransition = nil
                    },
                    onTapItem: revealPlace
                )
            }
        }
    }

    // MARK: - Footer Buttons (Icon Toolbar)

    private var footerButtons: some View {
        let status = footerStatus
        return ZStack {
            if status.ring == nil {
                footerStatusText(status)
            }

            HStack {
                if let ring = status.ring {
                    HStack(spacing: 7) {
                        FooterProgressRing(ring: ring)
                            .id(ring == .spinning)
                        Text(status.text())
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.leading, 5)
                    .frame(height: 26)
                    .accessibilityElement(children: .combine)
                } else {
                    refreshButton
                }

                Spacer()

                Button {
                    closePopoverAndOpenSettings()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13))
                        .frame(width: 26, height: 26)
                        .background(
                            Circle()
                                .fill(settingsHover ? Color.gray.opacity(0.12) : Color.clear)
                        )
                        .foregroundStyle(.primary)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open settings")
                .accessibilityHint("Open Prunr settings")
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.15)) {
                        settingsHover = hovering
                    }
                }
                .help("Settings")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: SoftBottomEdge.footerHeight)
    }

    private var refreshButton: some View {
        Button {
            Task { await refreshNow() }
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 13))
                .frame(width: 26, height: 26)
                .background(
                    Circle()
                        .fill(refreshHover ? Color.gray.opacity(0.12) : Color.clear)
                )
                .foregroundStyle(.primary)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(manager.isLoading || manager.isAutoScanning || isRefreshing)
        .accessibilityLabel("Refresh recent changes")
        .accessibilityHint("Run a lightweight refresh without a full scan")
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                refreshHover = hovering
            }
        }
        .help("Refresh recent changes")
    }

    private var isRefreshing: Bool {
        isRefreshRequested || manager.isCheckingGrowth
    }

    /// Runs the lightweight refresh and rereads the list. The footer says
    /// "Refreshing…" for at least a moment, so a quick refresh still shows.
    private func refreshNow() async {
        guard !isRefreshRequested else { return }
        isRefreshRequested = true
        let started = Date()
        await manager.checkGrowth()
        await manager.refreshChangeFeed()
        let remaining = 0.7 - Date().timeIntervalSince(started)
        if remaining > 0 {
            try? await Task.sleep(for: .seconds(remaining))
        }
        isRefreshRequested = false
    }

    private func retryAfterFailure() {
        Task {
            if shownErrorMessage != nil {
                await manager.loadInventory()
            }
            await manager.refreshChangeFeed()
        }
    }

    private func revealPlace(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else {
            showFooterNotice("No longer on disk")
            return
        }
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    private func showFooterNotice(_ text: String) {
        footerNoticeTask?.cancel()
        withAnimation(.easeInOut(duration: 0.15)) {
            footerNotice = text
        }
        footerNoticeTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.15)) {
                footerNotice = nil
            }
        }
    }

    private var footerStatus: FooterStatus {
        let activity = manager.footerActivity
        return FooterStatus.resolve(
            notice: footerNotice,
            refreshFailed: shownErrorMessage != nil || shownChangeFeed == .failed,
            scanText: activity.isFullScan ? activity.text : nil,
            scanProgress: activity.progress,
            isRefreshing: isRefreshing,
            foldersNotReadable: !manager.isGrowthTrackingActive
                || hasRequiredScanAccess == false
                || !manager.runtimeBlockedLocations.isEmpty,
            updateAvailable: manager.showsUpdateAvailableBanner,
            groupDay: isShowingGroup ? shownGroup?.day : nil,
            preview: devMode.panelPreview,
            watchingSinceToday: shownChangeFeed?.feed?.watchingSinceToday(now: Date(), calendar: .current),
            updatedAt: manager.updatedAt
        )
    }

    @ViewBuilder
    private func footerStatusText(_ status: FooterStatus) -> some View {
        switch status {
        case .refreshFailed:
            HStack(spacing: 4) {
                Text(status.text())
                    .foregroundStyle(.secondary)
                Text("\u{00B7}")
                    .foregroundStyle(.tertiary)
                Button("Retry", action: retryAfterFailure)
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
            }
            .font(.system(size: 11))
        case .scanning, .refreshing:
            EmptyView()
        case .foldersNotReadable:
            Button(action: closePopoverAndOpenFolderSettings) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                    Text(status.text())
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help("Prunr can't read some folders. Grant Full Disk Access in Folder settings.")
        case .updateAvailable:
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.blue)
                    .frame(width: 5, height: 5)

                Button {
                    manager.checkForUpdates()
                } label: {
                    Text(status.text())
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)

                Button {
                    manager.dismissUpdateBanner()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss update notice")
            }
            .font(.system(size: 11))
        case .updated:
            TimelineView(.everyMinute) { context in
                Text(status.text(now: context.date))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        case .none:
            Color.clear.frame(height: 1)
        case .notice, .groupDay, .preview, .watchingSince:
            Text(status.text())
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func applyOnboardingScanFolder(_ url: URL) {
        onboardingChosenFolderPath = url
        UserDefaults.standard.set(url.path, forKey: "onboardingChosenFolderPath")
        settingsStore.setMainBasePath(url)
        settingsStore.setPathEnabled(settingsStore.mainTrackedPath, enabled: true)
        refreshScanAccess()

        if manager.noBaseline {
            settingsStore.clearPendingScopeChanges()
        }
    }

    private func shortDisplayPath(for url: URL) -> String {
        OnboardingFolderOption.displayPath(for: url, home: FileManager.default.homeDirectoryForCurrentUser)
    }

    private func startOnboardingFirstScan() {
        guard onboardingCanStartScan else { return }
        guard manager.noBaseline else { return }
        guard onboardingFolderStepComplete else { return }
        guard !manager.isLoading, !manager.isAutoScanning else { return }

        Task {
            await manager.loadInventory(trackedPathsOverride: [settingsStore.mainTrackedPath])
        }
    }

    private func scanStatusCard(clampedProgress: Double, showStopButton: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if manager.isCleaningUp {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.blue)

                    Text("Cleaning up database")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                }

                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(.blue)

                Text("Reclaiming database space...")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else if manager.isAnalyzingChanges {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.green)

                    Text("Analyzing changes")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                }

                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(.green)

                Text("Comparing the latest snapshot and grouping growth.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Scanning files")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.primary)

                        if let scanFileCountLabel {
                            Text(scanFileCountLabel)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }

                    Spacer()

                    Text(manager.hasReliableScanProgressEstimate ? "\(Int(clampedProgress * 100))%" : "...")
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                }

                Group {
                    if manager.hasReliableScanProgressEstimate {
                        ProgressView(value: clampedProgress, total: 1.0)
                    } else {
                        ProgressView()
                    }
                }
                .progressViewStyle(.linear)
                .tint(.blue)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Current path")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)

                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 6, height: 6)

                        Text(scanPathLabel)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.gray.opacity(0.06))
                )
            }

            if showStopButton {
                onboardingButton("Stop", style: .secondary) {
                    Task { await manager.stopScan() }
                }
                .accessibilityLabel("Stop scan")
                .accessibilityHint("Cancel the current scan operation")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 22)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 16, x: 0, y: 10)
    }

    // MARK: - Helper Methods

    private var canNavigateBackFromDrilldown: Bool {
        manager.isDrilledDown && manager.selectedInventoryCategory != nil && !manager.isDrillDownTransitionAnimating
    }

    private func navigateBackFromDrilldown() {
        manager.closeDrilldownLevel()
    }

    private func navigateFromDriveBar(segmentID: String) {
        guard !manager.isDrillDownTransitionAnimating else { return }
        guard segmentID != outsideScopeSegmentID, segmentID != "other-used" else { return }
        guard let category = GrowthCategory(rawValue: segmentID) else { return }
        guard let item = manager.sortedCategories
            .first(where: { $0.category == category }) else { return }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            highlightedStorageSegmentID = segmentID
        }
        manager.openCategory(item)
    }

}

private struct DrilldownBackSwipeBridge: NSViewRepresentable {
    let isEnabled: Bool
    let onSwipeBack: () -> Void

    func makeNSView(context: Context) -> SwipeInstallerView {
        let view = SwipeInstallerView()
        view.onSwipeBack = onSwipeBack
        view.isEnabled = isEnabled
        return view
    }

    func updateNSView(_ nsView: SwipeInstallerView, context: Context) {
        nsView.onSwipeBack = onSwipeBack
        nsView.isEnabled = isEnabled
        nsView.installRecognizerIfNeeded()
    }

    static func dismantleNSView(_ nsView: SwipeInstallerView, coordinator: ()) {
        nsView.detachRecognizer()
    }

    final class SwipeInstallerView: NSView, NSGestureRecognizerDelegate {
        var onSwipeBack: (() -> Void)?
        private weak var installedOnView: NSView?
        private var didTriggerSwipe = false

        var isEnabled = false {
            didSet {
                panRecognizer.isEnabled = isEnabled
            }
        }

        private lazy var panRecognizer: NSPanGestureRecognizer = {
            let recognizer = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            recognizer.delegate = self
            return recognizer
        }()

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            installRecognizerIfNeeded()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            installRecognizerIfNeeded()
        }

        func installRecognizerIfNeeded() {
            guard let targetView = window?.contentView ?? superview else { return }

            if installedOnView !== targetView {
                detachRecognizer()
                targetView.addGestureRecognizer(panRecognizer)
                installedOnView = targetView
            }

            panRecognizer.isEnabled = isEnabled
        }

        func detachRecognizer() {
            installedOnView?.removeGestureRecognizer(panRecognizer)
            installedOnView = nil
            didTriggerSwipe = false
        }

        @objc
        private func handlePan(_ recognizer: NSPanGestureRecognizer) {
            guard isEnabled, let recognizerView = recognizer.view else { return }

            let translation = recognizer.translation(in: recognizerView)
            let isHorizontalBackSwipe = translation.x > 90 && abs(translation.x) > abs(translation.y) * 1.5

            switch recognizer.state {
            case .began, .changed:
                guard !didTriggerSwipe, isHorizontalBackSwipe else { return }
                didTriggerSwipe = true
                onSwipeBack?()
            case .ended, .cancelled, .failed:
                didTriggerSwipe = false
            default:
                break
            }
        }

        func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer) -> Bool {
            true
        }
    }
}

#Preview {
    // Cannot preview easily with Bindable manager without mock
    Text("Preview not available")
}
