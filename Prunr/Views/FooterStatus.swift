import Foundation

/// The one line in the middle of the panel's footer. Only the most urgent
/// state shows; `resolve` holds the order.
enum FooterStatus: Equatable {
    /// A brief answer to a click, such as "No longer on disk".
    case notice(String)
    case refreshFailed
    /// "Scanning 42%" or "Finalizing scan…", with a spinner.
    case scanning(String)
    case refreshing
    case foldersNotReadable
    case updateAvailable
    /// The open group's day.
    case groupDay(Date)
    case preview(PanelPreview)
    case updated(Date)
    case none

    static func resolve(
        notice: String? = nil,
        refreshFailed: Bool = false,
        scanText: String? = nil,
        isRefreshing: Bool = false,
        foldersNotReadable: Bool = false,
        updateAvailable: Bool = false,
        groupDay: Date? = nil,
        preview: PanelPreview = .live,
        updatedAt: Date? = nil
    ) -> FooterStatus {
        if let notice { return .notice(notice) }
        if refreshFailed { return .refreshFailed }
        if let scanText { return .scanning(scanText) }
        if isRefreshing { return .refreshing }
        if foldersNotReadable { return .foldersNotReadable }
        if updateAvailable { return .updateAvailable }
        if let groupDay { return .groupDay(groupDay) }
        if preview != .live { return .preview(preview) }
        if let updatedAt { return .updated(updatedAt) }
        return .none
    }

    var showsSpinner: Bool {
        switch self {
        case .scanning, .refreshing: return true
        default: return false
        }
    }

    func text(now: Date = Date(), calendar: Calendar = .current) -> String {
        switch self {
        case .notice(let text): return text
        case .refreshFailed: return "Couldn't refresh"
        case .scanning(let text): return text
        case .refreshing: return "Refreshing…"
        case .foldersNotReadable: return "Some folders not readable"
        case .updateAvailable: return "Update available"
        case .groupDay(let day): return EpisodeBuilder.dayLabel(for: day, calendar: calendar)
        case .preview(.sample): return "Sample data"
        case .preview(let preview): return "Preview: \(preview.title)"
        case .updated(let date): return Self.updatedText(since: date, now: now, calendar: calendar)
        case .none: return ""
        }
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
