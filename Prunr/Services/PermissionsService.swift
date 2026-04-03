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
        let deniedLocations: [String]

        var isGranted: Bool {
            deniedLocations.isEmpty
        }
    }

    private struct AccessProbe {
        let label: String
        let url: URL
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
    /// This requires access to the protected locations the scanner actually touches.
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

    /// Opens the current app bundle in Finder so the user can add the exact
    /// running build to Full Disk Access, including debug builds in DerivedData.
    func revealCurrentAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
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

    // MARK: - Helper Methods

    private func checkFullDiskAccess() -> FullDiskAccessReport {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "debugForceFDADenied") {
            return FullDiskAccessReport(deniedLocations: ["Debug override"])
        }
        #endif

        let denied = accessProbes().compactMap { probe in
            canReadProbe(probe) ? nil : probe.label
        }

        return FullDiskAccessReport(deniedLocations: denied)
    }

    private func accessProbes() -> [AccessProbe] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths: [(String, URL)] = [
            ("TCC", URL(fileURLWithPath: "/Library/Application Support/com.apple.TCC/TCC.db")),
            ("Desktop", home.appendingPathComponent("Desktop", isDirectory: true)),
            ("Documents", home.appendingPathComponent("Documents", isDirectory: true)),
            ("Downloads", home.appendingPathComponent("Downloads", isDirectory: true)),
            ("Music", home.appendingPathComponent("Music", isDirectory: true)),
            ("Pictures", home.appendingPathComponent("Pictures", isDirectory: true)),
            ("Movies", home.appendingPathComponent("Movies", isDirectory: true)),
            ("Mail", home.appendingPathComponent("Library/Mail", isDirectory: true)),
            ("Messages", home.appendingPathComponent("Library/Messages", isDirectory: true)),
            ("Safari", home.appendingPathComponent("Library/Safari", isDirectory: true)),
            ("iCloud Drive", home.appendingPathComponent("Library/Mobile Documents", isDirectory: true)),
            ("MobileSync", home.appendingPathComponent("Library/Application Support/MobileSync", isDirectory: true)),
            ("Music Library", home.appendingPathComponent("Music/Music", isDirectory: true)),
            ("iTunes", home.appendingPathComponent("Music/iTunes", isDirectory: true)),
            ("Photos Library", home.appendingPathComponent("Pictures/Photos Library.photoslibrary", isDirectory: true))
        ]

        return paths.compactMap { label, url in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                return nil
            }
            return AccessProbe(label: label, url: url)
        }
    }

    private func canReadProbe(_ probe: AccessProbe) -> Bool {
        let values = try? probe.url.resourceValues(forKeys: [.isDirectoryKey])
        if values?.isDirectory == true {
            do {
                _ = try FileManager.default.contentsOfDirectory(
                    at: probe.url,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
                return true
            } catch {
                return false
            }
        }

        do {
            _ = try Data(contentsOf: probe.url, options: [.mappedIfSafe])
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
