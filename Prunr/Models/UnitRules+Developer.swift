import Foundation

// Developer unit rules (slice s5): Xcode DerivedData / Archives / DeviceSupport /
// CoreSimulator, Docker and Colima, the outermost node_modules, Python envs,
// build output, .git, package caches (~/.npm, ~/.gradle, ~/.cargo, ~/.m2,
// ~/.cache/<tool>) and model stores (~/.ollama/models, ~/.cache/huggingface).
//
// How to add a rule:
// - Declare its kind here: `extension UnitKind { static let xcodeBuild = UnitKind(rawValue: "xcode-build") }`.
//   The raw value is persisted in keys; never rename it after release.
// - Append a `UnitRule(kind:resolve:name:)` to `developer`. `resolve` returns the
//   unit root (build it with `UnitPath.homeRoot(depth:)` / `root(depth:)` so the
//   path's case is preserved) or nil. `name` names a root of that kind.
// - Names pass through `UnitNamer.sanitize`; test them with
//   `UnitNamer.containsForbiddenToken`.
//
// Order: this pack resolves after Trash and Downloads, before media and app rules.

extension UnitKind {
    static let xcodeBuild = UnitKind(rawValue: "xcode-build")
    static let xcodeArchives = UnitKind(rawValue: "xcode-archives")
    static let xcodeDeviceSupport = UnitKind(rawValue: "xcode-devicesupport")
    static let xcodeSimulator = UnitKind(rawValue: "xcode-simulator")
    static let docker = UnitKind(rawValue: "docker")
    static let colima = UnitKind(rawValue: "colima")
    static let packageCache = UnitKind(rawValue: "package-cache")
    static let modelStore = UnitKind(rawValue: "model-store")
    static let nodeModules = UnitKind(rawValue: "node-modules")
    static let pythonEnv = UnitKind(rawValue: "python-env")
    static let buildOutput = UnitKind(rawValue: "build-output")
    static let gitHistory = UnitKind(rawValue: "git")
    /// A hidden home folder holding a tool's state: `~/.<tool>`, `~/.local/share/<tool>`.
    static let tool = UnitKind(rawValue: "tool")
}

extension UnitRules {
    /// Order matters: tool-owned folders first, then project markers, so a
    /// `node_modules` inside `~/.cargo` is still a cargo folder.
    static let developer: [UnitRule] = [
        xcodeBuildRule, xcodeArchivesRule, xcodeDeviceSupportRule, xcodeSimulatorRule,
        dockerRule, colimaRule, modelStoreRule, packageCacheRule,
        nodeModulesRule, pythonEnvRule, buildOutputRule, gitHistoryRule, toolRule
    ]

    // MARK: Xcode

    /// `~/Library/Developer/Xcode/<area>`: the lowercased `<area>`, or nil.
    private static func xcodeArea(_ path: UnitPath) -> String? {
        guard let rel = path.lowercasedRelative, rel.count >= 4,
              rel[0] == "library", rel[1] == "developer", rel[2] == "xcode" else { return nil }
        return rel[3]
    }

    /// `DerivedData/<Name-hash>` → "Xcode build files · Name". Also any folder
    /// shaped like DerivedData, wherever `-derivedDataPath` or the custom
    /// location points: it holds Xcode-only folders (`Index.noindex`,
    /// `ModuleCache.noindex`, `Build/Intermediates.noindex`, `Build/Products`)
    /// or is named `<Name>-<28 letter hash>` with a `Build`, `Logs`, ... inside.
    static let xcodeBuildRule = UnitRule(
        kind: .xcodeBuild,
        resolve: { path in
            if let rel = path.relative, xcodeArea(path) == "deriveddata" {
                return path.homeRoot(depth: rel.count >= 5 ? 5 : 4)
            }
            guard let index = derivedDataRootIndex(path) else { return nil }
            return path.root(depth: index + 1)
        },
        name: { root in
            let project: String?
            if let rel = root.relative, xcodeArea(root) == "deriveddata" {
                project = rel.count >= 5 ? strippingXcodeHash(rel[4]) : nil
            } else {
                project = derivedDataProjectName(root)
            }
            guard let project else {
                return UnitName(title: "Xcode build files", category: .developer, icon: .xcode)
            }
            return UnitName(title: "Xcode build files · \(project)", shortTitle: project, category: .developer, icon: .xcode)
        }
    )

