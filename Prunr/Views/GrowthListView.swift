import SwiftUI
import AppKit


/// List view showing growth items with modern, intuitive design
struct GrowthListView: View {
    /// Growth items to display
    let growthItems: [GrowthItem]

    /// Callback when an item is tapped
    var onTapItem: (GrowthItem) -> Void = { _ in }

    /// Maximum height for the scrollable list
    var maxHeight: CGFloat = 300

    var body: some View {
        Group {
            if growthItems.isEmpty {
                emptyStateView
            } else {
                ScrollView {
                    VStack(spacing: 0) { // System menus have no spacing between rows
                        ForEach(growthItems) { item in
                            GrowthItemRow(item: item)
                                .onTapGesture {
                                    onTapItem(item)
                                }
                                .buttonStyle(.plain)
                        }
                    }
                }
                .hiddenScrollIndicators()
                .frame(maxHeight: maxHeight)
            }
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.1))
                    .frame(width: 64, height: 64)

                Image(systemName: "checkmark")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.green)
            }

            VStack(spacing: 4) {
                Text("No Changes")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)

                Text("Your disk usage is stable")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: maxHeight)
        .padding(.vertical, 20) // HIG: within 12-24pt range
    }
}

// MARK: - Growth Item Row

private struct GrowthItemRow: View {
    let item: GrowthItem

    var body: some View {
        HStack(spacing: 10) {
            // Folder icon with color based on growth severity
            Image(systemName: "folder.fill")
                .font(.system(size: 16))
                .foregroundStyle(growthSeverityColor)
                .frame(width: 20, height: 20) // Fixed size for alignment

            // Folder name only (not full path - that's in header)
            Text(fileName)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer()

            // Growth amount on right side
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(growthSeverityColor)

                Text(growthText)
                    .font(.system(size: 12))
                    .foregroundStyle(growthSeverityColor)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(minHeight: 28)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6) // 6pt rounded corners like system menus
                .fill(hoverState ? Color.gray.opacity(0.1) : Color.clear)
        )
        .padding(.horizontal, 6) // Small inset from edges (not full width)
        .help(item.path)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                hoverState = hovering
            }
        }
    }

    @State private var hoverState = false

    // MARK: - Display Helpers

    /// Extract just the file/folder name
    private var fileName: String {
        URL(fileURLWithPath: item.path).lastPathComponent
    }

    /// Growth text (e.g., "+1.2 GB")
    private var growthText: String {
        formattedBytes(item.growthBytes, prefix: "+")
    }

    /// Color based on growth severity
    private var growthSeverityColor: Color {
        let gb = Double(item.growthBytes) / 1_000_000_000
        if gb >= 5 {
            return .red
        } else if gb >= 1 {
            return .orange
        } else if gb >= 0.1 {
            return .yellow
        } else {
            return .green
        }
    }

    /// Formats bytes for display
    private func formattedBytes(_ bytes: Int64, prefix: String = "") -> String {
        let kb = Double(bytes) / 1_000
        let mb = kb / 1_000
        let gb = mb / 1_000

        if abs(gb) >= 1 {
            return "\(prefix)\(String(format: "%.1f", gb)) GB"
        } else if abs(mb) >= 1 {
            return "\(prefix)\(String(format: "%.0f", mb)) MB"
        } else if abs(kb) >= 1 {
            return "\(prefix)\(String(format: "%.0f", kb)) KB"
        } else {
            return "\(prefix)\(bytes) B"
        }
    }
}

// MARK: - Sample Data

extension GrowthListView {
    enum PreviewData {
        static var sampleItems: [GrowthItem] {
            [
                GrowthItem(
                    path: "/Users/merlinkramer/Library/Caches/com.apple.Safari",
                    growthBytes: 5_500_000_000,
                    currentSizeBytes: 7_500_000_000,
                    percentOfParent: 0.45
                ),
                GrowthItem(
                    path: "/Users/merlinkramer/Library/Caches/com.apple.Safari/CacheData",
                    growthBytes: 2_100_000_000,
                    currentSizeBytes: 3_200_000_000,
                    percentOfParent: 0.25
                ),
                GrowthItem(
                    path: "/Users/merlinkramer/Documents/old-projects",
                    growthBytes: 850_000_000,
                    currentSizeBytes: 1_200_000_000,
                    percentOfParent: 0.15
                ),
                GrowthItem(
                    path: "/Users/merlinkramer/Downloads/installer.pkg",
                    growthBytes: 450_000_000,
                    currentSizeBytes: 450_000_000,
                    percentOfParent: 0.10
                ),
                GrowthItem(
                    path: "/Users/merlinkramer/.docker/overlay2",
                    growthBytes: 250_000_000,
                    currentSizeBytes: 800_000_000,
                    percentOfParent: 0.05
                ),
                GrowthItem(
                    path: "/Users/merlinkramer/test_data/small_file.txt",
                    growthBytes: 50_000_000,
                    currentSizeBytes: 100_000_000,
                    percentOfParent: 0.01
                ),
            ]
        }
    }
}

#Preview {
    VStack {
        Text("Growth List - Redesigned")
            .font(.headline)

        Divider()

        GrowthListView(growthItems: GrowthListView.PreviewData.sampleItems) { item in
            print("Tapped: \(item.path)")
        }
    }
    .frame(width: 320, height: 350)
    .padding()
}
