import SwiftUI

/// The header above every list: the coloured storage bar, a hairline, then one
/// row in a fixed place: "This week" on the change list, or a title row with a
/// back button. While `onOpenBar` is set, the bar area is one button with a row
/// hover that opens the categories view; otherwise the bar's own segments work.
struct ChangesHeaderView<Bar: View, Row: View>: View {
    let onOpenBar: (() -> Void)?
    @ViewBuilder let bar: () -> Bar
    @ViewBuilder let row: () -> Row

    @State private var isHoveringBar = false

    var body: some View {
        VStack(spacing: 0) {
            barArea

            Divider()

            row()
                .frame(maxWidth: .infinity)
                .frame(height: HeaderRowMetrics.height)
        }
    }

    @ViewBuilder
    private var barArea: some View {
        if let onOpenBar {
            Button(action: onOpenBar) {
                paddedBar
                    .allowsHitTesting(false)
                    .background(
                        ListRowHoverBackground(isHovering: isHoveringBar)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    isHoveringBar = hovering
                }
            }
            .help("Show categories")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Storage by category")
            .accessibilityHint("Shows storage by category")
            .accessibilityAddTraits(.isButton)
        } else {
            paddedBar
        }
    }

    private var paddedBar: some View {
        bar()
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)
    }
}

/// "This week" with the signed weekly amount on the right. Not clickable.
struct WeeklyChangeRow: View {
    let weekly: WeeklyChange

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("This week")
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            Text(weekly.amountText ?? "No change")
                .monospacedDigit()
                .foregroundStyle(amountStyle)
                .fixedSize()
        }
        .font(.system(size: 13))
        .lineLimit(1)
        .padding(.horizontal, 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var amountStyle: AnyShapeStyle {
        switch weekly {
        case .bytes(let net) where net >= EpisodeBuilder.rowThresholdBytes:
            return AnyShapeStyle(Color.orange)
        case .bytes:
            return AnyShapeStyle(.primary)
        case .unknown, .none:
            return AnyShapeStyle(.secondary)
        }
    }

    private var accessibilityText: String {
        switch weekly {
        case .unknown:
            return "Change this week unknown"
        case .none:
            return "No change this week"
        case .bytes(let net):
            return "This week \(net > 0 ? "up" : "down") \(formattedBytes(abs(net)))"
        }
    }
}

/// The change list's row under the bar: "This week", or the scroll-linked
/// storage balance while `DevMode.showsBalanceHeader` is on.
enum ChangeListHeaderRow: Equatable {
    case thisWeek(WeeklyChange)
    case balance(StorageBalance)

    static func make(
        showsBalance: Bool,
        feedResult: ChangeFeedResult?,
        scrollAnchor: Date?,
        history: StorageHistory?,
        usedBytes: Int64,
        capacityBytes: Int64,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ChangeListHeaderRow {
        guard showsBalance else {
            return .thisWeek(WeeklyChange(feedResult, now: now))
        }
        return .balance(StorageBalance.make(
            scrollAnchor: scrollAnchor,
            feed: feedResult?.feed,
            history: history,
            usedBytes: usedBytes,
            capacityBytes: capacityBytes,
            now: now,
            calendar: calendar
        ))
    }

    /// The bar's past fill; only the balance row moves it.
    var historicUsedBytes: Int64? {
        if case .balance(let balance) = self { return balance.historicUsedBytes }
        return nil
    }
}

/// What the row under the bar says on the change list: the used storage now
/// while the list is at its top, or, while it is scrolled, the date at the
/// top of the list with the used storage a snapshot recorded by its end.
enum StorageBalance: Equatable {
    case current(usedBytes: Int64, capacityBytes: Int64)
    /// `storage` is nil when no snapshot was recorded on or before `day`.
    case recorded(day: Date, storage: RecordedStorage?, capacityBytes: Int64)

