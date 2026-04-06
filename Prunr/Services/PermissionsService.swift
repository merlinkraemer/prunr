import AppKit
import Foundation
import SwiftUI

/// Service for detecting and managing Full Disk Access permissions.
///
/// macOS does not expose a supported API for FDA status. We combine a
/// non-interactive TCC database read (fast) with optional readability checks
/// on the user’s scan roots (after scope exists) so the UI matches real access.
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

    /// Whether the app has Full Disk Access (TCC “all files” only — no scan roots).
    var hasFullDiskAccess: Bool {
        probeSystemFullDiskAccessViaTCC().isGranted
    }

    /// Full report for scan roots (or TCC-only when `scanRootURLs` is empty).
    func evaluateFullDiskAccess(scanRootURLs: [URL] = []) -> FullDiskAccessReport {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "debugForceFDADenied") {
            return .debugDenied
        }
        #endif

        guard probeSystemFullDiskAccessViaTCC().isGranted else {
            return .denied
        }

        let roots = Self.normalizedScanRoots(scanRootURLs)
        guard !roots.isEmpty else {
            return .granted
        }

        var denied: [String] = []
        for url in roots where !Self.isRootReadable(url) {
            denied.append(Self.shortLocationLabel(for: url))
        }

        if denied.isEmpty {
            return .granted
        }
        return FullDiskAccessReport(isGranted: false, deniedLocations: denied)
    }

    // MARK: - Permission Request

    /// Opens System Settings to the Full Disk Access pane.
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
        return .denied
    }

    private func probeSystemFullDiskAccessViaTCC() -> FullDiskAccessReport {
        let tccDbURL = URL(fileURLWithPath: "/Library/Application Support/com.apple.TCC/TCC.db")
        do {
            _ = try Data(contentsOf: tccDbURL, options: [.mappedIfSafe])
            return .granted
        } catch {
            return .denied
        }
    }

    private static func normalizedScanRoots(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        var result: [URL] = []
        for url in urls {
            let std = url.standardizedFileURL
            let path = std.path
            guard seen.insert(path).inserted else { continue }
            result.append(std)
        }
        return result
    }

    private static func isRootReadable(_ url: URL) -> Bool {
        FileManager.default.isReadableFile(atPath: url.path)
    }

    private static func shortLocationLabel(for url: URL) -> String {
        let path = url.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home {
            return "Home folder"
        }
        if path == "/" {
            return "Full disk"
        }
        if path == "/System" || path.hasPrefix("/System/") {
            return "System"
        }
        let name = url.lastPathComponent
        return name.isEmpty ? path : name
    }
}

// MARK: - PermissionStatus

/// The permission status for Full Disk Access.
enum PermissionStatus: String, CaseIterable {
    case notDetermined
    case granted
    case denied

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
