import Foundation

struct ScanFolderName: Equatable {
    let path: String
    private let homePath: String

    init(path: String, homePath: String = NSHomeDirectory()) {
        self.path = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        self.homePath = URL(fileURLWithPath: homePath, isDirectory: true).standardizedFileURL.path
    }

    var isHome: Bool { path == homePath }

    var isWholeDisk: Bool { path == "/" }

    var title: String {
        if isHome { return "Home" }
        if isWholeDisk { return "Whole disk" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    var phrase: String {
        if isHome { return "your home folder" }
        if isWholeDisk { return "your whole disk" }
        return "the \(title) folder"
    }

    var displayPath: String {
        guard path.hasPrefix(homePath + "/") else { return path }
        return "~" + path.dropFirst(homePath.count)
    }
}
