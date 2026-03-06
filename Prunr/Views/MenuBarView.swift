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

    private let outsideScopeSegmentID = "outside-scan-scope"

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

    private var onboardingFolderStepComplete: Bool {
        hasEnabledScanPath && hasValidScanFolder
    }

    private var onboardingCanRunFirstScan: Bool {
        hasFullDiskAccess && onboardingFolderStepComplete && !manager.isLoading && !manager.isAutoScanning
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
        ScrollView {
            VStack(spacing: 16) {
                // Header section
                VStack(alignment: .leading, spacing: 4) {
                    Text("Setup")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)

                // Step 1: Full Disk Access
                onboardingStepCard(
                    number: 1,
                    title: "Full Disk Access",
                    isComplete: hasFullDiskAccess,
                    detail: "",
                    isActive: true
                ) {
                    if hasFullDiskAccess {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 12, weight: .medium))
                            Text("Granted")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(.green)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            primaryActionButton("Open Full Disk Access", minWidth: 168) {
                                openFullDiskAccessSettings()
                            }

                            secondaryActionButton("Reveal Current App") {
                                permissionsService.revealCurrentAppInFinder()
                            }
                        }
                    }
                }

                // Step 2: Choose scan folder
                onboardingStepCard(
                    number: 2,
                    title: "Choose scan folder",
                    isComplete: onboardingFolderStepComplete,
                    detail: "",
                    isActive: hasFullDiskAccess
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        // Folder options - styled as selectable list
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(scanFolderOptions) { option in
                                let isSelected = selectedScanFolderURL.standardizedFileURL == option.url.standardizedFileURL

                                Button {
                                    guard hasFullDiskAccess else { return }
                                    applyOnboardingScanFolder(option.url)
                                } label: {
                                    HStack(spacing: 10) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(option.title)
                                                .font(.system(size: 11, weight: .medium))
                                                .foregroundStyle(isSelected ? .white : (hasFullDiskAccess ? .primary : .secondary.opacity(0.5)))

                                            Text(option.subtitle)
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundStyle(isSelected ? .white.opacity(0.85) : (hasFullDiskAccess ? .secondary : .secondary.opacity(0.4)))
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
                                                .strokeBorder(Color.gray.opacity(hasFullDiskAccess ? 0.4 : 0.2), lineWidth: 1.5)
                                                .frame(width: 14, height: 14)
                                        }
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .frame(maxWidth: .infinity)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(isSelected ? Color.blue : Color.clear)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .strokeBorder(
                                                isSelected ? Color.clear : Color.gray.opacity(hasFullDiskAccess ? 0.25 : 0.12),
                                                lineWidth: 1
                                            )
                                    )
                                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }

                            // Custom folder option - styled as action button
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
                                        .foregroundStyle(hasFullDiskAccess ? .blue : Color.secondary.opacity(0.5))

                                    Text("Choose Custom Folder")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(hasFullDiskAccess ? .primary : Color.secondary.opacity(0.5))
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity)
                                .background(Color.clear)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(Color.gray.opacity(hasFullDiskAccess ? 0.25 : 0.12), lineWidth: 1)
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // Step 3: Run first scan
                onboardingStepCard(
                    number: 3,
                    title: "Run first scan",
                    isComplete: false,
                    detail: "",
                    isActive: onboardingFolderStepComplete
                ) {
                    VStack(alignment: .leading, spacing: 10) {
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
                                minWidth: 138,
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
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            // Header section - switches between drill-down and free space header
            headerSection
            // Single CategoryGrowthListView instance handles internal animation
            categoryListView
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Header Section

    private var headerSection: some View {
        Group {
            if manager.isDrilledDown, let category = manager.selectedInventoryCategory {
                // Drill-down header: back button, category name, size
                drillDownHeader(category: category)
            } else {
                // Main header: free space display
                freeSpaceHeader
            }
        }
        .animation(.easeInOut(duration: 0.3), value: manager.isDrilledDown)
    }

    // MARK: - Free Space Header

    private var freeSpaceHeader: some View {
        HStack(spacing: 6) {
            Spacer()

            // Free space display
            HStack(spacing: 4) {
                Text("Free: \(formattedBytes(manager.freeBytes)) of \(formattedBytes(manager.totalBytes))")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Spacer()
        }
        .padding(.vertical, 8)
    }

    // MARK: - Drill-down Header

    private func drillDownHeader(category: CategoryInventoryItem) -> some View {
        let headerIcon = manager.isSubcategoryDrillDown
            ? (manager.selectedSubcategory?.subcategory?.icon ?? "folder.fill")
            : category.category.icon
        let headerName = manager.isSubcategoryDrillDown
            ? (manager.selectedSubcategory?.displayName ?? category.category.displayName)
            : category.category.displayName
        let headerBytes = manager.isSubcategoryDrillDown
            ? (manager.selectedSubcategory?.totalBytes ?? category.currentSizeBytes)
            : category.currentSizeBytes

        return ZStack {
            // Centered title
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
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        if manager.isSubcategoryDrillDown {
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
                }) {
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
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
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
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13))
                    .frame(width: 26, height: 26)
                    .background(
                        Circle()
                            .fill(scanHover ? Color.gray.opacity(0.12) : Color.clear)
                    )
                    .foregroundStyle(manager.isLoading || manager.isAutoScanning ? .tertiary : .primary)
                    .contentShape(Circle())
                    .rotationEffect(.degrees(manager.isLoading || manager.isAutoScanning ? 360 : 0))
                    .animation(
                        manager.isLoading || manager.isAutoScanning
                            ? .linear(duration: 1).repeatForever(autoreverses: false)
                            : .default,
                        value: manager.isLoading || manager.isAutoScanning
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Refresh view")
            .accessibilityHint("Reload growth categories from the latest snapshot")
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    scanHover = hovering
                }
            }
            .disabled(manager.isLoading || manager.isAutoScanning)
            .help(manager.isLoading || manager.isAutoScanning ? "Refreshing..." : "Refresh Latest Delta")

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

    @ViewBuilder
    private func onboardingStepCard<Content: View>(
        number: Int,
        title: String,
        isComplete: Bool,
        detail: String,
        isActive: Bool = true,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header with step number and title
            HStack(alignment: .center, spacing: 10) {
                // Step indicator
                ZStack {
                    Circle()
                        .fill(isComplete ? Color.green.opacity(0.15) : (isActive ? Color.blue.opacity(0.12) : Color.gray.opacity(0.08)))
                        .frame(width: 28, height: 28)

                    if isComplete {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.green)
                    } else {
                        Text("\(number)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(isActive ? .blue : Color.secondary.opacity(0.5))
                    }
                }

                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isActive ? .primary : Color.secondary.opacity(0.5))

                Spacer(minLength: 0)
            }

            // Content area
            content()
                .padding(.leading, 38)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 4)
        .opacity(isActive ? 1.0 : 0.5)
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
