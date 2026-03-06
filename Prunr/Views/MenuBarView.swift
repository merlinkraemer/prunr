import SwiftUI
import AppKit

struct MenuBarView: View {
    @Bindable var manager: MenuBarManager

    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss
    @State private var scanHover = false
    @State private var settingsHover = false
    @State private var hasFullDiskAccess = false
    @State private var hasCompletedFDAOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedFDAOnboarding")
    @State private var permissionsService = PermissionsService.shared
    @State private var highlightedStorageSegmentID: String? = nil

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
                } else if manager.noBaseline {
                    if hasFullDiskAccess {
                        if hasCompletedFDAOnboarding {
                            firstScanView
                        } else {
                            fdaOnboardingView
                        }
                    } else {
                        fdaOnboardingView
                    }
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
        .onChange(of: hasFullDiskAccess) { _, newValue in
            if !newValue && hasCompletedFDAOnboarding {
                hasCompletedFDAOnboarding = false
                UserDefaults.standard.set(false, forKey: "hasCompletedFDAOnboarding")
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

    private var firstScanView: some View {
        onboardingCard(
            icon: "doc.text.magnifyingglass",
            iconColor: .blue,
            title: "Run your first scan",
            message: "Create a baseline so Prunr can track storage growth over time.",
            primaryTitle: hasEnabledScanPath ? "Run first scan" : "Enable scan path",
            primaryMinWidth: hasEnabledScanPath ? 150 : 170,
            primaryDisabled: manager.isLoading || manager.isAutoScanning,
            primaryAction: {
                if hasEnabledScanPath {
                    Task { await manager.loadInventory() }
                } else {
                    closePopoverAndOpenSettings()
                }
            },
            secondaryTitle: nil,
            secondaryAction: nil,
            detailText: hasEnabledScanPath
                ? "The first scan may take a while, but it only needs to build your initial baseline once."
                : "Choose a folder in Settings first, then come back here to start the initial scan."
        )
    }

    private var fdaOnboardingView: some View {
        onboardingCard(
            icon: hasFullDiskAccess ? "checkmark.seal.fill" : "lock.shield",
            iconColor: hasFullDiskAccess ? .green : .orange,
            title: "Full Disk Access",
            message: hasFullDiskAccess
                ? "Permission is ready. Continue to set up your first scan."
                : "Grant Full Disk Access so Prunr can scan system and user locations reliably.",
            primaryTitle: hasFullDiskAccess ? "Continue" : "Open Full Disk Access",
            primaryMinWidth: 180,
            primaryDisabled: false,
            primaryAction: {
                if hasFullDiskAccess {
                    completeFDAOnboarding()
                } else {
                    openFullDiskAccessSettings()
                }
            },
            secondaryTitle: hasFullDiskAccess ? nil : "Reveal Current App",
            secondaryAction: hasFullDiskAccess ? nil : {
                permissionsService.revealCurrentAppInFinder()
            },
            detailText: hasFullDiskAccess
                ? "The next step will create your baseline scan."
                : "If Prunr is not listed in Settings, use the + button and add the currently running app."
        )
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

    private func completeFDAOnboarding() {
        hasCompletedFDAOnboarding = true
        UserDefaults.standard.set(true, forKey: "hasCompletedFDAOnboarding")
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
        ZStack {
            let headerIcon = manager.isSubcategoryDrillDown
                ? (manager.selectedSubcategory?.subcategory?.icon ?? "folder.fill")
                : category.category.icon
            let headerName = manager.isSubcategoryDrillDown
                ? (manager.selectedSubcategory?.displayName ?? category.category.displayName)
                : category.category.displayName
            let headerBytes = manager.isSubcategoryDrillDown
                ? (manager.selectedSubcategory?.totalBytes ?? category.currentSizeBytes)
                : category.currentSizeBytes

            HStack(spacing: 8) {
                Image(systemName: headerIcon)
                    .font(.system(size: 13))
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
                            .font(.system(size: 13, weight: .semibold))
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
            .frame(maxWidth: .infinity, alignment: .leading)

            // Right: Category size
            HStack {
                Spacer()
                Text(formattedBytes(headerBytes))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.gray.opacity(0.15))
                    )
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
                        .foregroundStyle(.primary)
                        .contentShape(Circle())
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
                .help("Refresh Latest Delta")

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
                        .fill(isDisabled ? Color.blue.opacity(0.35) : Color.blue)
                )
                .foregroundStyle(.white)
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.7 : 1.0)
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

    private func onboardingCard(
        icon: String,
        iconColor: Color,
        title: String,
        message: String,
        primaryTitle: String,
        primaryMinWidth: CGFloat,
        primaryDisabled: Bool,
        primaryAction: @escaping () -> Void,
        secondaryTitle: String?,
        secondaryAction: (() -> Void)?,
        detailText: String
    ) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: 0) {
                VStack(spacing: 14) {
                    Image(systemName: icon)
                        .font(.system(size: 34))
                        .foregroundStyle(iconColor)

                    VStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 18, weight: .semibold))

                        Text(message)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 260)
                    }
                }
                .frame(height: 146)

                VStack(spacing: 10) {
                    primaryActionButton(
                        primaryTitle,
                        minWidth: primaryMinWidth,
                        isDisabled: primaryDisabled,
                        action: primaryAction
                    )

                    Group {
                        if let secondaryTitle, let secondaryAction {
                            secondaryActionButton(secondaryTitle, action: secondaryAction)
                        } else {
                            Color.clear.frame(height: 20)
                        }
                    }

                    Text(detailText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 270)
                        .frame(height: 42, alignment: .top)
                }
                .frame(height: 112, alignment: .top)
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
                        .fill(Color.white.opacity(0.45))
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

#Preview {
    // Cannot preview easily with Bindable manager without mock
    Text("Preview not available")
}
