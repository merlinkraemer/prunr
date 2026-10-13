import SwiftUI

/// The main list: newest day first, a plain date label per day, and under it
/// one row per category that changed that day. Date labels scroll with the
/// rows, and the rows fade out beneath the footer.
struct ChangeFeedView: View {
    /// Nil while the first read is in flight.
    let result: ChangeFeedResult?
    let scanFolder: ScanFolderName
    @Binding var expandedDays: Set<Date>
    /// The day at the top of the list, kept while a group is open so going
    /// back lands where the list was. The header shows this day's storage.
    @Binding var scrollAnchor: Date?
    let onOpenGroup: (ChangeGroup) -> Void
    let onRetry: () -> Void

    var body: some View {
        let now = Date()
        Group {
            switch result {
            case nil:
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clearOfFooter()
            case .failed?:
                ChangeFeedStateView(message: ChangeFeedStateView.failedText, onRetry: onRetry)
                    .clearOfFooter()
            case .loaded(let feed)? where feed.isDayOne(now: now):
                ChangeFeedStateView(message: ChangeFeedStateView.dayOneText(folder: scanFolder))
                    .clearOfFooter()
            case .loaded(let feed)?:
                ScrollView {
                    ChangeFeedRows(
                        feed: feed,
                        now: now,
                        expandedDays: $expandedDays,
                        onOpenGroup: onOpenGroup
                    )
                        .padding(.bottom, SoftBottomEdge.height)
                }
                .hiddenScrollIndicators()
                .scrollPosition(id: $scrollAnchor, anchor: .top)
                .softBottomEdge()
            }
        }
    }
}

/// The list's rows without the scroll view: the "Nothing over 1 GB since"
/// line, each day's label and category groups, and the "Watching since"
/// marker. The marketing renderer lays these out directly, since
/// `ImageRenderer` leaves AppKit-backed scroll views blank.
struct ChangeFeedRows: View {
    /// Groups a day shows before its "Show all (N)" row.
    static let collapsedGroupLimit = 3

    /// Scroll id of the "Nothing over 1 GB since" line above the first day.
    static let quietLineID = Date.distantFuture

    /// The scroll id at the very top of the list: the quiet line when it is
    /// shown, else the newest day.
    static func topAnchor(for feed: ChangeFeed, now: Date, calendar: Calendar = .current) -> Date? {
        feed.quietSince(now: now, calendar: calendar) == nil ? feed.days.first?.day : quietLineID
    }

    let feed: ChangeFeed
    let now: Date
    @Binding var expandedDays: Set<Date>
    let onOpenGroup: (ChangeGroup) -> Void

    private let calendar = Calendar.current

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            if let since = feed.quietSince(now: now, calendar: calendar) {
                Text(EpisodeBuilder.quietLabel(since: since, calendar: calendar))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                    .padding(.bottom, 2)
                    .id(Self.quietLineID)
            }

            ForEach(feed.days) { day in
                daySection(day)
                    .id(day.id)
            }

            if feed.isShortHistory(now: now, calendar: calendar), let since = feed.watchingSince {
                Text(EpisodeBuilder.watchingSinceLabel(since, calendar: calendar))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 14)
                    .padding(.bottom, 4)
            }
        }
        .scrollTargetLayout()
        .padding(.bottom, 6)
    }

    private func daySection(_ day: ChangeFeedDay) -> some View {
        let groups = day.groups
        let isCollapsed = groups.count > Self.collapsedGroupLimit && !expandedDays.contains(day.day)
        let shown = isCollapsed ? Array(groups.prefix(Self.collapsedGroupLimit)) : groups

        return VStack(alignment: .leading, spacing: 0) {
            Text(EpisodeBuilder.dayLabel(for: day.day, calendar: calendar))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)

            ForEach(shown) { group in
                ChangeGroupRow(group: group, onOpen: { onOpenGroup(group) })
            }

            if isCollapsed {
                ShowAllGroupsRow(count: groups.count) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        _ = expandedDays.insert(day.day)
                    }
                }
            }
        }
    }
}

struct ChangeGroupView: View {
    let group: ChangeGroup
    let onOpenPlace: (ChangeEpisode) -> Void
    let onReveal: (String) -> Void

    var body: some View {
        ScrollView {
            ChangeGroupRows(group: group, onOpenPlace: onOpenPlace, onReveal: onReveal)
                .padding(.bottom, SoftBottomEdge.height)
        }
        .hiddenScrollIndicators()
        .softBottomEdge()
    }
}

struct ChangeGroupRows: View {
    let group: ChangeGroup
    let onOpenPlace: (ChangeEpisode) -> Void
    let onReveal: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(group.episodes) { episode in
                ChangeRow(episode: episode, onOpen: onOpenPlace, onReveal: onReveal)
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 6)
    }
}

/// A gradient mask over a scroll view's bottom edge, so rows dissolve
/// gradually instead of being cut off. The list runs underneath the footer,
/// so the fade reaches zero behind it rather than at its top edge. A mask
/// (not an overlay) keeps the panel's translucent background showing through
/// on every macOS version.
enum SoftBottomEdge {
    static let height: CGFloat = 96
    static let footerHeight: CGFloat = 38

    static let stops: [Gradient.Stop] = (0...24).map { step in
        let t = Double(step) / 24
        let eased = t * t * (3 - 2 * t)
        return .init(color: .black.opacity(1 - eased), location: t)
    }
}

extension View {
    func softBottomEdge() -> some View {
        mask {
            VStack(spacing: 0) {
                Rectangle()
                LinearGradient(stops: SoftBottomEdge.stops, startPoint: .top, endPoint: .bottom)
                    .frame(height: SoftBottomEdge.height)
            }
        }
    }

    func clearOfFooter() -> some View {
        padding(.bottom, SoftBottomEdge.footerHeight)
    }
}
