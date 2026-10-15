import Foundation

/// The row a file belongs to on the category drilldown page: its subcategory,
/// or in Apps & System the owner of the file's place (an app, System, ...).
/// Owners are stored unresolved; the store merges the ones that turn out to
/// be the same installed app.
enum DrilldownGroupKey {
    static let ownerPrefix = "owner:"
    static let ownerCategory = GrowthCategory.cachesAndSystem

    static func make(category: GrowthCategory, subcategory: GrowthSubcategory?, path: String) -> String {
        category == ownerCategory ? ownerKey(path: path) : subcategory?.rawValue ?? ""
    }

    static func make(category: GrowthCategory, subcategory: GrowthSubcategory?, unitKey: String) -> String {
        category == ownerCategory ? ownerKey(unitKey: unitKey) : subcategory?.rawValue ?? ""
    }

    static func ownerKey(path: String) -> String {
        ownerKey(unitKey: UnitResolver.resolve(path: path))
    }

    static func ownerKey(unitKey: String) -> String {
        ownerPrefix + ownerTokens.token(forUnitKey: unitKey)
    }

    /// The owner of an owner group key; nil for subcategory groups.
    static func owner(of groupKey: String) -> UnitOwner? {
        guard isOwnerGroupKey(groupKey) else { return nil }
        return UnitOwner(token: String(groupKey.dropFirst(ownerPrefix.count)))
    }

    static func isOwnerGroupKey(_ groupKey: String) -> Bool {
        groupKey.hasPrefix(ownerPrefix)
    }

    private static let ownerTokens = OwnerTokenCache()
}

/// Owner tokens by unit key: a place's owner depends only on its key, and the
/// index asks once per file.
private final class OwnerTokenCache: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String: String] = [:]

    func token(forUnitKey unitKey: String) -> String {
        lock.lock()
        if let token = tokens[unitKey] {
            lock.unlock()
            return token
        }
        lock.unlock()
        let token = UnitNamer.name(forKey: unitKey).owner.token
        lock.lock()
        if tokens.count > 50_000 { tokens.removeAll(keepingCapacity: true) }
        tokens[unitKey] = token
        lock.unlock()
        return token
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

        mutating func add(_ sizeBytes: Int64) {
            totalBytes += sizeBytes
            fileCount += 1
        }
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
        let unitKey = unitKey ?? UnitResolver.resolve(path: path)

        let id = GroupID(
            category: category,
            groupKey: DrilldownGroupKey.make(category: category, subcategory: subcategory, unitKey: unitKey)
        )
        Self.accumulate(path: path, pathId: pathId, sizeBytes: sizeBytes, into: &groups[id, default: GroupAccumulator()])

        if let child = PlaceChildKey(path: path, unitKey: unitKey) {
            placeChildren[child, default: Totals()].add(sizeBytes)
        }
    }

    static func accumulate(path: String, pathId: Int64?, sizeBytes: Int64, into group: inout GroupAccumulator) {
        group.totalBytes += sizeBytes
        group.fileCount += 1
        group.candidates.append(TopFile(path: path, pathId: pathId, sizeBytes: sizeBytes))
        if group.candidates.count >= topLimit * 2 {
            group.candidates = ranked(group.candidates)
        }
    }

    /// The group's largest files, largest first, at most `topLimit`.
    func topFiles(of id: GroupID) -> [TopFile] {
        Self.ranked(groups[id]?.candidates ?? [])
    }

    static func ranked(_ files: [TopFile]) -> [TopFile] {
        Array(files.sorted {
            if $0.sizeBytes != $1.sizeBytes { return $0.sizeBytes > $1.sizeBytes }
            return $0.path < $1.path
        }.prefix(topLimit))
    }
}
