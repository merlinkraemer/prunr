import AppKit
import SwiftUI

enum FeedPage: Equatable {
    case feed
    case group(ChangeGroup)
    case place(ChangeGroup, ChangeEpisode)

    var depth: Int {
        switch self {
        case .feed: return 0
        case .group: return 1
        case .place: return 2
        }
    }

    var group: ChangeGroup? {
        switch self {
        case .feed: return nil
        case .group(let group), .place(let group, _): return group
        }
    }

    var place: ChangeEpisode? {
        if case .place(_, let place) = self { return place }
        return nil
    }

    var id: String {
        switch self {
        case .feed: return "feed"
        case .group(let group): return "group-\(group.id)"
        case .place(let group, let place): return "place-\(group.id)-\(place.id)"
        }
    }

    var parent: FeedPage {
        switch self {
        case .feed, .group: return .feed
        case .place(let group, _): return FeedPage.soloPlace(of: group) == nil ? .group(group) : .feed
        }
    }

    func opening(_ group: ChangeGroup) -> FeedPage {
        guard let place = FeedPage.soloPlace(of: group) else { return .group(group) }
        return .place(group, place)
    }

    func opening(_ place: ChangeEpisode) -> FeedPage {
        guard case .group(let group) = self, FeedPage.opensContents(place) else { return self }
        return .place(group, place)
    }

    static func opensContents(_ place: ChangeEpisode) -> Bool {
        place.rootPath != nil
    }

    static func soloPlace(of group: ChangeGroup) -> ChangeEpisode? {
        guard group.episodes.count == 1, let place = group.episodes.first, opensContents(place) else { return nil }
        return place
    }
}

extension ChangeGroup {
    var rowTitle: String {
        FeedPage.soloPlace(of: self).map(EpisodeBuilder.rowTitle(for:)) ?? category.displayName
    }

    var rowIconSource: UnitIconSource? {
        FeedPage.soloPlace(of: self)?.iconSource
    }
}

enum ListPage: Equatable, Identifiable {
    case categories
    case feed(FeedPage)

    var id: String {
        switch self {
        case .categories: return "categories"
        case .feed(let page): return page.id
        }
    }

    static func isPush(from old: ListPage, to new: ListPage) -> Bool {
        switch (old, new) {
        case (_, .categories): return true
        case (.categories, _): return false
        case (.feed(let oldPage), .feed(let newPage)): return newPage.depth > oldPage.depth
        }
    }
}

enum PushSlide {
    static func offset(isIncoming: Bool, forward: Bool, progress: CGFloat, width: CGFloat) -> CGFloat {
        let direction: CGFloat = forward ? 1 : -1
        return isIncoming ? direction * (1 - progress) * width : -direction * progress * width
    }

    static func mountedPages<Page: Identifiable>(retained: Page?, outgoing: Page?, shown: Page) -> [Page] {
        var seen = Set<Page.ID>()
        return Array([shown, outgoing, retained].compactMap { $0 }.filter { seen.insert($0.id).inserted }.reversed())
    }
}

struct PushPager<Page: Identifiable & Equatable, Content: View>: View {
    let page: Page
    var retained: Page? = nil
    let isForward: (Page, Page) -> Bool
    @ViewBuilder let content: (Page) -> Content

    @State private var shown: Page?
    @State private var outgoing: Page?
    @State private var forward = true
    @State private var progress: CGFloat = 1
    @State private var slideTask: Task<Void, Never>?

    private var mountedPages: [Page] {
        PushSlide.mountedPages(retained: retained, outgoing: outgoing, shown: shown ?? page)
    }

    private func isVisible(_ mounted: Page) -> Bool {
        mounted.id == (shown ?? page).id || mounted.id == outgoing?.id
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                ForEach(mountedPages) { mounted in
                    let isVisible = isVisible(mounted)
                    content(mounted)
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                        .offset(x: isVisible ? offset(of: mounted, width: geometry.size.width) : geometry.size.width)
                        .opacity(isVisible ? 1 : 0)
                        .allowsHitTesting(isVisible)
                        .accessibilityHidden(!isVisible)
                        .transition(.identity)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            .clipped()
        }
        .onChange(of: page) { old, new in
            guard old.id != new.id else {
                shown = new
                return
            }
            slide(from: old, to: new)
        }
        .onDisappear(perform: settle)
    }

    private func offset(of visible: Page, width: CGFloat) -> CGFloat {
        guard outgoing != nil else { return 0 }
        return PushSlide.offset(
            isIncoming: visible.id != outgoing?.id,
            forward: forward,
            progress: progress,
            width: width
        )
    }

    private func slide(from old: Page, to new: Page) {
        slideTask?.cancel()
        withoutAnimation {
            outgoing = old
            shown = new
            forward = isForward(old, new)
            progress = 0
        }
        slideTask = Task { @MainActor in
            await withCheckedContinuation { continuation in
                RunLoop.main.perform { continuation.resume() }
            }
            guard !Task.isCancelled else { return }
            withAnimation(DrilldownTransitionCoordinator.slideAnimation) {
                progress = 1
            }
            try? await Task.sleep(for: .milliseconds(Int(DrilldownTransitionCoordinator.slideMilliseconds)))
            guard !Task.isCancelled else { return }
            withoutAnimation {
                outgoing = nil
            }
        }
    }

    private func settle() {
        slideTask?.cancel()
        withoutAnimation {
            outgoing = nil
            shown = nil
            progress = 1
        }
    }

    private func withoutAnimation(_ change: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, change)
    }
}

enum RowPathAction: CaseIterable, Equatable {
    case showInFinder
    case copyPath

    var title: String {
        switch self {
        case .showInFinder: return "Show in Finder"
        case .copyPath: return "Copy Path"
        }
    }

    static func actions(forPath path: String?) -> [RowPathAction] {
        path == nil ? [] : allCases
    }

    static func copyToPasteboard(_ path: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
    }
}

extension View {
    @ViewBuilder
    func pathContextMenu(_ path: String?, onShowInFinder: @escaping (String) -> Void) -> some View {
        if let path {
            contextMenu {
                ForEach(RowPathAction.actions(forPath: path), id: \.self) { action in
                    Button(action.title) {
                        switch action {
                        case .showInFinder: onShowInFinder(path)
                        case .copyPath: RowPathAction.copyToPasteboard(path)
                        }
                    }
                }
            }
        } else {
            self
        }
    }
}

enum InlineStatus: Equatable {
    case indexing
    case empty
    case failed

    var text: String {
        switch self {
        case .indexing: return "Indexing files…"
        case .empty: return "No files found"
        case .failed: return "Couldn't read"
        }
    }
}

struct InlineStatusRow: View {
    let status: InlineStatus
    var onRetry: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 4) {
            Text(status.text)
                .foregroundStyle(.secondary)
            if status == .failed, let onRetry {
                Text("\u{00B7}")
                    .foregroundStyle(.tertiary)
                Button("Retry", action: onRetry)
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
            }
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 46)
        .padding(.trailing, 18)
        .frame(height: 34)
    }
}

struct ShowMoreRow: View {
    let title: String
    var isEnabled = true
    let onShowMore: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onShowMore) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 40)
                .padding(.trailing, 12)
                .frame(height: 30)
                .background(ListRowHoverBackground(isHovering: isHovering && isEnabled))
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.6)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}

struct ListChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(width: 12, height: 12)
            .accessibilityHidden(true)
    }
}
