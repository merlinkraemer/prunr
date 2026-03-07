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

    private var currentOnboardingPage: OnboardingPage {
        if !hasFullDiskAccess {
            return .permissions
        }

        if !onboardingFolderStepComplete {
            return .folder
        }

        return .scan
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
        .onAppear { refreshFullDiskAccess() }
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
    }

    private var manualScanLoadingView: some View {
        let clampedProgress = max(0.0, min(1.0, manager.scanProgressPercentage))

        return VStack(spacing: 0) {
            // Header bar
            HStack(spacing: 8) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.blue)

                Text(manager.isCleaningUp ? "Cleaning up" : (manager.isAnalyzingChanges ? "Analyzing changes" : "Scanning files"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            Spacer(minLength: 0)

            VStack(spacing: 16) {
                scanStatusCard(clampedProgress: clampedProgress)

                Button("Stop") {
                    Task { await manager.stopScan() }
                }
                .font(.system(size: 12, weight: .medium))
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.red.opacity(0.5), lineWidth: 1)
                )
                .accessibilityLabel("Stop scan")
                .accessibilityHint("Cancel the current scan operation")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)

            Spacer(minLength: 0)

            // Footer with settings in same position as normal view
            VStack(spacing: 0) {
                Divider()
                HStack {
                    Spacer()
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
        }
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
        VStack(spacing: 18) {
            onboardingProgressHeader

            GeometryReader { geometry in
                Group {
                    if let outgoingOnboardingPage {
                        onboardingSlidingPages(width: geometry.size.width, outgoingPage: outgoingOnboardingPage)
                    } else {
                        onboardingPage(for: displayedOnboardingPage, width: geometry.size.width)
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
            VStack(spacing: 4) {
                Text("Setup")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)

                Text("Three quick steps to start tracking disk growth.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                ForEach(OnboardingPage.allCases, id: \.rawValue) { page in
                    onboardingStepPill(for: page)
                }
            }
        }
    }

    private func onboardingStepPill(for page: OnboardingPage) -> some View {
        let isComplete = page.rawValue < currentOnboardingPage.rawValue
        let isActive = page == currentOnboardingPage

        return HStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(isComplete ? Color.green.opacity(0.14) : (isActive ? Color.blue.opacity(0.14) : Color.gray.opacity(0.08)))
                    .frame(width: 22, height: 22)

                if isComplete {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.green)
                } else {
                    Text("\(page.number)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isActive ? .blue : .secondary)
                }
            }

            Text(page.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isActive ? .primary : .secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(isActive ? Color.white.opacity(0.75) : Color.white.opacity(0.42))
        )
        .overlay(
            Capsule()
                .strokeBorder(isActive ? Color.blue.opacity(0.24) : Color.gray.opacity(0.12), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func onboardingPage(for page: OnboardingPage, width: CGFloat) -> some View {
        VStack {
            Spacer(minLength: 0)

            onboardingPageCard(for: page)
                .frame(maxWidth: 280)

            Spacer(minLength: 0)
        }
        .frame(width: width)
        .id(page.rawValue)
    }

    @ViewBuilder
    private func onboardingSlidingPages(width: CGFloat, outgoingPage: OnboardingPage) -> some View {
        HStack(spacing: 0) {
            if onboardingTransitionDirection == .forward {
                onboardingPage(for: outgoingPage, width: width)
                onboardingPage(for: displayedOnboardingPage, width: width)
            } else {
                onboardingPage(for: displayedOnboardingPage, width: width)
                onboardingPage(for: outgoingPage, width: width)
            }
        }
        .offset(x: onboardingOffset)
    }

    @ViewBuilder
    private func onboardingPageCard(for page: OnboardingPage) -> some View {
        switch page {
        case .permissions:
            onboardingContentCard(
                number: 1,
                icon: "lock.shield",
                title: "Grant Full Disk Access",
                subtitle: "Needed so Prunr can inspect the folders you choose and build a real baseline."
            ) {
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

        case .folder:
            onboardingContentCard(
                number: 2,
                icon: "folder.badge.gearshape",
                title: "Choose What To Watch",
                subtitle: "Pick the folder scope for your first baseline. You need to make an explicit choice here."
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(scanFolderOptions) { option in
                        let isSelected = onboardingChosenFolderPath?.standardizedFileURL == option.url.standardizedFileURL

                        Button {
                            guard hasFullDiskAccess else { return }
                            applyOnboardingScanFolder(option.url)
                        } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.title)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(isSelected ? .white : .primary)

                                    Text(option.subtitle)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(isSelected ? .white.opacity(0.85) : .secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }

                                Spacer()

                                if isSelected {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 14))
                                        .foregroundStyle(.white)
                                } else {
                                    Circle()
                                        .strokeBorder(Color.gray.opacity(0.28), lineWidth: 1.5)
                                        .frame(width: 14, height: 14)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .frame(maxWidth: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(isSelected ? Color.blue : Color.white.opacity(0.72))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(isSelected ? Color.clear : Color.gray.opacity(0.14), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }

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
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.white.opacity(0.58))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.gray.opacity(0.14), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

        case .scan:
            onboardingContentCard(
                number: 3,
                icon: "waveform.path.ecg",
                title: "Run First Scan",
                subtitle: "This builds the first baseline snapshot so new growth can be detected from then on."
            ) {
                VStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)

                        Text(selectedScanFolderLabel)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.56))
                    )

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
            }
        }
    }

    private func onboardingContentCard<Content: View>(
        number: Int,
        icon: String,
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 18) {
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.12))
                        .frame(width: 56, height: 56)

                    Image(systemName: icon)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.blue)
                }

                Text("Step \(number)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                VStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)

                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            content()
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.92),
                            Color.white.opacity(0.72)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.72), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 14, x: 0, y: 8)
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
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.green)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Baseline ready")
                            .font(.system(size: 17, weight: .semibold))

                        Text("Prunr is now watching \(selectedScanFolderLabel).")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                expectationRow(
                    icon: "bolt.horizontal.circle",
                    text: "Refresh reopens the latest saved delta without rescanning."
                )
                expectationRow(
                    icon: "externaldrive.badge.timemachine",
                    text: "Use Complete Rescan in Settings when you want a fresh filesystem pass."
                )

                primaryActionButton("Open inventory", minWidth: 136) {
                    dismissOnboardingSuccess()
                }
            }
            .frame(maxWidth: 292)
            .padding(.horizontal, 20)
            .padding(.vertical, 22)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.gray.opacity(0.08))
            )

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 14)
        .padding(.vertical, 18)
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
            partial + (item.growthTrend?.growthBytes ?? 0)
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
        .frame(height: 40)
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
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func drillDownHeader(category: CategoryInventoryItem, subcategory: SubcategoryGroup?) -> some View {
        let headerIcon = subcategory?.subcategory?.icon ?? category.category.icon
        let headerName = subcategory?.displayName ?? category.category.displayName
        let headerBytes = subcategory?.totalBytes ?? category.currentSizeBytes

        return ZStack {
            HStack(spacing: 6) {
                Image(systemName: headerIcon)
                    .font(.system(size: 14))
                    .foregroundStyle(category.category.color)

                Text(headerName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)

            // Left: Back button
            HStack {
                Button(action: navigateBackFromDrilldown) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Back")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
                .accessibilityHint("Return to category overview")
                Spacer()
            }

            // Right: Size
            HStack {
                Spacer()
                Text(formattedBytes(headerBytes))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
            // Scan/Refresh button (lower left)
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
            .accessibilityLabel("Refresh view")
            .accessibilityHint("Trigger a background refresh of growth categories")
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    scanHover = hovering
                }
            }
            .disabled(manager.isLoading || manager.isAutoScanning)
            .help(manager.isLoading || manager.isAutoScanning ? "Refreshing..." : "Refresh in Background")

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
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(isDisabled ? Color.gray.opacity(0.25) : Color.blue)
                )
                .foregroundStyle(isDisabled ? .gray : .white)
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
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

    private func scanStatusCard(clampedProgress: Double) -> some View {
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
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.gray.opacity(0.06))
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.gray.opacity(0.08))
        )
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
            recognizer.allowedTouchTypes = [.indirect]
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
