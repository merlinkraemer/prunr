import Foundation

enum HeadlessCommandRouter {
    static func runIfNeeded(arguments: [String]) -> Int32? {
        guard let command = arguments.first else {
            return nil
        }

        do {
            switch command {
            case "stress-scan":
                let config = try StressScanConfig(arguments: Array(arguments.dropFirst()))
                return runAsync {
                    await StressScanCommand.executeScan(config: config)
                }
            case "stress-report":
                let config = try StressReportConfig(arguments: Array(arguments.dropFirst()))
                return StressScanCommand.executeReport(config: config)
            case "e2e":
                return runE2E(arguments: Array(arguments.dropFirst()))
            default:
                return nil
            }
        } catch {
            fputs("[stress] \(error)\n", stderr)
            return 2
        }
    }

    static func runAsync(_ operation: @escaping @Sendable () async -> Int32) -> Int32 {
        let holder = ExitCodeHolder()

        Task(priority: .userInitiated) {
            let result = await operation()
            holder.markFinished(value: result)
        }

        while !holder.isFinished {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }

        return holder.value
    }
}

private enum StressScanCommand {
    private static let trackedPathID = UUID(uuidString: "4D2F7A45-3E9F-4A37-A8A1-EA7A3D4A58B0")!
    private static let defaultIgnoredNames: Set<String> = [
        ".DS_Store",
        ".localized",
        "Thumbs.db",
        "desktop.ini"
    ]

    static func executeScan(config: StressScanConfig) async -> Int32 {
        do {
            if config.mode == .baseline {
                try removeSQLiteFiles(at: config.dbPath)
            }

            try DatabaseManager.shared.initialize(at: config.dbPath)

            let databasePath = DatabaseManager.shared.databasePath ?? config.dbPath
            let dbSizesBefore = sqliteFileSizes(at: databasePath)
            let trackedPath = TrackedPath(
                id: trackedPathID,
                url: URL(fileURLWithPath: config.datasetPath, isDirectory: true),
                displayName: "Stress Dataset",
                isDefault: false
            )

            let startedAt = Date()
            let snapshot = try await BaselineService.shared.createBaseline(
                trackedPath: trackedPath,
                ignoredNames: defaultIgnoredNames
            )
            let finishedAt = Date()

            guard let currentSnapshotID = snapshot.id else {
                throw StressCommandError.runtime("Scan finished without a snapshot ID")
            }

            let snapshots = try await DatabaseManager.shared.fetchAllSnapshots(trackedPathId: trackedPath.id)
            let previousSnapshotID = snapshots.dropFirst().first?.id
            let deltas: [Delta]
            if let previousSnapshotID {
                deltas = try await DatabaseManager.shared.calculateDeltas(
                    beforeId: previousSnapshotID,
                    afterId: currentSnapshotID
                )
            } else {
                deltas = []
            }

            let totalGrowthBytes = deltas
                .filter { $0.changeBytes > 0 }
                .reduce(Int64(0)) { $0 + $1.changeBytes }
            let totalShrinkBytes = deltas
                .filter { $0.changeBytes < 0 }
                .reduce(Int64(0)) { $0 + abs($1.changeBytes) }
            let falseGrowthBytes = config.expectUnchanged ? totalGrowthBytes : 0
            let expectationMet = !config.expectUnchanged || falseGrowthBytes == 0
            let dbSizesAfter = sqliteFileSizes(at: databasePath)

            let result = try StressRunResult(
                mode: config.mode,
                label: config.label,
                expectation: config.expectUnchanged ? .unchanged : .allowGrowth,
                datasetPath: config.datasetPath,
                databasePath: databasePath,
                startedAt: startedAt,
                finishedAt: finishedAt,
                currentSnapshotId: currentSnapshotID,
                previousSnapshotId: previousSnapshotID,
                snapshotCount: snapshots.count,
                entryCount: try await DatabaseManager.shared.fetchEntryCount(for: currentSnapshotID),
                currentSizeBytes: try await DatabaseManager.shared.sumEntrySizes(for: currentSnapshotID),
                deltaCount: deltas.count,
                totalGrowthBytes: totalGrowthBytes,
                totalShrinkBytes: totalShrinkBytes,
                falseGrowthBytes: falseGrowthBytes,
                expectationMet: expectationMet,
                dbFileSizeBeforeBytes: dbSizesBefore.db,
                dbFileSizeAfterBytes: dbSizesAfter.db,
                walFileSizeBeforeBytes: dbSizesBefore.wal,
                walFileSizeAfterBytes: dbSizesAfter.wal,
                shmFileSizeBeforeBytes: dbSizesBefore.shm,
                shmFileSizeAfterBytes: dbSizesAfter.shm
            )

            let resultPath = try write(result: result, resultsDir: config.resultsDir)
            print(result.consoleSummary(resultPath: resultPath))

            if config.expectUnchanged && !expectationMet {
                return 3
            }

            return 0
        } catch {
            fputs("[stress] \(error)\n", stderr)
            return 1
        }
    }

