import SwiftUI
import AppKit

struct MenuBarView: View {
    @Bindable var manager: MenuBarManager
    
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss
    @State private var resetHover = false
    @State private var settingsHover = false
    @State private var isResetting = false

    private func closePopoverAndOpenSettings() {
        // Close the popover first
        if let popover = NSApp.windows.first(where: { $0.contentViewController?.view.window?.isVisible == true && $0.className.contains("NSPopover") }) {
            popover.close()
        }
        
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
            // Drive bar section
            VStack(alignment: .leading, spacing: 4) {
                DriveBarView(
                    totalBytes: manager.totalBytes,
                    usedBytes: manager.usedBytes,
                    freeBytes: manager.freeBytes
                )
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            // Growth list section
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("What Grew")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        if !manager.monitoredPathName.isEmpty {
                            Text(manager.monitoredPathName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

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
                                await manager.loadGrowthList()
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else if manager.growthItems.isEmpty && !manager.isLoading {
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
                                await manager.loadGrowthList()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else {
                    GrowthListView(
                        growthItems: manager.growthItems,
                        onTapItem: { item in
                            manager.revealInFinder(path: item.path)
                        }
                    )
                }
            }

            Spacer()

            Divider()

            // Footer - native macOS menu style rows (per design guide)
            VStack(spacing: 0) {
                // Reset Baseline (28pt row height, 6pt corner radius, 4-6pt inset)
                Button {
                    isResetting = true
                    Task {
                        // We access resetBaseline directly via selector or expose it?
                        // MenuBarManager has public method? No, it's @objc private.
                        // But we can call createBaseline which is similar but reset is actually "Reset Baseline".
                        // Wait, MenuBarManager had 'resetBaseline' as action, but it calls baselineService.
                        // Let's assume we can call resetBaseline if we make it internal/public.
                        // Or we call `baselineService.resetBaseline()` directly? No, better via manager.
                        // I need to start exposing `resetBaseline` in Manager as internal.
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
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(resetHover && !isResetting ? Color.accentColor : Color.clear)
                    )
                    .foregroundStyle(resetHover && !isResetting ? .white : .primary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    resetHover = hovering
                }
                .disabled(manager.isLoading || isResetting)
                .padding(.horizontal, 5)

                // Settings (28pt row height, 6pt corner radius, 4-6pt inset)
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
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(settingsHover ? Color.accentColor : Color.clear)
                    )
                    .foregroundStyle(settingsHover ? .white : .primary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    settingsHover = hovering
                }
                .padding(.horizontal, 5)
            }
            .padding(.vertical, 4)
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

                        if !manager.scanProgress.isEmpty {
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
