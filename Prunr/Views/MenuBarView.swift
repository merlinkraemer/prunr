import SwiftUI
import AppKit

struct MenuBarView: View {
    @Bindable var manager: MenuBarManager

    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss
    @State private var resetHover = false
    @State private var scanHover = false
    @State private var settingsHover = false
    @State private var isResetting = false
    @State private var isScanning = false

    private func closePopoverAndOpenSettings() {
        // Close the popover first via manager to ensure state sync
        manager.closePopover()

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

                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.regular)

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
                                .font(.caption2)
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
                    .padding(20)
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
            // Header with drive bar + monitoring path (hidden during drill-down - ISS-037)
            if !manager.isDrilledDown {
                mainHeaderView
                Divider()
            }

            // Category list
            categoryListView

            Spacer()

            Divider()

            // Footer buttons
            footerButtons
        }
    }

    // MARK: - Main Header View

    private var mainHeaderView: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Top row: Drive bar with total/free (PRIMARY INFO)
            DriveBarView(
                totalBytes: manager.totalBytes,
                usedBytes: manager.usedBytes,
                freeBytes: manager.freeBytes
            )

            // Subtle separator between sections
            Rectangle()
                .fill(Color.gray.opacity(0.1))
                .frame(height: 1)

            // Bottom row: Path info (SECONDARY INFO) - clickable to open settings
            Button {
                closePopoverAndOpenSettings()
            } label: {
                HStack(spacing: 8) {
                    // Path icon
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    // Path text (truncated with middle ellipsis)
                    Text(manager.monitoredPathDisplay)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    // Path size badge or loading state
                    if manager.isCalculatingPathSize {
                        HStack(spacing: 4) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("Calculating...")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.gray.opacity(0.1))
                        )
                    } else if manager.monitoredPathSizeBytes > 0 {
                        Text(formattedBytes(manager.monitoredPathSizeBytes))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(Color.gray.opacity(0.15))
                            )
                    }

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

                    // Settings chevron indicator
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(20)
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
                )
            }
        }
    }

    // MARK: - Footer Buttons

    private var footerButtons: some View {
        VStack(spacing: 0) {
                // Scan Now
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
                    HStack(spacing: 8) {
                        Group {
                            if isScanning {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } else {
                                Image(systemName: "magnifyingglass")
                            }
                        }
                        .frame(width: 16, height: 16)

                        Text(isScanning ? "Done!" : "Scan Now")
                            .font(.system(size: 13))
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 6) // 6pt rounded corners like system menus
                            .fill(scanHover && !isScanning ? Color.gray.opacity(0.1) : Color.clear)
                    )
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 6) // Small inset from edges (not full width)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    scanHover = hovering
                }
                .disabled(manager.isLoading || isScanning)

                // Reset Baseline
                Button {
                    isResetting = true
                    Task {
                        await manager.performReset()

                        // Brief delay to show completion
                        try? await Task.sleep(for: .milliseconds(500))
                        isResetting = false
                    }
                } label: {
                    HStack(spacing: 8) {
                        Group {
                            if isResetting {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .frame(width: 16, height: 16)

                        Text(isResetting ? "Done!" : "Reset Baseline")
                            .font(.system(size: 13))
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(resetHover && !isResetting ? Color.gray.opacity(0.1) : Color.clear)
                    )
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 6) // Small inset from edges
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    resetHover = hovering
                }
                .disabled(manager.isLoading || isResetting)

                // Settings
                Button {
                    closePopoverAndOpenSettings()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "gear")
                            .frame(width: 16, height: 16)
                        Text("Settings...")
                            .font(.system(size: 13))
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(settingsHover ? Color.gray.opacity(0.1) : Color.clear)
                    )
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 6) // Small inset from edges
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    settingsHover = hovering
                }
            }
            .padding(.vertical, 8)
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