    private static let xcodeOnlyFolders: Set<String> = [
        "index.noindex", "modulecache.noindex", "compilationcache.noindex", "sdkstatcaches.noindex"
    ]
    private static let derivedDataBuildFolders: Set<String> = ["intermediates.noindex", "products"]
    private static let derivedDataHashedChildren: Set<String> = [
        "build", "index.noindex", "logs", "info.plist", "sourcepackages", "textbasedinstallapi"
    ]

    /// Index of the outermost component that is a DerivedData folder by shape.
    private static func derivedDataRootIndex(_ path: UnitPath) -> Int? {
        let lower = path.components.map { $0.lowercased() }
        guard lower.count >= 2 else { return nil }
        for index in 0..<(lower.count - 1) {
            let child = lower[index + 1]
            if xcodeOnlyFolders.contains(child) { return index }
            if child == "build", index + 2 < lower.count, derivedDataBuildFolders.contains(lower[index + 2]) {
                return index
            }
            if derivedDataHashedChildren.contains(child), hasXcodeHash(path.components[index]) { return index }
        }
        return nil
    }

    /// The project a DerivedData folder outside Xcode's default location builds:
    /// "Weatherly-<hash>" → "Weatherly", "pad-dd" → "pad", "<project>/build" →
    /// "project". Words that only say "build output" are dropped; a folder made
    /// only of them names its parent instead.
    private static func derivedDataProjectName(_ root: UnitPath) -> String? {
        let parts = root.relative ?? root.components
        for folder in parts.reversed().prefix(4) {
            if let project = strippingXcodeHash(folder) { return project }
            let stem = UnitNamer.plainStem(folder)
            let tokens = (stem ?? folder).split(whereSeparator: { "-_. ".contains($0) })
            let kept = tokens.filter { !buildOutputWords.contains($0.lowercased()) }
            if kept.isEmpty { continue }
            if stem == nil, kept.count == tokens.count { return UnitNamer.displayComponent(folder) }
            return UnitNamer.displayComponent(kept.joined(separator: " "))
        }
        return nil
    }

    private static let buildOutputWords: Set<String> = [
        "dd", "derived", "deriveddata", "data", "build", "builds", "xcode", "xcodebuild",
        "mac", "macos", "ios", "debug", "release", "dev"
    ]

    private static func hasXcodeHash(_ component: String) -> Bool {
        component.range(of: "-[a-z]{28}$", options: .regularExpression) != nil
    }

    static let xcodeArchivesRule = UnitRule(
        kind: .xcodeArchives,
        resolve: { path in xcodeArea(path) == "archives" ? path.homeRoot(depth: 4) : nil },
        name: { _ in UnitName(title: "Xcode archives", category: .developer, icon: .xcode) }
    )

    /// "iOS DeviceSupport", "watchOS DeviceSupport", "tvOS DeviceSupport".
    static let xcodeDeviceSupportRule = UnitRule(
        kind: .xcodeDeviceSupport,
        resolve: { path in
            guard let area = xcodeArea(path), area.hasSuffix("devicesupport") else { return nil }
            return path.homeRoot(depth: 4)
        },
        name: { _ in UnitName(title: "Device support", category: .developer, icon: .xcode) }
    )

    static let xcodeSimulatorRule = UnitRule(
        kind: .xcodeSimulator,
        resolve: { path in
            guard let rel = path.lowercasedRelative, rel.count >= 3,
                  rel[0] == "library", rel[1] == "developer", rel[2] == "coresimulator" else { return nil }
            return path.homeRoot(depth: 3)
        },
        name: { _ in UnitName(title: "Simulators", category: .developer, icon: .xcode) }
    )

