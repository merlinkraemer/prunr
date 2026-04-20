import Foundation

// MARK: - Router

extension HeadlessCommandRouter {
    static func runE2E(arguments: [String]) -> Int32 {
        let config = E2EConfig(arguments: arguments)

        let holder = ExitCodeHolder()

        Task.detached(priority: .userInitiated) {
            let result = await E2ETestRunner.runAll(config: config)
            holder.markFinished(value: result)
        }

        // Spin RunLoop to service MainActor continuations from the detached task.
        // Task.detached avoids inheriting MainActor from the SwiftUI @main init,
        // but internal services still hop to MainActor for UI state updates.
        let timeout = Date().addingTimeInterval(600)
        while !holder.isFinished && Date() < timeout {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }

        if !holder.isFinished {
            print("[e2e] TIMEOUT after 10 minutes")
            return 1
        }

        return holder.value
    }
}

// MARK: - Config

struct E2EConfig {
    let resultsDir: String
    let fileCount: Int
    let fileSize: Int
    let watcherTimeout: TimeInterval
    let cpuSamples: Int
    let cpuInterval: TimeInterval
    let cpuIdleThreshold: Double
    let rssMaxMB: Double

    init(arguments: [String]) {
        var resultsDir: String?
        var fileCount = 5_000
        var fileSize = 4_096
        var watcherTimeout: TimeInterval = 8.0
        var cpuSamples = 6
        var cpuInterval: TimeInterval = 5.0
        var cpuIdleThreshold = 10.0
        var rssMaxMB = 400.0

        var i = 0
        while i < arguments.count {
            switch arguments[i] {
            case "--results-dir":
                resultsDir = arguments[i + 1]
            case "--file-count":
                fileCount = Int(arguments[i + 1]) ?? fileCount
            case "--file-size":
                fileSize = Int(arguments[i + 1]) ?? fileSize
            case "--watcher-timeout":
                watcherTimeout = TimeInterval(arguments[i + 1]) ?? watcherTimeout
            case "--cpu-samples":
                cpuSamples = Int(arguments[i + 1]) ?? cpuSamples
            case "--cpu-interval":
                cpuInterval = TimeInterval(arguments[i + 1]) ?? cpuInterval
            case "--cpu-idle-threshold":
                cpuIdleThreshold = Double(arguments[i + 1]) ?? cpuIdleThreshold
            case "--rss-max-mb":
                rssMaxMB = Double(arguments[i + 1]) ?? rssMaxMB
            default:
                break
            }
            i += 2
        }

        self.resultsDir = resultsDir ?? NSTemporaryDirectory() + "prunr-e2e/results"
        self.fileCount = fileCount
        self.fileSize = fileSize
        self.watcherTimeout = watcherTimeout
        self.cpuSamples = cpuSamples
        self.cpuInterval = cpuInterval
        self.cpuIdleThreshold = cpuIdleThreshold
        self.rssMaxMB = rssMaxMB
    }
}

// MARK: - Runner

private enum E2ETestRunner {
    struct PhaseResult: Codable {
        let name: String
        let passed: Bool
        let durationSeconds: Double
        let message: String
        let detail: String?
    }

    struct E2EResult: Codable {
        let version = 1
        let timestamp: Date
        let phases: [PhaseResult]
        var passed: Bool { phases.allSatisfy(\.passed) }
    }

    // MARK: - Entry

    static func runAll(config: E2EConfig) async -> Int32 {
        let startTime = Date()
        var phases: [PhaseResult] = []

        print("══════════════════════════════════════════════════")
        print("  Prunr E2E — \(config.fileCount) files")
        print("══════════════════════════════════════════════════")

        let treeRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prunr-e2e-tree-\(UUID().uuidString)", isDirectory: true)
        let dbPath = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prunr-e2e-\(UUID().uuidString)", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: treeRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: dbPath, withIntermediateDirectories: true)
        } catch {
            print("FAIL: setup — \(error)")
            return 1
        }

        let dbFilePath = dbPath.appendingPathComponent("prunr.sqlite").path
        let trackedPathID = UUID()
        let trackedPath = TrackedPath(
            id: trackedPathID,
            url: treeRoot,
            displayName: "E2E Dataset"
        )
        let ignoredNames: Set<String> = [".DS_Store", ".localized"]

        defer {
            try? DatabaseManager.shared.close()
            try? FileManager.default.removeItem(at: treeRoot)
            try? FileManager.default.removeItem(at: dbPath)
        }

