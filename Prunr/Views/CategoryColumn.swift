import SwiftUI

/// First column: Category selection with item counts
struct CategoryColumn: View {
    /// Binding to the currently selected category (nil = show all)
    @Binding var selectedCategory: DeltaCategory?

    /// All deltas to categorize and count
    var deltas: [Delta]

    /// Computed property: deltas grouped by category
    private var categorizedDeltas: [DeltaCategory: [Delta]] {
        var result: [DeltaCategory: [Delta]] = [:]
        for category in DeltaCategory.allCases {
            result[category] = []
        }
        for delta in deltas {
            let category = DeltaCategory.categorize(path: delta.path)
            result[category, default: []].append(delta)
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Categories")
                .font(.headline)
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 8)

            List(selection: $selectedCategory) {
                // "All" option at top to show unfiltered items
                AllCategoriesOption(count: deltas.count)
                    .tag(nil as DeltaCategory?)

                Divider()

                // Individual categories
                ForEach(DeltaCategory.allCases) { category in
                    CategoryRow(
                        category: category,
                        count: categorizedDeltas[category]?.count ?? 0
                    )
                    .tag(category as DeltaCategory?)
                }
            }
            .listStyle(.inset)
        }
    }
}

/// Row for "All" option (shows unfiltered items)
private struct AllCategoriesOption: View {
    let count: Int

    var body: some View {
        Label {
            Text("All")
            Spacer()
            Text("\(count)")
                .font(.caption)
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: "doc.text.magnifyingglass")
        }
    }
}

/// Row for a single category
private struct CategoryRow: View {
    let category: DeltaCategory
    let count: Int

    var body: some View {
        Label {
            Text(category.displayName)
            Spacer()
            Text("\(count)")
                .font(.caption)
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: category.icon)
        }
    }
}

#Preview {
    CategoryColumn(
        selectedCategory: .constant(nil),
        deltas: [
            Delta(path: "/Applications/Test.app", oldSizeBytes: 1000000, newSizeBytes: 1500000),
            Delta(path: "~/Library/Containers/test", oldSizeBytes: 500000, newSizeBytes: 600000),
            Delta(path: "~/node_modules/package", oldSizeBytes: 10000000, newSizeBytes: 12000000),
            Delta(path: "/tmp/file.txt", oldSizeBytes: 100, newSizeBytes: 200)
        ]
    )
}