    /// Xcode appends a 28 letter hash to the project name ("Prunr-bkgqx..."). Nil
    /// when there is no hash (ModuleCache.noindex) or nothing readable is left.
    private static func strippingXcodeHash(_ component: String) -> String? {
        guard let range = component.range(of: "-[a-z]{20,}$", options: .regularExpression) else { return nil }
        return UnitNamer.displayComponent(String(component[..<range.lowerBound]))
    }

    // MARK: Docker and Colima

    private static let dockerDetail = "images, containers, volumes"

    /// "Docker disk": the Docker Desktop container and group container,
    /// `~/.docker` and any stray `Docker.raw`.
    static let dockerRule = UnitRule(
        kind: .docker,
        resolve: { path in
            guard let rel = path.lowercasedRelative else { return nil }
            if rel.first == ".docker" { return path.homeRoot(depth: 1) }
            if rel.count >= 3, rel[0] == "library",
               rel[1] == "containers" || rel[1] == "group containers",
               rel[2] == "com.docker.docker" || rel[2] == "group.com.docker" {
                return path.homeRoot(depth: 3)
            }
            if let index = rel.firstIndex(of: "docker.raw") {
                return path.homeRoot(depth: index + 1)
            }
            return nil
        },
        name: { _ in UnitName(title: "Docker disk", context: dockerDetail, category: .developer, icon: .docker) }
    )

    static let colimaRule = UnitRule(
        kind: .colima,
        resolve: { path in path.lowercasedRelative?.first == ".colima" ? path.homeRoot(depth: 1) : nil },
        name: { _ in UnitName(title: "Docker disk · Colima", context: dockerDetail, category: .developer, icon: .docker) }
    )

    // MARK: Model stores and package caches

    /// `~/.ollama/models` and `~/.cache/huggingface`.
    static let modelStoreRule = UnitRule(
        kind: .modelStore,
        resolve: { path in
            guard let rel = path.lowercasedRelative, rel.count >= 2 else { return nil }
            if rel[0] == ".ollama", rel[1] == "models" { return path.homeRoot(depth: 2) }
            if rel[0] == ".cache", rel[1] == "huggingface" { return path.homeRoot(depth: 2) }
            return nil
        },
        name: { root in
            guard let rel = root.lowercasedRelative, rel.count >= 2 else { return nil }
            if rel[0] == ".ollama" { return UnitName(title: "Ollama models", category: .developer) }
            if rel[0] == ".cache" { return UnitName(title: "Hugging Face models", category: .developer) }
            return nil
        }
    )

    private static let packageCacheTitles: [String: String] = [
        ".npm": "npm cache", ".gradle": "Gradle cache", ".cargo": "Cargo cache", ".m2": "Maven cache"
    ]

    /// `~/.npm`, `~/.gradle`, `~/.cargo`, `~/.m2` and `~/.cache/<tool>`.
    static let packageCacheRule = UnitRule(
        kind: .packageCache,
        resolve: { path in
            guard let rel = path.lowercasedRelative, let first = rel.first else { return nil }
            if packageCacheTitles[first] != nil { return path.homeRoot(depth: 1) }
            if first == ".cache" { return path.homeRoot(depth: rel.count >= 2 ? 2 : 1) }
            return nil
        },
        name: { root in
            guard let rel = root.relative, let first = rel.first?.lowercased() else { return nil }
            if let title = packageCacheTitles[first] {
                return UnitName(title: title, category: .developer)
            }
            guard first == ".cache" else { return nil }
            guard rel.count >= 2, let tool = UnitNamer.displayComponent(rel[1]) else {
                return UnitName(title: "Cache files", category: .developer)
            }
            return UnitName(title: "\(tool) cache", category: .developer)
        }
    )

    // MARK: Project markers (outermost wins)

    private static let projectRoots = GrowthCategory.developerFolderNames
    private static let globalPackageFolders: Set<String> = [
        ".npm-global", ".bun", ".yarn", ".nvm", ".volta", ".fnm", ".pnpm", ".pnpm-store", ".asdf"
    ]

