import AppKit
import Darwin
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
    private var lastLoggedBlockedLocations: Set<String> = []

    // MARK: - Scan Scope Access

    /// Returns whether the selected scan roots are reachable, plus any protected
    /// locations inside those roots that remain blocked.
    func evaluateScanScopeAccess(scanRootURLs: [URL]) -> ScanScopeAccessReport {
        let report = Self.evaluateScanScopeAccessSynchronously(scanRootURLs: scanRootURLs)
        logAccessReportIfNeeded(report)
        return report
    }

    func evaluateScanScopeAccessAsync(scanRootURLs: [URL]) async -> ScanScopeAccessReport {
        isCheckingPermission = true
        defer { isCheckingPermission = false }

        let report = await Task.detached(priority: .utility) {
            Self.evaluateScanScopeAccessSynchronously(scanRootURLs: scanRootURLs)
        }.value

        logAccessReportIfNeeded(report)
        return report
    }

    private nonisolated static func evaluateScanScopeAccessSynchronously(scanRootURLs: [URL]) -> ScanScopeAccessReport {
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
            case .permissionDenied:
                let label = Self.shortLocationLabel(for: url)
                blocked.insert(label)
            case .unavailable:
                continue
            }
        }

        for candidate in Self.protectedProbeCandidates(for: roots) {
            let probe = Self.probeRootAccess(candidate)
            switch probe {
            case .granted:
                continue
            case .permissionDenied:
                let label = Self.shortLocationLabel(for: candidate)
                blocked.insert(label)
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

    private nonisolated static func normalizedScanRoots(_ urls: [URL]) -> [URL] {
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

    private nonisolated static func protectedProbeCandidates(for roots: [URL]) -> [URL] {
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

    private nonisolated static func shortLocationLabel(for url: URL) -> String {
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

    private nonisolated static func isPath(_ candidate: String, inside root: String) -> Bool {
        candidate == root || candidate.hasPrefix(root == "/" ? "/" : root + "/")
    }

    private nonisolated static func probeRootAccess(_ url: URL) -> AccessProbeResult {
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

    private nonisolated static func probeFileRead(_ url: URL) -> AccessProbeResult {
        url.withUnsafeFileSystemRepresentation { fileSystemPath in
            guard let fileSystemPath else {
                return .unavailable(reason: "Invalid file path")
            }

            let fileDescriptor = Darwin.open(fileSystemPath, O_RDONLY)
            guard fileDescriptor >= 0 else {
                return classifyPOSIXErrno(Darwin.errno)
            }

            Darwin.close(fileDescriptor)
            return .granted
        }
    }

    private nonisolated static func probeDirectoryList(_ url: URL) -> AccessProbeResult {
        url.withUnsafeFileSystemRepresentation { fileSystemPath in
            guard let fileSystemPath else {
                return .unavailable(reason: "Invalid directory path")
            }

            guard let directory = opendir(fileSystemPath) else {
                return classifyPOSIXErrno(Darwin.errno)
            }

            closedir(directory)
            return .granted
        }
    }

    private nonisolated static func classifyPOSIXErrno(_ code: Int32) -> AccessProbeResult {
        switch code {
        case EACCES:
            return .permissionDenied(reason: "POSIX EACCES")
        case EPERM:
            return .permissionDenied(reason: "POSIX EPERM")
        case ENOENT:
            return .unavailable(reason: "Path does not exist")
        default:
            return .unavailable(reason: "POSIX \(code)")
        }
    }

    private func logAccessReportIfNeeded(_ report: ScanScopeAccessReport) {
        let blocked = Set(report.blockedLocations)
        guard blocked != lastLoggedBlockedLocations else { return }

        let previouslyBlocked = lastLoggedBlockedLocations
        lastLoggedBlockedLocations = blocked

        if blocked.isEmpty {
            guard !previouslyBlocked.isEmpty else { return }
            Self.logger.notice("Scan scope access restored for current roots")
            return
        }

        let blockedSummary = blocked.sorted().joined(separator: ", ")
        Self.logger.notice("Blocked scan scope locations: \(blockedSummary, privacy: .public)")
    }
}