    /// `scrollAnchor` is the list's top day; the list's own top (its first
    /// day, or the quiet line above it) reads as now.
    static func make(
        scrollAnchor: Date?,
        feed: ChangeFeed?,
        history: StorageHistory?,
        usedBytes: Int64,
        capacityBytes: Int64,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> StorageBalance {
        guard let feed,
              let scrollAnchor,
              scrollAnchor != ChangeFeedRows.topAnchor(for: feed, now: now, calendar: calendar),
              feed.days.contains(where: { $0.day == scrollAnchor }) else {
            return .current(usedBytes: usedBytes, capacityBytes: capacityBytes)
        }
        return .recorded(
            day: scrollAnchor,
            storage: history?.usedStorage(atEndOf: scrollAnchor, capacityBytes: capacityBytes, calendar: calendar),
            capacityBytes: capacityBytes
        )
    }

    var isScrolled: Bool {
        if case .recorded = self { return true }
        return false
    }

    /// The bar's past fill; nil at the top or without a recorded value.
    var historicUsedBytes: Int64? {
        if case .recorded(_, let storage?, _) = self { return storage.usedBytes }
        return nil
    }

    func title(calendar: Calendar = .current) -> String {
        switch self {
        case .current:
            return "Used"
        case .recorded(let day, _, _):
            return EpisodeBuilder.dayLabel(for: day, calendar: calendar)
        }
    }

    /// "1.73 of 2 TB"; "~1.68 of 2 TB" when an older day's snapshot stands
    /// in for the date; "—" without a value.
    var amountText: String {
        switch self {
        case .current(let used, let capacity):
            guard capacity > 0 else { return "\u{2014}" }
            return Self.usedOfCapacity(used, capacity)
        case .recorded(_, let storage, let capacity):
            guard let storage, capacity > 0 else { return "\u{2014}" }
            let text = Self.usedOfCapacity(storage.usedBytes, capacity)
            return storage.isFromThatDay ? text : "~\(text)"
        }
    }

    /// "Last recorded Sun 4 Oct" when an older day's value stands in.
    func olderRecordNote(calendar: Calendar = .current) -> String? {
        guard case .recorded(_, let storage?, _) = self, !storage.isFromThatDay else { return nil }
        return "Last recorded \(EpisodeBuilder.dayLabel(for: storage.recordedAt, calendar: calendar))"
    }

    /// Both numbers in the capacity's unit: "1.73 of 2 TB", "312 of 500 GB".
    static func usedOfCapacity(_ usedBytes: Int64, _ capacityBytes: Int64) -> String {
        let inTerabytes = capacityBytes >= 1_000_000_000_000
        let divisor = inTerabytes ? 1e12 : 1e9
        func number(_ bytes: Int64) -> String {
            let value = Double(max(0, bytes)) / divisor
            let decimals = inTerabytes ? 2 : (value >= 100 ? 0 : 1)
            var text = String(format: "%.\(decimals)f", value)
            if text.contains(".") {
                while text.hasSuffix("0") { text.removeLast() }
                if text.hasSuffix(".") { text.removeLast() }
            }
            return text
        }
        return "\(number(usedBytes)) of \(number(capacityBytes)) \(inTerabytes ? "TB" : "GB")"
    }
}

/// The row under the bar on the change list: "Used" and "1.73 of 2 TB" at
/// the top; while scrolled, the top date, a "Now ↑" control back to the top
/// and that date's recorded value in grey. Not clickable itself.
struct StorageBalanceRow: View {
    let balance: StorageBalance
    let onNow: () -> Void
    var calendar: Calendar = .current

    var body: some View {
        HStack(spacing: 8) {
            Text(balance.title(calendar: calendar))
                .foregroundStyle(balance.isScrolled ? HierarchicalShapeStyle.primary : HierarchicalShapeStyle.secondary)

            if balance.isScrolled {
                Button(action: onNow) {
                    Text("Now \u{2191}")
                        .font(.system(size: 11))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.1)))
                        .frame(height: HeaderRowMetrics.height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Back to now")
                .accessibilityLabel("Now")
                .accessibilityHint("Scrolls the list back to the top")
            }

            Spacer(minLength: 0)

            Text(balance.amountText)
                .monospacedDigit()
                .foregroundStyle(balance.isScrolled ? HierarchicalShapeStyle.secondary : HierarchicalShapeStyle.primary)
                .fixedSize()
                .help(balance.olderRecordNote(calendar: calendar) ?? "")
                .accessibilityLabel(amountAccessibilityText)
        }
        .font(.system(size: 13))
        .lineLimit(1)
        .padding(.horizontal, 18)
        .accessibilityElement(children: .contain)
    }

    private var amountAccessibilityText: String {
        guard balance.amountText != "\u{2014}" else {
            return "\(balance.title(calendar: calendar)): no recorded value"
        }
        let used = balance.amountText.replacingOccurrences(of: "~", with: "")
        if let note = balance.olderRecordNote(calendar: calendar) {
            return "\(balance.title(calendar: calendar)): about \(used) used. \(note)"
        }
        return "\(balance.title(calendar: calendar)): \(used) used"
    }
}

/// A title row in the header's row slot: back chevron at the left edge, the
/// title (with an optional category glyph) centred, no amount.
struct HeaderTitleRow: View {
    let title: String
    var category: GrowthCategory? = nil
    let backHint: String
    let onBack: () -> Void

    private static var backWidth: CGFloat { 52 }

    var body: some View {
        ZStack {
            HStack(spacing: 8) {
                if let category {
                    Image(systemName: category.icon)
                        .font(.system(size: 15))
                        .foregroundStyle(category.color)
                        .frame(width: 18, height: 18)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, Self.backWidth)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            HStack(spacing: 0) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.leading, 18)
                        .frame(width: Self.backWidth, height: HeaderRowMetrics.height, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
                .accessibilityHint(backHint)

                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The header row's fixed height, shared by the storage row and every title row.
enum HeaderRowMetrics {
    static let height: CGFloat = 34
}
