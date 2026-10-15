import SwiftUI

/// The one line in the middle of the panel's footer. Only the most urgent
/// state shows; `resolve` holds the order.
enum FooterStatus: Equatable {
    /// A brief answer to a click, such as "No longer on disk".
    case notice(String)
    case refreshFailed
    case scanning(String, progress: Double?)
    case refreshing
    case foldersNotReadable
    case updateAvailable
    /// The open group's day.
    case groupDay(Date)
    case preview(PanelPreview)
    /// Day one until the watcher sees a change: "Watching since today 16:38".
    case watchingSince(Date)
    case updated(Date)
    case none

    static func resolve(
        notice: String? = nil,
        refreshFailed: Bool = false,
        scanText: String? = nil,
        scanProgress: Double? = nil,
        isRefreshing: Bool = false,
        foldersNotReadable: Bool = false,
        updateAvailable: Bool = false,
        groupDay: Date? = nil,
        preview: PanelPreview = .live,
        watchingSinceToday: Date? = nil,
        updatedAt: Date? = nil
    ) -> FooterStatus {
        if let notice { return .notice(notice) }
        if refreshFailed { return .refreshFailed }
        if let scanText { return .scanning(scanText, progress: scanProgress) }
        if isRefreshing { return .refreshing }
        if foldersNotReadable { return .foldersNotReadable }
        if updateAvailable { return .updateAvailable }
        if let groupDay { return .groupDay(groupDay) }
        if preview != .live { return .preview(preview) }
        if let watchingSinceToday { return .watchingSince(watchingSinceToday) }
        if let updatedAt { return .updated(updatedAt) }
        return .none
    }

    enum Ring: Equatable {
        case progress(Double)
        case spinning
    }

    var ring: Ring? {
        switch self {
        case .scanning(_, let progress?): return .progress(max(0, min(1, progress)))
        case .scanning, .refreshing: return .spinning
        default: return nil
        }
    }

    func text(now: Date = Date(), calendar: Calendar = .current) -> String {
        switch self {
        case .notice(let text): return text
        case .refreshFailed: return "Couldn't refresh"
        case .scanning(let text, _): return text
        case .refreshing: return "Refreshing…"
        case .foldersNotReadable: return "Some folders not readable"
        case .updateAvailable: return "Update available"
        case .groupDay(let day): return EpisodeBuilder.dayLabel(for: day, calendar: calendar)
        case .preview(.sample): return "Sample data"
        case .preview(let preview): return "Preview: \(preview.title)"
        case .watchingSince(let date): return Self.watchingSinceText(date, calendar: calendar)
        case .updated(let date): return Self.updatedText(since: date, now: now, calendar: calendar)
        case .none: return ""
        }
    }

    static func watchingSinceText(_ date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "Watching since today %02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }

    /// "Updated just now", "Updated 4 min ago", "Updated 3 h ago", or
    /// "Updated Mon 5 Oct" after a day.
    static func updatedText(since date: Date, now: Date, calendar: Calendar = .current) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "Updated just now" }
        if minutes < 60 { return "Updated \(minutes) min ago" }
        let hours = minutes / 60
        if hours < 24 { return "Updated \(hours) h ago" }
        return "Updated \(EpisodeBuilder.dayLabel(for: date, calendar: calendar))"
    }
}

struct FooterProgressRing: View {
    let ring: FooterStatus.Ring

    @State private var isSpinning = false

    private var fraction: Double {
        switch ring {
        case .progress(let progress): return max(0.02, progress)
        case .spinning: return 0.25
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1.8)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(Color.primary, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .rotationEffect(.degrees(isSpinning ? 360 : 0))
        }
        .frame(width: 12, height: 12)
        .frame(width: 16, height: 16)
        .animation(.easeInOut(duration: 0.3), value: fraction)
        .onAppear {
            guard ring == .spinning else { return }
            withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                isSpinning = true
            }
        }
        .accessibilityHidden(true)
    }
}
