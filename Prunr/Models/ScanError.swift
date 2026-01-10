import Foundation

/// Errors that can occur during scanning
enum ScanError: Error, LocalizedError, Sendable {
    /// Permission denied for the given path
    case permissionDenied(String)

    /// The provided path is invalid or doesn't exist
    case invalidPath

    /// An unknown error occurred during scanning
    case unknown(Error)

    var errorDescription: String? {
        switch self {
        case .permissionDenied(let path):
            return "Permission denied: \(path)"
        case .invalidPath:
            return "Invalid path or path does not exist"
        case .unknown(let error):
            return "Unknown error: \(error.localizedDescription)"
        }
    }
}
