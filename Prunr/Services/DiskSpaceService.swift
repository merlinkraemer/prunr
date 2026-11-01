import Foundation

final class DiskSpaceService {
    static let shared = DiskSpaceService()

    func getFreeSpace(for url: URL? = nil) -> Int64? {
        fileSystemStats(for: url)?.freeBytes
    }

    func getTotalSpace(for url: URL? = nil) -> Int64? {
        fileSystemStats(for: url)?.totalBytes
    }

    func getFreeSpaceFormatted(for url: URL? = nil) -> String? {
        guard let freeBytes = getFreeSpace(for: url) else { return nil }
        return ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)
    }

    func getSpace(for url: URL? = nil) -> (freeBytes: Int64, totalBytes: Int64)? {
        fileSystemStats(for: url)
    }

    private func fileSystemStats(for url: URL?) -> (freeBytes: Int64, totalBytes: Int64)? {
        let targetURL = (url ?? FileManager.default.homeDirectoryForCurrentUser).standardizedFileURL
        let resourceKeys: Set<URLResourceKey> = [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
            .volumeTotalCapacityKey
        ]

        guard let values = try? targetURL.resourceValues(forKeys: resourceKeys),
              let freeBytes = values.volumeAvailableCapacityForImportantUsage
                ?? values.volumeAvailableCapacity.map(Int64.init),
              let totalCapacity = values.volumeTotalCapacity else {
            return nil
        }
        return (freeBytes: freeBytes, totalBytes: Int64(totalCapacity))
    }
}
