import SwiftUI
import AppKit

/// List view showing inventory grouped by category with growth indicators and drill-down navigation
struct CategoryGrowthListView: View {
    /// Growing categories with active growth trends
    let growingCategories: [CategoryInventoryItem]

    /// Stable categories without growth
    let stableCategories: [CategoryInventoryItem]

    /// Total size of all stable categories
    let stableTotalBytes: Int64

    /// Menu bar manager for drill-down state tracking
    @Bindable var manager: MenuBarManager

    /// Callback when an item is tapped (reveal in Finder)
    var onTapItem: (String) -> Void = { _ in }

    /// Maximum height for the scrollable list
    var maxHeight: CGFloat = 360

    private let maxItemsPerExpandedFolder = 50

    var body: some View {
        // Conditional rendering: ONLY ONE view exists at a time for proper push animation
        ZStack {
            if manager.isDrilledDown, let selected = manager.selectedInventoryCategory {
                // Detail view - enters from right, exits left on back
                inventoryDetailView(for: selected)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing),
                        removal: .move(edge: .leading)
                    ))
            } else {
                // Main list view - exits left when category selected
                categoryListView
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading),
                        removal: .move(edge: .leading)
                    ))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: manager.isDrilledDown)
        .onChange(of: growingCategories.map(\.id) + stableCategories.map(\.id)) { _, _ in
            if manager.isDrilledDown && manager.selectedInventoryCategory == nil {
                manager.isDrilledDown = false
                expandedFolders.removeAll()
            }
        }
    }

    // MARK: - State

    @State private var expandedFolders: Set<String> = []

    // MARK: - Category List View

    private var categoryListView: some View {
        Group {
            if growingCategories.isEmpty && stableCategories.isEmpty {
                emptyStateView
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        if !growingCategories.isEmpty {
                            // Show growing categories first
                            ForEach(growingCategories) { item in
                                CategoryInventoryRow(
                                    item: item,
                                    onTap: {
                                        withAnimation(.easeInOut(duration: 0.3)) {
                                            selectCategory(item)
                                        }
                                    }
                                )
                                .equatable()
                            }

                            // "Everything else" summary row
                            StableCategoriesRow(
                                totalBytes: stableTotalBytes,
                                count: stableCategories.count
                            )
                        } else {
                            // Nothing growing - show full inventory
                            ForEach(stableCategories) { item in
                                CategoryInventoryRow(
                                    item: item,
                                    onTap: {
                                        // Non-tappable for now in stable view
                                        // Could expand to show full inventory later
                                    }
                                )
                                .equatable()
                            }
                        }
                    }
                }
                .frame(maxHeight: maxHeight)
            }
        }
    }

    // MARK: - Inventory Detail View

    private func inventoryDetailView(for category: CategoryInventoryItem) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                // Placeholder for folder-based drill-down
                // In a full implementation, we'd fetch and group items by folder
                Text("Category details for \(category.category.displayName)")
                    .font(.headline)
                    .padding()

                Text(formattedBytes(category.currentSizeBytes))
                    .font(.title)
                    .foregroundStyle(.secondary)

                if let trend = category.growthTrend {
                    VStack(spacing: 8) {
                        Text("↑ Growth: \(formattedBytes(trend.growthBytes))")
                            .foregroundStyle(.orange)

                        Text("Over \(trend.growthSpanDays) days")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: maxHeight)
    }

    // MARK: - Actions

    private func selectCategory(_ item: CategoryInventoryItem) {
        expandedFolders.removeAll()
        manager.selectedInventoryCategory = item
        manager.isDrilledDown = true
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
                Text("Your disk is stable")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)

                Text("Nothing significant has changed recently")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: maxHeight)
        .padding(.vertical, 20)
    }

    // MARK: - Helper Methods

    private func formattedBytes(_ bytes: Int64) -> String {
        let kb = Double(bytes) / 1_000
        let mb = kb / 1_000
        let gb = mb / 1_000

        if abs(gb) >= 1 {
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

// MARK: - Category Inventory Row

private struct CategoryInventoryRow: View, Equatable {
    static func == (lhs: CategoryInventoryRow, rhs: CategoryInventoryRow) -> Bool {
        lhs.item.id == rhs.item.id &&
        lhs.item.currentSizeBytes == rhs.item.currentSizeBytes &&
        lhs.item.growthTrend == rhs.item.growthTrend
    }

    let item: CategoryInventoryItem
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                // Category icon
                Image(systemName: item.category.icon)
                    .font(.system(size: 16))
                    .foregroundStyle(item.category.color ?? .secondary)
                    .frame(width: 20, height: 20)

                // Category name (flexible)
                Text(item.category.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Size (right-aligned, primary)
                Text(formattedBytes(item.currentSizeBytes))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minHeight: 32)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hoverState ? Color.gray.opacity(0.1) : Color.clear)
            )
            .padding(.horizontal, 6)
            .contentShape(Rectangle())

            // Growth indicator row (below, only if growing)
            if let trend = item.growthTrend {
                HStack(spacing: 10) {
                    // Spacer to align with icon above
                    Spacer().frame(width: 20)

                    Text("↑ \(formattedBytes(trend.growthBytes)) · \(trend.growthSpanDays) days")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)

                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                hoverState = hovering
            }
        }
    }

    @State private var hoverState = false

    private func formattedBytes(_ bytes: Int64) -> String {
        let kb = Double(bytes) / 1_000
        let mb = kb / 1_000
        let gb = mb / 1_000

        if abs(gb) >= 1 {
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

// MARK: - Stable Categories Summary Row

private struct StableCategoriesRow: View {
    let totalBytes: Int64
    let count: Int

    var body: some View {
        HStack(spacing: 10) {
            // Icon
            Image(systemName: "folder")
                .font(.system(size: 16))
                .foregroundStyle(.gray)
                .frame(width: 20, height: 20)

            // Label
            Text("Everything else")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Size
            Text(formattedBytes(totalBytes))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(minHeight: 32)
        .padding(.horizontal, 6)
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        let kb = Double(bytes) / 1_000
        let mb = kb / 1_000
        let gb = mb / 1_000

        if abs(gb) >= 1 {
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

// MARK: - Preview

#Preview {
    // Note: Preview not available without MenuBarManager instance
    Text("Preview requires MenuBarManager")
        .frame(width: 320, height: 400)
}
