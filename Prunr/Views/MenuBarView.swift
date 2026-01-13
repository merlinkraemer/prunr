import SwiftUI
import AppKit

struct MenuBarView: View {
    @Bindable var manager: MenuBarManager

    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss
    @State private var scanHover = false
    @State private var settingsHover = false
    @State private var isHeaderExpanded = false
    @State private var isScanning = false

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
            // Main category view with monitoring path header
            mainCategoryView
        }
        .frame(width: 320, height: 480)
        .overlay {
            // Loading indicator with progress
            // Only show blocking overlay for manual scans, not auto-scans (ISS-038)
            if manager.isLoading && !manager.isAutoScanning {
                ZStack {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()

                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.regular)

                        // Progress bar with percentage (shows from 1% onward)
                        if manager.scanProgressPercentage >= 0.01 {
                            ProgressView(value: manager.scanProgressPercentage, total: 1.0)
                                .frame(width: 200)
                                .progressViewStyle(.linear)
                            Text("\(Int(manager.scanProgressPercentage * 100))%")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }

                        if manager.isAutoScanning {
                            Text("Auto-scanning changes...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if !manager.scanProgress.isEmpty {
                            Text(manager.scanProgress)
                                .font(.caption)
                                .foregroundStyle(.primary)
                        }

                        if manager.filesScanned > 0 {
                            Text("\(manager.filesScanned) files scanned")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }

                        Button("Stop") {
                            Task {
                                await manager.stopScan()
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .frame(width: 260, height: 180)
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .task {
            // Fast: Check if baseline exists (UserDefaults lookup)
            await manager.checkBaseline()

            // Fast: Update disk space with caching (only if >5s since last update)
            manager.updateFreeSpaceIfNeeded()

            // Slow: Defer path size calculation to background after popup is visible
            // This scans the entire directory tree and should NOT block popup opening
            Task.detached(priority: .utility) {
                await manager.updatePathSize()
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

            // Footer buttons (no separator)
            footerButtons
        }
    }

    // MARK: - Drive Bar Section (Always Visible)

    private var driveBarSection: some View {
        DriveBarView(
            totalBytes: manager.totalBytes,
            usedBytes: manager.usedBytes,
            freeBytes: manager.freeBytes
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Page Navigation Content

    private var pageNavigationContent: some View {
        VStack(spacing: 0) {
            // Header section - switches between monitoring path and drill-down
            headerSection
            Divider()
            // Single CategoryGrowthListView instance handles internal animation
            categoryListView
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Header Section

    private var headerSection: some View {
        Group {
            if manager.isDrilledDown, let category = manager.selectedCategoryForDrilldown {
                // Drill-down header: back button, category name, size
                drillDownHeader(category: category)
            } else {
                // Main header: monitoring path, size, settings link
                monitoringPathHeader
            }
        }
        .animation(.easeInOut(duration: 0.3), value: manager.isDrilledDown)
    }

    // MARK: - Drill-down Header

    private func drillDownHeader(category: CategoryGrowthItem) -> some View {
        Button {
            closePopoverAndOpenSettings()
        } label: {
            HStack(spacing: 8) {
                // Back button on left
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        manager.isDrilledDown = false
                        manager.selectedCategoryForDrilldown = nil
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

                Spacer()

                // Category name and icon (center)
                HStack(spacing: 6) {
                    Image(systemName: category.category.icon)
                        .font(.system(size: 11))
                        .foregroundStyle(category.category.color ?? .secondary)

                    Text(category.category.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                Spacer()

                // Category size (right)
                Text(formattedBytes(category.totalGrowthBytes))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color.gray.opacity(0.15))
                    )
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Monitoring Path Header

    private var hasMultiplePaths: Bool {
        SettingsStore.shared.enabledTrackedPaths.count > 1
    }

    private var monitoringPathHeader: some View {
        VStack(spacing: 0) {
            Button {
                // Only expand if multiple paths
                if hasMultiplePaths {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        isHeaderExpanded.toggle()
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    // Path icon
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    // Single path: show full path, Multiple paths: show tags
                    if hasMultiplePaths {
                        // Folder tags (showing folder names)
                        HStack(spacing: 6) {
                            ForEach(manager.folderNames, id: \.self) { folderName in
                                Text(folderName)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        Capsule()
                                            .fill(Color.gray.opacity(0.15))
                                    )
                            }
                        }
                    } else if let firstPath = SettingsStore.shared.enabledTrackedPaths.first {
                        // Single path: show full path
                        Text(firstPath.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()

                    // Auto-scan indicator (if scanning)
                    if manager.isAutoScanning {
                        HStack(spacing: 4) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Scanning...")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .transition(.opacity)
                    }

                    // Expand/collapse chevron - only show for multiple paths
                    if hasMultiplePaths {
                        Image(systemName: isHeaderExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            // Expanded paths list - full width dropdown (only for multiple paths)
            if isHeaderExpanded && hasMultiplePaths {
                Divider()

                VStack(spacing: 0) {
                    ForEach(Array(SettingsStore.shared.enabledTrackedPaths.enumerated()), id: \.element.id) { index, path in
                        HStack(spacing: 8) {
                            // Folder icon
                            Image(systemName: "folder.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.blue)

                            // Path text with tilde notation
                            Text(path.url.path)
                                .font(.system(size: 11))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer()

                            // Size badge if calculated
                            if manager.monitoredPathSizeBytes > 0 && !manager.isCalculatingPathSize {
                                Text(formattedBytes(manager.monitoredPathSizeBytes))
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.gray.opacity(0.03))

                        if index < SettingsStore.shared.enabledTrackedPaths.count - 1 {
                            Divider()
                                .padding(.leading, 36)
                        }
                    }
                }
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
    }

    // MARK: - Category List View

    private var categoryListView: some View {
        Group {
            if manager.noBaseline {
                // No baseline prompt
                VStack(spacing: 12) {
                    Image(systemName: "clock.badge.questionmark")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("No baseline yet")
                        .font(.headline)
                    Text("Create a baseline to start tracking growth")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Create Baseline") {
                        Task {
                            await manager.createBaseline()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else if let error = manager.errorMessage {
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
                            await manager.loadCategoryGrowthList()
                        }
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else if manager.categoryItems.isEmpty && !manager.isLoading {
                // Baseline exists but no growth data loaded yet
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("Ready to scan")
                        .font(.headline)
                    Text("Scan to see what changed since baseline")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Scan Now") {
                        Task {
                            await manager.loadCategoryGrowthList()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                CategoryGrowthListView(
                    categoryItems: manager.categoryItems,
                    manager: manager,
                    onTapItem: { item in
                        // Reveal item in Finder
                        NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
                    }
                    // No forcedCategory - uses internal selection
                )
            }
        }
    }

    // MARK: - Footer Buttons (Icon Toolbar - No Separator)

    private var footerButtons: some View {
        HStack {
            // Scan/Refresh button (lower left)
            Button {
                isScanning = true
                Task {
                    await manager.loadCategoryGrowthList()

                    // Wait for manager to finish loading before showing done
                    while manager.isLoading {
                        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
                    }

                    // Brief delay to show completion
                    try? await Task.sleep(for: .milliseconds(500))
                    isScanning = false
                }
            } label: {
                Group {
                    if isScanning {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .font(.system(size: 13))
                .frame(width: 26, height: 26)
                .background(
                    Circle()
                        .fill(scanHover && !isScanning ? Color.gray.opacity(0.12) : Color.clear)
                )
                .foregroundStyle(.primary)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    scanHover = hovering
                }
            }
            .disabled(manager.isLoading || isScanning)
            .help("Refresh View")

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
