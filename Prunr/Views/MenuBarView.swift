import SwiftUI
import AppKit

struct MenuBarView: View {
    @Bindable var manager: MenuBarManager

    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss
    @State private var scanHover = false
    @State private var settingsHover = false
    @State private var isHeaderExpanded = false

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
        Group {
            if manager.isLoading && !manager.isAutoScanning {
                manualScanLoadingView
            } else if manager.noBaseline || manager.lastScanStatusText == "Last update: never" {
                firstScanView
            } else {
                VStack(spacing: 0) {
                    // Main category view with monitoring path header
                    mainCategoryView
                }
            }
        }
        .frame(width: 320, height: 480)
        .task {
            // Fast: Check if baseline exists (UserDefaults lookup)
            await manager.checkBaseline()

            // Fast: Update disk space with caching (only if >5s since last update)
            manager.updateFreeSpaceIfNeeded()

            // Update from latest snapshot (no filesystem rescan)
            await manager.updatePathSize()
        }
        .onChange(of: manager.isDrilledDown) { _, newValue in
            // Reset path header expansion when exiting drilldown
            if !newValue {
                withAnimation {
                    isHeaderExpanded = false
                }
            }
        }
    }

    private var manualScanLoadingView: some View {
        let clampedProgress = max(0.0, min(1.0, manager.scanProgressPercentage))

        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.blue)

                Text(manager.isCleaningUp ? "Cleaning up" : (manager.isAnalyzingChanges ? "Analyzing changes" : "Scanning files"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer()

                Button("Stop") {
                    Task { await manager.stopScan() }
                }
                .font(.system(size: 12, weight: .medium))
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .accessibilityLabel("Stop scan")
                .accessibilityHint("Cancel the current scan operation")

                Button {
                    closePopoverAndOpenSettings()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .background(
                            Circle()
                                .fill(Color.gray.opacity(0.10))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open settings")
                .accessibilityHint("Open settings while scan continues")
                .help("Settings (scan continues)")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            Spacer(minLength: 0)

            VStack(spacing: 18) {
                if manager.isCleaningUp {
                    VStack(spacing: 10) {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 13))
                                .foregroundStyle(.blue)
                            Text("Cleaning up")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.primary)
                        }

                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Reclaiming database space...")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if manager.isAnalyzingChanges {
                    VStack(spacing: 10) {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.green)
                            Text("Scan complete")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.primary)
                        }

                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Analyzing file changes...")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    VStack(spacing: 10) {
                        Text("\(Int(clampedProgress * 100))%")
                            .font(.system(size: 36, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)

                        ProgressView(value: clampedProgress, total: 1.0)
                            .progressViewStyle(.linear)
                            .tint(.blue)
                    }
                }

                if manager.filesScanned > 0 {
                    Text("\(manager.filesScanned) files scanned")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                if !manager.scanProgress.isEmpty && manager.scanCurrentPath.isEmpty && !manager.isAnalyzingChanges {
                    Text(manager.scanProgress)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if !manager.scanCurrentPath.isEmpty && !manager.isAnalyzingChanges {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Current path")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .textCase(.uppercase)

                        HStack(spacing: 8) {
                            Circle()
                                .fill(Color.blue)
                                .frame(width: 6, height: 6)

                            Text(manager.scanCurrentPath.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)

                            Spacer(minLength: 0)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.gray.opacity(0.08))
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Spacer(minLength: 0)
        }
        .background(Color(nsColor: .windowBackgroundColor))
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
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: 14) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 36))
                    .foregroundStyle(.blue)

                Text("Run your first scan")
                    .font(.system(size: 18, weight: .semibold))

                Text("Scanning creates a baseline so Prunr can track growth.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 260)

                Button {
                    Task {
                        await manager.loadCategoryGrowthList()
                    }
                } label: {
                    Text("Run first scan")
                        .frame(minWidth: 140)
                }
                .buttonStyle(.borderedProminent)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        ZStack {
            // Center: Category icon and name (truly centered)
            HStack(spacing: 8) {
                Image(systemName: category.category.icon)
                    .font(.system(size: 13))
                    .foregroundStyle(category.category.color ?? .secondary)

                Text(category.category.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)

            // Left: Back button
            HStack {
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
                .accessibilityLabel("Back")
                .accessibilityHint("Return to category overview")
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Right: Category size
            HStack {
                Spacer()
                Text(formattedBytes(category.totalGrowthBytes))
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

    // MARK: - Monitoring Path Header

    private var hasMultiplePaths: Bool {
        SettingsStore.shared.enabledOverviewPaths.count > 1
    }

    private var overviewPaths: [TrackedPath] {
        SettingsStore.shared.enabledOverviewPaths
    }

    private var monitoringPathHeader: some View {
        VStack(spacing: 0) {
            Button {
                // Multiple paths: expand/collapse, Single path: open settings
                if hasMultiplePaths {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        isHeaderExpanded.toggle()
                    }
                } else {
                    closePopoverAndOpenSettings()
                }
            } label: {
                HStack(spacing: 8) {
                    // Path icon
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    // Single path: show full path, Multiple paths: show count
                    if hasMultiplePaths {
                        Text("\(overviewPaths.count) paths")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    } else if let firstPath = overviewPaths.first {
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

                    // Right icon: chevron for multiple paths, > for single path
                    if hasMultiplePaths {
                        Image(systemName: isHeaderExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Monitored paths")
            .accessibilityHint(hasMultiplePaths ? "Expand or collapse tracked paths" : "Open settings")
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            // Expanded paths list - full width dropdown (only for multiple paths)
            if isHeaderExpanded && hasMultiplePaths {
                Divider()

                VStack(spacing: 0) {
                    ForEach(Array(overviewPaths.enumerated()), id: \.element.id) { index, path in
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
                            if !manager.isCalculatingPathSize {
                                let sizeBytes = manager.pathSizeBytes(for: path)
                                Text(formattedBytes(sizeBytes))
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.gray.opacity(0.03))

                        if index < overviewPaths.count - 1 {
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
                            await manager.loadCategoryGrowthList()
                        }
                    }
                    .buttonStyle(.bordered)
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
                Task {
                    await manager.loadCategoryGrowthList()
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
            .accessibilityLabel("Run scan now")
            .accessibilityHint("Create a new snapshot and refresh growth categories")
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    scanHover = hovering
                }
            }
            .disabled(manager.isLoading)
            .help("Refresh View")

            Spacer()

            Text(manager.isAutoScanning ? "Background scan running..." : manager.lastScanStatusText)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

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
        .background(Color(nsColor: .windowBackgroundColor))
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
