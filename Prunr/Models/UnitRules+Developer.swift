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
}

extension UnitRules {
    /// Order matters: tool-owned folders first, then project markers, so a
    /// `node_modules` inside `~/.cargo` is still a cargo folder.
    static let developer: [UnitRule] = [
        xcodeBuildRule, xcodeArchivesRule, xcodeDeviceSupportRule, xcodeSimulatorRule,
        dockerRule, colimaRule, modelStoreRule, packageCacheRule,
        nodeModulesRule, pythonEnvRule, buildOutputRule, gitHistoryRule
    ]

    // MARK: Xcode

    /// `~/Library/Developer/Xcode/<area>`: the lowercased `<area>`, or nil.
    private static func xcodeArea(_ path: UnitPath) -> String? {
        guard let rel = path.lowercasedRelative, rel.count >= 4,
              rel[0] == "library", rel[1] == "developer", rel[2] == "xcode" else { return nil }
        return rel[3]
    }

    /// `DerivedData/<Name-hash>` → "Xcode build files · Name".
    static let xcodeBuildRule = UnitRule(
        kind: .xcodeBuild,
        resolve: { path in
            guard let rel = path.relative, xcodeArea(path) == "deriveddata" else { return nil }
            return path.homeRoot(depth: rel.count >= 5 ? 5 : 4)
        },
        name: { root in
            guard let rel = root.relative, rel.count >= 5,
                  let project = strippingXcodeHash(rel[4]) else {
                return UnitName(title: "Xcode build files", category: .developer)
            }
            return UnitName(title: "Xcode build files · \(project)", category: .developer)
        }
    )

    static let xcodeArchivesRule = UnitRule(
        kind: .xcodeArchives,
        resolve: { path in xcodeArea(path) == "archives" ? path.homeRoot(depth: 4) : nil },
        name: { _ in UnitName(title: "Xcode archives", category: .developer) }
    )

    /// "iOS DeviceSupport", "watchOS DeviceSupport", "tvOS DeviceSupport".
    static let xcodeDeviceSupportRule = UnitRule(
        kind: .xcodeDeviceSupport,
        resolve: { path in
            guard let area = xcodeArea(path), area.hasSuffix("devicesupport") else { return nil }
            return path.homeRoot(depth: 4)
        },
        name: { _ in UnitName(title: "Xcode device support", category: .developer) }
    )

    static let xcodeSimulatorRule = UnitRule(
        kind: .xcodeSimulator,
        resolve: { path in
            guard let rel = path.lowercasedRelative, rel.count >= 3,
                  rel[0] == "library", rel[1] == "developer", rel[2] == "coresimulator" else { return nil }
            return path.homeRoot(depth: 3)
        },
        name: { _ in UnitName(title: "Xcode simulators", category: .developer) }
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
        name: { _ in UnitName(title: "Docker disk", detail: dockerDetail, category: .developer) }
    )

    static let colimaRule = UnitRule(
        kind: .colima,
        resolve: { path in path.lowercasedRelative?.first == ".colima" ? path.homeRoot(depth: 1) : nil },
        name: { _ in UnitName(title: "Docker disk · Colima", detail: dockerDetail, category: .developer) }
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

    private static let projectRoots: Set<String> = [
        "dev", "projects", "code", "repos", "src", "workspace", "developer", "xcode", "android"
    ]
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
                return UnitName(title: "\(title) · \(project)", category: .developer)
            }
        )
    }

    static let nodeModulesRule = markerRule(.nodeModules, title: "node_modules", orphanTitle: "node_modules")
    static let pythonEnvRule = markerRule(.pythonEnv, title: "Python env", orphanTitle: "Python environments")
    static let buildOutputRule = markerRule(.buildOutput, title: "Build files", orphanTitle: "Build files")
    static let gitHistoryRule = markerRule(.gitHistory, title: "Git history", orphanTitle: "Git history")
}
