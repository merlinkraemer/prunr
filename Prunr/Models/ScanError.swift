import Foundation

/// Errors that can occur during scanning
enum ScanError: Error, LocalizedError, Sendable {
    /// Permission denied for the given path
    case permissionDenied(String)

    /// The provided path is invalid or doesn't exist
    case invalidPath

    /// Scan was cancelled by the user
    case cancelled

    /// Scan traversal stopped making progress and was aborted
    case stalled(String)

    /// The filesystem reported an unreadable or otherwise incomplete subtree.
    case traversalFailed(String)

    /// An unknown error occurred during scanning
    case unknown(Error)

    var errorDescription: String? {
        switch self {
        case .permissionDenied(let path):
            return "Permission denied: \(path)\n\nGrant Full Disk Access in System Settings > Privacy & Security > Full Disk Access"
        case .invalidPath:
            return "Invalid path or path does not exist"
        case .cancelled:
            return "Scan cancelled"
        case .stalled(let path):
            return "Scan stalled while reading: \(path)\n\nThe scan was stopped so Prunr can recover. Try scanning a smaller folder or add this location to the ignore list."
        case .traversalFailed(let path):
            return "Scan could not read: \(path)\n\nThe previous inventory was kept so unreadable files are not mistaken for deletions."
        case .unknown(let error):
            return "Scan failed: \(error.localizedDescription)"
        }
    }

    /// Recovery suggestion for the error
    var recoverySuggestion: String? {
        switch self {
        case .permissionDenied:
            return "Go to System Settings > Privacy & Security > Full Disk Access and add Prunr to the list of allowed applications."
        case .invalidPath:
            return "Check that the path exists and you have access to it."
        case .cancelled:
            return nil
        case .stalled:
            return "Try again after excluding problematic folders, or choose a more specific tracked path."
        case .traversalFailed:
            return "Check access to this folder, then try again."
        case .unknown:
            return "Try again or contact support if the problem persists."
        }
    }
}
