import Foundation

final class DiskSpaceService {
    static let shared = DiskSpaceService()

    private var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    func getFreeSpace() -> Int64 {
        do {
            let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return values.volumeAvailableCapacityForImportantUsage ?? 0
        } catch {
            return 0
        }
    }

    func getTotalSpace() -> Int64 {
        do {
            let values = try url.resourceValues(forKeys: [.volumeTotalCapacityKey])
            return Int64(values.volumeTotalCapacity ?? 0)
        } catch {
            return 0
        }
    }

    func getFreeSpaceFormatted() -> String {
        let freeBytes = getFreeSpace()
        return ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)
    }
}
