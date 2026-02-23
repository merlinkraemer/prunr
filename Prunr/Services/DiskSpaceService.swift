import Foundation
import Darwin

final class DiskSpaceService {
    static let shared = DiskSpaceService()

    private var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    func getFreeSpace() -> Int64 {
        let stats = fileSystemStats()
        return stats?.freeBytes ?? 0
    }

    func getTotalSpace() -> Int64 {
        let stats = fileSystemStats()
        return stats?.totalBytes ?? 0
    }

    func getFreeSpaceFormatted() -> String {
        let freeBytes = getFreeSpace()
        return ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)
    }

    private func fileSystemStats() -> (freeBytes: Int64, totalBytes: Int64)? {
        var fs = statfs()
        let path = url.path

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