    /// The outermost project marker in a path: its kind and the number of absolute
    /// components up to and including it. Nil for global packages and paths
    /// without a marker. `build`, `dist` and `target` only count under a
    /// developer folder; `.build` always does.
    private static func outermostMarker(_ path: UnitPath) -> (kind: UnitKind, depth: Int)? {
        let base = path.homeDepth ?? 0
        let parts = path.components[base...].map { $0.lowercased() }
        let inDevRoot = path.homeDepth != nil && parts.first.map { projectRoots.contains($0) } == true
        for (index, part) in parts.enumerated() {
            let depth = base + index + 1
            switch part {
            case "node_modules":
                let outsideHomeSystem = path.homeDepth == nil && ["usr", "opt", "system"].contains(parts.first ?? "")
                let isGlobal = outsideHomeSystem
                    || parts.contains { globalPackageFolders.contains($0) }
                    || (index >= 1 && parts[index - 1] == "lib")
                if isGlobal { return nil }
                return (.nodeModules, depth)
            case ".venv", "venv", ".conda":
                return (.pythonEnv, depth)
            case ".git":
                return (.gitHistory, depth)
            case ".build":
                return (.buildOutput, depth)
            case "build", "dist", "target":
                if inDevRoot && index >= 1 { return (.buildOutput, depth) }
            default:
                break
            }
        }
        return nil
    }

    /// The folder holding the marker; nil when the marker sits directly in home
    /// or at the top of the disk.
    private static func projectName(of root: UnitPath) -> String? {
        let parts = root.relative ?? root.components
        guard parts.count >= 2 else { return nil }
        return UnitNamer.displayComponent(parts[parts.count - 2])
    }

    private static func markerRule(_ kind: UnitKind, title: String, orphanTitle: String) -> UnitRule {
        UnitRule(
            kind: kind,
            resolve: { path in
                guard let marker = outermostMarker(path), marker.kind == kind else { return nil }
                return path.root(depth: marker.depth)
            },
            name: { root in
                guard let project = projectName(of: root) else {
                    return UnitName(title: orphanTitle, category: .developer)
                }
                return UnitName(title: "\(title) · \(project)", shortTitle: project, category: .developer)
            }
        )
    }

    static let nodeModulesRule = markerRule(.nodeModules, title: "node_modules", orphanTitle: "node_modules")
    static let pythonEnvRule = markerRule(.pythonEnv, title: "Python env", orphanTitle: "Python environments")
    static let buildOutputRule = markerRule(.buildOutput, title: "Build files", orphanTitle: "Build files")
    static let gitHistoryRule = markerRule(.gitHistory, title: "Git history", orphanTitle: "Git history")

    // MARK: Tool state in hidden home folders

    private static let xdgDataFolders: Set<String> = ["share", "state"]

    /// A hidden folder in home is a tool's state by Unix convention: `~/.codex`
    /// → "Codex data", one unit. XDG folders go one level deeper:
    /// `~/.local/share/<tool>`, `~/.local/state/<tool>`, `~/.config/<tool>`.
    /// Runs after every other developer rule, so Docker, Colima, package caches
    /// and project markers inside hidden folders keep their own units.
    static let toolRule = UnitRule(
        kind: .tool,
        resolve: { path in
            guard let rel = path.lowercasedRelative, rel.count >= 2, let first = rel.first,
                  first.hasPrefix("."), first.count > 1 else { return nil }
            switch first {
            case ".local":
                if rel.count >= 4, xdgDataFolders.contains(rel[1]) { return path.homeRoot(depth: 3) }
                return path.homeRoot(depth: rel.count >= 3 ? 2 : 1)
            case ".config":
                return path.homeRoot(depth: rel.count >= 3 ? 2 : 1)
            default:
                return path.homeRoot(depth: 1)
            }
        },
        name: { root in
            guard let rel = root.relative, let folder = rel.last else { return nil }
            let tool = String(folder.drop(while: { $0 == "." }))
            guard let readable = UnitNamer.displayComponent(tool) else {
                return UnitName(title: "Tool data", category: .developer)
            }
            let name = readable.count > 3 ? readable.prefix(1).uppercased() + readable.dropFirst() : readable
            return UnitName(
                title: "\(name) data", shortTitle: name, category: .developer, icon: .namedApp(name: name, vendor: nil)
            )
        }
    )
}
