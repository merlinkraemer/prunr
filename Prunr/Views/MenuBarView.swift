import SwiftUI
import AppKit

struct MenuBarView: View {
    @State private var viewModel = MenuBarViewModel()
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
                    totalBytes: viewModel.totalBytes,
                    usedBytes: viewModel.usedBytes,
                    freeBytes: viewModel.freeBytes
                )
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            // Growth list section
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("What Grew")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                GrowthListView(
                    growthItems: viewModel.growthItems,
                    onTapItem: { item in
                        viewModel.revealInFinder(path: item.path)
                    }
                )
            }

            Spacer()

            Divider()

            // Footer - native macOS menu style rows (per design guide)
            VStack(spacing: 0) {
                // Reset Baseline (28pt row height, 6pt corner radius, 4-6pt inset)
                Button {
                    isResetting = true
                    Task {
                        await viewModel.resetBaseline()
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
                .disabled(viewModel.isLoading || isResetting)
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
            // Loading indicator
            if viewModel.isLoading {
                ZStack {
                    Color.black.opacity(0.1)
                        .ignoresSafeArea()

                    VStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.regular)

                        Text("Scanning...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .task {
            // Load growth list when popover appears
            await viewModel.loadGrowthList()
            viewModel.refreshDiskSpace()
        }
    }
}

#Preview {
    MenuBarView()
}
