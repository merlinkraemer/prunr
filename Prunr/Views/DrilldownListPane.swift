import Foundation

/// List side of the menu bar drill-down stack (shared with header mapping).
enum DrilldownListLevel: Int, Sendable {
    case main
    case subcategories
    case files
}

struct DrilldownPaneContent: Equatable {
    let groups: [SubcategoryGroup]
    let fileGroup: SubcategoryGroup?
    let isGroupsPending: Bool
    let groupsReadFailed: Bool
    let filesReadFailed: Bool
    let isFilesLoaded: Bool
}

struct DrilldownListPane: Equatable {
    let level: DrilldownListLevel
    let category: CategoryInventoryItem?
    let subcategory: SubcategoryGroup?
    var content: DrilldownPaneContent?

    func frozen(with content: DrilldownPaneContent) -> DrilldownListPane {
        DrilldownListPane(level: level, category: category, subcategory: subcategory, content: content)
    }

    static let main = DrilldownListPane(level: .main, category: nil, subcategory: nil)

    static func == (lhs: DrilldownListPane, rhs: DrilldownListPane) -> Bool {
        lhs.id == rhs.id
    }

    var id: String {
        switch level {
        case .main:
            "main"
        case .subcategories:
            "subcategories-\(category?.category.rawValue ?? "none")"
        case .files:
            "files-\(category?.category.rawValue ?? "none")-\(subcategory?.id ?? "none")"
        }
    }
}
