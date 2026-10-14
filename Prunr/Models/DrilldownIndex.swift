import Foundation

/// The row a file belongs to on the category drilldown page: its subcategory,
/// or for application caches the application that owns the cache folder.
enum DrilldownGroupKey {
    static let cachePrefix = "cache:"
    static let cacheSubcategories: Set<GrowthSubcategory> = [.appCaches, .browserCaches, .spotifyCache]

    static func make(category: GrowthCategory, subcategory: GrowthSubcategory?, path: String) -> String {
        if isCacheGroup(category: category, subcategory: subcategory) {
            return cacheKey(path: path)
        }
        return subcategory?.rawValue ?? ""
    }

    static func isCacheGroup(category: GrowthCategory, subcategory: GrowthSubcategory?) -> Bool {
        guard category == .cachesAndSystem, let subcategory else { return false }
        return cacheSubcategories.contains(subcategory)
    }

    static func cacheKey(path: String) -> String {
        cachePrefix + (GrowthCategory.cacheApplicationKey(for: path) ?? "")
    }

    /// The owning application for a cache group key; nil for other groups and
    /// for caches without an application folder.
    static func cacheApplication(of groupKey: String) -> String? {
        guard groupKey.hasPrefix(cachePrefix) else { return nil }
        let application = String(groupKey.dropFirst(cachePrefix.count))
        return application.isEmpty ? nil : application
    }

    static func isCacheGroupKey(_ groupKey: String) -> Bool {
        groupKey.hasPrefix(cachePrefix)
    }
}

/// One direct child of a place (unit root): a folder with everything below it
/// aggregated, or a file. A file unit (e.g. a single download) has one child,
/// the root itself, stored with an empty name.
struct PlaceChildKey: Hashable, Sendable {
    let unitRoot: String
    let name: String
    let isFolder: Bool

    init(unitRoot: String, name: String, isFolder: Bool) {
        self.unitRoot = unitRoot
        self.name = name
        self.isFolder = isFolder
    }

    init?(path: String, unitKey: String) {
        guard let key = UnitKey(rawValue: unitKey) else { return nil }
        let root = key.rootPath
        if path == root || path.caseInsensitiveCompare(root) == .orderedSame {
            self.init(unitRoot: root, name: "", isFolder: false)
            return
        }

        let prefix = root == "/" ? "/" : root + "/"
        let rest: Substring
        if path.hasPrefix(prefix) {
            rest = path.dropFirst(prefix.count)
        } else if let range = path.range(of: prefix, options: [.anchored, .caseInsensitive]) {
            rest = path[range.upperBound...]
        } else {
            return nil
        }
        guard !rest.isEmpty else { return nil }

        if let slash = rest.firstIndex(of: "/") {
            self.init(unitRoot: root, name: String(rest[..<slash]), isFolder: true)
        } else {
            self.init(unitRoot: root, name: String(rest), isFolder: false)
        }
    }
}

/// Exact drilldown index for one tracked path, accumulated file by file: per
/// group totals plus the group's largest files, and per place child totals.
/// Fed by a full scan in memory or by a pass over the working set.
struct DrilldownIndexBuilder: Sendable {
    struct GroupID: Hashable, Sendable {
        let category: GrowthCategory
        let groupKey: String
    }

    struct TopFile: Sendable, Equatable {
        let path: String
        let pathId: Int64?
        let sizeBytes: Int64
    }

    struct GroupAccumulator: Sendable {
        var totalBytes: Int64 = 0
        var fileCount = 0
        var candidates: [TopFile] = []
    }

    struct Totals: Sendable, Equatable {
        var totalBytes: Int64 = 0
        var fileCount = 0
    }

    static let topLimit = 200

    private(set) var groups: [GroupID: GroupAccumulator] = [:]
    private(set) var placeChildren: [PlaceChildKey: Totals] = [:]
    private(set) var categoryTotals: [GrowthCategory: Int64] = [:]

    init() {}

    mutating func add(
        path: String,
        pathId: Int64? = nil,
        sizeBytes: Int64,
        category: GrowthCategory,
        subcategory: GrowthSubcategory?,
        unitKey: String? = nil
    ) {
        categoryTotals[category, default: 0] += sizeBytes

        let id = GroupID(
            category: category,
            groupKey: DrilldownGroupKey.make(category: category, subcategory: subcategory, path: path)
        )
        var group = groups[id] ?? GroupAccumulator()
        group.totalBytes += sizeBytes
        group.fileCount += 1
        group.candidates.append(TopFile(path: path, pathId: pathId, sizeBytes: sizeBytes))
        if group.candidates.count >= Self.topLimit * 2 {
            group.candidates = Self.ranked(group.candidates)
        }
        groups[id] = group

        if let child = PlaceChildKey(path: path, unitKey: unitKey ?? UnitResolver.resolve(path: path)) {
            placeChildren[child, default: Totals()].totalBytes += sizeBytes
            placeChildren[child, default: Totals()].fileCount += 1
        }
    }

    /// The group's largest files, largest first, at most `topLimit`.
    func topFiles(of id: GroupID) -> [TopFile] {
        Self.ranked(groups[id]?.candidates ?? [])
    }

    private static func ranked(_ files: [TopFile]) -> [TopFile] {
        Array(files.sorted {
            if $0.sizeBytes != $1.sizeBytes { return $0.sizeBytes > $1.sizeBytes }
            return $0.path < $1.path
        }.prefix(topLimit))
    }
}
