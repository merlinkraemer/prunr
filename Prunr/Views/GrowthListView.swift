import SwiftUI
import AppKit

/// List view showing growth items with reveal-in-Finder functionality
struct GrowthListView: View {
    /// Growth items to display
    let growthItems: [BaselineService.GrowthItem]

    /// Callback when an item is tapped
    var onTapItem: (BaselineService.GrowthItem) -> Void = { _ in }

    /// Maximum height for the scrollable list
    var maxHeight: CGFloat = 300

    var body: some View {
        Group {
            if growthItems.isEmpty {
                emptyStateView
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(growthItems) { item in
                            GrowthItemRow(item: item)
                                .onTapGesture {
                                    onTapItem(item)
                                }
                                .buttonStyle(.plain)

                            if item.id != growthItems.last?.id {
                                Divider()
                                    .padding(.leading, 44)
                            }
                        }
                    }
                }
                .frame(maxHeight: maxHeight)
            }
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 32))
                .foregroundStyle(.green)

            Text("No changes detected")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("Your disk usage is stable")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: maxHeight)
        .padding(.vertical, 20)
    }
}

// MARK: - Growth Item Row

private struct GrowthItemRow: View {
    let item: BaselineService.GrowthItem

    var body: some View {
        HStack(spacing: 12) {
            // Folder icon
            Image(systemName: "folder.fill")
                .font(.system(size: 16))
                .foregroundStyle(.blue)
                .frame(width: 20)

            // Path and growth info
            VStack(alignment: .leading, spacing: 4) {
                // Truncated path name
                Text(displayName)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)

                // Growth bar and size info
                HStack(spacing: 8) {
                    GrowthBarView(
                        changeBytes: item.growthBytes,
                        maxBytes: maxGrowthBytes
                    )
                    .frame(width: 60, height: 6)

                    Text(growthText)
                        .font(.caption)
                        .foregroundStyle(.red)

                    Spacer()

                    Text(currentSizeText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 8)

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(hoverState ? Color.accentColor : Color.clear)
        )
        .foregroundStyle(hoverState ? .white : .primary)
        .padding(.horizontal, 5)
        .onHover { hovering in
            hoverState = hovering
        }
    }

    @State private var hoverState = false

    // MARK: - Display Helpers

    /// Truncated display name for the path
    private var displayName: String {
        let path = item.path
        let maxLength = 40

        if path.count <= maxLength {
            return path
        }

        // Show first part and last part
        let firstPart = String(path.prefix(maxLength / 2 - 2))
        let lastPart = String(path.suffix(maxLength / 2 - 2))
        return "\(firstPart)...\(lastPart)"
    }

    /// Growth text (e.g., "+1.2 GB")
    private var growthText: String {
        formattedBytes(item.growthBytes, prefix: "+")
    }

    /// Current size text (e.g., "3.5 GB")
    private var currentSizeText: String {
        formattedBytes(item.currentSizeBytes)
    }

    /// Max growth bytes for proportional bar calculation
    /// Using a reasonable default for visual scaling
    private var maxGrowthBytes: Int64 {
        // Scale bars so 1 GB is about half width
        max(1_000_000_000, item.growthBytes * 2)
    }

    /// Formats bytes for display
    private func formattedBytes(_ bytes: Int64, prefix: String = "") -> String {
        let mb = Double(bytes) / 1_000_000
        let gb = mb / 1000

        if abs(gb) >= 1 {
            return "\(prefix)\(String(format: "%.1f", gb)) GB"
        } else if abs(mb) >= 1 {
            return "\(prefix)\(String(format: "%.0f", mb)) MB"
        } else {
            return "\(prefix)\(bytes) B"
        }
    }
}

// MARK: - Sample Data

extension GrowthListView {
    enum PreviewData {
        static var sampleItems: [BaselineService.GrowthItem] {
            [
                BaselineService.GrowthItem(
                    path: "/Users/merlinkramer/Library/Caches/com.apple.Safari",
                    growthBytes: 1_500_000_000,
                    currentSizeBytes: 2_500_000_000,
                    percentOfParent: 0.45
                ),
                BaselineService.GrowthItem(
                    path: "/Users/merlinkramer/Documents/old-projects",
                    growthBytes: 850_000_000,
                    currentSizeBytes: 1_200_000_000,
                    percentOfParent: 0.25
                ),
                BaselineService.GrowthItem(
                    path: "/Users/merlinkramer/Downloads/installer.pkg",
                    growthBytes: 450_000_000,
                    currentSizeBytes: 450_000_000,
                    percentOfParent: 0.15
                ),
                BaselineService.GrowthItem(
                    path: "/Users/merlinkramer/.docker/overlay2",
                    growthBytes: 250_000_000,
                    currentSizeBytes: 800_000_000,
                    percentOfParent: 0.10
                ),
                BaselineService.GrowthItem(
                    path: "/Users/merlinkramer/Media/videos",
                    growthBytes: 100_000_000,
                    currentSizeBytes: 3_500_000_000,
                    percentOfParent: 0.05
                ),
            ]
        }
    }
}

#Preview {
    VStack {
        Text("Growth List Preview")
            .font(.headline)

        Divider()

        GrowthListView(growthItems: GrowthListView.PreviewData.sampleItems) { item in
            print("Tapped: \(item.path)")
        }
    }
    .frame(width: 320, height: 300)
    .padding()
}
