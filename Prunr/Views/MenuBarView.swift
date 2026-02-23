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
        VStack(spacing: 0) {
            // Main category view with monitoring path header
            mainCategoryView
        }
        .frame(width: 320, height: 480)
        .overlay(alignment: .top) {
            if manager.isLoading && !manager.isAutoScanning {
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        ProgressView(value: max(0.0, min(1.0, manager.scanProgressPercentage)), total: 1.0)
                            .progressViewStyle(.linear)
                            .tint(.blue)

                        Text("\(Int(max(0.0, min(1.0, manager.scanProgressPercentage)) * 100))%")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)

                        if manager.filesScanned > 0 {
                            Text("\(manager.filesScanned)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 0)

                        Button("Stop") {
                            Task { await manager.stopScan() }
                        }
                        .font(.system(size: 11, weight: .medium))
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                    }

                    if !manager.scanCurrentPath.isEmpty {
                        Text(manager.scanCurrentPath.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.96))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                )
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
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
        SettingsStore.shared.enabledTrackedPaths.count > 1
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
                        Text("\(SettingsStore.shared.enabledTrackedPaths.count) paths")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
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
