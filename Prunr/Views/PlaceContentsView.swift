import SwiftUI

@MainActor
@Observable
final class PlaceContentsModel {
    typealias Loader = @MainActor (_ offset: Int) async throws -> PlaceContentsPage
    typealias ChangesLoader = @MainActor () async throws -> PlaceChanges

    enum Phase: Equatable {
        case loading
        case loaded
        case failed
    }

    private(set) var children: [PlaceChild] = []
    private(set) var hasMore = false
    private(set) var phase: Phase = .loading
    private(set) var isLoadingMore = false
    /// What the row's span changed, child by child; nil shows sizes now.
    private(set) var changes: [PlaceChildChange]?
    private(set) var notes: [String] = []

    @ObservationIgnored private let loader: Loader
    @ObservationIgnored private let changesLoader: ChangesLoader?
    @ObservationIgnored private let notesFor: (PlaceChanges) -> [String]

    init(
        loader: @escaping Loader,
        changesLoader: ChangesLoader? = nil,
        notes: @escaping (PlaceChanges) -> [String] = { _ in [] }
    ) {
        self.loader = loader
        self.changesLoader = changesLoader
        self.notesFor = notes
    }

    func load() async {
        do {
            if let changesLoader {
                let report = try await changesLoader()
                notes = notesFor(report)
                if let children = report.children {
                    changes = children
                    phase = .loaded
                    return
                }
            }
            let page = try await loader(0)
            children = page.children
            hasMore = page.hasMore
            phase = .loaded
        } catch {
            phase = .failed
        }
    }

    func loadMore() async {
        guard phase == .loaded, changes == nil, hasMore, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        guard let page = try? await loader(children.count) else { return }
        var seen = Set(children.map(\.id))
        children += page.children.filter { seen.insert($0.id).inserted }
        hasMore = page.hasMore
    }

    var inlineStatus: InlineStatus? {
        switch phase {
        case .loading: return nil
        case .failed: return .failed
        case .loaded: return changes == nil && children.isEmpty ? .empty : nil
        }
    }
}

struct PlaceContentsView: View {
    let category: GrowthCategory
    let caption: String?
    let onReveal: (String) -> Void

    @State private var model: PlaceContentsModel

    init(
        category: GrowthCategory,
        caption: String? = nil,
        onReveal: @escaping (String) -> Void,
        loader: @escaping PlaceContentsModel.Loader,
        changesLoader: PlaceContentsModel.ChangesLoader? = nil,
        notes: @escaping (PlaceChanges) -> [String] = { _ in [] }
    ) {
        self.category = category
        self.caption = caption
        self.onReveal = onReveal
        _model = State(initialValue: PlaceContentsModel(loader: loader, changesLoader: changesLoader, notes: notes))
    }

    var body: some View {
        ScrollView {
            PlaceContentsRows(
                category: category,
                caption: caption,
                notes: model.notes,
                children: model.children,
                changes: model.changes,
                status: model.inlineStatus,
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
        .task {
            await model.load()
        }
    }
}

struct PlaceContentsRows: View {
    let category: GrowthCategory
    var caption: String? = nil
    var notes: [String] = []
    let children: [PlaceChild]
    var changes: [PlaceChildChange]? = nil
    let status: InlineStatus?
    let hasMore: Bool
    let isLoadingMore: Bool
    let onShowMore: () -> Void
    let onRetry: () -> Void
    let onReveal: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let caption {
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.top, 4)
                    .padding(.bottom, 4)
                    .help(caption)
            }
            ForEach(notes, id: \.self) { note in
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 4)
                    .help(note)
            }
            if let status {
                InlineStatusRow(status: status, onRetry: onRetry)
            } else if let changes {
                ForEach(changes) { change in
                    PlaceChangeRow(change: change, category: category, onReveal: onReveal)
                }
            } else {
                ForEach(children) { child in
                    PlaceChildRow(child: child, category: category, onTap: { onReveal(child.path) })
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
    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            content
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .help(child.path)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([displayName, countText, CategorySizes.sizeText(child.totalBytes)].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint("Shows it in Finder")
        .accessibilityAddTraits(.isButton)
    }

    private var content: some View {
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
        .background(ListRowHoverBackground(isHovering: isHovering))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }

    private var displayName: String {
        child.name.isEmpty ? URL(fileURLWithPath: child.path).lastPathComponent : child.name
    }

    private var countText: String? {
        child.isFolder ? CategorySizes.fileCountText(child.fileCount) : nil
    }
}

/// A child on a row's page: what it changed in the row's span, its size now
/// below its name. A child that is gone, and the remainder row, do not open.
struct PlaceChangeRow: View {
    let change: PlaceChildChange
    let category: GrowthCategory
    let onReveal: (String) -> Void

    @State private var isHovering = false

    var body: some View {
        if let path = revealPath {
            Button { onReveal(path) } label: {
                content(opens: true)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    isHovering = hovering
                }
            }
            .help(path)
            .pathContextMenu(path, onShowInFinder: onReveal)
            .accessibilityHint("Shows it in Finder")
            .accessibilityAddTraits(.isButton)
        } else {
            content(opens: false)
        }
    }

    private var revealPath: String? {
        change.currentBytes == nil ? nil : change.path
    }

    private var symbol: String {
        if change.path == nil { return "ellipsis.circle" }
        return change.isFolder ? "folder" : "doc"
    }

    private var secondaryText: String? {
        PlacePageNotes.currentText(change)
    }

    private func content(opens: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(change.isFolder && change.currentBytes != nil ? AnyShapeStyle(category.color) : AnyShapeStyle(.secondary))
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(change.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(change.currentBytes == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let secondaryText {
                    Text(secondaryText)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(signedBytes(change.deltaBytes))
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(changeAmountStyle(change.deltaBytes))
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .frame(height: secondaryText == nil ? 34 : 44)
        .background(ListRowHoverBackground(isHovering: opens && isHovering))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([change.name, secondaryText, spokenChangeAmount(change.deltaBytes)].compactMap { $0 }.joined(separator: ", "))
    }
}
