import SwiftUI

@MainActor
@Observable
final class PlaceContentsModel {
    typealias Loader = @MainActor (_ offset: Int) async throws -> PlaceContentsPage

    enum Phase: Equatable {
        case loading
        case loaded
        case failed
    }

    private(set) var children: [PlaceChild] = []
    private(set) var hasMore = false
    private(set) var phase: Phase = .loading
    private(set) var isLoadingMore = false

    @ObservationIgnored private let loader: Loader

    init(loader: @escaping Loader) {
        self.loader = loader
    }

    func load() async {
        do {
            let page = try await loader(0)
            children = page.children
            hasMore = page.hasMore
            phase = .loaded
        } catch {
            phase = .failed
        }
    }

    func loadMore() async {
        guard phase == .loaded, hasMore, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        guard let page = try? await loader(children.count) else { return }
        var seen = Set(children.map(\.id))
        children += page.children.filter { seen.insert($0.id).inserted }
        hasMore = page.hasMore
    }

    func inlineStatus(isIndexing: Bool) -> InlineStatus? {
        if isIndexing { return .indexing }
        switch phase {
        case .loading: return nil
        case .failed: return .failed
        case .loaded: return children.isEmpty ? .empty : nil
        }
    }
}

struct PlaceContentsView: View {
    let category: GrowthCategory
    let isIndexing: Bool
    let onReveal: (String) -> Void

    @State private var model: PlaceContentsModel

    init(
        category: GrowthCategory,
        isIndexing: Bool,
        onReveal: @escaping (String) -> Void,
        loader: @escaping PlaceContentsModel.Loader
    ) {
        self.category = category
        self.isIndexing = isIndexing
        self.onReveal = onReveal
        _model = State(initialValue: PlaceContentsModel(loader: loader))
    }

    var body: some View {
        ScrollView {
            PlaceContentsRows(
                category: category,
                children: model.children,
                status: model.inlineStatus(isIndexing: isIndexing),
                hasMore: model.hasMore,
                isLoadingMore: model.isLoadingMore,
                onShowMore: { Task { await model.loadMore() } },
                onRetry: { Task { await model.load() } },
                onReveal: onReveal
            )
            .padding(.bottom, SoftBottomEdge.height)
        }
        .hiddenScrollIndicators()
        .softBottomEdge()
        .task(id: isIndexing) {
            guard !isIndexing else { return }
            await model.load()
        }
    }
}

struct PlaceContentsRows: View {
    let category: GrowthCategory
    let children: [PlaceChild]
    let status: InlineStatus?
    let hasMore: Bool
    let isLoadingMore: Bool
    let onShowMore: () -> Void
    let onRetry: () -> Void
    let onReveal: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let status {
                InlineStatusRow(status: status, onRetry: onRetry)
            } else {
                ForEach(children) { child in
                    PlaceChildRow(child: child, category: category)
                        .pathContextMenu(child.path, onShowInFinder: onReveal)
                }
                if hasMore {
                    ShowMoreRow(title: "Show more", isEnabled: !isLoadingMore, onShowMore: onShowMore)
                }
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 6)
    }
}

struct PlaceChildRow: View {
    let child: PlaceChild
    let category: GrowthCategory

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: child.isFolder ? "folder" : "doc")
                .font(.system(size: 14))
                .foregroundStyle(child.isFolder ? AnyShapeStyle(category.color) : AnyShapeStyle(.secondary))
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let countText {
                    Text(countText)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(CategorySizes.sizeText(child.totalBytes))
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .frame(height: countText == nil ? 34 : 44)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .help(child.path)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([displayName, countText, CategorySizes.sizeText(child.totalBytes)].compactMap { $0 }.joined(separator: ", "))
    }

    private var displayName: String {
        child.name.isEmpty ? URL(fileURLWithPath: child.path).lastPathComponent : child.name
    }

    private var countText: String? {
        child.isFolder ? CategorySizes.fileCountText(child.fileCount) : nil
    }
}
