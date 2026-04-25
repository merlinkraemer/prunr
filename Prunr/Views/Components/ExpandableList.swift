import SwiftUI

/// A list that reveals items in chunks to avoid overwhelming the UI.
///
/// Two-level pagination:
/// - Level 1 (UI): Only `chunkSize` items are visible at a time. A "Show more"
///   button reveals the next chunk from already-loaded data.
/// - Level 2 (DB): When all loaded items are visible but more exist in the
///   database, a "Load more from disk" button triggers a DB fetch.
///
/// This keeps the UI responsive and reduces expensive DB round-trips because
/// the user can reveal multiple chunks before the disk needs to be hit again.
struct ExpandableList<Items: RandomAccessCollection, Row: View>: View where Items.Element: Identifiable {
    let items: Items
    let chunkSize: Int

    let canLoadMoreFromDB: Bool
    let isLoadingFromDB: Bool
    let onLoadMoreFromDB: () -> Void

    let remainingCountInDB: Int
    let remainingBytesInDB: Int64
    let maxLoadableCount: Int

    @ViewBuilder let row: (Items.Element) -> Row

    @State private var visibleCount: Int = 0
    @State private var previousItemCount: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.prefix(visibleCount))) { item in
                row(item)
            }

            affordance
        }
        .onAppear {
            resetVisibleCount(to: items.count)
        }
        .onChange(of: items.count) { oldCount, newCount in
            if newCount < oldCount {
                // Subcategory changed or data reset — start fresh
                resetVisibleCount(to: newCount)
            } else if newCount > oldCount && visibleCount == oldCount {
                // DB loaded more while user was showing all loaded items —
                // expand to include the newly loaded chunk so they notice.
                visibleCount = min(visibleCount + (newCount - oldCount), newCount)
            }
            visibleCount = min(visibleCount, newCount)
            previousItemCount = newCount
        }
    }

    @ViewBuilder
    private var affordance: some View {
        let hasMoreLoaded = visibleCount < items.count
        let maxReached = items.count >= maxLoadableCount && canLoadMoreFromDB

        if hasMoreLoaded {
            showMoreButton
        } else if maxReached {
            maxReachedHint
        } else if canLoadMoreFromDB {
            loadMoreFromDBButton
        }
    }

    private var showMoreButton: some View {
        let toReveal = min(chunkSize, items.count - visibleCount)
        let totalRemaining = items.count - visibleCount

        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                visibleCount = min(visibleCount + chunkSize, items.count)
            }
        } label: {
            VStack(spacing: 2) {
                HStack(spacing: 4) {
                    Text("Show \(toReveal) more")
                        .font(.system(size: 12, weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }

                if totalRemaining > toReveal {
                    Text("\(totalRemaining) total remaining")
                        .font(.system(size: 10))
                }
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .padding(.top, 4)
    }

    private var loadMoreFromDBButton: some View {
        Button {
            onLoadMoreFromDB()
        } label: {
            VStack(spacing: 3) {
                HStack(spacing: 6) {
                    if isLoadingFromDB {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 13))
                    }
                    Text("Load more from disk")
                        .font(.system(size: 12, weight: .medium))
                }

                Text("\(remainingCountInDB) files · \(formattedBytes(remainingBytesInDB)) on disk")
                    .font(.system(size: 10))
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .disabled(isLoadingFromDB)
        .padding(.horizontal, 6)
        .padding(.top, 4)
    }

    private var maxReachedHint: some View {
        Text("Showing \(items.count) of \(maxLoadableCount)+ max files")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
    }

    private func resetVisibleCount(to count: Int) {
        let target = min(chunkSize, count)
        visibleCount = target
        previousItemCount = count
    }
}