    static func executeReport(config: StressReportConfig) -> Int32 {
        do {
            let runs = try loadRuns(resultsDir: config.resultsDir)
            guard !runs.isEmpty else {
                throw StressCommandError.runtime("No stress run JSON files found in \(config.resultsDir)")
            }

            let report = StressReport(
                generatedAt: Date(),
                resultsDir: config.resultsDir,
                runs: runs.sorted { $0.startedAt < $1.startedAt }
            )

            let outputPath = config.outputPath ?? URL(fileURLWithPath: config.resultsDir)
                .appendingPathComponent("report.json")
                .path
            try writeJSON(report, to: outputPath)

            print("stress report: \(outputPath)")
            for run in report.runs {
                print(run.reportLine)
            }

            return 0
        } catch {
            fputs("[stress] \(error)\n", stderr)
            return 1
        }
    }

    private static func removeSQLiteFiles(at dbPath: String) throws {
        let fileManager = FileManager.default
        for candidate in [dbPath, dbPath + "-wal", dbPath + "-shm"] where fileManager.fileExists(atPath: candidate) {
            try fileManager.removeItem(atPath: candidate)
        }
    }

    private static func sqliteFileSizes(at dbPath: String) -> (db: Int64, wal: Int64, shm: Int64) {
        (
            db: fileSize(atPath: dbPath),
            wal: fileSize(atPath: dbPath + "-wal"),
            shm: fileSize(atPath: dbPath + "-shm")
        )
    }

    private static func fileSize(atPath path: String) -> Int64 {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            let size = attributes[.size] as? NSNumber
        else {
            return 0
        }

        return size.int64Value
    }

    private static func runsDirectory(resultsDir: String) -> URL {
        URL(fileURLWithPath: resultsDir, isDirectory: true).appendingPathComponent("runs", isDirectory: true)
    }

    private static func write(result: StressRunResult, resultsDir: String) throws -> String {
        let runsURL = runsDirectory(resultsDir: resultsDir)
        try FileManager.default.createDirectory(at: runsURL, withIntermediateDirectories: true)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let timestamp = formatter.string(from: result.startedAt)
            .replacingOccurrences(of: ":", with: "")
        let filename = "\(timestamp)-\(sanitize(result.label)).json"
        let outputURL = runsURL.appendingPathComponent(filename)

        try writeJSON(result, to: outputURL.path)
        return outputURL.path
    }

    private static func writeJSON<T: Encodable>(_ value: T, to path: String) throws {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private static func loadRuns(resultsDir: String) throws -> [StressRunResult] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let runsURL = runsDirectory(resultsDir: resultsDir)
        guard FileManager.default.fileExists(atPath: runsURL.path) else {
            return []
        }

        let paths = try FileManager.default.contentsOfDirectory(at: runsURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }

        return try paths.map { url in
            let data = try Data(contentsOf: url)
            return try decoder.decode(StressRunResult.self, from: data)
        }
    }

    private static func sanitize(_ label: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let filtered = label.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(filtered).replacingOccurrences(of: "--", with: "-")
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-")).lowercased()
    }
}

private struct StressScanConfig {
    let mode: StressScanMode
    let datasetPath: String
    let resultsDir: String
    let dbPath: String
    let label: String
    let expectUnchanged: Bool

