import AppKit
import Foundation
import SwiftUI

/// Service for detecting and managing Full Disk Access permissions.
///
/// macOS doesn't provide a direct API to check Full Disk Access status.
/// We must test by attempting to access protected locations like /Library.
@MainActor
@Observable
final class PermissionsService {
    struct FullDiskAccessReport: Sendable {
        let isGranted: Bool
        let deniedLocations: [String]

        static let granted = FullDiskAccessReport(isGranted: true, deniedLocations: [])
        static let denied = FullDiskAccessReport(isGranted: false, deniedLocations: [])
        static let debugDenied = FullDiskAccessReport(isGranted: false, deniedLocations: ["Debug override"])
    }

    // MARK: - Singleton

    static let shared = PermissionsService()

    private init() {}

    // MARK: - State

    /// Tracks whether a permission check is currently in progress
    var isCheckingPermission = false

    // MARK: - Full Disk Access Detection

    /// Whether the app has Full Disk Access.
    ///
    /// Uses the TCC database as a surrogate probe. Avoid probing user-protected
    /// folders here because that can itself trigger Desktop/Documents/etc prompts
    /// during onboarding before the user has chosen to scan.
    var hasFullDiskAccess: Bool {
        fullDiskAccessReport.isGranted
    }

    var fullDiskAccessReport: FullDiskAccessReport {
        checkFullDiskAccess()
    }

    // MARK: - Permission Request

    /// Opens System Settings to the Full Disk Access pane.
    ///
    /// This uses the x-apple.systempreferences URL scheme to deep-link
    /// directly to the Privacy & Security > Full Disk Access section.
    func requestFullDiskAccess() async {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        )!

        NSWorkspace.shared.open(url)
    }

    // MARK: - Permission Status

    /// The current permission status based on Full Disk Access availability.
    var permissionStatus: PermissionStatus {
        if hasFullDiskAccess {
            return .granted
        }
        // Since we can't reliably distinguish between "not determined" and "denied"
        // without FDA, we default to denied for UI purposes
        return .denied
    }

    private func checkFullDiskAccess() -> FullDiskAccessReport {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "debugForceFDADenied") {
            return .debugDenied
        }
        #endif

        let tccDbURL = URL(fileURLWithPath: "/Library/Application Support/com.apple.TCC/TCC.db")
        do {
            _ = try Data(contentsOf: tccDbURL, options: [.mappedIfSafe])
            return .granted
        } catch {
            return .denied
        }
    }
}

// MARK: - PermissionStatus

/// The permission status for Full Disk Access.
enum PermissionStatus: String, CaseIterable {
    /// Permission has not been requested yet
    case notDetermined
    /// Full Disk Access has been granted
    case granted
    /// Full Disk Access has been denied
    case denied

    /// Display name for UI purposes.
    var displayName: String {
        switch self {
        case .notDetermined:
            "Not Determined"
        case .granted:
            "Granted"
        case .denied:
            "Denied"
        }
    }

    /// SF Symbol icon name for UI display.
    var icon: String {
        switch self {
        case .notDetermined:
            "questionmark.circle"
        case .granted:
            "checkmark.circle.fill"
        case .denied:
            "xmark.circle.fill"
        }
    }
}
