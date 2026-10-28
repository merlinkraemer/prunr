import Foundation

extension Notification.Name {
    static let devModeDidChange = Notification.Name("com.prunr.devModeDidChange")
}

enum PanelPreview: String, CaseIterable, Identifiable {
    case live
    case onboarding
    case scanning
    case dayOne
    case firstDay
    case error
    case sample

    var id: Self { self }

    var title: String {
        switch self {
        case .live: return "Live"
        case .onboarding: return "Onboarding"
        case .scanning: return "Scanning"
        case .dayOne: return "Day one"
        case .firstDay: return "First day (after scan)"
        case .error: return "Error"
        case .sample: return "Sample"
        }
    }

    func changeFeed(over live: ChangeFeedResult?, now: Date = Date()) -> ChangeFeedResult? {
        switch self {
        case .dayOne: return .loaded(ChangeFeed(days: [], weekNetBytes: 0, watchingSince: now))
        case .firstDay: return .loaded(FirstDayPreview.feed(now: now))
        case .error: return .failed
        case .sample: return .loaded(MarketingSample.feed)
        case .live, .onboarding, .scanning: return live
        }
    }

    func errorMessage(over live: String?) -> String? {
        self == .live ? live : nil
    }
}

@MainActor
@Observable
final class DevMode {
    nonisolated static let defaultsKey = "devMode"
    nonisolated static let balanceHeaderKey = "balanceHeader"
    static let shared = DevMode()

    nonisolated static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    private let defaults: UserDefaults

    private(set) var isEnabled: Bool

    private(set) var showsBalanceHeader: Bool

    var panelPreview: PanelPreview = .live

    init(
        defaults: UserDefaults = .standard,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        isDebugBuild: Bool = DevMode.isDebugBuild
    ) {
        self.defaults = defaults
        isEnabled = Self.resolve(arguments: arguments, defaults: defaults, isDebugBuild: isDebugBuild)
        showsBalanceHeader = Self.resolveBalanceHeader(arguments: arguments, defaults: defaults)
    }

    nonisolated static func resolve(arguments: [String], defaults: UserDefaults, isDebugBuild: Bool) -> Bool {
        if let fromArguments = launchArgument(defaultsKey, in: arguments) {
            return fromArguments
        }
        if let stored = defaults.object(forKey: defaultsKey) as? Bool {
            return stored
        }
        return isDebugBuild
    }

    nonisolated static func resolveBalanceHeader(arguments: [String], defaults: UserDefaults) -> Bool {
        launchArgument(balanceHeaderKey, in: arguments) ?? defaults.bool(forKey: balanceHeaderKey)
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.defaultsKey)
        if !enabled {
            panelPreview = .live
        }
        NotificationCenter.default.post(name: .devModeDidChange, object: self)
    }

    func toggle() {
        setEnabled(!isEnabled)
    }

    func setShowsBalanceHeader(_ shows: Bool) {
        guard shows != showsBalanceHeader else { return }
        showsBalanceHeader = shows
        defaults.set(shows, forKey: Self.balanceHeaderKey)
    }

    private nonisolated static func launchArgument(_ key: String, in arguments: [String]) -> Bool? {
        guard let flagIndex = arguments.lastIndex(of: "-\(key)"),
              flagIndex + 1 < arguments.count else { return nil }
        switch arguments[flagIndex + 1].lowercased() {
        case "yes", "true", "1": return true
        case "no", "false", "0": return false
        default: return nil
        }
    }
}
