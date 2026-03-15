import Foundation

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
        let targetURL = (url ?? FileManager.default.homeDirectoryForCurrentUser).standardizedFileURL
        let resourceKeys: Set<URLResourceKey> = [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeTotalCapacityKey
        ]

        do {
            let values = try targetURL.resourceValues(forKeys: resourceKeys)
            let freeBytes = values.volumeAvailableCapacityForImportantUsage
                ?? Int64(values.volumeAvailableCapacity ?? 0)
            let totalBytes = Int64(values.volumeTotalCapacity ?? 0)
            return (freeBytes: freeBytes, totalBytes: totalBytes)
        } catch {
            return nil
        }
    }
}
