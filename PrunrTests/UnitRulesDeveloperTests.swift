import XCTest
@testable import Prunr

final class UnitRulesDeveloperTests: XCTestCase {
    private let home = "/Users/tester"
    private let xcodeHash = "bkgqxrtyuiopasdfghjklzxcvbnm"

    private func key(_ path: String) -> UnitKey {
        UnitResolver.resolveKey(path: path, home: home)
    }

    private func name(_ path: String) -> UnitName {
        UnitNamer.name(path: path, home: home)
    }

    // MARK: - Fixture: every path must get a developer name

    private var fixture: [(path: String, kind: UnitKind, root: String, title: String)] {
        let xcode = "/Users/tester/Library/Developer/Xcode"
        return [
            ("\(xcode)/DerivedData/Prunr-\(xcodeHash)/Build/Products/Debug/Prunr.app", .xcodeBuild, "\(xcode)/DerivedData/Prunr-\(xcodeHash)", "Xcode build files · Prunr"),
            ("\(xcode)/DerivedData/My App-\(xcodeHash)/Index", .xcodeBuild, "\(xcode)/DerivedData/My App-\(xcodeHash)", "Xcode build files · My App"),
            ("\(xcode)/DerivedData/ModuleCache.noindex/x.pcm", .xcodeBuild, "\(xcode)/DerivedData/ModuleCache.noindex", "Xcode build files"),
            ("\(xcode)/DerivedData", .xcodeBuild, "\(xcode)/DerivedData", "Xcode build files"),
            ("\(xcode)/Archives/2026-10-01/Prunr.xcarchive/Products", .xcodeArchives, "\(xcode)/Archives", "Xcode archives"),
            ("\(xcode)/iOS DeviceSupport/17.4 (21E213)/Symbols/usr/lib", .xcodeDeviceSupport, "\(xcode)/iOS DeviceSupport", "Device support"),
            ("/Users/tester/Library/Developer/CoreSimulator/Devices/ABC/data/x", .xcodeSimulator, "/Users/tester/Library/Developer/CoreSimulator", "Simulators"),
            ("/Users/tester/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw", .docker, "/Users/tester/Library/Containers/com.docker.docker", "Docker disk"),
            ("/Users/tester/Library/Group Containers/group.com.docker/settings.json", .docker, "/Users/tester/Library/Group Containers/group.com.docker", "Docker disk"),
            ("/Users/tester/.docker/desktop/vms/0/data/Docker.raw", .docker, "/Users/tester/.docker", "Docker disk"),
            ("/Users/tester/.colima/default/colima.yaml", .colima, "/Users/tester/.colima", "Docker disk · Colima"),
            ("/Users/tester/dev/acme/web/node_modules/react/index.js", .nodeModules, "/Users/tester/dev/acme/web/node_modules", "node_modules · web"),
            ("/Users/tester/dev/acme/node_modules/a/node_modules/b/x.js", .nodeModules, "/Users/tester/dev/acme/node_modules", "node_modules · acme"),
            ("/Users/tester/dev/acme/.venv/lib/python3.12/site.py", .pythonEnv, "/Users/tester/dev/acme/.venv", "Python env · acme"),
            ("/Users/tester/dev/acme/venv/bin/python", .pythonEnv, "/Users/tester/dev/acme/venv", "Python env · acme"),
            ("/Users/tester/.conda/envs/ml/lib/x.so", .pythonEnv, "/Users/tester/.conda", "Python environments"),
            ("/Users/tester/dev/acme/.build/debug/acme", .buildOutput, "/Users/tester/dev/acme/.build", "Build files · acme"),
            ("/Users/tester/dev/acme/target/release/acme", .buildOutput, "/Users/tester/dev/acme/target", "Build files · acme"),
            ("/Users/tester/projects/acme/dist/bundle.js", .buildOutput, "/Users/tester/projects/acme/dist", "Build files · acme"),
            ("/Users/tester/code/acme/build/out.o", .buildOutput, "/Users/tester/code/acme/build", "Build files · acme"),
            ("/Users/tester/dev/acme/.git/objects/pack/pack-1.pack", .gitHistory, "/Users/tester/dev/acme/.git", "Git history · acme"),
            ("/Users/tester/.npm/_cacache/content-v2/x", .packageCache, "/Users/tester/.npm", "npm cache"),
            ("/Users/tester/.gradle/caches/modules-2/x", .packageCache, "/Users/tester/.gradle", "Gradle cache"),
            ("/Users/tester/.cargo/registry/cache/x.crate", .packageCache, "/Users/tester/.cargo", "Cargo cache"),
            ("/Users/tester/.m2/repository/org/x.jar", .packageCache, "/Users/tester/.m2", "Maven cache"),
            ("/Users/tester/.cache/pip/http/a", .packageCache, "/Users/tester/.cache/pip", "pip cache"),
            ("/Users/tester/.cache", .packageCache, "/Users/tester/.cache", "Cache files"),
            ("/Users/tester/.ollama/models/blobs/sha256-abc", .modelStore, "/Users/tester/.ollama/models", "Ollama models"),
            ("/Users/tester/.cache/huggingface/hub/models--x/blobs/y", .modelStore, "/Users/tester/.cache/huggingface", "Hugging Face models")
        ]
    }