        // ── Phase 1: DB init ──────────────────────────
        phases.append(await runPhase("1. database-init") {
            try DatabaseManager.shared.initialize(at: dbFilePath)
            let path = DatabaseManager.shared.databasePath
            guard path != nil else {
                throw E2EError("databasePath is nil after init")
            }
        })

        guard phases.last?.passed == true else { return finish(phases: phases, startTime: startTime, config: config) }

        // ── Phase 2: Create synthetic tree ────────────
        phases.append(await runPhase("2. create-tree") {
            try createSyntheticTree(root: treeRoot, fileCount: config.fileCount, fileSize: config.fileSize)
        })

        guard phases.last?.passed == true else { return finish(phases: phases, startTime: startTime, config: config) }

        // ── Phase 3: First baseline scan ──────────────
        var snapshotID: Int64?
        var scanEntryCount = 0
        var scanTotalBytes: Int64 = 0

        phases.append(await runPhase("3. first-baseline-scan") {
            let snapshot = try await BaselineService.shared.createBaseline(
                trackedPath: trackedPath,
                ignoredNames: ignoredNames
            )
            snapshotID = snapshot.id
            guard let id = snapshot.id, id > 0 else {
                throw E2EError("snapshot has no ID")
            }
            scanEntryCount = try await DatabaseManager.shared.fetchEntryCount(for: id)
            scanTotalBytes = try await DatabaseManager.shared.sumEntrySizes(for: id)
            guard scanEntryCount > 0 else {
                throw E2EError("scan produced 0 entries")
            }
        })

        guard phases.last?.passed == true, let firstSnapshotID = snapshotID else {
            return finish(phases: phases, startTime: startTime, config: config)
        }

