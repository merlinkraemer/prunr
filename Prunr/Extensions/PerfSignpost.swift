import os
import Foundation
import AppKit

extension Logger {
    /// Performance/diagnostic channel. Also mirrored to an on-disk diagnostics
    /// log (see `DiagnosticsReporter`) so an alpha tester can hand us the file
    /// instead of us pulling `log show` off their machine.
    static let perf = Logger(subsystem: "com.prunr.perf", category: "Perf")
}

/// Lightweight performance instrumentation used to confirm which path burns CPU
/// during sustained file-system activity (full scans vs. incremental refresh DB
/// aggregation vs. FSEvents churn). Emits an os_signpost interval (for
/// Instruments), a notice-level duration log, and folds the timing into the
/// rolling on-disk diagnostics window.
enum Perf {
    static let signposter = OSSignposter(subsystem: "com.prunr.perf", category: .pointsOfInterest)

    /// Times an async operation. Balanced on throw via `defer`.
    @discardableResult
    static func measure<T>(
        _ name: StaticString,
        detail: @autoclosure () -> String = "",
        _ body: () async throws -> T
    ) async rethrows -> T {
        let id = signposter.makeSignpostID()
        let state = signposter.beginInterval(name, id: id)
        let start = DispatchTime.now()
        defer {
            signposter.endInterval(name, state)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            let nameText = "\(name)"
            let detailText = detail()
            if detailText.isEmpty {
                Logger.perf.notice("\(nameText, privacy: .public): \(ms, format: .fixed(precision: 1))ms")
            } else {
                Logger.perf.notice("\(nameText, privacy: .public): \(ms, format: .fixed(precision: 1))ms \(detailText, privacy: .public)")
            }
            Task { @MainActor in
                DiagnosticsReporter.shared.recordOperation(name: nameText, milliseconds: ms)
            }
        }
        return try await body()
    }
}

/// Snapshot of app-level state captured when the user hits "Generate Diagnostics".
/// Built by `MenuBarManager` so the reporter stays decoupled from app internals.
struct DiagnosticsAppContext {
    var scopePaths: [String]
    var enabledPathCount: Int
    var watchedPathCount: Int
    var protectedTraversalConfirmed: Bool
    var usedBytes: Int64
    var totalBytes: Int64
    var freeBytes: Int64
    var categoryCount: Int
    var growingCount: Int
    var stableCount: Int
    var fullScanRunning: Bool
    var pendingRecentChanges: Bool
    var noBaseline: Bool
    var lastFullScanCompletedAt: Date?
}

/// Main-actor rolling diagnostics recorder. Accumulates FSEvents/refresh activity,
/// per-operation timings, and periodic CPU samples, then appends a compact summary
/// line to `~/Library/Logs/Prunr/diagnostics.log` every `windowSeconds`. A manual
/// snapshot (with full app state) is appended on demand, and the file is revealed
/// in Finder so the tester can send it over.
///
/// The file is dense rather than pretty — it is meant to be pasted straight into
/// Claude, not read by a human.
@MainActor
final class DiagnosticsReporter {
    static let shared = DiagnosticsReporter()

    /// How often the rolling window is flushed to disk (seconds).
    private let windowSeconds: TimeInterval = 30 * 60
    /// How often process CPU is sampled (seconds).
    private let cpuSampleSeconds: TimeInterval = 20

    private var windowStart = Date()

    private var fsBatches = 0
    private var fsRawEvents = 0
    private var fsFilteredPaths = 0
    private var fsDirtyBatches = 0
    private var incrementalRefreshes = 0
    private var incrementalTargets = 0
    private var fullScanEscalations = 0

    private struct OpStat {
        var count = 0
        var totalMs = 0.0
        var maxMs = 0.0
    }
    private var ops: [String: OpStat] = [:]

    private var cpuSamples = 0
    private var cpuSum = 0.0
    private var cpuMax = 0.0
    private var cpuMin = Double.greatestFiniteMagnitude

