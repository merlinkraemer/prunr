import Foundation

/// Shared action handler for menu commands
/// Works around focusedValue not propagating from NavigationStack to App
@MainActor
final class AppActions {
    static let shared = AppActions()

    private init() {}

    var scanAction: (() -> Void)?
    var refreshAction: (() -> Void)?

    #if DEBUG
    var generateTestDataAction: (() -> Void)?
    #endif
}
