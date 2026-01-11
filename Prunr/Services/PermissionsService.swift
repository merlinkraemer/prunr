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
}