        // ── Phase 4: Working set + category totals ────
        phases.append(await runPhase("4. working-set-verify") {
            let dbPool = try XCTUnwrap(DatabaseManager.shared.dbPool)

            // Working set should have entries
            let wsCount = try await dbPool.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM workingSetEntry") ?? 0
            }
            guard wsCount > 0 else {
                throw E2EError("working set is empty after baseline scan")
            }
            guard wsCount == scanEntryCount else {
                throw E2EError("working set count (\(wsCount)) != snapshot entry count (\(scanEntryCount))")
            }

            // Category totals should exist
            let totals = try await DatabaseManager.shared.fetchCategoryTotals(for: firstSnapshotID)
            guard !totals.isEmpty else {
                throw E2EError("category totals are empty")
            }
            let totalFromCategories = totals.reduce(Int64(0)) { $0 + $1.currentSizeBytes }
            guard totalFromCategories == scanTotalBytes else {
                throw E2EError("category total (\(totalFromCategories)) != scan total (\(scanTotalBytes))")
            }
        })

        guard phases.last?.passed == true else { return finish(phases: phases, startTime: startTime, config: config) }

        // ── Phase 5: Idempotent rescan (no changes) ──
        phases.append(await runPhase("5. idempotent-rescan") {
            let snapshot2 = try await BaselineService.shared.createBaseline(
                trackedPath: trackedPath,
                ignoredNames: ignoredNames
            )
            guard let id2 = snapshot2.id else {
                throw E2EError("second snapshot has no ID")
            }
            let entryCount2 = try await DatabaseManager.shared.fetchEntryCount(for: id2)
            let totalBytes2 = try await DatabaseManager.shared.sumEntrySizes(for: id2)

            guard entryCount2 == scanEntryCount else {
                throw E2EError("rescan entry count (\(entryCount2)) != first scan (\(scanEntryCount))")
            }
            guard totalBytes2 == scanTotalBytes else {
                throw E2EError("rescan total bytes (\(totalBytes2)) != first scan (\(scanTotalBytes)) — false growth detected")
            }
        })

        guard phases.last?.passed == true else { return finish(phases: phases, startTime: startTime, config: config) }

        // ── Phase 6: Mutate files → incremental refresh
        let mutatedFileURL = treeRoot.appendingPathComponent("bucket-000000").appendingPathComponent("file-00000000.dat")
        let addedFileURL = treeRoot.appendingPathComponent("e2e-new-file-\(UUID().uuidString).dat")
        let addedBytes = 65536

        phases.append(await runPhase("6. incremental-refresh") {
            // Mutate one existing file
            if FileManager.default.fileExists(atPath: mutatedFileURL.path) {
                let handle = try FileHandle(forWritingTo: mutatedFileURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(repeating: 0xAA, count: addedBytes))
                try handle.close()
            } else {
                // Fallback: write to any file
                let fallback = treeRoot.appendingPathComponent("e2e-mutate.dat")
                try Data(repeating: 0xAA, count: addedBytes).write(to: fallback)
            }

            // Add a brand new file
            try Data(repeating: 0xBB, count: addedBytes).write(to: addedFileURL)

            // Run recent-change refresh
            let changedPaths: Set<URL> = [mutatedFileURL, addedFileURL]
            let result = await RecentChangeService.shared.refreshChangedPaths(
                changedPaths,
                trackedPath: trackedPath
            )

            switch result {
            case .updated(let deltas):
                guard !deltas.isEmpty else {
                    throw E2EError("incremental refresh returned zero deltas after file mutations")
                }
            case .noChanges:
                throw E2EError("incremental refresh returned noChanges despite file mutations")
            case .needsFullScan:
                throw E2EError("incremental refresh escalated to needsFullScan for 2 file changes")
            }

            // Verify working set reflects the new file
            let dbPool = try XCTUnwrap(DatabaseManager.shared.dbPool)
            let hasNewFile = try await dbPool.read { db in
                try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM workingSetEntry wse
                    JOIN paths p ON p.id = wse.pathId
                    WHERE p.path = ?
                    """, arguments: [addedFileURL.path]) ?? 0
            }
            guard hasNewFile == 1 else {
                throw E2EError("new file not found in working set after incremental refresh")
            }
        })

        guard phases.last?.passed == true else { return finish(phases: phases, startTime: startTime, config: config) }

        // ── Phase 7: FSEvents watcher round-trip ─────
        phases.append(await runPhase("7. watcher-round-trip") {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                Task { @MainActor in
                    let watcherDir = treeRoot.appendingPathComponent("watcher-test", isDirectory: true)
                    try? FileManager.default.createDirectory(at: watcherDir, withIntermediateDirectories: true)

                    let watcher = FSEventsWatcher(pathsToWatch: [watcherDir], coalescingInterval: 0.1)
                    var fulfilled = false

                    watcher.setOnChange { batch in
                        guard !fulfilled else { return }
                        fulfilled = true
                        watcher.stop()

                        if batch.changedPaths.isEmpty {
                            continuation.resume(throwing: E2EError("watcher fired with empty changedPaths"))
                        } else {
                            continuation.resume()
                        }
                    }

                    watcher.start()

                    // Give the stream a moment to start
                    try? await Task.sleep(for: .milliseconds(300))

                    // Write a file to trigger the watcher
                    let triggerFile = watcherDir.appendingPathComponent("trigger.txt")
                    try "e2e watcher test".write(to: triggerFile, atomically: true, encoding: .utf8)

                    // Timeout
                    Task {
                        try? await Task.sleep(for: .seconds(config.watcherTimeout))
                        if !fulfilled {
                            fulfilled = true
                            watcher.stop()
                            continuation.resume(throwing: E2EError("watcher did not fire within \(config.watcherTimeout)s"))
                        }
                    }
                }
            }
        })

        guard phases.last?.passed == true else { return finish(phases: phases, startTime: startTime, config: config) }

        // ── Phase 8: Noise filter ─────────────────────
        phases.append(await runPhase("8. noise-filter") {
            let noisePaths = [
                "/tmp/test/prunr.sqlite-wal",
                "/tmp/test/prunr.sqlite-shm",
                "/tmp/test/prunr.sqlite-journal",
                "/tmp/test/.DS_Store",
                "/tmp/test/.localized",
            ]
            for path in noisePaths {
                guard FSEventsNoiseFilter.shouldIgnore(path) else {
                    throw E2EError("noise filter did not ignore \(path)")
                }
            }
            // Non-noise should pass through
            let realPath = treeRoot.appendingPathComponent("real-file.txt").path
            guard !FSEventsNoiseFilter.shouldIgnore(realPath) else {
                throw E2EError("noise filter incorrectly ignored real file: \(realPath)")
            }
        })

        // ── Phase 9: Post-scan stability ─────────────
        // Run one more scan, then verify DB integrity and process health
        phases.append(await runPhase("9. post-scan-stability") {
            // Final scan
            let finalSnapshot = try await BaselineService.shared.createBaseline(
                trackedPath: trackedPath,
                ignoredNames: ignoredNames
            )
            guard let finalID = finalSnapshot.id else {
                throw E2EError("final snapshot has no ID")
            }

            // Verify entry count is stable
            let finalCount = try await DatabaseManager.shared.fetchEntryCount(for: finalID)
            // +1 for the new file added in phase 6
            // +1 for the watcher trigger file from phase 7
            let expectedCount = scanEntryCount + 2
            guard finalCount == expectedCount else {
                throw E2EError("final scan entry count (\(finalCount)) != expected (\(expectedCount))")
            }

            // Verify no rescan loop: should have exactly 3 snapshots now
            // (phase 3 baseline, phase 5 rescan, phase 9 final)
            let allSnapshots = try await DatabaseManager.shared.fetchAllSnapshots(trackedPathId: trackedPathID)
            guard allSnapshots.count == 3 else {
                throw E2EError("expected 3 snapshots after all phases, got \(allSnapshots.count) — possible rescan loop")
            }
        })

        // ── Phase 10: DB integrity ────────────────────
        phases.append(await runPhase("10. db-integrity") {
            let dbPool = try XCTUnwrap(DatabaseManager.shared.dbPool)
            let result = try await dbPool.read { db in
                try String.fetchOne(db, sql: "PRAGMA integrity_check") ?? ""
            }
            guard result == "ok" else {
                throw E2EError("SQLite integrity_check: \(result)")
            }
        })

        return finish(phases: phases, startTime: startTime, config: config)
    }

    // MARK: - Helpers

    private static func runPhase(_ name: String, _ operation: () async throws -> Void) async -> PhaseResult {
        let start = Date()
        do {
            try await operation()
            let elapsed = Date().timeIntervalSince(start)
            let result = PhaseResult(name: name, passed: true, durationSeconds: elapsed, message: "PASS", detail: nil)
            print("  ✅ \(name) (\(String(format: "%.2f", elapsed))s)")
            return result
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            let msg = error.localizedDescription
            let result = PhaseResult(name: name, passed: false, durationSeconds: elapsed, message: "FAIL", detail: msg)
            print("  ❌ \(name) (\(String(format: "%.2f", elapsed))s) — \(msg)")
            return result
        }
    }

    private static func finish(phases: [PhaseResult], startTime: Date, config: E2EConfig) -> Int32 {
        let elapsed = Date().timeIntervalSince(startTime)
        let allPassed = phases.allSatisfy(\.passed)
        let passCount = phases.filter(\.passed).count

        print("")
        print("══════════════════════════════════════════════════")
        print("  \(allPassed ? "✅ ALL PASSED" : "❌ SOME FAILED") — \(passCount)/\(phases.count) phases, \(String(format: "%.1f", elapsed))s total")
        print("══════════════════════════════════════════════════")

        // Write results JSON
        let result = E2EResult(timestamp: Date(), phases: phases)
        do {
            let resultsDir = URL(fileURLWithPath: config.resultsDir, isDirectory: true)
            try FileManager.default.createDirectory(at: resultsDir, withIntermediateDirectories: true)
            let outPath = resultsDir.appendingPathComponent("e2e-result.json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(result).write(to: outPath, options: .atomic)
            print("  Results: \(outPath.path)")
        } catch {
            print("  Warning: could not write results JSON: \(error)")
        }

        return allPassed ? 0 : 1
    }

    private static func createSyntheticTree(root: URL, fileCount: Int, fileSize: Int) throws {
        let fanout = 250
        let start = Date()
        for index in 0..<fileCount {
            let bucket = index / fanout
            let dir = root.appendingPathComponent(String(format: "bucket-%06d", bucket), isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let fileURL = dir.appendingPathComponent(String(format: "file-%08d.dat", index))
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.truncate(atOffset: 0)
            try writePattern(to: handle, bytes: fileSize, seed: UInt8(index % 251))
            try handle.close()

            if index > 0 && index % 5_000 == 0 {
                print("  ... created \(index) files")
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        print("  created \(fileCount) files (\(String(format: "%.1f", elapsed))s)")
    }

    private static func writePattern(to handle: FileHandle, bytes: Int, seed: UInt8) throws {
        let chunkSize = min(64 * 1024, max(1, bytes))
        let chunk = Data(repeating: seed, count: chunkSize)
        var remaining = bytes
        while remaining > 0 {
            let writeCount = min(chunk.count, remaining)
            try handle.write(contentsOf: chunk.prefix(writeCount))
            remaining -= writeCount
        }
    }

    // MARK: - Helpers (reserved for future CPU profiling phase)

    /*
        // Read CPU from /proc-ish ps output
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ps")
        process.arguments = ["-p", "\(pid)", "-o", "%cpu=,rss="]
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    */
}

// MARK: - Error

private struct E2EError: Error, LocalizedError {
    let errorDescription: String?
    init(_ description: String) { self.errorDescription = description }
}

// MARK: - Unwrap helper (mirrors XCTest for non-test contexts)

private func XCTUnwrap<T>(_ optional: T?, file: String = #file, line: Int = #line) throws -> T {
    guard let value = optional else {
        throw E2EError("Unexpected nil at \(file):\(line)")
    }
    return value
}
