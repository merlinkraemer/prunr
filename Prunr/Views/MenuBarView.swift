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
    @State private var developerFolderExists = false
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

    private enum OnboardingPage: Int, CaseIterable {
        case folder
        case permissions
        case scan

        var number: Int {
            rawValue + 1
        }

        var title: String {
            switch self {
            case .folder:
                return "Folder"
            case .permissions:
                return "Access"
            case .scan:
                return "Scan"
            }
        }
    }

    private struct PendingOnboardingTransition {
        let from: OnboardingPage
        let to: OnboardingPage
        let direction: OnboardingNavigationDirection
    }

    private struct FolderAvailabilitySnapshot: Sendable {
        let selectedScanFolderExists: Bool
        let onboardingChosenFolderExists: Bool
        let developerFolderExists: Bool
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

    private var maxUnlockedOnboardingPage: OnboardingPage {
        if !onboardingFolderStepComplete {
            return .folder
        }

        if !onboardingPermissionSatisfied {
            return .permissions
        }

        return .scan
    }

    private var accessCheckRoots: [URL] {
        let enabledRoots = settingsStore.enabledTrackedPaths.map(\.url.standardizedFileURL)
        if manager.noBaseline || enabledRoots.isEmpty {
            return [selectedScanFolderURL]
        }
        return enabledRoots
    }

    private var currentOnboardingPage: OnboardingPage {
        guard selectedOnboardingPage.rawValue <= maxUnlockedOnboardingPage.rawValue else {
            return maxUnlockedOnboardingPage
        }
        return selectedOnboardingPage
    }

    private var onboardingCardFillColor: Color {
        // Keep the content surface translucent so the panel's Liquid Glass
        // remains visible on macOS 26+; the fallback panel still gets a quiet
        // contrast layer on older systems.
        Color.primary.opacity(0.045)
    }

    private var onboardingControlFillColor: Color {
        Color.primary.opacity(0.06)
    }

    private var onboardingStrokeColor: Color {
        Color(nsColor: .separatorColor).opacity(0.55)
    }

    private func onboardingStepIsComplete(_ page: OnboardingPage) -> Bool {
        page.rawValue < maxUnlockedOnboardingPage.rawValue
    }

    private func onboardingStepIsUnlocked(_ page: OnboardingPage) -> Bool {
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
        let developerFolderURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("dev", isDirectory: true)
            .standardizedFileURL

        folderValidationTask?.cancel()
        folderValidationTask = Task {
            let snapshot = await Task.detached(priority: .utility) {
                FolderAvailabilitySnapshot(
                    selectedScanFolderExists: menuBarViewDirectoryExists(at: selectedFolderURL),
                    onboardingChosenFolderExists: chosenFolderURL.map { menuBarViewDirectoryExists(at: $0) } ?? false,
                    developerFolderExists: menuBarViewDirectoryExists(at: developerFolderURL)
                )
            }.value

            guard !Task.isCancelled else { return }

            await MainActor.run {
                selectedScanFolderExists = snapshot.selectedScanFolderExists
                onboardingChosenFolderExists = snapshot.onboardingChosenFolderExists
                developerFolderExists = snapshot.developerFolderExists
            }
        }
    }

    private var scanFolderOptions: [OnboardingFolderOption] {
        var options: [OnboardingFolderOption] = []

        let home = FileManager.default.homeDirectoryForCurrentUser
        let dev = home.appendingPathComponent("dev", isDirectory: true)

        options.append(
            OnboardingFolderOption(
                id: "recommended",
                title: "Recommended",
                subtitle: shortDisplayPath(for: home),
                url: home
            )
        )
        if developerFolderExists {
            options.append(
                OnboardingFolderOption(
                    id: "dev",
                    title: "Developer Folder",
                    subtitle: shortDisplayPath(for: dev),
                    url: dev
                )
            )
        }
        options.append(
            OnboardingFolderOption(
                id: "full-disk",
                title: "Full Disk",
                subtitle: "/",
                url: URL(fileURLWithPath: "/", isDirectory: true)
            )
        )

        // Add custom path if one was selected via file picker
        if let customPath = customOnboardingFolderPath {
            let isAlreadyInList = options.contains { $0.url.standardizedFileURL == customPath.standardizedFileURL }
            if !isAlreadyInList {
                options.insert(
                    OnboardingFolderOption(
                        id: "custom",
                        title: "Custom Folder",
                        subtitle: shortDisplayPath(for: customPath),
                        url: customPath
                    ),
                    at: 0
                )
            }
        }

        return options
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
                        .allowsHitTesting(false)
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
        .onChange(of: maxUnlockedOnboardingPage) { oldValue, newValue in
            if selectedOnboardingPage.rawValue > newValue.rawValue || selectedOnboardingPage == oldValue {
                selectedOnboardingPage = newValue
                return
            }

            if selectedOnboardingPage.rawValue < newValue.rawValue {
                selectedOnboardingPage = newValue
            }
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
                .padding(.bottom, 14)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(onboardingStrokeColor.opacity(0.55))
                        .frame(height: 1)
                }

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
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDisappear {
            onboardingTransitionTask?.cancel()
            synchronizeVisibleOnboardingToCurrent()
        }
    }

    private var onboardingProgressHeader: some View {
        VStack(spacing: 12) {
            HStack {
                if canNavigateBackInOnboarding {
                    Button {
                        let prevIndex = max(0, currentOnboardingPage.rawValue - 1)
                        if let prevPage = OnboardingPage(rawValue: prevIndex) {
                            selectedOnboardingPage = prevPage
                        }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 12, height: 12)
                } else {
                    Color.clear.frame(width: 12, height: 12)
                }

                Spacer()

                Text("Setup")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer()

                Color.clear.frame(width: 12, height: 12)
            }

            HStack(spacing: 10) {
                ForEach(OnboardingPage.allCases, id: \.rawValue) { page in
                    onboardingStepPill(for: page)
                }
            }
        }
    }

    private func onboardingStepPill(for page: OnboardingPage) -> some View {
        let isComplete = onboardingStepIsComplete(page)
        let isActive = page == currentOnboardingPage
        let isUnlocked = onboardingStepIsUnlocked(page)
        let pillFill: Color = isActive
            ? Color.accentColor.opacity(0.14)
            : (isUnlocked ? onboardingControlFillColor : Color.gray.opacity(0.12))
        let titleStyle: AnyShapeStyle = isActive
            ? AnyShapeStyle(.primary)
            : AnyShapeStyle(isUnlocked ? .secondary : .tertiary)
        let numberStyle: AnyShapeStyle = isActive
            ? AnyShapeStyle(Color.accentColor)
            : AnyShapeStyle(isUnlocked ? .secondary : .tertiary)

        return Button {
            guard isUnlocked else { return }
            selectedOnboardingPage = page
        } label: {
            HStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(
                            isComplete
                                ? Color.green.opacity(0.14)
                                : (isActive ? Color.accentColor.opacity(0.14) : Color.gray.opacity(isUnlocked ? 0.1 : 0.07))
                        )
                        .frame(width: 22, height: 22)

                    if isComplete {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.green)
                    } else {
                        Text("\(page.number)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(numberStyle)
                    }
                }

                Text(page.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(titleStyle)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(pillFill)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isUnlocked)
        .opacity(isUnlocked ? 1.0 : 0.72)
    }

    private func onboardingPage(for page: OnboardingPage, size: CGSize) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            onboardingPageCard(for: page)
                .frame(maxWidth: 284)
                .frame(maxWidth: .infinity)

            Spacer(minLength: 0)
        }
        .frame(width: size.width, height: size.height)
        .transition(.identity)
    }

    @ViewBuilder
    private func onboardingPageCard(for page: OnboardingPage) -> some View {
        switch page {
        case .folder:
            VStack(spacing: 10) {
                onboardingTitleSection(
                    number: 1,
                    icon: "folder.badge.gearshape",
                    title: "Setup Path",
                    description: "Pick the scope for your first scan."
                )

                onboardingContentCard {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(scanFolderOptions) { option in
                            let isSelected = onboardingChosenFolderPath?.standardizedFileURL == option.url.standardizedFileURL

                            Button {
                                applyOnboardingScanFolder(option.url)
                            } label: {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(option.title)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(isSelected ? Color.accentColor : .primary)

                                        Text(option.subtitle)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }

                                    Spacer()

                                    if isSelected {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 14))
                                            .foregroundStyle(Color.accentColor)
                                    } else {
                                        Circle()
                                            .strokeBorder(Color.gray.opacity(0.4), lineWidth: 1.5)
                                            .frame(width: 14, height: 14)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }

                        Divider()
                            .padding(.vertical, 4)

                        Button {
                            manager.showOnboardingFolderPicker { url in
                                if let url = url {
                                    customOnboardingFolderPath = url
                                    applyOnboardingScanFolder(url)
                                }
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "folder.badge.plus")
                                    .font(.system(size: 12, weight: .medium))
                                Text("Choose Custom Folder")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .foregroundStyle(.primary)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                    }
                }
            }

        case .permissions:
            VStack(spacing: 10) {
                onboardingTitleSection(
                    number: 2,
                    icon: "lock.shield",
                    title: "Review Privacy Access",
                    description: "Prunr checks whether the folder you chose is actually reachable. Some protected locations may still need extra macOS privacy access."
                )

                VStack(spacing: 14) {
                    if onboardingPermissionSatisfied {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 12, weight: .medium))
                            Text("Selected scan scope is accessible")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(.green)
                    } else {
                        VStack(spacing: 10) {
                            primaryActionButton("Open Privacy Settings", minWidth: 188) {
                                openScanAccessSettings()
                            }

                            if !blockedScanAccessLocations.isEmpty {
                                Text("Still blocked: \(blockedScanAccessLocations.prefix(3).joined(separator: ", "))")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            } else {
                                Text("Choose a folder first, then return here if macOS blocks protected locations inside it.")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 18)
                .padding(.vertical, 22)
            }

        case .scan:
            VStack(spacing: 10) {
                onboardingTitleSection(
                    number: 3,
                    icon: "waveform.path.ecg",
                    title: "Run First Scan",
                    description: "This can take a while for a full-disk scan or large drives."
                )

                onboardingContentCard {
                    VStack(spacing: 14) {
                        HStack(spacing: 8) {
                            Image(systemName: "folder")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)

                            Text(selectedScanFolderLabel)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        if !onboardingPermissionSatisfied {
                            VStack(spacing: 8) {
                                Text(
                                    blockedScanAccessLocations.isEmpty
                                        ? "Open Privacy Settings if macOS blocks protected locations inside this folder."
                                        : "Protected locations still blocked: \(blockedScanAccessLocations.prefix(3).joined(separator: ", "))"
                                )
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)

                                secondaryActionButton("Open Privacy Settings", minWidth: 168) {
                                    openScanAccessSettings()
                                }
                            }
                        }

                        primaryActionButton("Start Scan", minWidth: 168) {
                            startOnboardingFirstScan()
                        }
                        .opacity(onboardingPermissionSatisfied ? 1.0 : 0.5)
                    }
                }
            }
        }
    }

    /// Title section displayed above the onboarding card
    private func onboardingTitleSection(number: Int, icon: String, title: String, description: String) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)

                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
            }

            Text(description)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
    }

    /// Card content wrapper - just the visual card with content
    private func onboardingContentCard<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 14) {
            content()
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(onboardingCardFillColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(onboardingStrokeColor, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 16, x: 0, y: 10)
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
                    backHint: "Return to this day's \(place.category.displayName) changes",
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

    /// The change list is the root page. The categories view (with the
    /// category → subcategory → files drill) and a day group's rows slide in
    /// from the right over it; their title rows live in the header.
    private var pageNavigationContent: some View {
        ZStack(alignment: .top) {
            if showsCategoryOverview {
                categoryListView
                    .clearOfFooter()
                    .transition(.move(edge: .trailing))
            } else if let place = shownPlace, let unitRoot = place.rootPath {
                PlaceContentsView(
                    category: place.category,
                    isIndexing: manager.drilldownStore.isBuilding,
                    onReveal: revealPlace,
                    loader: { offset in try await manager.loadPlaceContents(unitRoot: unitRoot, offset: offset) }
                )
                .id("place-\(place.id)")
                .transition(.move(edge: .trailing))
            } else if let group = shownGroup {
                ChangeGroupView(group: group, onOpenPlace: openPlace, onReveal: revealPlace)
                    .id(group.id)
                    .transition(.asymmetric(
                        insertion: .move(edge: feedSlidesForward ? .trailing : .leading),
                        removal: .move(edge: feedSlidesForward ? .leading : .trailing)
                    ))
            } else {
                changeFeedView
                    .transition(.move(edge: .leading))
            }
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
        let forward = page.depth > feedPage.depth
        guard forward != feedSlidesForward else {
            withAnimation(DrilldownTransitionCoordinator.slideAnimation) {
                feedPage = page
            }
            return
        }
        feedSlidesForward = forward
        DispatchQueue.main.async {
            withAnimation(DrilldownTransitionCoordinator.slideAnimation) {
                feedPage = page
            }
        }
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
        withAnimation(DrilldownTransitionCoordinator.slideAnimation) {
            showsCategoryOverview = shows
            feedPage = .feed
            highlightedStorageSegmentID = nil
        }
        synchronizeVisibleHeaderToCurrent()
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
            foldersNotReadable: !manager.isGrowthTrackingActive || hasRequiredScanAccess == false,
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

    private func primaryActionButton(
        _ title: String,
        minWidth: CGFloat = 140,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .frame(minWidth: minWidth)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isDisabled ? Color.gray.opacity(0.25) : Color.blue)
                )
                .foregroundStyle(isDisabled ? .gray : .white)
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1.0)
    }

    private func secondaryActionButton(
        _ title: String,
        minWidth: CGFloat = 140,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .frame(minWidth: minWidth)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.blue, lineWidth: 1.25)
                )
                .foregroundStyle(.blue)
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
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

        selectedOnboardingPage = .permissions
    }

    private func shortDisplayPath(for url: URL) -> String {
        let standardizedPath = url.standardizedFileURL.path
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path

        if standardizedPath == "/" {
            return "/"
        }

        if standardizedPath.hasPrefix(homePath) {
            let relativePath = String(standardizedPath.dropFirst(homePath.count))
            if relativePath.isEmpty {
                return "~"
            }
            return "~" + relativePath
        }

        return standardizedPath
    }

    private func startOnboardingFirstScan() {
        guard onboardingPermissionSatisfied else { return }
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
                HStack {
                    Spacer()
                    Button("Stop") {
                        Task { await manager.stopScan() }
                    }
                    .font(.system(size: 12, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.red.opacity(0.5), lineWidth: 1)
                    )
                    .accessibilityLabel("Stop scan")
                    .accessibilityHint("Cancel the current scan operation")
                    Spacer()
                }
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

private struct OnboardingFolderOption: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let url: URL
}

#Preview {
    // Cannot preview easily with Bindable manager without mock
    Text("Preview not available")
}
