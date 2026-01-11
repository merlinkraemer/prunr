import SwiftUI

/// Third column: Full details for the selected delta item
struct DetailColumn: View {
    /// The selected delta item (nil shows empty state)
    let item: Delta?

    /// Category of the selected item
    private var category: DeltaCategory? {
        guard let item = item else { return nil }
        return DeltaCategory.categorize(path: item.path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Details")
                .font(.headline)
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 8)

            if let item = item {
                detailContent(item)
            } else {
                emptyState
            }

            Spacer()
        }
    }

    /// Detail view for a selected item
    @ViewBuilder
    private func detailContent(_ item: Delta) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Path section
                DetailSection(title: "Path") {
                    Text(item.path)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }

                // Category badge
                if let category = category {
                    DetailSection(title: "Category") {
                        Label(category.displayName, systemImage: category.icon)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(category.color.opacity(0.15))
                            .foregroundStyle(category.color)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }

                // Before size
                if let before = item.oldSizeBytes {
                    DetailSection(title: "Before") {
                        Text(ByteCountFormatter.string(fromByteCount: before, countStyle: .file))
                            .font(.system(.body, design: .monospaced))
                    }
                } else {
                    DetailSection(title: "Before") {
                        Text("New file")
                            .foregroundStyle(.secondary)
                    }
                }

                // After size
                if let after = item.newSizeBytes {
                    DetailSection(title: "After") {
                        Text(ByteCountFormatter.string(fromByteCount: after, countStyle: .file))
                            .font(.system(.body, design: .monospaced))
                    }
                } else {
                    DetailSection(title: "After") {
                        Text("Deleted")
                            .foregroundStyle(.secondary)
                    }
                }

                // Change
                DetailSection(title: "Change") {
                    HStack(spacing: 6) {
                        Image(systemName: item.isGrowth ? "arrow.up" : "arrow.down")
                            .foregroundStyle(item.changeColor)
                        Text(formattedChange(item.changeBytes))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(item.changeColor)
                    }
                }

                // Percentage change
                if let percent = item.percentChange {
                    DetailSection(title: "Percentage") {
                        Text(formattedPercent(percent))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(item.changeColor)
                    }
                }
            }
            .padding()
        }
    }

    /// Empty state when no item is selected
    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "info.circle")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Select an item")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Choose a category and item to view details")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Helpers

    private func formattedChange(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.countStyle = .file
        let formatted = formatter.string(fromByteCount: abs(bytes))
        return bytes > 0 ? "+\(formatted)" : "-\(formatted)"
    }

    private func formattedPercent(_ percent: Double) -> String {
        let sign = percent >= 0 ? "+" : ""
        return String(format: "\(sign)%.2f%%", percent)
    }
}

/// Reusable section with label and content
private struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content
        }
    }
}

// MARK: - Delta Extensions for DetailColumn

extension Delta {
    /// Color for size change indicator
    var changeColor: Color {
        isGrowth ? .green : .red
    }
}

// MARK: - DeltaCategory Color Extension

extension DeltaCategory {
    /// Display color for the category
    var color: Color {
        switch self {
        case .apps: return .blue
        case .packages: return .purple
        case .containers: return .orange
        case .caches: return .yellow
        case .developer: return .indigo
        case .homebrew: return .brown
        case .docker: return .cyan
        case .npm: return .green
        case .media: return .pink
        case .other: return .gray
        }
    }
}

#Preview {
    DetailColumn(item: Delta(
        path: "/Users/test/Developer/project/node_modules/package/index.js",
        oldSizeBytes: 1024000,
        newSizeBytes: 1536000
    ))
}
