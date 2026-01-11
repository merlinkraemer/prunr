import SwiftUI

/// Three-column container for category-based navigation of delta data
/// Columns: CategoryColumn (categories) -> ItemColumn (filtered items) -> DetailColumn (item details)
struct ColumnContainerView: View {
    /// Binding to the deltas array
    @Binding var deltas: [Delta]

    /// Currently selected category (nil shows all items)
    @State private var selectedCategory: DeltaCategory?

    /// Currently selected delta item
    @State private var selectedItem: Delta?

    var body: some View {
        HStack(spacing: 0) {
            // Column 1: Category selection
            CategoryColumn(
                selectedCategory: $selectedCategory,
                deltas: deltas
            )
            .frame(minWidth: 140, maxWidth: 200)

            Divider()

            // Column 2: Item list (filtered by category)
            ItemColumn(
                selectedItem: $selectedItem,
                selectedCategory: selectedCategory,
                deltas: deltas
            )
            .frame(minWidth: 280, maxWidth: 450)

            Divider()

            // Column 3: Item details
            DetailColumn(item: selectedItem)
                .frame(minWidth: 250, maxWidth: .infinity)
        }
    }
}

#Preview {
    ColumnContainerView(deltas: .constant([
        Delta(path: "/Users/test/app.app", oldSizeBytes: 1000000, newSizeBytes: 1500000),
        Delta(path: "/Users/test/file.txt", oldSizeBytes: 500, newSizeBytes: 200)
    ]))
}
