import SwiftUI
import AppKit

struct MenuBarView: View {
    @Bindable var manager: MenuBarManager

    @Environment(\.openSettings) private var openSettings
    @State private var settingsStore = SettingsStore.shared
    @State private var scanHover = false
    @State private var settingsHover = false
    @State private var hasFullDiskAccess = false
    @State private var permissionsService = PermissionsService.shared
    @State private var highlightedStorageSegmentID: String? = nil
    @State private var shouldShowOnboardingSuccess = false
    @State private var startedOnboardingScan = false
    @State private var onboardingSuccessTask: Task<Void, Never>? = nil
    @State private var customOnboardingFolderPath: URL? = nil
    @State private var onboardingChosenFolderPath: URL? = nil
    @State private var headerTransitionTask: Task<Void, Never>? = nil
    @State private var headerTransitionDirection: HeaderNavigationDirection = .forward
    @State private var displayedHeader = HeaderScreen.overview
    @State private var outgoingHeader: HeaderScreen? = nil
    @State private var headerOffset: CGFloat = 0
    @State private var headerWidth: CGFloat = 0
    @State private var pendingHeaderTransition: PendingHeaderTransition? = nil
    @State private var onboardingTransitionTask: Task<Void, Never>? = nil
    @State private var onboardingTransitionDirection: OnboardingNavigationDirection = .forward
    @State private var selectedOnboardingPage = OnboardingPage.permissions
    @State private var displayedOnboardingPage = OnboardingPage.permissions
    @State private var outgoingOnboardingPage: OnboardingPage? = nil
    @State private var onboardingOffset: CGFloat = 0
    @State private var onboardingWidth: CGFloat = 0
    @State private var pendingOnboardingTransition: PendingOnboardingTransition? = nil

    private let outsideScopeSegmentID = "outside-scan-scope"

    private enum HeaderNavigationDirection {
        case forward
        case backward
    }

    private struct PendingHeaderTransition {
        let from: HeaderScreen
        let to: HeaderScreen
        let direction: HeaderNavigationDirection
    }

    private enum OnboardingNavigationDirection {
        case forward
        case backward
    }

    private enum OnboardingPage: Int, CaseIterable {
        case permissions
        case folder
        case scan

        var number: Int {
            rawValue + 1
        }

