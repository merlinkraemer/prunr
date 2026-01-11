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
        
        // Ensure Settings window is focused
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.activate(ignoringOtherApps: true)
            if let settingsWindow = NSApp.windows.first(where: { $0.title.contains("Settings") }) {
                settingsWindow.makeKeyAndOrderFront(nil)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Drive bar section (HIG: 20pt margins for standard window content)
            VStack(alignment: .leading, spacing: 4) {
                DriveBarView(
                    totalBytes: manager.totalBytes,
                    usedBytes: manager.usedBytes,
                    freeBytes: manager.freeBytes
                )
            }
            .padding(20) // HIG standard: 20pt margins

            Divider()

            // Growth list section header (distinct from list items, shows full scanned path)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    // Label + path (no folder icon to differentiate from list items)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("MONITORING")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)

                        Text(manager.monitoredPathDisplay)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }

                    Spacer()

                    // Auto-scan indicator
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
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12) // Extra spacing below header for separation

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
                        onTapItem: { item in
                            manager.revealInFinder(path: item.path)
                        }
                    )
                }
            }

            Spacer()

            Divider()

            // Footer - buttons like WiFi/Bluetooth system menus (small inset + rounded corners)
            VStack(spacing: 0) {
                // Scan Now
                Button {
                    isScanning = true
                    Task {
                        await manager.loadCategoryGrowthList()

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
        .frame(width: 320, height: 420)
        .overlay {
            // Loading indicator with progress
            if manager.isLoading {
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
            // Refresh disk space immediately (fast)
            manager.updateFreeSpace()
            
            // Just check if baseline exists, don't auto-scan
            await manager.checkBaseline()
        }
    }
}

#Preview {
    // Cannot preview easily with Bindable manager without mock
    Text("Preview not available")
}
