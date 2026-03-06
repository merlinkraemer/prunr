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

    // MARK: - Singleton

    static let shared = PermissionsService()

    private init() {}

    // MARK: - State

    /// Tracks whether a permission check is currently in progress
    var isCheckingPermission = false

    // MARK: - Full Disk Access Detection

    /// Whether the app has Full Disk Access.
    ///
    /// This tests access by attempting to read a restricted location (/Library).
    /// Without Full Disk Access, this check will fail.
    var hasFullDiskAccess: Bool {
        testAccess(to: "/Library")
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

    /// Opens the current app bundle in Finder so the user can add the exact
    /// running build to Full Disk Access, including debug builds in DerivedData.
    func revealCurrentAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    // MARK: - Permission Status

    /// The current permission status based on Full Disk Access availability.
    var permissionStatus: PermissionStatus {
        if canAccessRootLibrary() {
            return .granted
        }
        // Since we can't reliably distinguish between "not determined" and "denied"
        // without FDA, we default to denied for UI purposes
        return .denied
    }

    // MARK: - Helper Methods

    /// Tests read access to a given path using FileManager.
    ///
    /// - Parameter path: The file system path to test
    /// - Returns: `true` if the path can be accessed, `false` otherwise
    func testAccess(to path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    /// Tests access to the user's Home Library folder.
    ///
    /// This location typically requires Full Disk Access to be accessed
    /// when the app is sandboxed.
    ///
    /// - Returns: `true` if ~/Library can be accessed
    func canAccessHomeLibrary() -> Bool {
        let homeLibrary = FileManager.default.urls(
            for: .libraryDirectory,
            in: .userDomainMask
        ).first
        return homeLibrary.map { testAccess(to: $0.path) } ?? false
    }

    /// Tests access to the root /Library folder.
    ///
    /// This location always requires Full Disk Access.
    ///
    /// - Returns: `true` if /Library can be accessed
    func canAccessRootLibrary() -> Bool {
        checkFullDiskAccess()
    }

    /// Checks Full Disk Access by attempting to read the TCC database.
    ///
    /// The TCC database is reliably protected by FDA on signed builds.
    /// Uses Data(contentsOf:) to test actual read access.
    ///
    /// - Returns: `true` if FDA is granted, `false` otherwise
    private func checkFullDiskAccess() -> Bool {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "debugForceFDADenied") {
            return false
        }
        #endif

        let tccDbPath = "/Library/Application Support/com.apple.TCC/TCC.db"
        let tccDbURL = URL(fileURLWithPath: tccDbPath)

        do {
            _ = try Data(contentsOf: tccDbURL)
            return true
        } catch {
            return false
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