        var title: String {
            switch self {
            case .permissions:
                return "Access"
            case .folder:
                return "Folder"
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

    private enum HeaderLevel: Int {
        case overview
        case category
        case files
    }

    private struct HeaderScreen: Equatable {
        let level: HeaderLevel
        let category: CategoryInventoryItem?
        let subcategory: SubcategoryGroup?

        static let overview = HeaderScreen(level: .overview, category: nil, subcategory: nil)

        var id: String {
            switch level {
            case .overview:
                return "overview"
            case .category:
                return "category-\(category?.category.rawValue ?? "none")"
            case .files:
                return "files-\(subcategory?.id ?? "none")"
            }
        }
    }

    private var hasEnabledScanPath: Bool {
        !SettingsStore.shared.enabledTrackedPaths.isEmpty
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

    private var hasValidScanFolder: Bool {
        FileManager.default.fileExists(atPath: selectedScanFolderURL.path)
    }

    private var hasExplicitOnboardingFolderChoice: Bool {
        guard let onboardingChosenFolderPath else { return false }
        return FileManager.default.fileExists(atPath: onboardingChosenFolderPath.path)
    }

    private var onboardingFolderStepComplete: Bool {
        hasFullDiskAccess && hasEnabledScanPath && hasValidScanFolder && hasExplicitOnboardingFolderChoice
    }

    private var onboardingCanRunFirstScan: Bool {
        hasFullDiskAccess && onboardingFolderStepComplete && !manager.isLoading && !manager.isAutoScanning
    }

    private var maxUnlockedOnboardingPage: OnboardingPage {
        if !hasFullDiskAccess {
            return .permissions
        }

        if !onboardingFolderStepComplete {
            return .folder
        }

        return .scan
    }

    private var currentOnboardingPage: OnboardingPage {
        guard selectedOnboardingPage.rawValue <= maxUnlockedOnboardingPage.rawValue else {
            return maxUnlockedOnboardingPage
        }
        return selectedOnboardingPage
    }

    private var onboardingCardFillColor: Color {
        Color(nsColor: .controlBackgroundColor).opacity(0.92)
    }

    private var onboardingControlFillColor: Color {
        Color(nsColor: .windowBackgroundColor).opacity(0.9)
    }

    private var onboardingStrokeColor: Color {
        Color(nsColor: .separatorColor).opacity(0.55)
    }

    private func onboardingStepIsComplete(_ page: OnboardingPage) -> Bool {
        page.rawValue < maxUnlockedOnboardingPage.rawValue
    }

    private func onboardingStepIsUnlocked(_ page: OnboardingPage) -> Bool {
        page.rawValue <= maxUnlockedOnboardingPage.rawValue
    }

    private var selectedScanFolderLabel: String {
        shortDisplayPath(for: selectedScanFolderURL)
    }

    private var scanFolderOptions: [OnboardingFolderOption] {
        var options: [OnboardingFolderOption] = []
        
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dev = home.appendingPathComponent("dev", isDirectory: true)
        let recommendedURL = FileManager.default.fileExists(atPath: dev.path) ? dev : home

        options.append(
            OnboardingFolderOption(
                id: "recommended",
                title: FileManager.default.fileExists(atPath: dev.path) ? "Recommended" : "Recommended Home",
                subtitle: shortDisplayPath(for: recommendedURL),
                url: recommendedURL
            )
        )
        options.append(
            OnboardingFolderOption(
                id: "home",
                title: "Home Directory",
                subtitle: shortDisplayPath(for: home),
                url: home
            )
        )
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

    private func closePopoverAndOpenSettings() {
        // Close the popover first via manager to ensure state sync
        manager.closePopover()

        // Set settings tab to "Paths" before opening (ISS-034)
        // Paths tab is tag 1 in SettingsView
        UserDefaults.standard.set(1, forKey: "settingsSelectedTab")

        // Use openSettings environment action
        openSettings()

        // Ensure Settings window is focused immediately - ISS-024
        // Same improved logic as MenuBarManager.openSettings with faster 50ms delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NSApp.activate(ignoringOtherApps: true)

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
                    NSApp.activate(ignoringOtherApps: true)
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
            if !hasFullDiskAccess {
                fullDiskAccessBanner
            }

            Group {
                if manager.isLoading && !manager.isAutoScanning {
                    manualScanLoadingView
                } else if shouldShowOnboardingSuccess {
                    onboardingSuccessView
                } else if manager.noBaseline {
                    setupOnboardingView
                } else {
                    VStack(spacing: 0) {
                        // Main category view with monitoring path header
                        mainCategoryView
                    }
                }
            }
        }
        .frame(width: 320, height: 480)
        .onAppear {
            refreshFullDiskAccess()
            selectedOnboardingPage = maxUnlockedOnboardingPage
        }
        .onDisappear {
            onboardingSuccessTask?.cancel()
            onboardingTransitionTask?.cancel()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshFullDiskAccess()
        }
        .task {
            // Fast: Check if baseline exists (UserDefaults lookup)
            await manager.checkBaseline()

            // Fast: Update disk space with caching (only if >5s since last update)
            manager.updateFreeSpaceIfNeeded()

            // Update from latest snapshot (no filesystem rescan)
            await manager.updatePathSize()

            if !manager.noBaseline {
                await manager.loadInventoryFromLatestSnapshot()
            }
        }
        .onChange(of: manager.noBaseline) { oldValue, newValue in
            guard oldValue, !newValue, startedOnboardingScan else { return }
            startedOnboardingScan = false
            presentOnboardingSuccessState()
        }
        .onChange(of: hasFullDiskAccess) { _, newValue in
            if !newValue {
                shouldShowOnboardingSuccess = false
                onboardingSuccessTask?.cancel()
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

    private var manualScanLoadingView: some View {
        let clampedProgress = max(0.0, min(1.0, manager.scanProgressPercentage))

        return VStack(spacing: 0) {
            Spacer(minLength: 0)

            scanStatusCard(clampedProgress: clampedProgress, showStopButton: true)
                .padding(.horizontal, 16)

            Spacer(minLength: 0)

            // Footer with settings
            HStack {
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
                .accessibilityHint("Open settings while scan continues")
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.15)) {
                        settingsHover = hovering
                    }
                }
                .help("Settings (scan continues)")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
        .padding(.vertical, 18)
    }

    // MARK: - Main Category View

    private var mainCategoryView: some View {
        VStack(spacing: 0) {
            // Storage bar - ALWAYS visible (outside page navigation)
            driveBarSection
            Divider()

            // Page navigation container - swaps between main/detail pages
            pageNavigationContent
            
            Spacer(minLength: 0)

            // Footer buttons (no separator)
            footerButtons
        }
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
                Group {
                    if let outgoingOnboardingPage {
                        onboardingSlidingPages(size: geometry.size, outgoingPage: outgoingOnboardingPage)
                    } else {
                        onboardingPage(for: displayedOnboardingPage, size: geometry.size)
                    }
                }
                .clipped()
                .onAppear {
                    onboardingWidth = geometry.size.width
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
                    let direction: OnboardingNavigationDirection = newValue.rawValue >= oldValue.rawValue ? .forward : .backward
                    onboardingTransitionDirection = direction
                    let resolvedWidth = geometry.size.width > 0 ? geometry.size.width : onboardingWidth

                    guard resolvedWidth > 0 else {
                        pendingOnboardingTransition = PendingOnboardingTransition(from: oldValue, to: newValue, direction: direction)
                        return
                    }

                    pendingOnboardingTransition = nil
                    startOnboardingTransition(from: oldValue, to: newValue, width: resolvedWidth)
                }
            }
            .padding(.top, 18)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDisappear {
            onboardingTransitionTask?.cancel()
        }
    }

    private var onboardingProgressHeader: some View {
        VStack(spacing: 12) {
            HStack {
                if currentOnboardingPage != .permissions {
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
                }

                Spacer()

                Text("Setup")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer()

                // Balance the back button width
                if currentOnboardingPage != .permissions {
                    Color.clear.frame(width: 12, height: 12)
                }
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
        let pillStroke: Color = isActive
            ? Color.accentColor.opacity(0.3)
            : onboardingStrokeColor.opacity(isUnlocked ? 1.0 : 0.6)
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

    @ViewBuilder
    private func onboardingPage(for page: OnboardingPage, size: CGSize) -> some View {
        ScrollView(.vertical) {
            VStack(spacing: 10) {
                onboardingPageCard(for: page)
            }
            .frame(maxWidth: 284)
            .frame(maxWidth: .infinity)
            .frame(minHeight: size.height, alignment: .center)
            .padding(.vertical, 6)
        }
        .hiddenScrollIndicators()
        .frame(width: size.width, height: size.height)
        .id(page.rawValue)
    }

    @ViewBuilder
    private func onboardingSlidingPages(size: CGSize, outgoingPage: OnboardingPage) -> some View {
        HStack(spacing: 0) {
            if onboardingTransitionDirection == .forward {
                onboardingPage(for: outgoingPage, size: size)
                onboardingPage(for: displayedOnboardingPage, size: size)
            } else {
                onboardingPage(for: displayedOnboardingPage, size: size)
                onboardingPage(for: outgoingPage, size: size)
            }
        }
        .offset(x: onboardingOffset)
    }

    @ViewBuilder
    private func onboardingPageCard(for page: OnboardingPage) -> some View {
        switch page {
        case .permissions:
            VStack(spacing: 10) {
                onboardingTitleSection(
                    number: 1,
                    icon: "lock.shield",
                    title: "Grant Full Disk Access",
                    description: "Grant full disk access in order to do full disk scan."
                )

                VStack(spacing: 14) {
                    if hasFullDiskAccess {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 12, weight: .medium))
                            Text("Access granted")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(.green)
                    } else {
                        VStack(spacing: 10) {
                            primaryActionButton("Open Full Disk Access", minWidth: 188) {
                                openFullDiskAccessSettings()
                            }

                            secondaryActionButton("Reveal Current App") {
                                permissionsService.revealCurrentAppInFinder()
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 18)
                .padding(.vertical, 22)
            }

        case .folder:
            VStack(spacing: 10) {
                onboardingTitleSection(
                    number: 2,
                    icon: "folder.badge.gearshape",
                    title: "Setup Path",
                    description: "Pick the scope for your first scan."
                )

                onboardingContentCard {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(scanFolderOptions) { option in
                            let isSelected = onboardingChosenFolderPath?.standardizedFileURL == option.url.standardizedFileURL

                            Button {
                                guard hasFullDiskAccess else { return }
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
                            }
                            .buttonStyle(.plain)
                        }

                        Divider()
                            .padding(.vertical, 4)

                        Button {
                            guard hasFullDiskAccess else { return }
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
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

        case .scan:
            VStack(spacing: 10) {
                onboardingTitleSection(
                    number: 3,
                    icon: "waveform.path.ecg",
                    title: "Run First Scan",
                    description: "Build your first baseline to track growth over time."
                )

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

                    if startedOnboardingScan {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.7)
                            Text("Starting scan...")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        primaryActionButton(
                            "Run first scan",
                            minWidth: 160,
                            isDisabled: !onboardingCanRunFirstScan
                        ) {
                            startedOnboardingScan = true
                            Task { await manager.loadInventory() }
                        }
                    }

                    if !onboardingCanRunFirstScan {
                        Text(stepThreeHintText)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 18)
                .padding(.vertical, 22)
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

        guard width > 0 else {
            outgoingOnboardingPage = nil
            displayedOnboardingPage = newPage
            onboardingOffset = 0
            return
        }

        displayedOnboardingPage = newPage
        outgoingOnboardingPage = previousPage
        onboardingOffset = onboardingTransitionDirection == .forward ? 0 : -width

        onboardingTransitionTask = Task { @MainActor in
            withAnimation(.snappy(duration: 0.28, extraBounce: 0)) {
                onboardingOffset = onboardingTransitionDirection == .forward ? -width : 0
            }

            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }

            outgoingOnboardingPage = nil
            onboardingOffset = 0
        }
    }

    private var onboardingSuccessView: some View {
        VStack(spacing: 10) {
            onboardingTitleSection(
                number: 0,
                icon: "checkmark.circle.fill",
                title: "Baseline Ready",
                description: "Prunr is now watching \(selectedScanFolderLabel)."
            )

            onboardingContentCard {
                VStack(alignment: .leading, spacing: 14) {
                    expectationRow(
                        icon: "bolt.horizontal.circle",
                        text: "Prunr keeps the latest scan cached and updates recent growth in the background."
                    )
                    expectationRow(
                        icon: "externaldrive.badge.timemachine",
                        text: "Use Scan Now when you want a fresh filesystem pass."
                    )

                    HStack(spacing: 10) {
                        secondaryActionButton("Stop") {
                            dismissOnboardingSuccess()
                        }

                        primaryActionButton("Open inventory", minWidth: 100) {
                            dismissOnboardingSuccess()
                        }
                    }
                }
            }
        }
        .frame(maxWidth: 284)
    }

    // MARK: - Drive Bar Section (Always Visible)

    private var driveBarSection: some View {
        DriveBarView(
            totalBytes: manager.totalBytes,
            usedBytes: manager.usedBytes,
            freeBytes: manager.freeBytes,
            categorySegments: driveBarSegments,
            highlightedSegmentID: $highlightedStorageSegmentID
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var driveBarSegments: [DriveBarSegment] {
        var segments = (manager.growingCategories + manager.stableCategories)
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
        (manager.growingCategories + manager.stableCategories)
            .reduce(Int64(0)) { $0 + $1.currentSizeBytes }
    }

    private var outsideScanScopeBytes: Int64 {
        max(0, manager.usedBytes - trackedInventoryBytes)
    }

    private var supplementalInventoryItems: [SupplementalInventoryItem] {
        guard outsideScanScopeBytes > 0 else {
            return []
        }

        return [
            SupplementalInventoryItem(
                id: outsideScopeSegmentID,
                title: "Outside Scan Scope",
                icon: "square.dashed",
                currentSizeBytes: outsideScanScopeBytes,
                badgeText: "Not scanned"
            )
        ]
    }

    private var overallGrowthBytes: Int64 {
        manager.growingCategories.reduce(Int64(0)) { partial, item in
            if let story = item.recentGrowthStory {
                return partial + story.deltaBytes
            }

            return partial + (item.growthTrend?.growthBytes ?? 0)
        }
    }

    private var currentHeaderScreen: HeaderScreen {
        guard let category = manager.selectedInventoryCategory, manager.isDrilledDown else {
            return .overview
        }

        if manager.isSubcategoryDrillDown, let subcategory = manager.selectedSubcategory {
            return HeaderScreen(level: .files, category: category, subcategory: subcategory)
        }

        return HeaderScreen(level: .category, category: category, subcategory: nil)
    }

    private func refreshFullDiskAccess() {
        hasFullDiskAccess = permissionsService.hasFullDiskAccess
    }

    private func openFullDiskAccessSettings() {
        Task {
            await permissionsService.requestFullDiskAccess()
        }
    }

    private var fullDiskAccessBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield")
                .font(.system(size: 11))
                .foregroundStyle(.orange)

            Text("Full Disk Access required")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)

            Spacer()

            Button("Open") {
                openFullDiskAccessSettings()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }

    // MARK: - Page Navigation Content

    private var pageNavigationContent: some View {
        VStack(spacing: 0) {
            headerNavigationView
            categoryListView
        }
        .background(
            DrilldownBackSwipeBridge(
                isEnabled: canNavigateBackFromDrilldown,
                onSwipeBack: navigateBackFromDrilldown
            )
        )
        .frame(maxHeight: .infinity, alignment: .top)
        .onDisappear {
            headerTransitionTask?.cancel()
        }
    }

    private var headerNavigationView: some View {
        GeometryReader { geometry in
            Group {
                if let outgoingHeader {
                    HStack(spacing: 0) {
                        if headerTransitionDirection == .forward {
                            headerPage(for: outgoingHeader, width: geometry.size.width)
                            headerPage(for: displayedHeader, width: geometry.size.width)
                        } else {
                            headerPage(for: displayedHeader, width: geometry.size.width)
                            headerPage(for: outgoingHeader, width: geometry.size.width)
                        }
                    }
                    .offset(x: headerOffset)
                } else {
                    headerPage(for: displayedHeader, width: geometry.size.width)
                }
            }
            .clipped()
            .onAppear {
                headerWidth = geometry.size.width
                if pendingHeaderTransition == nil && outgoingHeader == nil {
                    displayedHeader = currentHeaderScreen
                }
            }
            .onChange(of: geometry.size.width) { _, newWidth in
                guard newWidth > 0 else { return }
                headerWidth = newWidth

                guard let pendingHeaderTransition else { return }
                self.pendingHeaderTransition = nil
                headerTransitionDirection = pendingHeaderTransition.direction
                startHeaderTransition(from: pendingHeaderTransition.from, to: pendingHeaderTransition.to, width: newWidth)
            }
            .onChange(of: currentHeaderScreen) { oldValue, newValue in
                guard oldValue != newValue else { return }
                let direction: HeaderNavigationDirection = newValue.level.rawValue >= oldValue.level.rawValue ? .forward : .backward
                headerTransitionDirection = direction
                let resolvedWidth = geometry.size.width > 0 ? geometry.size.width : headerWidth

                guard resolvedWidth > 0 else {
                    pendingHeaderTransition = PendingHeaderTransition(from: oldValue, to: newValue, direction: direction)
                    return
                }

                pendingHeaderTransition = nil
                startHeaderTransition(from: oldValue, to: newValue, width: resolvedWidth)
            }
        }
        .frame(height: 36)
    }

    @ViewBuilder
    private func headerView(for screen: HeaderScreen) -> some View {
        switch screen.level {
        case .overview:
            overviewHeader
        case .category, .files:
            if let category = screen.category {
                drillDownHeader(category: category, subcategory: screen.subcategory)
            } else {
                Color.clear
            }
        }
    }

    private func startHeaderTransition(from previousHeader: HeaderScreen, to newHeader: HeaderScreen, width: CGFloat) {
        headerTransitionTask?.cancel()

        guard width > 0 else {
            outgoingHeader = nil
            displayedHeader = newHeader
            headerOffset = 0
            return
        }

        displayedHeader = newHeader
        outgoingHeader = previousHeader
        headerOffset = headerTransitionDirection == .forward ? 0 : -width

        headerTransitionTask = Task { @MainActor in
            withAnimation(.snappy(duration: 0.28, extraBounce: 0)) {
                headerOffset = headerTransitionDirection == .forward ? -width : 0
            }

            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }

            outgoingHeader = nil
            headerOffset = 0
        }
    }

    private func headerPage(for screen: HeaderScreen, width: CGFloat) -> some View {
        headerView(for: screen)
            .frame(width: width)
            .id(screen.id)
    }

    private var overviewHeader: some View {
        HStack {
            Spacer()

            // Centered growth indicator or stable pill
            if overallGrowthBytes > 0 {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                    Text("+\(formattedBytes(overallGrowthBytes))")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                }
                .foregroundStyle(.orange)
            } else {
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

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func drillDownHeader(category: CategoryInventoryItem, subcategory: SubcategoryGroup?) -> some View {
        let headerIcon = subcategory?.subcategory?.icon ?? category.category.icon
        let headerName = subcategory?.displayName ?? category.category.displayName
        let headerBytes = subcategory?.totalBytes ?? category.currentSizeBytes
        // Get growth info for the header (subcategory takes precedence, else category)
        let growthBytes: Int64? = {
            if let subcategory = subcategory {
                // Sum growth from top files in subcategory
                return subcategory.topFiles.reduce(Int64(0)) { $0 + $1.growthBytes }
            }
            return category.recentGrowthStory?.deltaBytes ?? category.growthTrend?.growthBytes
        }()
        let growthDays = category.growthTrend?.growthSpanDays

        return HStack(spacing: 0) {
            // Back button (left aligned, compact)
            Button(action: navigateBackFromDrilldown) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")
            .accessibilityHint("Return to category overview")
            .frame(width: 20)

            // Centered icon + title + growth indicator below
            VStack(spacing: 2) {
                HStack(spacing: 5) {
                    Image(systemName: headerIcon)
                        .font(.system(size: 14))
                        .foregroundStyle(category.category.color)

                    Text(headerName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                // Growth indicator below title (small, centered)
                if let growth = growthBytes, growth > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 8, weight: .semibold))
                        Text("+\(formattedBytes(growth))\(growthDays != nil ? " · \(growthDays!)d" : "")")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity)
            .offset(x: 18) // Offset right to visually center (56 - 20 = 36, half = 18)

            // Bytes (right aligned, matches list item font)
            Text(formattedBytes(headerBytes))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize()
                .frame(width: 56, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(minHeight: 36)
        .padding(.horizontal, 6)
    }

    // MARK: - Category List View

    private var categoryListView: some View {
        Group {
            if let error = manager.errorMessage {
                // Error message
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
            } else {
                CategoryGrowthListView(
                    growingCategories: manager.growingCategories,
                    stableCategories: manager.stableCategories,
                    supplementalItems: supplementalInventoryItems,
                    stableTotalBytes: manager.stableTotalBytes,
                    manager: manager,
                    highlightedSegmentID: $highlightedStorageSegmentID,
                    onTapItem: { path in
                        // Reveal item in Finder
                        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                    }
                )
            }
        }
    }

    // MARK: - Footer Buttons (Icon Toolbar)

    private var footerButtons: some View {
        HStack {
            // Scan button (lower left)
            Button {
                Task {
                    await manager.refreshVisibleInventory()
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(scanHover ? Color.gray.opacity(0.12) : Color.clear)
                        .frame(width: 26, height: 26)

                    if manager.isLoading || manager.isAutoScanning {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.75)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13))
                            .foregroundStyle(.primary)
                    }
                }
                .frame(width: 26, height: 26)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Scan now")
            .accessibilityHint("Trigger a fresh background scan")
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    scanHover = hovering
                }
            }
            .disabled(manager.isLoading || manager.isAutoScanning)
            .help(manager.isLoading || manager.isAutoScanning ? "Scanning..." : "Scan Now")

            Spacer()

            footerStatusText

            Spacer()

            // Settings button (lower right)
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
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var footerStatusText: some View {
        if manager.isAutoScanning {
            Text("Scanning...")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else if manager.isProcessingRecentChanges {
            Text("Updating…")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else if manager.hasPendingRecentChanges {
            Text("Changes detected")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else if let lastScan = manager.lastAutomaticScanAt {
            Text(relativeTime(from: lastScan))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        } else {
            Text(manager.lastScanStatusText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func relativeTime(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
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
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.blue)
        }
        .buttonStyle(.plain)
    }

    private var stepThreeHintText: String {
        if !hasFullDiskAccess {
            return "Grant Full Disk Access first."
        }

        if !onboardingFolderStepComplete {
            return "Choose a scan folder first."
        }

        return "Run the first scan to build your baseline."
    }

    private func applyOnboardingScanFolder(_ url: URL) {
        onboardingChosenFolderPath = url
        settingsStore.setMainBasePath(url)
        settingsStore.setPathEnabled(settingsStore.mainTrackedPath, enabled: true)

        if manager.noBaseline {
            settingsStore.clearPendingScopeChanges()
        }
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

    private func expectationRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 14)

            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }

    private func presentOnboardingSuccessState() {
        shouldShowOnboardingSuccess = true
        onboardingSuccessTask?.cancel()
        onboardingSuccessTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.8))
            dismissOnboardingSuccess()
        }
    }

    private func dismissOnboardingSuccess() {
        onboardingSuccessTask?.cancel()
        shouldShowOnboardingSuccess = false
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
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 16, x: 0, y: 10)
    }

    // MARK: - Helper Methods

    private var canNavigateBackFromDrilldown: Bool {
        manager.isDrilledDown && manager.selectedInventoryCategory != nil
    }

    private func navigateBackFromDrilldown() {
        guard let category = manager.selectedInventoryCategory else { return }
        let isFileLevel = manager.isSubcategoryDrillDown && manager.selectedSubcategory != nil

        withAnimation(.easeInOut(duration: 0.3)) {
            if isFileLevel {
                if category.category.supportsSubcategories {
                    manager.isSubcategoryDrillDown = false
                    manager.selectedSubcategory = nil
                } else {
                    manager.isSubcategoryDrillDown = false
                    manager.selectedSubcategory = nil
                    manager.selectedInventoryCategory = nil
                    manager.isDrilledDown = false
                }
            } else {
                manager.selectedSubcategory = nil
                manager.selectedInventoryCategory = nil
                manager.isSubcategoryDrillDown = false
                manager.isDrilledDown = false
            }
        }
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        let kb = Double(bytes) / 1_000
        let mb = kb / 1_000
        let gb = mb / 1_000
        let tb = gb / 1_000

        if abs(tb) >= 1 {
            return "\(String(format: "%.1f", tb)) TB"
        } else if abs(gb) >= 1 {
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