    nonisolated(unsafe) private var flushTimer: Timer?
    nonisolated(unsafe) private var cpuTimer: Timer?

    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private init() {}

    /// Starts the background CPU sampling + periodic flush timers. Idempotent.
    func start() {
        guard flushTimer == nil else { return }
        windowStart = Date()
        writeHeaderLine()

        let cpu = Timer.scheduledTimer(withTimeInterval: cpuSampleSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleCPU() }
        }
        cpu.tolerance = cpuSampleSeconds * 0.25
        RunLoop.main.add(cpu, forMode: .common)
        cpuTimer = cpu

        let flush = Timer.scheduledTimer(withTimeInterval: windowSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flushWindow(force: false) }
        }
        flush.tolerance = 60
        RunLoop.main.add(flush, forMode: .common)
        flushTimer = flush
    }

    // MARK: - Recording

    func recordBatch(rawEvents: Int, filteredPaths: Int, dirty: Bool) {
        fsBatches += 1
        fsRawEvents += rawEvents
        fsFilteredPaths += filteredPaths
        if dirty { fsDirtyBatches += 1 }
    }

    func recordIncrementalRefresh(targets: Int) {
        incrementalRefreshes += 1
        incrementalTargets += targets
    }

    func recordFullScanEscalation() {
        fullScanEscalations += 1
    }

    func recordOperation(name: String, milliseconds: Double) {
        var stat = ops[name] ?? OpStat()
        stat.count += 1
        stat.totalMs += milliseconds
        stat.maxMs = max(stat.maxMs, milliseconds)
        ops[name] = stat
    }

    // MARK: - Manual report

    /// Appends a fresh full snapshot, flushes the current window, and reveals the
    /// log file in Finder. Returns the file URL (nil if writing failed).
    @discardableResult
    func generateReport(context: DiagnosticsAppContext) -> URL? {
        sampleCPU() // make sure the snapshot has a current CPU reading
        appendManualSnapshot(context: context)
        flushWindow(force: true)
        guard let url = logFileURL else { return nil }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return url
    }

    // MARK: - CPU sampling

    private func sampleCPU() {
        let usage = ProcessCPU.usagePercent()
        guard usage >= 0 else { return }
        cpuSamples += 1
        cpuSum += usage
        cpuMax = max(cpuMax, usage)
        cpuMin = min(cpuMin, usage)
    }

    // MARK: - Flushing

    private func windowSummaryLine(label: String) -> String {
        let elapsed = Int(Date().timeIntervalSince(windowStart))
        let cpuAvg = cpuSamples > 0 ? cpuSum / Double(cpuSamples) : 0
        let cpuMinOut = cpuSamples > 0 ? cpuMin : 0
        let opsText = ops
            .sorted { $0.key < $1.key }
            .map { name, s in
                "\(name):n=\(s.count),total=\(String(format: "%.0f", s.totalMs))ms,max=\(String(format: "%.0f", s.maxMs))ms"
            }
            .joined(separator: "; ")
        return "[\(isoFormatter.string(from: Date()))] \(label) window=\(elapsed)s"
            + " cpu(avg/max/min/n)=\(String(format: "%.1f", cpuAvg))/\(String(format: "%.1f", cpuMax))/\(String(format: "%.1f", cpuMinOut))/\(cpuSamples)"
            + " fsBatches=\(fsBatches) rawEvents=\(fsRawEvents) filteredPaths=\(fsFilteredPaths) dirtyBatches=\(fsDirtyBatches)"
            + " incRefreshes=\(incrementalRefreshes) incTargets=\(incrementalTargets) fullScanEsc=\(fullScanEscalations)"
            + " ops={\(opsText)}"
    }

    /// Writes the rolling window to disk and resets it. `force` writes even an
    /// otherwise-empty window (used by the manual report so the file always has a
    /// fresh line).
    private func flushWindow(force: Bool) {
        let hadActivity = fsBatches + incrementalRefreshes + fullScanEscalations + cpuSamples > 0
        if hadActivity || force {
            let line = windowSummaryLine(label: "window")
            append(line)
            Logger.perf.notice("\(line, privacy: .public)")
        }
        resetWindow()
    }

    private func resetWindow() {
        windowStart = Date()
        fsBatches = 0
        fsRawEvents = 0
        fsFilteredPaths = 0
        fsDirtyBatches = 0
        incrementalRefreshes = 0
        incrementalTargets = 0
        fullScanEscalations = 0
        ops.removeAll(keepingCapacity: true)
        cpuSamples = 0
        cpuSum = 0
        cpuMax = 0
        cpuMin = .greatestFiniteMagnitude
    }

    private func appendManualSnapshot(context ctx: DiagnosticsAppContext) {
        let bcf = ByteCountFormatter()
        bcf.countStyle = .file
        func bytes(_ v: Int64) -> String { bcf.string(fromByteCount: v) }
        let lastScan = ctx.lastFullScanCompletedAt.map { isoFormatter.string(from: $0) } ?? "never"
        let memMB = ProcessCPU.residentMemoryBytes() / (1024 * 1024)

        var block = "\n===== MANUAL SNAPSHOT [\(isoFormatter.string(from: Date()))] =====\n"
        block += "app=\(Self.appVersion) macOS=\(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        block += "scope: paths=\(ctx.scopePaths) enabled=\(ctx.enabledPathCount) watched=\(ctx.watchedPathCount) protectedTraversal=\(ctx.protectedTraversalConfirmed)\n"
        block += "disk: used=\(bytes(ctx.usedBytes)) total=\(bytes(ctx.totalBytes)) free=\(bytes(ctx.freeBytes))\n"
        block += "inventory: categories=\(ctx.categoryCount) growing=\(ctx.growingCount) stable=\(ctx.stableCount)\n"
        block += "state: fullScanRunning=\(ctx.fullScanRunning) pendingRecentChanges=\(ctx.pendingRecentChanges) noBaseline=\(ctx.noBaseline) lastFullScan=\(lastScan)\n"
        block += "process: residentMem=\(memMB)MB cpuNow=\(String(format: "%.1f", ProcessCPU.usagePercent()))%\n"
        block += windowSummaryLine(label: "live-window-so-far") + "\n"
        append(block)
    }

    // MARK: - File IO

    private static var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }

    /// `~/Library/Logs/Prunr/diagnostics.log`. Created lazily.
    private(set) lazy var logFileURL: URL? = {
        guard let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs/Prunr", isDirectory: true) else { return nil }
        do {
            try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        } catch {
            Logger.perf.error("diagnostics: could not create logs dir: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return logsDir.appendingPathComponent("diagnostics.log")
    }()

    private func writeHeaderLine() {
        append("[\(isoFormatter.string(from: Date()))] launch app=\(Self.appVersion) macOS=\(ProcessInfo.processInfo.operatingSystemVersionString)")
    }

    private func append(_ text: String) {
        guard let url = logFileURL else { return }
        let line = text.hasSuffix("\n") ? text : text + "\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// Process-level CPU + memory sampling via the mach task APIs. `usagePercent`
/// returns the instantaneous total across all non-idle threads (Activity-Monitor
/// style; can exceed 100 on multi-core), or -1 on failure.
enum ProcessCPU {
    static func usagePercent() -> Double {
        var threadList: thread_act_array_t?
        var threadCount = mach_msg_type_number_t(0)
        guard task_threads(mach_task_self_, &threadList, &threadCount) == KERN_SUCCESS,
              let threadList else { return -1 }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: threadList)),
                          vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride))
        }

        var total = 0.0
        for i in 0..<Int(threadCount) {
            var info = thread_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
            let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
                ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    thread_info(threadList[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
                }
            }
            if kr == KERN_SUCCESS, (info.flags & TH_FLAGS_IDLE) == 0 {
                total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0
            }
        }
        return total
    }

    static func residentMemoryBytes() -> Int64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int64(info.resident_size) : 0
    }
}