    func testEveryFixturePathResolvesToItsRuleAndName() {
        for entry in fixture {
            let resolved = key(entry.path)
            XCTAssertEqual(resolved.kind, entry.kind, entry.path)
            XCTAssertEqual(resolved.rootPath, entry.root, entry.path)
            XCTAssertEqual(name(entry.path).title, entry.title, entry.path)
            XCTAssertEqual(name(entry.path).category, .developer, entry.path)
        }
    }

    func testNoFixturePathFallsThroughToTheFallback() {
        for entry in fixture {
            XCTAssertNotEqual(key(entry.path).kind, .place, entry.path)
            XCTAssertNotEqual(key(entry.path).kind, .library, entry.path)
        }
    }

    func testNoFixtureNameContainsHashOrBundleId() {
        for entry in fixture {
            let unitName = name(entry.path)
            XCTAssertFalse(UnitNamer.containsForbiddenToken(unitName.title), unitName.title)
            XCTAssertFalse(UnitNamer.containsForbiddenToken(unitName.context ?? ""), unitName.context ?? "")
            XCTAssertFalse(unitName.title.contains(xcodeHash), unitName.title)
            XCTAssertFalse(unitName.title.contains("Library"), unitName.title)
        }
    }

    // MARK: - Specific behaviour

    func testDerivedDataHashIsStrippedAndUnitIsPerProject() {
        let base = "/Users/tester/Library/Developer/Xcode/DerivedData/Prunr-\(xcodeHash)"
        XCTAssertEqual(key("\(base)/Build/a").rawValue, key("\(base)/Logs/b").rawValue)
        XCTAssertEqual(name("\(base)/Build/a").title, "Xcode build files · Prunr")
    }

    func testDockerDiskNamingAndCaption() {
        let docker = name("/Users/tester/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw")
        XCTAssertEqual(docker.title, "Docker disk")
        XCTAssertEqual(docker.context, "images, containers, volumes")
        XCTAssertFalse(docker.title.localizedCaseInsensitiveContains("images"))
        XCTAssertEqual(name("/Users/tester/.colima/default/disk").context, "images, containers, volumes")
    }

    func testOutermostNodeModulesWinsEvenForNestedBuildFolders() {
        let nested = "/Users/tester/dev/acme/node_modules/pkg/build/Release/x.node"
        XCTAssertEqual(key(nested).rawValue, "node-modules|/Users/tester/dev/acme/node_modules")
    }

    func testOutermostMarkerWinsAcrossKinds() {
        XCTAssertEqual(key("/Users/tester/dev/acme/build/node_modules/x/y.js").kind, .buildOutput)
        XCTAssertEqual(key("/Users/tester/dev/acme/node_modules/x/.git/HEAD").kind, .nodeModules)
    }

    func testGlobalNodePackagesAreNotProjectModules() {
        XCTAssertNotEqual(key("/usr/local/lib/node_modules/typescript/lib/x.js").kind, .nodeModules)
        XCTAssertNotEqual(key("/Users/tester/.npm-global/lib/node_modules/x/y.js").kind, .nodeModules)
        XCTAssertNotEqual(key("/Users/tester/.nvm/versions/node/v20/lib/node_modules/x").kind, .nodeModules)
    }

    func testBuildFolderNamesOutsideDeveloperFoldersAreNotBuildFiles() {
        XCTAssertNotEqual(key("/Users/tester/Documents/Notes/build/a.txt").kind, .buildOutput)
        XCTAssertNotEqual(key("/Users/tester/Documents/Notes/dist/a.txt").kind, .buildOutput)
        XCTAssertNotEqual(key("/Users/tester/Documents/Notes/target/a.txt").kind, .buildOutput)
        // `.build` is distinctive enough anywhere.
        XCTAssertEqual(key("/Users/tester/Documents/Pkg/.build/x").kind, .buildOutput)
    }

    func testMarkerDirectlyInHomeHasNoProjectName() {
        XCTAssertEqual(name("/Users/tester/node_modules/x/y.js").title, "node_modules")
        XCTAssertEqual(name("/Users/tester/.venv/bin/python").title, "Python environments")
    }

    func testCaseOfIncomingPathIsPreservedInRoot() {
        XCTAssertEqual(
            key("/Users/tester/Dev/Acme/Node_Modules/x").rootPath,
            "/Users/tester/Dev/Acme/Node_Modules"
        )
        XCTAssertEqual(name("/Users/tester/Dev/Acme/Node_Modules/x").title, "node_modules · Acme")
    }

    func testNonDeveloperPathsAreUntouched() {
        XCTAssertEqual(key("/Users/tester/Downloads/a.zip").kind, .download)
        XCTAssertEqual(key("/Users/tester/Documents/Archive/x.pdf").kind, .place)
        XCTAssertEqual(key("/Users/tester/.Trash/node_modules/x").kind, .trash)
    }
}