    init(arguments: [String]) throws {
        var mode: StressScanMode?
        var datasetPath: String?
        var resultsDir: String?
        var dbPath: String?
        var label: String?
        var expectUnchanged = false

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            guard index + 1 < arguments.count else {
                throw StressCommandError.invalidArguments("Missing value for \(argument)")
            }

            let value = arguments[index + 1]
            switch argument {
            case "--mode":
                guard let parsed = StressScanMode(rawValue: value) else {
                    throw StressCommandError.invalidArguments("Unsupported mode: \(value)")
                }
                mode = parsed
            case "--dataset":
                datasetPath = URL(fileURLWithPath: value).standardizedFileURL.path
            case "--results-dir":
                resultsDir = URL(fileURLWithPath: value).standardizedFileURL.path
            case "--db-path":
                dbPath = URL(fileURLWithPath: value).standardizedFileURL.path
            case "--label":
                label = value
            case "--expect-unchanged":
                expectUnchanged = try Self.parseBool(value, argument: argument)
            default:
                throw StressCommandError.invalidArguments("Unknown argument: \(argument)")
            }

            index += 2
        }

        guard let mode else {
            throw StressCommandError.invalidArguments("Missing --mode")
        }
        guard let datasetPath else {
            throw StressCommandError.invalidArguments("Missing --dataset")
        }
        guard FileManager.default.fileExists(atPath: datasetPath) else {
            throw StressCommandError.invalidArguments("Dataset path does not exist: \(datasetPath)")
        }
        guard let resultsDir else {
            throw StressCommandError.invalidArguments("Missing --results-dir")
        }
        guard let dbPath else {
            throw StressCommandError.invalidArguments("Missing --db-path")
        }

        self.mode = mode
        self.datasetPath = datasetPath
        self.resultsDir = resultsDir
        self.dbPath = dbPath
        self.label = label ?? mode.defaultLabel
        self.expectUnchanged = expectUnchanged
    }

    private static func parseBool(_ value: String, argument: String) throws -> Bool {
        switch value.lowercased() {
        case "1", "true", "yes":
            return true
        case "0", "false", "no":
            return false
        default:
            throw StressCommandError.invalidArguments("Expected boolean for \(argument), got \(value)")
        }
    }
}

private struct StressReportConfig {
    let resultsDir: String
    let outputPath: String?

    init(arguments: [String]) throws {
        var resultsDir: String?
        var outputPath: String?

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            guard index + 1 < arguments.count else {
                throw StressCommandError.invalidArguments("Missing value for \(argument)")
            }

            let value = arguments[index + 1]
            switch argument {
            case "--results-dir":
                resultsDir = URL(fileURLWithPath: value).standardizedFileURL.path
            case "--output":
                outputPath = URL(fileURLWithPath: value).standardizedFileURL.path
            default:
                throw StressCommandError.invalidArguments("Unknown argument: \(argument)")
            }

            index += 2
        }

        guard let resultsDir else {
            throw StressCommandError.invalidArguments("Missing --results-dir")
        }

        self.resultsDir = resultsDir
        self.outputPath = outputPath
    }
}

private enum StressScanMode: String, Codable {
    case baseline
    case `repeat`

    var defaultLabel: String {
        switch self {
        case .baseline:
            return "baseline"
        case .repeat:
            return "repeat"
        }
    }
}

private enum StressExpectation: String, Codable {
    case unchanged
    case allowGrowth
}

private struct StressRunResult: Codable {
    let version = 1
    let mode: StressScanMode
    let label: String
    let expectation: StressExpectation
    let datasetPath: String
    let databasePath: String
    let startedAt: Date
    let finishedAt: Date
    let wallClockSeconds: Double
    let currentSnapshotId: Int64
    let previousSnapshotId: Int64?
    let snapshotCount: Int
    let entryCount: Int
    let currentSizeBytes: Int64
    let deltaCount: Int
    let totalGrowthBytes: Int64
    let totalShrinkBytes: Int64
    let falseGrowthBytes: Int64
    let expectationMet: Bool
    let dbFileSizeBeforeBytes: Int64
    let dbFileSizeAfterBytes: Int64
    let walFileSizeBeforeBytes: Int64
    let walFileSizeAfterBytes: Int64
    let shmFileSizeBeforeBytes: Int64
    let shmFileSizeAfterBytes: Int64

