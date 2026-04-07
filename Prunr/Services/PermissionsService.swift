import AppKit
import Foundation
import os
import SwiftUI

/// Service for checking whether the current scan scope is reachable.
///
/// macOS does not expose a supported API for asking whether Full Disk Access is
/// enabled. Product behavior therefore probes the actual scan roots plus a few
/// protected descendants that commonly require extra privacy access.
@MainActor
@Observable
final class PermissionsService {
    private static let logger = Logger(subsystem: "com.prunr.permissions", category: "ScanScopeAccess")

    struct ScanScopeAccessReport: Sendable {
        let isGranted: Bool
        let blockedLocations: [String]

        static let granted = ScanScopeAccessReport(isGranted: true, blockedLocations: [])
        static let debugDenied = ScanScopeAccessReport(isGranted: false, blockedLocations: ["Debug override"])
    }

    // MARK: - Singleton

    static let shared = PermissionsService()

    private init() {}

    // MARK: - State

    /// Tracks whether a permission check is currently in progress
    var isCheckingPermission = false

    // MARK: - Scan Scope Access

    /// Returns whether the selected scan roots are reachable, plus any protected
    /// locations inside those roots that remain blocked.
    func evaluateScanScopeAccess(scanRootURLs: [URL]) -> ScanScopeAccessReport {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "debugForceFDADenied") {
            return .debugDenied
        }
        #endif

        let roots = Self.normalizedScanRoots(scanRootURLs)
        guard !roots.isEmpty else { return .granted }

        var blocked = Set<String>()
        for url in roots {
            let probe = Self.probeRootAccess(url)
            switch probe {
            case .granted:
                continue
            case .permissionDenied(let reason):
                let label = Self.shortLocationLabel(for: url)
                blocked.insert(label)
                Self.logger.warning("Permission denied for root '\(url.path, privacy: .public)': \(reason, privacy: .public)")
            case .unavailable(let reason):
                Self.logger.debug("Root probe unavailable for '\(url.path, privacy: .public)': \(reason, privacy: .public)")
            }
        }

        for candidate in Self.protectedProbeCandidates(for: roots) {
            let probe = Self.probeRootAccess(candidate)
            switch probe {
            case .granted:
                continue
            case .permissionDenied(let reason):
                let label = Self.shortLocationLabel(for: candidate)
                blocked.insert(label)
                Self.logger.warning(
                    "Permission denied for protected descendant '\(candidate.path, privacy: .public)': \(reason, privacy: .public)"
                )
            case .unavailable:
                continue
            }
        }

        if blocked.isEmpty {
            return .granted
        }
        return ScanScopeAccessReport(isGranted: false, blockedLocations: blocked.sorted())
    }

    // MARK: - Permission Request

    /// Opens System Settings to the Full Disk Access pane for protected locations.
    func requestFullDiskAccess() async {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        )!

        NSWorkspace.shared.open(url)
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

    private static func protectedProbeCandidates(for roots: [URL]) -> [URL] {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.standardizedFileURL
        let candidates: [URL] = [
            home.appendingPathComponent("Library/Safari/History.db"),
            home.appendingPathComponent("Library/Messages/chat.db"),
            home.appendingPathComponent("Library/Mail", isDirectory: true)
        ]

        return candidates.filter { candidate in
            let standardizedCandidate = candidate.standardizedFileURL
            guard roots.contains(where: { isPath(standardizedCandidate.path, inside: $0.path) }) else {
                return false
            }
            return fileManager.fileExists(atPath: standardizedCandidate.path)
        }
    }

    private enum AccessProbeResult {
        case granted
        case permissionDenied(reason: String)
        case unavailable(reason: String)
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

    private static func isPath(_ candidate: String, inside root: String) -> Bool {
        candidate == root || candidate.hasPrefix(root == "/" ? "/" : root + "/")
    }

    private static func probeRootAccess(_ url: URL) -> AccessProbeResult {
        let path = url.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return .unavailable(reason: "Path does not exist")
        }
        if isDirectory.boolValue {
            return probeDirectoryList(url)
        }
        return probeFileRead(url)
    }

    private static func probeFileRead(_ url: URL) -> AccessProbeResult {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            _ = try handle.read(upToCount: 1)
            return .granted
        } catch {
            return classifyAccessError(error)
        }
    }

    private static func probeDirectoryList(_ url: URL) -> AccessProbeResult {
        do {
            _ = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).prefix(1)
            return .granted
        } catch {
            return classifyAccessError(error)
        }
    }

    private static func classifyAccessError(_ error: Error) -> AccessProbeResult {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            switch nsError.code {
            case Int(EACCES):
                return .permissionDenied(reason: "POSIX EACCES")
            case Int(EPERM):
                return .permissionDenied(reason: "POSIX EPERM")
            default:
                break
            }
        }
        if nsError.domain == NSCocoaErrorDomain {
            if nsError.code == NSFileReadNoPermissionError || nsError.code == NSFileWriteNoPermissionError {
                return .permissionDenied(reason: "Cocoa no-permission")
            }
        }
        return .unavailable(reason: "\(nsError.domain) \(nsError.code)")
    }
}
