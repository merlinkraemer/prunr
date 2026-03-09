import Foundation
import Darwin

final class DiskSpaceService {
    static let shared = DiskSpaceService()

    func getFreeSpace(for url: URL? = nil) -> Int64 {
        let stats = fileSystemStats(for: url)
        return stats?.freeBytes ?? 0
    }

    func getTotalSpace(for url: URL? = nil) -> Int64 {
        let stats = fileSystemStats(for: url)
        return stats?.totalBytes ?? 0
    }

    func getFreeSpaceFormatted(for url: URL? = nil) -> String {
        let freeBytes = getFreeSpace(for: url)
        return ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)
    }

    private func fileSystemStats(for url: URL?) -> (freeBytes: Int64, totalBytes: Int64)? {
        var fs = statfs()
        let targetURL = (url ?? FileManager.default.homeDirectoryForCurrentUser).standardizedFileURL
        let path = targetURL.path

        let result = path.withCString { cPath in
            statfs(cPath, &fs)
        }

        guard result == 0 else { return nil }

        let blockSize = Int64(fs.f_bsize)
        let freeBytes = Int64(fs.f_bavail) * blockSize
        let totalBytes = Int64(fs.f_blocks) * blockSize
        return (freeBytes: freeBytes, totalBytes: totalBytes)
    }
}