    init(
        mode: StressScanMode,
        label: String,
        expectation: StressExpectation,
        datasetPath: String,
        databasePath: String,
        startedAt: Date,
        finishedAt: Date,
        currentSnapshotId: Int64,
        previousSnapshotId: Int64?,
        snapshotCount: Int,
        entryCount: Int,
        currentSizeBytes: Int64,
        deltaCount: Int,
        totalGrowthBytes: Int64,
        totalShrinkBytes: Int64,
        falseGrowthBytes: Int64,
        expectationMet: Bool,
        dbFileSizeBeforeBytes: Int64,
        dbFileSizeAfterBytes: Int64,
        walFileSizeBeforeBytes: Int64,
        walFileSizeAfterBytes: Int64,
        shmFileSizeBeforeBytes: Int64,
        shmFileSizeAfterBytes: Int64
    ) throws {
        self.mode = mode
        self.label = label
        self.expectation = expectation
        self.datasetPath = datasetPath
        self.databasePath = databasePath
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.wallClockSeconds = finishedAt.timeIntervalSince(startedAt)
        self.currentSnapshotId = currentSnapshotId
        self.previousSnapshotId = previousSnapshotId
        self.snapshotCount = snapshotCount
        self.entryCount = entryCount
        self.currentSizeBytes = currentSizeBytes
        self.deltaCount = deltaCount
        self.totalGrowthBytes = totalGrowthBytes
        self.totalShrinkBytes = totalShrinkBytes
        self.falseGrowthBytes = falseGrowthBytes
        self.expectationMet = expectationMet
        self.dbFileSizeBeforeBytes = dbFileSizeBeforeBytes
        self.dbFileSizeAfterBytes = dbFileSizeAfterBytes
        self.walFileSizeBeforeBytes = walFileSizeBeforeBytes
        self.walFileSizeAfterBytes = walFileSizeAfterBytes
        self.shmFileSizeBeforeBytes = shmFileSizeBeforeBytes
        self.shmFileSizeAfterBytes = shmFileSizeAfterBytes
    }

    func consoleSummary(resultPath: String) -> String {
        """
        stress scan complete:
          label: \(label)
          mode: \(mode.rawValue)
          dataset: \(datasetPath)
          snapshots: previous=\(previousSnapshotId.map(String.init) ?? "none") current=\(currentSnapshotId)
          entry count: \(entryCount)
          current bytes: \(currentSizeBytes)
          delta count: \(deltaCount)
          total growth bytes: \(totalGrowthBytes)
          total shrink bytes: \(totalShrinkBytes)
          false growth bytes: \(falseGrowthBytes)
          expectation met: \(expectationMet)
          wall clock seconds: \(String(format: "%.3f", wallClockSeconds))
          db bytes: \(dbFileSizeBeforeBytes) -> \(dbFileSizeAfterBytes)
          result: \(resultPath)
        """
    }

    var reportLine: String {
        "\(label) mode=\(mode.rawValue) currentSnapshot=\(currentSnapshotId) previousSnapshot=\(previousSnapshotId.map(String.init) ?? "none") deltaCount=\(deltaCount) growthBytes=\(totalGrowthBytes) falseGrowthBytes=\(falseGrowthBytes) wallClockSeconds=\(String(format: "%.3f", wallClockSeconds))"
    }
}

private struct StressReport: Codable {
    let version = 1
    let generatedAt: Date
    let resultsDir: String
    let runs: [StressRunResult]
}

private enum StressCommandError: LocalizedError {
    case invalidArguments(String)
    case runtime(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let message):
            return "\(message)\nUsage:\n  Prunr stress-scan --mode baseline|repeat --dataset <path> --results-dir <path> --db-path <path> [--label <label>] [--expect-unchanged true|false]\n  Prunr stress-report --results-dir <path> [--output <path>]"
        case .runtime(let message):
            return message
        }
    }
}

final class ExitCodeHolder: @unchecked Sendable {
    let lock = NSLock()
    var _value: Int32 = 1
    var _isFinished = false

    var value: Int32 {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }

    var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }; return _isFinished
    }

    func markFinished(value: Int32) {
        lock.lock()
        _value = value
        _isFinished = true
        lock.unlock()
    }
}
