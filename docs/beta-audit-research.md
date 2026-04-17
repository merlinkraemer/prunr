phase 1: Apple’s documented pattern is to watch only the directory hierarchies whose changes you actually care about, then rescan the reported hierarchy when FSEvents says something in that hierarchy changed; the docs do **not** describe post-delivery filtering as a substitute for excluding irrelevant roots up front.  For your case, the safest documented design is: keep the app’s SQLite store outside every watched root, or at minimum never include the database directory in `pathsToWatch`; then process delivered events directly on the queue you scheduled, without re-posting to `RunLoop.main`, and avoid `FSEventStreamFlushSync` as a scan-complete “drain my own writes” mechanism. [developer.apple](https://developer.apple.com/documentation/coreservices/file_system_events/1455376-fseventstreamcreateflags)

## Watch roots

Apple describes FSEvents as a way to monitor “a directory hierarchy” and says your app creates a stream by passing the paths to watch into `FSEventStreamCreate`; when an event arrives, you scan the directory at the specified path, and when `MustScanSubDirs` or dropped flags appear, you rescan more broadly.  That documentation supports choosing watch roots carefully at stream creation time, because the stream reports changes for the hierarchies you asked it to monitor; it does **not** say “watch broad roots and discard your own app noise later” is the preferred pattern. [developer.apple](https://developer.apple.com/documentation/coreservices/1443980-fseventstreamcreate)

Apple also says FSEvents is for passively monitoring a **large tree** and is not designed for fine-grained per-file filtering or immediate preemptive handling.  From that, the documented fact is: FSEvents tells you something changed in a watched hierarchy, not whether the change was semantically relevant to your app.  The architectural inference is: if your SQLite database lives under a watched root, its `-wal`, `-shm`, main DB, or journal writes are ordinary file changes inside that hierarchy and therefore legitimate inputs to FSEvents, so filtering them only after callback delivery cannot avoid callback cost, path decoding, or queue hops. [sqlite](https://sqlite.org/walformat.html)

A practical consequence for your app is that `ignoredDirectoryPrefixes` is only a **secondary** noise reducer, not the primary Apple-documented fix.  The primary fix is to remove the DB directory from the watched universe entirely. [developer.apple](https://developer.apple.com/documentation/coreservices/file_system_events/1455376-fseventstreamcreateflags)

```swift
@MainActor
final class FSEventsWatcher {
    private let watchedRoots: [URL]

    init(allTrackedRoots: [URL], appDatabaseRoot: URL) {
        let dbRoot = appDatabaseRoot.standardizedFileURL.resolvingSymlinksInPath()
        self.watchedRoots = allTrackedRoots
            .map { $0.standardizedFileURL.resolvingSymlinksInPath() }
            .filter { root in
                let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
                let dbPath = dbRoot.path.hasSuffix("/") ? dbRoot.path : dbRoot.path + "/"
                return !dbPath.hasPrefix(rootPath) && !rootPath.hasPrefix(dbPath)
            }
    }
}
```

That code reflects an **inference** from Apple’s stream-creation model, not a quoted Apple prescription for SQLite specifically. [developer.apple](https://developer.apple.com/documentation/coreservices/1443980-fseventstreamcreate)

## Main queue delivery

Apple documents `FSEventStreamSetDispatchQueue(_:_:)` as scheduling the stream on the specified dispatch queue.  Once you do that with `DispatchQueue.main`, the callback is already being delivered on the main dispatch queue according to the scheduling API you chose. [developer.apple](https://developer.apple.com/documentation/coreservices/1444164-fseventstreamsetdispatchqueue?changes=latest_major)

Apple’s older programming guide describes a stream lifecycle where you create the stream, schedule it, start it, and then “the API posts events by calling the callback function specified” for the stream.  Documented fact: scheduling is part of the stream’s delivery mechanism; there is no Apple text in the cited docs recommending an additional `RunLoop.main.perform` wrapper around a callback already delivered on `DispatchQueue.main`.  So wrapping again in `RunLoop.main.perform` is best classified as **redundant by documentation and potentially risky by inference**, because it changes timing and ordering relative to the original callback delivery without any Apple-stated benefit. [developer.apple](https://developer.apple.com/documentation/coreservices/1444164-fseventstreamsetdispatchqueue?changes=latest_major)

For a main-actor object, the simpler pattern is to handle the callback directly and hop only if you actually scheduled on a non-main queue. [developer.apple](https://developer.apple.com/documentation/coreservices/1444164-fseventstreamsetdispatchqueue?changes=latest_major)

```swift
FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)

let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, eventFlags, eventIds in
    guard let info else { return }
    let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()

    let paths = unsafeBitCast(eventPaths, to: NSArray.self) as! [String]
    var changed = Set<URL>()
    var fullRescan = false

    for i in 0..<numEvents {
        changed.insert(URL(fileURLWithPath: paths[Int(i)]).standardizedFileURL)

        let flags = eventFlags[Int(i)]
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0 ||
           flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 {
            fullRescan = true
        }
    }

    watcher.emitChangeBatch(changed, requiresFullRescan: fullRescan)
}
```

If you instead want the watcher isolated off-main, schedule on a private queue and then enter the main actor once per batch. [developer.apple](https://developer.apple.com/documentation/coreservices/1444164-fseventstreamsetdispatchqueue?changes=latest_major)

```swift
private let fsQueue = DispatchQueue(label: "app.fs-events", qos: .utility)

FSEventStreamSetDispatchQueue(stream, fsQueue)

let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, eventFlags, _ in
    guard let info else { return }
    let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
    let batch = ChangeBatch.make(numEvents: numEvents, eventPaths: eventPaths, eventFlags: eventFlags)

    Task { @MainActor in
        watcher.emit(batch)
    }
}
```

That “private queue then one actor hop per batch” part is an engineering recommendation, not something Apple spells out in the FSEvents docs. [developer.apple](https://developer.apple.com/documentation/coreservices/file_system_events/1455376-fseventstreamcreateflags)

## Flush semantics

Apple documents `FSEventStreamFlushSync(_:)` as asking the FS Events service to flush out events that have occurred but have not yet been delivered **due to the latency parameter** supplied when the stream was created.  The older programming guide adds that the synchronous call “will not return until all pending events are flushed,” while the asynchronous call returns immediately with the last pending event ID. [developer.apple](https://developer.apple.com/documentation/coreservices/1445629-fseventstreamflushsync)

That is a narrow guarantee: flush affects pending buffered delivery, not semantic suppression of “my own writes.”  Apple documents flush near cleanup/steady-state handling, saying you “may find it useful” if you need to ensure the file system has reached a steady state prior to cleaning up the stream.  I do **not** see Apple documentation saying to call `FSEventStreamFlushSync` after a scan to prevent feedback loops; in fact, based on the documented behavior, doing so can immediately force delivery of buffered events generated by your own writes under watched roots. [developer.apple](https://developer.apple.com/documentation/coreservices/1445629-fseventstreamflushsync)

So for question 3, the documented answer is:

- `FSEventStreamFlushSync` forces pending latency-buffered events to be delivered before returning. [developer.apple](https://developer.apple.com/documentation/coreservices/1445629-fseventstreamflushsync)
- Apple documents it as a stream/cleanup utility, not as a post-scan debouncing primitive. [developer.apple](https://developer.apple.com/documentation/coreservices/file_system_events/1455376-fseventstreamcreateflags)
- Apple does **not** provide documented loop-avoidance guidance for app-generated writes under watched roots. [developer.apple](https://developer.apple.com/documentation/coreservices/1445629-fseventstreamflushsync)

## SQLite sidecars

SQLite documents that in WAL mode the database state is represented by three files while in active use: the main database file `X`, the write-ahead log `X-wal`, and the wal-index file `X-shm`.  SQLite also documents that a WAL-mode connection maintains the extra `-wal` file while open, and that the directory containing the database must be writable so the `-shm` and `-wal` files can be created.  In rollback-journal modes, SQLite also uses a `-journal` sidecar, though that exact filename pattern is part of SQLite journaling behavior rather than an Apple FSEvents rule. [sqlite](https://www.sqlite.org/wal.html)

Apple’s FSEvents docs in the sources here do **not** document any special treatment for SQLite file families such as `-wal`, `-shm`, or `-journal`.  Therefore the supported conclusion is straightforward: FSEvents sees ordinary filesystem changes inside watched hierarchies, and SQLite sidecars are just ordinary files from FSEvents’ point of view.  The inference is that if your DB directory is under a watched root, WAL checkpoints, transaction commits, or sidecar creation/removal can legitimately trigger your watcher. [sqlite](https://sqlite.org/walformat.html)

## Recommended pattern

For a macOS 14+ menu bar app that wants near-real-time rescans without self-triggered storms, the best documented pattern is:

- Start monitoring **before** scanning, because Apple explicitly says to avoid missing changes you must start monitoring the directory before you start scanning it. [developer.apple](https://developer.apple.com/documentation/coreservices/file_system_events/1455376-fseventstreamcreateflags)
- Watch only user-tracked content roots, not app-private persistence roots. [developer.apple](https://developer.apple.com/documentation/coreservices/1443980-fseventstreamcreate)
- On each callback, rescan the changed directory or hierarchy Apple tells you to rescan; do a broader rescan only for `MustScanSubDirs`, dropped events, or `RootChanged`. [developer.apple](https://developer.apple.com/documentation/coreservices/1455361-fseventstreameventflags/kfseventstreameventflagrootchanged)
- Do not rely on `FlushSync` to “clear” self-generated DB traffic. [developer.apple](https://developer.apple.com/documentation/coreservices/1445629-fseventstreamflushsync)

A concrete architecture for your app would look like this:

```swift
@MainActor
func configureFileWatcher(trackedRoots: [URL], databaseRoot: URL) {
    let watchRoots = trackedRoots
        .map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        .filter { !$0.path.hasPrefix(databaseRoot.standardizedFileURL.resolvingSymlinksInPath().path + "/") }

    let watcher = FSEventsWatcher(pathsToWatch: watchRoots, coalescingInterval: 1.0)
    watcher.setOnChange { [weak self] batch in
        self?.recordFileWatcherChangeBatch(batch)
    }
    fileEventsWatcher = watcher
    watcher.start()
}
```

And the scan pipeline should avoid restarting itself from DB writes:

```swift
actor RefreshCoordinator {
    private var scanInProgress = false
    private var pendingPaths = Set<URL>()
    private var pendingFullRescan = false

    func ingest(_ batch: ChangeBatch) {
        pendingPaths.formUnion(batch.paths)
        pendingFullRescan = pendingFullRescan || batch.requiresFullRescan
    }

    func maybeSchedule(perform: @escaping @Sendable (_ full: Bool, _ paths: Set<URL>) async -> Void) async {
        guard !scanInProgress else { return }
        guard pendingFullRescan || !pendingPaths.isEmpty else { return }

        scanInProgress = true
        let full = pendingFullRescan
        let paths = pendingPaths
        pendingFullRescan = false
        pendingPaths.removeAll()

        await perform(full, paths)
        scanInProgress = false
    }
}
```

The key fix is still structural, not algorithmic: keep GRDB/SQLite files outside the watched tree.  Once you do that, your post-delivery noise filter can remain as a belt-and-suspenders defense for system churn like `.Spotlight-V100` or `.fseventsd`, but it no longer has to absorb your own database traffic at all. [sqlite](https://www.sqlite.org/wal.html)

Would you like a second pass that rewrites your `FSEventsWatcher` and `MenuBarManager` into a fully revised Swift 5 implementation for macOS 14 with actor-safe batching?


phase 2
Apple’s documentation supports using `NSWorkspace`’s own notification center for sleep/wake and volume events, using `SMAppService` APIs plus service status to keep launch-at-login UI truthful, and using Swift concurrency isolation to avoid shared mutable state races; taken together, that strongly favors passing an immutable settings snapshot into each scan instead of letting a long-lived service hold `BoundaryConfig.default` forever. [developer.apple](https://developer.apple.com/library/archive/qa/qa1340/_index.html)

## Workspace events

Apple’s sleep/wake guidance says these notifications are posted on `NSWorkspace`’s notification center, not the default `NotificationCenter`, and explicitly warns that you will not receive sleep/wake notifications if you register with the default center.  Apple documents `NSWorkspace.willSleepNotification` as a workspace notification and notes that an observer can delay sleep for up to 30 seconds while handling it, which means handlers should do minimal work and hand off any heavier cleanup quickly.  Apple’s `NSWorkspace` documentation also identifies the workspace object as the source of these notifications. [developer.apple](https://developer.apple.com/documentation/appkit/nsworkspace/willsleepnotification)

For your app, the documented pattern is to register observers once from a long-lived app object, such as the menu bar app’s app delegate or another process-lifetime coordinator created during launch, because the notifications come from the shared workspace and are app-process scoped rather than view scoped.  Apple’s older QA example shows exactly that shape: observe from an app object and subscribe to `NSWorkspaceWillSleepNotification` and `NSWorkspaceDidWakeNotification` on `[[NSWorkspace sharedWorkspace] notificationCenter]`.  For mounted volumes, Apple’s `NSWorkspace` docs enumerate mount-related notifications on the same API surface, and community references around the class point to `didMount` and `willUnmount` notifications as the relevant hooks, but Apple’s search-visible snippets are less explicit about placement details than the sleep/wake QA. [cocoadev.github](https://cocoadev.github.io/DiscMountedOrUnmountedNotification/)

A menu bar app does not need a window to receive these workspace notifications; the key gotcha is lifetime and center selection, not window presence.  In practice, register them in `applicationDidFinishLaunching`, keep the observer tokens alive for the app lifetime, and route the events into your scan coordinator so it can pause, cancel, or rescan when sleep/wake or mount changes occur. [developer.apple](https://developer.apple.com/documentation/AppKit/NSWorkspace)

```swift
import AppKit

@MainActor
final class WorkspaceLifecycleController {
    private var observers: [NSObjectProtocol] = []
    private let workspaceCenter = NSWorkspace.shared.notificationCenter
    private let scanCoordinator: ScanCoordinator

    init(scanCoordinator: ScanCoordinator) {
        self.scanCoordinator = scanCoordinator
    }

    func start() {
        observers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: NSWorkspace.shared,
                queue: .main
            ) { [weak self] _ in
                self?.handleWillSleep()
            }
        )

        observers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: NSWorkspace.shared,
                queue: .main
            ) { [weak self] _ in
                self?.handleDidWake()
            }
        )

        observers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.didMountNotification,
                object: NSWorkspace.shared,
                queue: .main
            ) { [weak self] note in
                self?.handleDidMount(note)
            }
        )

        observers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.willUnmountNotification,
                object: NSWorkspace.shared,
                queue: .main
            ) { [weak self] note in
                self?.handleWillUnmount(note)
            }
        )
    }

    deinit {
        for observer in observers {
            workspaceCenter.removeObserver(observer)
        }
    }

    private func handleWillSleep() {
        scanCoordinator.prepareForSleep()
    }

    private func handleDidWake() {
        scanCoordinator.handleWake()
    }

    private func handleDidMount(_ note: Notification) {
        scanCoordinator.handleVolumeTopologyChange(note)
    }

    private func handleWillUnmount(_ note: Notification) {
        scanCoordinator.handleVolumeTopologyChange(note)
    }
}
```

## Launch at login

Apple documents `SMAppService` as the API for registering app services, and its docs say `register()` and `unregister()` replace older login-item style installation patterns for supported service types.  Apple also exposes `SMAppService.mainApp` specifically for the main app case you are using.  Apple further documents asynchronous and synchronous unregister/register-style APIs on the type, and search-visible docs make clear these operations can fail and therefore must be surfaced as real state transitions, not swallowed logs. [github](https://github.com/sindresorhus/LaunchAtLogin/issues/76)

The important UI consequence is that your toggle state should not be treated as the source of truth by itself; Apple gives you service status, and that status is what should drive whether the UI shows enabled, disabled, or “requires approval / failed.”  If registration throws, you should revert the presented toggle to the actual service state and expose an error message inline in settings, because otherwise the UI can lie about launch-at-login being active when the system rejected registration. [theevilbit.github](https://theevilbit.github.io/posts/smappservice/)

Documented fact: Apple provides status on `SMAppService`, and the platform distinguishes states such as enabled, not registered, requires approval, and not found.  Inference: for a truthful settings UX, bind the toggle to a derived state machine rather than directly to a persisted Bool, because Apple documents the service can be in an intermediate or externally changed state that a plain Bool cannot represent. [developer.apple](https://developer.apple.com/documentation/servicemanagement/smappservice)

```swift
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsStore: ObservableObject {
    enum LaunchAtLoginState: Equatable {
        case enabled
        case disabled
        case requiresApproval
        case error(message: String)
    }

    @Published private(set) var launchAtLoginState: LaunchAtLoginState = .disabled
    @Published var launchAtLoginIntent: Bool = false

    func refreshLaunchAtLoginState() {
        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLoginState = .enabled
            launchAtLoginIntent = true
        case .notRegistered:
            launchAtLoginState = .disabled
            launchAtLoginIntent = false
        case .requiresApproval:
            launchAtLoginState = .requiresApproval
            launchAtLoginIntent = true
        case .notFound:
            launchAtLoginState = .error(message: "Login item not found.")
            launchAtLoginIntent = false
        @unknown default:
            launchAtLoginState = .error(message: "Unknown launch-at-login state.")
            launchAtLoginIntent = false
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refreshLaunchAtLoginState()
        } catch {
            refreshLaunchAtLoginState()
            if case .enabled = launchAtLoginState, !enabled {
                launchAtLoginState = .error(message: "Could not disable launch at login: \(error.localizedDescription)")
            } else if case .disabled = launchAtLoginState, enabled {
                launchAtLoginState = .error(message: "Could not enable launch at login: \(error.localizedDescription)")
            } else {
                launchAtLoginState = .error(message: error.localizedDescription)
            }
        }
    }
}
```

```swift
struct LaunchAtLoginSection: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Launch at login", isOn: Binding(
                get: { settings.launchAtLoginIntent },
                set: { settings.setLaunchAtLogin($0) }
            ))

            switch settings.launchAtLoginState {
            case .enabled:
                EmptyView()
            case .disabled:
                EmptyView()
            case .requiresApproval:
                Text("Enabled, but macOS still requires user approval in Login Items.")
                    .foregroundStyle(.secondary)
            case .error(let message):
                Text(message)
                    .foregroundStyle(.red)
            }
        }
        .onAppear { settings.refreshLaunchAtLoginState() }
    }
}
```

## Concurrency pattern

Apple’s concurrency guidance says actors protect mutable state by isolating it so only one task accesses that state at a time, and that eliminating data races depends on isolation boundaries and `Sendable` values crossing between domains safely.  Apple also emphasizes that actor isolation is determined by context and that actor instance properties are isolated to that actor, while `Sendable` values are the mechanism for safely moving data into other isolation domains.  That means a scanning service should not casually reach back into `@MainActor` UI state during deep background work. [developer.apple](https://developer.apple.com/videos/play/wwdc2021/10133/)

For your three choices, the safest documented pattern is: read settings once on the main actor, convert them into an immutable `Sendable` snapshot, then pass that snapshot into the scan task.  Reading `SettingsStore` directly from the main actor at scan start is acceptable as the snapshot creation point if `SettingsStore` is main-actor isolated, but the long-running scan itself should then operate only on the copied value, not repeatedly consult UI state. [developer.apple](https://developer.apple.com/videos/play/wwdc2022/110351/)

Documented fact: Apple strongly favors isolation and safe transfer of values across concurrency domains.  Inference: keeping `BoundaryConfig.default` as a hidden static inside `BaselineService` is the opposite of that model, because it prevents each scan from receiving the current isolated settings snapshot and makes correctness depend on a process-global default. [developer.apple](https://developer.apple.com/videos/play/wwdc2021/10133/)

```swift
struct ScanPolicy: Sendable, Equatable {
    let enabledBoundaries: Set<String>
}

struct BoundaryConfig: Sendable, Equatable {
    let enabledBoundaries: Set<String>

    func shouldStopDrillDown(at url: URL) -> Bool {
        enabledBoundaries.contains(url.lastPathComponent)
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    var allBoundaries: Set<String> {
        BoundaryConfig.standardBoundaries.union(Set(customBoundaries))
    }

    var enabledBoundaries: Set<String> {
        allBoundaries.filter { isBoundaryEnabled($0) }
    }

    func makeScanPolicySnapshot() -> ScanPolicy {
        ScanPolicy(enabledBoundaries: enabledBoundaries)
    }
}

final class BaselineService {
    func drillDown(
        path: String,
        trackedPath: TrackedPath,
        policy: ScanPolicy
    ) async throws -> [GrowthItem] {
        let boundaryConfig = BoundaryConfig(enabledBoundaries: policy.enabledBoundaries)
        let url = URL(fileURLWithPath: path)

        if boundaryConfig.shouldStopDrillDown(at: url) {
            return []
        }

        // Continue scanning using only `policy` / `boundaryConfig`.
        return []
    }
}
```

## Settings snapshots

Apple does not, as far as the surfaced documentation here shows, have a page that explicitly says “user settings for long-running work should be treated as a snapshot.”  What Apple does document is the underlying rule set that leads to that design: isolate mutable state, avoid shared mutable access across tasks, and pass safe values between concurrency domains.  So you should separate this into documented fact versus inference in your audit notes. [developer.apple](https://developer.apple.com/documentation/servicemanagement/smappservice)

Documented facts:
- Actors isolate mutable state. [developer.apple](https://developer.apple.com/videos/play/wwdc2022/110351/)
- Actor-isolated properties must be accessed from the right isolation domain. [developer.apple](https://developer.apple.com/videos/play/wwdc2022/110351/)
- `Sendable` values are designed to cross domains safely. [developer.apple](https://developer.apple.com/videos/play/wwdc2022/110351/)

Inference for your app:
- A scan policy built from `UserDefaults`/`SettingsStore` should be snapshotted at scan start and carried through the scan as an immutable value.
- Mid-scan policy changes can apply to the next scan or trigger an explicit cancellation/restart policy if you want live reconfiguration.
- A permanently stored `BoundaryConfig.default` in `BaselineService` is not supported by any Apple pattern surfaced here and is contrary to the concurrency model above. [developer.apple](https://developer.apple.com/videos/play/wwdc2021/10133/)

## Recommended pattern

For this phase, use a three-part design: `SettingsStore` on the main actor, a `ScanCoordinator` actor for lifecycle and task management, and stateless scan services that accept explicit immutable inputs.  This keeps UI-owned settings on the main actor, serializes lifecycle reactions safely inside one coordinator, and ensures each scan uses the exact settings chosen at its start. [developer.apple](https://developer.apple.com/documentation/AppKit/NSWorkspace)

### Architecture

| Concern | Recommended owner | Why |
|---|---|---|
| UserDefaults-backed preferences | `@MainActor SettingsStore` | UI and settings mutation naturally live on the main actor.  [developer.apple](https://developer.apple.com/videos/play/wwdc2022/110351/) |
| Long-running scan orchestration | `actor ScanCoordinator` | Apple’s actor model protects mutable task/lifecycle state.  [developer.apple](https://developer.apple.com/videos/play/wwdc2021/10133/) |
| Boundary checks during scan | `ScanPolicy` / `BoundaryConfig` value passed per scan | Safe cross-domain value transfer fits Apple’s `Sendable` model.  [developer.apple](https://developer.apple.com/videos/play/wwdc2022/110351/) |
| Sleep/wake and mount events | `WorkspaceLifecycleController` started at app launch | Apple documents `NSWorkspace` notifications on the workspace notification center.  [developer.apple](https://developer.apple.com/library/archive/qa/qa1340/_index.html) |
| Launch-at-login UI truth | Derived from `SMAppService.mainApp.status` plus surfaced errors | Status reflects actual system state better than a naked Bool.  [developer.apple](https://developer.apple.com/documentation/servicemanagement/smappservice) |

### End-to-end sketch

```swift
import AppKit
import ServiceManagement

struct ScanPolicy: Sendable, Equatable {
    let enabledBoundaries: Set<String>
}

struct BoundaryConfig: Sendable, Equatable {
    static let standardBoundaries: Set<String> = [
        "node_modules", ".git", ".venv", "target", "build", ".build",
        "DerivedData", ".cache", "Pods", "Carthage", ".docker"
    ]

    let enabledBoundaries: Set<String>

    func shouldStopDrillDown(at url: URL) -> Bool {
        enabledBoundaries.contains(url.lastPathComponent)
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    @Published private(set) var launchErrorMessage: String?
    @Published var customBoundaries: [String] = []
    @Published var launchAtLoginIntent = false

    var allBoundaries: Set<String> {
        BoundaryConfig.standardBoundaries.union(customBoundaries)
    }

    var enabledBoundaries: Set<String> {
        allBoundaries.filter(isBoundaryEnabled(_:))
    }

    func makeScanPolicySnapshot() -> ScanPolicy {
        ScanPolicy(enabledBoundaries: enabledBoundaries)
    }

    func refreshLaunchAtLoginState() {
        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLoginIntent = true
            launchErrorMessage = nil
        case .notRegistered:
            launchAtLoginIntent = false
            launchErrorMessage = nil
        case .requiresApproval:
            launchAtLoginIntent = true
            launchErrorMessage = "macOS requires approval in Login Items."
        case .notFound:
            launchAtLoginIntent = false
            launchErrorMessage = "Login item could not be found."
        @unknown default:
            launchAtLoginIntent = false
            launchErrorMessage = "Unknown launch-at-login state."
        }
    }

    func updateLaunchAtLogin(to enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchErrorMessage = error.localizedDescription
        }
        refreshLaunchAtLoginState()
    }

    private func isBoundaryEnabled(_ boundary: String) -> Bool {
        UserDefaults.standard.object(forKey: "boundary.\(boundary)") as? Bool ?? true
    }
}

actor ScanCoordinator {
    private let baselineService: BaselineService
    private var currentTask: Task<Void, Never>?

    init(baselineService: BaselineService) {
        self.baselineService = baselineService
    }

    func startScan(path: String, trackedPath: TrackedPath, policy: ScanPolicy) {
        currentTask?.cancel()
        currentTask = Task {
            _ = try? await baselineService.drillDown(
                path: path,
                trackedPath: trackedPath,
                policy: policy
            )
        }
    }

    func prepareForSleep() {
        currentTask?.cancel()
        currentTask = nil
    }

    func handleWake() {
        // Optionally enqueue a fresh scan request from the caller.
    }

    func handleVolumeTopologyChange(_ notification: Notification) {
        currentTask?.cancel()
        currentTask = nil
        // Optionally mark tracked paths dirty and request a rescan.
    }
}

final class BaselineService {
    func drillDown(
        path: String,
        trackedPath: TrackedPath,
        policy: ScanPolicy
    ) async throws -> [GrowthItem] {
        let config = BoundaryConfig(enabledBoundaries: policy.enabledBoundaries)
        let url = URL(fileURLWithPath: path)

        if config.shouldStopDrillDown(at: url) {
            return []
        }

        // Scan with `policy` only.
        return []
    }
}
```

## Practical rules

- Register `NSWorkspace` observers once at launch on `NSWorkspace.shared.notificationCenter`, not `NotificationCenter.default`. [developer.apple](https://developer.apple.com/library/archive/qa/qa1340/_index.html)
- Keep handlers short, especially for `willSleep`, because Apple documents a limited delay window. [developer.apple](https://developer.apple.com/documentation/appkit/nsworkspace/willsleepnotification)
- Treat `SMAppService.mainApp.status` as the source of truth for settings presentation. [theevilbit.github](https://theevilbit.github.io/posts/smappservice/)
- On `register()` / `unregister()` failure, refresh status and show an inline error; do not leave the toggle in the requested state if the system refused it. [developer.apple](https://developer.apple.com/documentation/servicemanagement/smappservice/unregister())
- Build a `Sendable` scan-policy snapshot from `SettingsStore` at scan start and pass it into scanning code. [developer.apple](https://developer.apple.com/videos/play/wwdc2021/10133/)
- Do not let `BaselineService` retain `BoundaryConfig.default` as a forever-default if correctness depends on current user settings. [developer.apple](https://developer.apple.com/videos/play/wwdc2021/10133/)

If you want, I can turn this into a concrete patch for your existing `SettingsStore`, `BaselineService`, and `AppDelegate` files next.

phase 3
The safest documented approach is to rely on GRDB’s per-migration transaction boundary **and** make each complex migration internally idempotent with schema/feature guards, because GRDB documents that each migration block runs in its own transaction, while SQLite documents that adding constraints to existing tables generally requires the create-copy-drop-rename pattern rather than in-place alteration. For your case, I would treat “partial-failure rerun safety” as a combination problem: transactional migration units, restart-safe existence checks, rebuild-table migrations for new uniqueness constraints, and connection bootstrap that explicitly enforces `foreign_keys` and verifies `journal_mode` on each opened connection. [groue.github](https://groue.github.io/GRDB.swift/docs/5.12/Structs/DatabaseMigrator.html)

## Migration boundaries

GRDB documents that a registered migration block is executed in a transaction, and that migrations are applied in order, once and only once. GRDB also documents that migrations run with deferred foreign key checks, so foreign key violations are checked at migration end rather than statement-by-statement, which matters for table rewrites that are only temporarily inconsistent during the copy/drop/rename sequence. [contextqmd](https://contextqmd.com/libraries/grdb-swift/versions/7.10.0/pages/GRDB/Documentation.docc/Migrations)

**What that means in practice for v7/v10:**
- Use the migration block as the main atomic boundary.
- Inside the block, add **existence/state guards** so a rerun can detect “already migrated” or “intermediate object exists”.
- Prefer a fresh target table name plus final rename, and detect completion by checking the final schema, not by assuming prior statements all ran.
- Only add explicit SQLite savepoints when you intentionally want recoverable substeps inside a larger migration; they are not a substitute for idempotence, and `PRAGMA foreign_keys` cannot be toggled inside a transaction or savepoint because SQLite documents that it is a no-op while a transaction is pending. [sqlite](https://sqlite.org/pragma.html)

A practical GRDB pattern for a rewrite migration is:

```swift
migrator.registerMigration("v7_path_dedup") { db in
    let tables = try Set(db.tableNames())
    guard tables.contains("snapshotEntry") else { return }

    let cols = try db.columns(in: "snapshotEntry")
    let hasLegacyPath = cols.contains { $0.name.lowercased() == "path" }
    let hasPathId = cols.contains { $0.name.lowercased() == "pathId".lowercased() }

    if !hasLegacyPath && hasPathId {
        return // already migrated
    }

    try db.create(table: "paths", ifNotExists: true) { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("path", .text).notNull().unique()
    }

    try db.execute(sql: """
        INSERT OR IGNORE INTO paths(path)
        SELECT DISTINCT path
        FROM snapshotEntry
        WHERE path IS NOT NULL
    """)

    if !tables.contains("snapshotEntry_new") {
        try db.create(table: "snapshotEntry_new") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("snapshotId", .integer).notNull()
                .references("snapshot", onDelete: .cascade)
            t.column("pathId", .integer).notNull()
                .references("paths")
            // other columns...
        }

        try db.execute(sql: """
            INSERT INTO snapshotEntry_new (id, snapshotId, pathId /* ... */)
            SELECT se.id, se.snapshotId, p.id /* ... */
            FROM snapshotEntry se
            JOIN paths p ON p.path = se.path
        """)
    }

    let finalCols = try db.columns(in: "snapshotEntry")
    if finalCols.contains(where: { $0.name.lowercased() == "path" }) {
        try db.execute(sql: "DROP TABLE snapshotEntry")
        try db.execute(sql: "ALTER TABLE snapshotEntry_new RENAME TO snapshotEntry")
    }
}
```

That pattern is aligned with GRDB’s transaction behavior and SQLite’s rebuild-table style for schema evolution, while remaining restart-safe if the migration is retried before GRDB records it as applied. [w3resource](https://www.w3resource.com/sqlite/sqlite-create-alter-drop-table.php)

## SQLite rebuild pattern

SQLite documents limited `ALTER TABLE` support, and the documented workaround for adding or changing constraints is effectively: create a new table with the desired schema, copy data, drop the old table, rename the new table, and recreate dependent indexes/triggers as needed. This is the right documented pattern for adding uniqueness to `categorySnapshot` and `subcategorySnapshot`, because uniqueness constraints on shipped tables are not something you should try to patch in-place with ad hoc updates. [w3resource](https://www.w3resource.com/sqlite/sqlite-create-alter-drop-table.php)

Recommended raw SQLite sequence:

```sql
BEGIN;

CREATE TABLE categorySnapshot_new (
    snapshotId INTEGER NOT NULL
        REFERENCES snapshot(id) ON DELETE CASCADE,
    category TEXT NOT NULL,
    totalBytes INTEGER NOT NULL,
    PRIMARY KEY (snapshotId, category)
);

INSERT INTO categorySnapshot_new (snapshotId, category, totalBytes)
SELECT snapshotId, category, totalBytes
FROM (
    SELECT
        snapshotId,
        category,
        totalBytes,
        ROW_NUMBER() OVER (
            PARTITION BY snapshotId, category
            ORDER BY rowid DESC
        ) AS rn
    FROM categorySnapshot
)
WHERE rn = 1;

DROP TABLE categorySnapshot;
ALTER TABLE categorySnapshot_new RENAME TO categorySnapshot;

COMMIT;
```

And similarly:

```sql
BEGIN;

CREATE TABLE subcategorySnapshot_new (
    snapshotId INTEGER NOT NULL
        REFERENCES snapshot(id) ON DELETE CASCADE,
    category TEXT NOT NULL,
    subcategory TEXT NOT NULL,
    totalBytes INTEGER NOT NULL,
    fileCount INTEGER NOT NULL,
    topItemsJSON TEXT,
    PRIMARY KEY (snapshotId, category, subcategory)
);

INSERT INTO subcategorySnapshot_new (
    snapshotId, category, subcategory, totalBytes, fileCount, topItemsJSON
)
SELECT snapshotId, category, subcategory, totalBytes, fileCount, topItemsJSON
FROM (
    SELECT
        snapshotId,
        category,
        subcategory,
        totalBytes,
        fileCount,
        topItemsJSON,
        ROW_NUMBER() OVER (
            PARTITION BY snapshotId, category, subcategory
            ORDER BY rowid DESC
        ) AS rn
    FROM subcategorySnapshot
)
WHERE rn = 1;

DROP TABLE subcategorySnapshot;
ALTER TABLE subcategorySnapshot_new RENAME TO subcategorySnapshot;

COMMIT;
```

The `ROW_NUMBER()` dedupe is **SQLite-version-sensitive** because window functions require SQLite 3.25.0+; on older SQLite versions you need an alternate dedupe query such as `GROUP BY` plus join-back on chosen survivor rowids. After the rename, recreate any non-PK indexes explicitly, because rebuild migrations can discard old indexes/triggers attached to the dropped table. [sqlite](https://sqlite.org/pragma.html)

GRDB form:

```swift
migrator.registerMigration("v11_category_snapshot_pk") { db in
    let indexes = try db.indexes(on: "categorySnapshot")
    let hasTarget = indexes.contains { _ in false } // inspect schema your own way if needed

    try db.create(table: "categorySnapshot_new", ifNotExists: true) { t in
        t.column("snapshotId", .integer).notNull().references("snapshot", onDelete: .cascade)
        t.column("category", .text).notNull()
        t.column("totalBytes", .integer).notNull()
        t.primaryKey(["snapshotId", "category"])
    }

    try db.execute(sql: """
        INSERT INTO categorySnapshot_new (snapshotId, category, totalBytes)
        SELECT snapshotId, category, totalBytes
        FROM (
            SELECT
                snapshotId, category, totalBytes,
                ROW_NUMBER() OVER (
                    PARTITION BY snapshotId, category
                    ORDER BY rowid DESC
                ) AS rn
            FROM categorySnapshot
        )
        WHERE rn = 1
    """)

    try db.drop(table: "categorySnapshot")
    try db.rename(table: "categorySnapshot_new", to: "categorySnapshot")
}
```

## UPSERT patterns

For safe UPSERT, SQLite requires a uniqueness constraint or unique index on the conflict target, so your audit is right that the current delete-then-insert approach is fragile until uniqueness is added. Once those composite keys exist, the documented UPSERT form is `INSERT ... ON CONFLICT(columns) DO UPDATE ...` against the exact unique key. [sqlite](https://sqlite.org/pragma.html)

Recommended SQL for `categorySnapshot(snapshotId, category)`:

```sql
INSERT INTO categorySnapshot (snapshotId, category, totalBytes)
VALUES (?, ?, ?)
ON CONFLICT(snapshotId, category) DO UPDATE SET
    totalBytes = excluded.totalBytes;
```

Recommended SQL for `subcategorySnapshot(snapshotId, category, subcategory)`:

```sql
INSERT INTO subcategorySnapshot
    (snapshotId, category, subcategory, totalBytes, fileCount, topItemsJSON)
VALUES
    (?, ?, ?, ?, ?, ?)
ON CONFLICT(snapshotId, category, subcategory) DO UPDATE SET
    totalBytes = excluded.totalBytes,
    fileCount = excluded.fileCount,
    topItemsJSON = excluded.topItemsJSON;
```

In Swift/GRDB, this lets you replace the `DELETE` + batch `INSERT` pattern with straight idempotent writes:

```swift
func replaceCategorySnapshots(snapshotId: Int64, totals: [GrowthCategory: Int64]) async throws {
    try await dbPool.write { db in
        let stmt = try db.makeStatement(sql: """
            INSERT INTO categorySnapshot (snapshotId, category, totalBytes)
            VALUES (?, ?, ?)
            ON CONFLICT(snapshotId, category) DO UPDATE SET
                totalBytes = excluded.totalBytes
        """)
        for (category, totalBytes) in totals {
            try stmt.execute(arguments: [snapshotId, category.rawValue, totalBytes])
        }
    }
}
```

```swift
func replaceSubcategorySnapshots(snapshotId: Int64, rows: [StoredSubcategorySnapshot]) async throws {
    try await dbPool.write { db in
        let stmt = try db.makeStatement(sql: """
            INSERT INTO subcategorySnapshot
                (snapshotId, category, subcategory, totalBytes, fileCount, topItemsJSON)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(snapshotId, category, subcategory) DO UPDATE SET
                totalBytes = excluded.totalBytes,
                fileCount = excluded.fileCount,
                topItemsJSON = excluded.topItemsJSON
        """)
        for row in rows {
            try stmt.execute(arguments: [
                snapshotId,
                row.category,
                row.subcategory,
                row.totalBytes,
                row.fileCount,
                row.topItemsJSON
            ])
        }
    }
}
```

If you need “exact replacement” semantics where stale rows for a snapshot must disappear, do it as one transaction: upsert all incoming rows into a temp table or keyed target table, then delete rows for that snapshot not present in the incoming set; the crucial point is that the key constraint makes reruns safe and prevents duplicates. [sqlite](https://sqlite.org/pragma.html)

## Connection invariants

SQLite documents that foreign key enforcement must be enabled separately for **each database connection**, and warns developers not to assume the default state. SQLite also documents that changing `PRAGMA foreign_keys` is a no-op inside a transaction or savepoint, so it belongs in connection setup before work begins. [sqlite](https://sqlite.org/foreignkeys.html)

GRDB documents two relevant things:
- `Configuration.foreignKeysEnabled` exists and defaults to `true`. [groue.github](http://groue.github.io/GRDB.swift/docs/5.21/Structs/Configuration.html)
- With `DatabasePool`, `prepareDatabase` is called for the writer and all reader connections, and on newly created databases the pool activates WAL **after** preparation functions have run. [groue.github](http://groue.github.io/GRDB.swift/docs/5.21/Structs/Configuration.html)

That means your bootstrap should be explicit on both points:

```swift
func initialize(at dbPath: String) throws {
    var config = Configuration()
    config.foreignKeysEnabled = true

    config.prepareDatabase { db in
        try db.execute(sql: "PRAGMA foreign_keys = ON")

        let journalMode = try String.fetchOne(db, sql: "PRAGMA journal_mode = WAL")
        guard journalMode?.lowercased() == "wal" else {
            throw DatabaseError(message: "Failed to enable WAL journal mode")
        }
    }

    dbPool = try DatabasePool(path: dbPath, configuration: config)
    try runMigrations()
}
```

Two nuances matter:
- In GRDB `DatabasePool`, WAL is automatically activated on newly created databases after preparation runs, so explicit `PRAGMA journal_mode=WAL` is mainly useful as an invariant check or for existing files where you want to force/verify WAL mode rather than assume it. [groue.github](http://groue.github.io/GRDB.swift/docs/5.21/Structs/Configuration.html)
- `journal_mode` persistence is **SQLite-version/file-state-sensitive** in the sense that journal mode is a database-file property and changing it can fail or return another mode depending on environment or VFS conditions, so verify the returned value instead of assuming success from issuing the pragma alone. [sqlite](https://sqlite.org/pragma.html)

## Corruption recovery

**SQLite-documented recovery:** SQLite documents integrity checks via pragmas such as `PRAGMA integrity_check`, and the SQLite CLI supports `.recover` for extracting as much data as possible from a corrupt database into a new one. SQLite’s WAL behavior is also recovery-sensitive: WAL recovery scans frames in order and stops at the first invalid checksum, so corruption in the WAL can cause later frames to be ignored rather than applied, which is why startup validation and a backup/restore strategy matter. [manager](https://www.manager.io/guides/corrupt)

**GRDB-documented recovery:** the GRDB documentation you surfaced does not define a bespoke corruption-repair subsystem, but it does document reliable backup/copy APIs and explicitly recommends backing up before migrations. So the GRDB-side documented pattern is operational rather than magical: keep backups, restore from backup, or copy data into a fresh database; corruption detection/repair itself remains a SQLite concern. [github](https://github.com/groue/GRDB.swift/blob/master/GRDB/Migration/DatabaseMigrator.swift)

A startup strategy consistent with the docs is:
1. Open with connection invariants.
2. Run a lightweight validation such as `PRAGMA quick_check` or `integrity_check` before migrations if corruption is suspected, using SQLite pragmas for diagnosis. [sqlite](https://sqlite.org/pragma.html)
3. If invalid, move the file aside, attempt CLI-level `.recover` into a fresh DB in a maintenance tool or user-support flow, or restore from a known-good backup; GRDB’s documented contribution here is its backup API, including the recommendation to back up before schema changes. [github](https://github.com/groue/GRDB.swift/blob/master/GRDB/Migration/DatabaseMigrator.swift)

## Recommended plan

For this hardening phase, I’d implement the following documented plan:

| Area | Recommendation |
|---|---|
| Complex rewrites | Keep each rewrite as one GRDB migration block, rely on GRDB’s transaction, and add idempotent schema guards so reruns are safe before the migration is marked applied  [groue.github](https://groue.github.io/GRDB.swift/docs/5.12/Structs/DatabaseMigrator.html). |
| New uniqueness | Rebuild `categorySnapshot` and `subcategorySnapshot` with composite primary keys or unique constraints using create-copy-deduplicate-drop-rename, then recreate any needed indexes  [w3resource](https://www.w3resource.com/sqlite/sqlite-create-alter-drop-table.php). |
| Snapshot writes | Replace `DELETE` + `INSERT` with keyed UPSERT using `ON CONFLICT` on the new composite keys  [sqlite](https://sqlite.org/pragma.html). |
| Pool setup | Set `foreignKeysEnabled = true`, still issue/verify `PRAGMA foreign_keys = ON`, and explicitly set/check `PRAGMA journal_mode = WAL` per opened connection policy  [groue.github](http://groue.github.io/GRDB.swift/docs/5.21/Structs/Configuration.html). |
| Pre-migration safety | Take a backup before running schema migrations, which GRDB backup docs explicitly recommend  [github](https://github.com/groue/GRDB.swift/blob/master/GRDB/Migration/DatabaseMigrator.swift). |
| Corruption handling | On startup failure or failed integrity check, prefer restore-from-backup first; use SQLite integrity pragmas and `.recover` for salvage workflows, not GRDB-specific magic  [sqlite](https://sqlite.org/pragma.html). |

A concrete migration order would be:
1. Add bootstrap invariant enforcement and verification.
2. Add backup-before-migrate step.
3. Introduce rewrite migrations for `categorySnapshot` and `subcategorySnapshot` constraints.
4. Change runtime writers to UPSERT-by-key.
5. Rewrite `v7`/`v10` style migrations to be state-checked and restart-safe.
6. Optionally add startup `quick_check` plus quarantine/restore flow for corrupted files. [manager](https://www.manager.io/guides/corrupt)

One final implementation note: if you support older SQLite engines bundled indirectly through system libraries, UPSERT syntax and window-function dedupe are both version-sensitive features, so confirm the actual SQLite version available to your macOS deployment target before adopting those exact SQL forms universally. Would you like a fully rewritten `DatabaseManager.swift` migration/bootstrap sketch with these patterns applied end-to-end? [sqlite](https://sqlite.org/pragma.html)

phase 4:
On macOS 14+, the Apple-documented way to run follow-up work after a SwiftUI animation finishes is to use the newer `withAnimation(_:completionCriteria:_:completion:)` API, not a duration-matched sleep; that API is documented as available starting in the 2023 SwiftUI generation and is the right fit for your coordinator on macOS 14 because it gives you a real completion callback plus explicit completion semantics like `.logicallyComplete` and `.removed`.  Apple also documents that `.animation(_:value:)` writes animation into the transaction when the monitored value changes, and WWDC23 explicitly warns that broad animation overrides can cause accidental descendant animations, which is directly relevant to your header-level modifiers near a coordinated drill-down. [github](https://github.com/pointfreeco/swift-composable-architecture/discussions/3259)

## Animation completion

Apple added `withAnimation(_:completionCriteria:_:completion:)`, which provides a completion closure tied to SwiftUI’s animation system rather than wall-clock time.  Apple’s documentation for the related completion criteria distinguishes `.logicallyComplete` from removal of the animation, so you can choose whether teardown should happen when the animated state has logically reached its target or only after the animation is fully removed. [developer.apple](https://developer.apple.com/documentation/swiftui/animationcompletioncriteria/logicallycomplete)

For your case, `.logicallyComplete` is usually the best match for “finish the slide, then do non-animated cleanup,” because it lets the coordinator treat the movement as done before doing teardown in a non-animated transaction.  If you specifically need to wait until a spring or bounce has fully settled out of the render tree, use the stricter criterion Apple documents for full removal instead. [developer.apple](https://developer.apple.com/videos/play/wwdc2023/10156/)

```swift
@MainActor
@Observable
final class DrilldownTransitionCoordinator {
    static let slideAnimation: Animation = .snappy(duration: 0.28, extraBounce: 0)

    var slideOffset: CGFloat = 0
    private var navigationTask: Task<Void, Never>?

    func performCoordinatedSlide(
        targetOffset: CGFloat,
        phase1: @escaping () -> Void,
        phase3: @escaping () -> Void,
        afterTeardown: @escaping () -> Void
    ) {
        navigationTask?.cancel()

        phase1()

        navigationTask = Task { @MainActor in
            await withCheckedContinuation { continuation in
                RunLoop.main.perform { continuation.resume() }
            }

            withAnimation(
                Self.slideAnimation,
                completionCriteria: .logicallyComplete
            ) {
                self.slideOffset = targetOffset
            } completion: {
                var transaction = Transaction()
                transaction.disablesAnimations = true

                withTransaction(transaction) {
                    phase3()
                    self.slideOffset = 0
                }

                afterTeardown()
            }
        }
    }
}
```

That pattern is much closer to Apple’s transaction-based model shown in WWDC23, where `withAnimation` is described as a thin wrapper around `withTransaction`, and the transaction is propagated for that specific update only.  Your current `Task.sleep(for: .milliseconds(280))` is therefore replacing an API-level completion boundary with a guessed elapsed time, which Apple does not document as the synchronization mechanism. [developer.apple](https://developer.apple.com/videos/play/wwdc2023/10156/)

## Implicit animation scope

Apple’s `animation(_:value:)` documentation says it applies animation to the view whenever the monitored value changes, and the WWDC23 SwiftUI animation talk explains that this works by writing animation into the transaction for downstream updates.  Apple also explicitly warns that indiscriminately overriding animation for descendants can lead to accidental animations, then recommends scoping animation more precisely. [developer.apple](https://developer.apple.com/documentation/swiftui/view/animation(_:value:)?changes=_5)

That means your header code is risky if the monitored values can change during the drill-down transition, because those modifiers sit high enough in the subtree to potentially animate descendant changes that you intended to coordinate explicitly.  Apple’s guidance points toward moving those animations closer to the exact animating element or using more narrowly scoped animation APIs instead of broad container-level implicit animation. [developer.apple](https://developer.apple.com/fr/videos/play/wwdc2023/10156/)

Your current example:

```swift
private var overviewHeader: some View {
    HStack {
        // ...
    }
    .animation(.snappy(duration: 0.24, extraBounce: 0), value: overallGrowthBytes > 0)
    .animation(.snappy(duration: 0.28, extraBounce: 0), value: justAcceptedGrowth)
}
```

A safer pattern is to animate only the specific leaf views that should react to those values, while leaving the drill-down container free of unrelated implicit animation state. [developer.apple](https://developer.apple.com/documentation/swiftui/view/animation(_:value:)?changes=_5)

```swift
private var overviewHeader: some View {
    HStack {
        GrowthBadge(isPositive: overallGrowthBytes > 0)
        AcceptedGrowthIndicator(isActive: justAcceptedGrowth)
    }
}

struct GrowthBadge: View {
    let isPositive: Bool

    var body: some View {
        Text(isPositive ? "Growing" : "Stable")
            .foregroundStyle(isPositive ? .green : .secondary)
            .animation(.snappy(duration: 0.24, extraBounce: 0), value: isPositive)
    }
}

struct AcceptedGrowthIndicator: View {
    let isActive: Bool

    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .symbolEffect(.bounce, value: isActive)
    }
}
```

If you must keep a parent modifier, Apple’s transaction tools are the documented escape hatch for disabling or replacing animation on a subtree for a given update.  That is a better fit than hoping sibling `.animation(_:value:)` modifiers will stay isolated during a multi-phase navigation sequence. [developer.apple](https://developer.apple.com/documentation/swiftui/view/transaction(value:_:))

## Sleep vs docs

I did not find Apple documentation that recommends `Task.sleep` as a supported way to synchronize follow-up logic with SwiftUI animation completion.  The Apple material surfaced here instead focuses on transaction-based animation, value-scoped animation, and the newer completion-based `withAnimation` API. [developer.apple](https://developer.apple.com/documentation/swiftui/view/animation(_:value:))

So the safest answer to your question 3 is: Apple docs do not document sleep-based timing as the supported coordination pattern here; the documented path is completion-based animation APIs and transaction scoping.  If you keep the sleep anyway, that becomes an app-specific workaround rather than a documented SwiftUI synchronization technique. [github](https://github.com/pointfreeco/swift-composable-architecture/discussions/3259)

## Best coordinator pattern

For a shared multi-phase navigation coordinator, the most Apple-aligned pattern is:

- Do setup state first, outside or before the animated movement. [developer.apple](https://developer.apple.com/videos/play/wwdc2023/10156/)
- Perform the movement inside `withAnimation(...)`. [developer.apple](https://developer.apple.com/videos/play/wwdc2023/10156/)
- Use `completion:` to run teardown after the animation completes. [developer.apple](https://developer.apple.com/documentation/swiftui/animationcompletioncriteria/logicallycomplete)
- Use `withTransaction` with `disablesAnimations = true` for cleanup/reset that must not animate. [developer.apple](https://developer.apple.com/forums/thread/775334)

That maps cleanly to your three phases and avoids mixing real animation state with a guessed timer.  Apple’s WWDC explanation of transactions strongly supports this separation because animation lives in the transaction for a specific update pass, not as a general-purpose delayed workflow primitive. [developer.apple](https://developer.apple.com/forums/thread/775334)

A documented-style rewrite of your coordinator would look like this:

```swift
@MainActor
@Observable
final class DrilldownTransitionCoordinator {
    static let slideAnimation: Animation = .snappy(duration: 0.28, extraBounce: 0)

    var slideOffset: CGFloat = 0
    private var navigationTask: Task<Void, Never>?

    func performCoordinatedSlide(
        targetOffset: CGFloat,
        setup: @escaping () -> Void,
        teardown: @escaping () -> Void,
        finish: @escaping () -> Void
    ) {
        navigationTask?.cancel()

        setup()

        navigationTask = Task { @MainActor in
            await withCheckedContinuation { continuation in
                RunLoop.main.perform { continuation.resume() }
            }

            withAnimation(
                Self.slideAnimation,
                completionCriteria: .logicallyComplete
            ) {
                slideOffset = targetOffset
            } completion: {
                var t = Transaction()
                t.disablesAnimations = true

                withTransaction(t) {
                    teardown()
                    slideOffset = 0
                }

                finish()
            }
        }
    }
}
```

Version note: this completion-based form is a modern SwiftUI API associated with the 2023 SDK cycle; for your stated macOS 14.0+ deployment target, it is the version-specific API you should prefer and should be flagged as such in code review. [github](https://github.com/pointfreeco/swift-composable-architecture/discussions/3259)

## UserDefaults guidance

Apple’s `UserDefaults` documentation and the archived “About the User Defaults System” material explain that defaults are identified by domain, name, and value, and they emphasize preference domains plus registering defaults for known values.  Apple also documents suite-based defaults with `UserDefaults(suiteName:)`, saying the returned object writes settings to the specified domain. [developer.apple](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/UserDefaults/AboutPreferenceDomains/AboutPreferenceDomains.html)

What Apple docs do not appear to provide, at least in the surfaced material here, is strong app-architecture guidance like “always namespace keys in a central enum to avoid collisions across legacy codepaths.”  So on your question 5, the precise answer is: Apple documents domains, keys, and suites, but does not say much about old/new in-app key-collision cleanup patterns beyond the general structure of domains and key names. [developer.apple](https://developer.apple.com/documentation/foundation/userdefaults/init(suitename:)?language=objc)

The minimal justified inference is:

- Centralizing keys lowers the risk of duplicate literals in one app. This is an engineering practice, not a specifically stated Apple rule in the surfaced docs. [developer.apple](https://developer.apple.com/documentation/foundation/userdefaults)
- Using a separate suite or separate key name isolates persisted state by domain or identifier, and that part is directly supported by Apple docs. [developer.apple](https://developer.apple.com/documentation/foundation/userdefaults/init(suitename:)?language=objc)
- Reusing the exact same `"trackedPaths"` string in dead and live stores creates an app-specific corruption risk, but Apple docs do not make that exact cleanup judgment for you. [developer.apple](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/UserDefaults/AboutPreferenceDomains/AboutPreferenceDomains.html)

## Safest fix

For this phase, the safest documented pattern is to replace sleep-based timing with `withAnimation(...completion:)`, keep the animated move in one explicit transaction, run teardown in a transaction with animations disabled, and shrink or remove broad `.animation(_:value:)` modifiers near the transitioning subtree.  On the persistence side, either delete the dead `PathManager` or give it a distinct key or distinct suite immediately, because Apple documents that defaults are keyed by domain and name, so identical names in the same active domain refer to the same persisted preference slot. [developer.apple](https://developer.apple.com/documentation/swiftui/view/transaction(value:_:))

A conservative cleanup could be:

```swift
// Live store only
enum SettingsKeys {
    static let trackedPaths = "com.yourcompany.prunr.trackedPaths"
}
```

```swift
@MainActor
@Observable
final class SettingsStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            SettingsKeys.trackedPaths: [String]()
        ])
    }
}
```

```swift
// Best: delete this type if unused.
// If temporarily retained, isolate it completely.
@Observable
@MainActor
final class PathManager {
    private static let legacyPathsKey = "com.yourcompany.prunr.legacy.pathManager.trackedPaths"
}
```

If you need true storage separation during a transition period, use a dedicated suite that Apple documents as writing to the specified domain. [developer.apple](https://developer.apple.com/documentation/foundation/userdefaults/init(suitename:)?language=objc)

```swift
let legacyDefaults = UserDefaults(suiteName: "com.yourcompany.prunr.legacy")
```

## Recommended decision

My recommendation for your beta-polish pass is:

- Replace `Task.sleep` with `withAnimation(..., completionCriteria: .logicallyComplete) { ... } completion: { ... }`. [developer.apple](https://developer.apple.com/documentation/swiftui/animationcompletioncriteria/logicallycomplete)
- Keep `phase3()` and `slideOffset = 0` inside `withTransaction` with `disablesAnimations = true`. [developer.apple](https://developer.apple.com/forums/thread/775334)
- Remove or relocate the header’s `.animation(_:value:)` modifiers so only the exact subviews that need those animations own them. [developer.apple](https://developer.apple.com/fr/videos/play/wwdc2023/10156/)
- Delete dead `PathManager`; if you cannot delete it yet, rename its key or move it to a different suite immediately. [developer.apple](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/UserDefaults/AboutPreferenceDomains/AboutPreferenceDomains.html)

That combination is the closest match to Apple-documented SwiftUI and `UserDefaults` behavior, and the parts about flicker and duplicate-key corruption risk that go beyond the docs are best treated as your app-specific cleanup decisions rather than something Apple explicitly prescribes. [developer.apple](https://developer.apple.com/documentation/foundation/userdefaults/init(suitename:)?language=objc)

phase 5
The documented pattern is: use `withTaskCancellationHandler` to trigger cancellation-specific side effects, but use structured cleanup such as `defer` and transaction rollback for resources whose lifetime is scoped to the operation; cancellation handlers run when the task is canceled, but cancellation itself is cooperative and does not automatically unwind your async work unless your code checks or propagates cancellation.  For your SQLite/GRDB write correctness issue, the safest documented design is to make each subtree replacement or snapshot publish step a single atomic write transaction so concurrent maintenance cannot observe or delete intermediate state; GRDB’s `write`/`writeInTransaction` APIs are documented as transactional, and SQLite enforces that deferred integrity checks are resolved at commit time. [developer.apple](https://developer.apple.com/documentation/swift/withtaskcancellationhandler(operation:oncancel:isolation:))

## Cancellation cleanup

Apple documents `withTaskCancellationHandler` as executing an operation with a cancellation handler that is immediately invoked if the current task is canceled, and `Task.cancel()` as causing active cancellation handlers on the task to run while only flagging the task as canceled rather than forcibly stopping it.  That means `withTaskCancellationHandler` is the documented hook for “tell collaborators to stop now,” while `defer` remains the right local mechanism for “if this function exits by success, error, or cancellation propagation, run final cleanup before returning”; using only a `catch` block is weaker because cancellation may be noticed and rethrown at multiple suspension points. [developer.apple](https://developer.apple.com/documentation/swift/task/cancel())

Documented behavior supports this split:
- `withTaskCancellationHandler` for proactive cancellation signaling to the scanner, stream producer, or underlying cancellable object. [developer.apple](https://developer.apple.com/documentation/swift/withtaskcancellationhandler(operation:oncancel:isolation:))
- `Task.checkCancellation()` or equivalent cooperative checks inside long-running work, because cancellation is not preemptive. [developer.apple](https://developer.apple.com/documentation/swift/task/cancel())
- `defer` or transaction rollback for deterministic cleanup of resources created in the operation scope, especially database rows that should not survive failure. This is an inference from Swift’s cancellation model plus GRDB/SQLite transactional semantics, not a single Apple sentence that says “always use defer for cleanup.” [mintlify](https://mintlify.com/groue/GRDB.swift/core/transactions)

A cancellation-safe Swift shape for the outer scan is therefore:

```swift
func scan(...) async throws -> Snapshot {
    try await withTaskCancellationHandler {
        try await scanBody(...)
    } onCancel: {
        scanner.cancel()              // or actor-safe synchronous cancel signal
    }
}

private func scanBody(...) async throws -> Snapshot {
    let snapshot = try await db.createSnapshot(...)
    guard let snapshotId = snapshot.id else { throw ScanError.unknown("missing snapshot id") }

    var committed = false
    defer {
        if !committed {
            Task {
                do { try await db.deleteSnapshot(id: snapshotId) }
                catch { logger.error("Failed to delete incomplete snapshot \(snapshotId): \(error.localizedDescription)") }
            }
        }
    }

    try Task.checkCancellation()

    var categoryTotals: [CategoryTotal] = []
    var storedSubcategories: [StoredSubcategory] = []

    for try await result in scanner.scan(...) {
        try Task.checkCancellation()
        // accumulate
    }

    try Task.checkCancellation()
    try await db.publishFinishedSnapshot(
        snapshotId: snapshotId,
        totals: categoryTotals,
        subcategories: storedSubcategories
    )

    committed = true
    return snapshot
}
```

The important documented part is not the exact syntax above, but the division of responsibility: cancellation handler for signaling cancellation, cooperative cancellation checks during iteration, and deterministic final cleanup outside a `catch`-only path. [developer.apple](https://developer.apple.com/documentation/swift/withtaskcancellationhandler(operation:oncancel:isolation:))

## AsyncSequence cancellation

Swift’s `AsyncSequence` proposal says `AsyncIteratorProtocol` types should use Swift `Task` cancellation primitives, and that common cancellation behavior is either throwing `CancellationError` or returning `nil` from `next()`.  Apple also documents `AsyncThrowingStream.Continuation.onTermination` to run when iteration is canceled, specifically noting that canceling an active iteration invokes `onTermination` first and then the iterator ends by yielding `nil` or throwing. [github](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0298-asyncsequence.md)

For nested services, the documented pattern is therefore:
- Do not hide scanning in an unstructured child task unless you also forward cancellation explicitly. [developer.apple](https://developer.apple.com/videos/play/wwdc2023/10170/)
- Consume the sequence in the same structured task tree when possible, so parent cancellation reaches the consumer naturally. [developer.apple](https://developer.apple.com/wwdc21/10134)
- Make the producer cancel-aware, either by checking `Task.isCancelled` / `Task.checkCancellation()` in `next()` or by wiring `AsyncThrowingStream.Continuation.onTermination` to stop underlying file enumeration promptly. [developer.apple](https://developer.apple.com/documentation/swift/asyncthrowingstream/continuation/ontermination)

Apple’s WWDC23 guidance is especially relevant: because the cancellation handler runs immediately and can race the main body, shared state between the handler and operation must be synchronized; Apple explicitly warns that you cannot rely on actor ordering for “cancel first” semantics in that situation.  So this pattern is documented-safe: [developer.apple](https://developer.apple.com/videos/play/wwdc2023/10170/)

```swift
func scan(_ root: URL, ignoredNames: Set<String>) -> AsyncThrowingStream<ScanResult, Error> {
    AsyncThrowingStream { continuation in
        let state = ScannerState(root: root, ignoredNames: ignoredNames)

        continuation.onTermination = { @Sendable termination in
            if case .cancelled = termination {
                state.cancel()   // thread-safe / lock-protected / atomic
            }
        }

        Task {
            do {
                while let entry = try state.nextEntry() {
                    try Task.checkCancellation()
                    continuation.yield(entry)
                }
                continuation.finish()
            } catch is CancellationError {
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}
```

And the nested service should not own an independent scanner that escapes parent cancellation semantics unless that scanner is explicitly bound to the parent task’s cancellation.  In your `RecentChangeService`, a documented-friendly shape is to have `applySubtreeRefresh` iterate a cancellation-aware `AsyncSequence` directly in the caller’s task and call `Task.checkCancellation()` before each batch flush and before the final replacement write. [github](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0298-asyncsequence.md)

## Atomic DB writes

GRDB documents that `write` wraps statements in a transaction that commits iff no error occurs, rolling back all changes on the first unhandled error.  GRDB also documents explicit `writeInTransaction` for grouped operations that must commit together.  SQLite documents that deferred foreign key constraints are checked at `COMMIT`, allowing temporary inconsistency only inside the explicit transaction. [sqlite](https://sqlite.org/foreignkeys.html)

For your subtree replacement race, the documented safest pattern is:
- Put “delete old subtree rows + insert replacement rows + remove staging + update metadata” in one write transaction. [groue.github](http://groue.github.io/GRDB.swift/docs/4.11/)
- Run orphan cleanup in a separate transaction, but only against committed final state; it must never be able to interleave between the replacement’s delete and insert steps. [mintlify](https://www.mintlify.com/groue/GRDB.swift/api/database-pool)
- Prefer one transaction over a savepoint for the whole logical replacement when coordinating against other writers, because savepoints are nested rollback scopes inside an outer transaction rather than a separate concurrency boundary. This last sentence is inference from SQLite/GRDB transaction semantics. [mintlify](https://mintlify.com/groue/GRDB.swift/core/transactions)

A good GRDB shape is:

```swift
try await dbPool.writeInTransaction { db in
    try db.execute(sql: """
        DELETE FROM workingSetEntry
        WHERE trackedPathId = ?
          AND pathId IN (
              SELECT id FROM paths WHERE path = ? OR path LIKE ? || '/%'
          )
        """, arguments: [trackedPathId, rootPath, rootPath])

    for entry in stagedEntries {
        try db.execute(sql: """
            INSERT INTO workingSetEntry (trackedPathId, pathId, bytes, updatedAt)
            VALUES (?, ?, ?, ?)
            """, arguments: [trackedPathId, entry.pathId, entry.bytes, updatedAt])
    }

    try db.execute(sql: """
        DELETE FROM workingSetRefreshStaging
        WHERE sessionId = ?
        """, arguments: [stagingSessionId])

    return .commit
}
```

If you need rollback of an internal subsection without aborting the whole replacement, GRDB savepoints are useful, but they do not solve the race you described unless the entire externally visible replacement is still enclosed in one outer write transaction. [mintlify](https://www.mintlify.com/groue/GRDB.swift/api/database-pool)

## Immediate vs deferred

SQLite foreign keys are immediate by default, while deferred constraints are checked at commit if declared `DEFERRABLE INITIALLY DEFERRED` or otherwise deferred for the transaction.  That is useful when parent and child rows are both created inside one transaction and temporary ordering would otherwise violate constraints. [sqlite](https://sqlite.org/foreignkeys.html)

For write coordination, two distinct questions matter:

| Concern | Documented guidance |
|---|---|
| Prevent other writes from seeing partial subtree replacement | Use one explicit GRDB write transaction for the whole replacement.  [groue.github](http://groue.github.io/GRDB.swift/docs/4.11/) |
| Allow temporary FK inconsistency within that replacement | Use deferred FK constraints only if your schema/order requires it; SQLite checks them at commit.  [sqlite](https://sqlite.org/foreignkeys.html) |

Whether to use `BEGIN IMMEDIATE` specifically is more nuanced: SQLite distinguishes transaction modes, but from the sources gathered here the strongest directly documented GRDB guidance is “use a single write transaction,” not “always use IMMEDIATE.”  So my recommendation is: [mintlify](https://mintlify.com/groue/GRDB.swift/core/transactions)
- Documented: one explicit write transaction in GRDB. [groue.github](http://groue.github.io/GRDB.swift/docs/4.11/)
- Inference: if you have lock-upgrade contention or want to reserve the write lock earlier, an immediate transaction can be appropriate, but that is a tuning choice rather than the primary correctness requirement. [mintlify](https://mintlify.com/groue/GRDB.swift/core/transactions)

## Cascade implications

SQLite documents that `ON DELETE CASCADE` causes child rows to be deleted automatically when the parent row is deleted.  GRDB’s associations documentation states the same: a foreign key with `onDelete: .cascade` makes SQLite automatically delete dependent rows when the parent row is deleted. [github](https://github.com/groue/GRDB.swift/blob/master/Documentation/AssociationsBasics.md)

That implies the following for your shared `paths` table:
- If cleanup deletes a `paths` row while another transaction has not yet inserted or committed all dependent `workingSetEntry` / `snapshotEntry` rows, cascade can remove currently dependent committed rows immediately as part of the cleanup delete. [github](https://github.com/groue/GRDB.swift/blob/master/Documentation/AssociationsBasics.md)
- If the other writer is still in the middle of a multi-step replacement outside one encompassing transaction, cleanup may observe a transient “no dependents exist” state and delete the parent `paths` row, after which cascades can wipe rows that were meant to survive or the in-flight writer can later fail FK checks when inserting dependents. This sentence is inference from SQLite FK timing plus your schema pattern. [sqlite](https://sqlite.org/foreignkeys.html)
- If both operations are isolated as proper transactions, SQLite serializes writes, so the cleanup transaction cannot interleave inside another write transaction’s internal statement sequence. [groue.github](http://groue.github.io/GRDB.swift/docs/4.11/)

So the race is real if subtree replacement is split across separate committed write blocks; it largely disappears if replacement is one atomic write transaction and orphan cleanup only runs against committed state. [mintlify](https://www.mintlify.com/groue/GRDB.swift/api/database-pool)

## Recommended pattern

For “create snapshot -> run cancellable scan -> either fully commit or reliably delete incomplete snapshot,” the most robust documented pattern is a two-phase design:

1. Create a snapshot row in a state like `pending`, ideally in its own short write. This lets long file I/O happen outside a long-held SQLite write transaction. This state-column idea is inference, not directly required by docs. [groue.github](http://groue.github.io/GRDB.swift/docs/4.11/)
2. Run the file scan in structured concurrency, with `withTaskCancellationHandler` signaling the scanner, `Task.checkCancellation()` in the scan loop, and `AsyncThrowingStream.onTermination` or equivalent to stop the producer promptly. [developer.apple](https://developer.apple.com/documentation/swift/asyncthrowingstream/continuation/ontermination)
3. Publish results in one atomic GRDB write transaction that inserts/replaces all dependent rows and marks the snapshot `complete` in the same commit. [mintlify](https://www.mintlify.com/groue/GRDB.swift/api/database-pool)
4. If scan fails or is canceled before publish, delete the pending snapshot and any staging rows in cleanup guarded by `defer` or by a transactional rollback boundary, not just a `catch` around the final writes. [developer.apple](https://developer.apple.com/documentation/swift/task/cancel())
5. Exclude `pending` snapshots from readers and from orphan cleanup, or better, keep all snapshot-dependent rows in staging tables until the final publish transaction. This is inference from the transactional model and directly addresses your orphan-snapshot audit finding. [groue.github](http://groue.github.io/GRDB.swift/docs/4.11/)

A concrete sketch:

```swift
func scan(...) async throws -> Snapshot {
    let snapshot = try await db.createPendingSnapshot(...)
    guard let snapshotId = snapshot.id else { throw ScanError.unknown("missing id") }

    var published = false
    defer {
        if !published {
            Task {
                try? await db.deletePendingSnapshot(id: snapshotId)
                try? await db.clearSnapshotStaging(snapshotId: snapshotId)
            }
        }
    }

    return try await withTaskCancellationHandler {
        var stagedCategories: [CategoryTotal] = []
        var stagedSubcategories: [StoredSubcategory] = []

        for try await result in scanner.scan(url, ignoredNames: ignoredNames) {
            try Task.checkCancellation()
            // transform into stagedCategories/stagedSubcategories
        }

        try Task.checkCancellation()

        try await db.publishSnapshotAtomically(
            snapshotId: snapshotId,
            categoryTotals: stagedCategories,
            subcategories: stagedSubcategories
        )

        published = true
        return snapshot
    } onCancel: {
        scanner.cancel()
    }
}
```

And the publish side:

```swift
func publishSnapshotAtomically(
    snapshotId: Int64,
    categoryTotals: [CategoryTotal],
    subcategories: [StoredSubcategory]
) async throws {
    try await dbPool.writeInTransaction { db in
        try db.execute(sql: "DELETE FROM categorySnapshot WHERE snapshotId = ?", arguments: [snapshotId])
        try db.execute(sql: "DELETE FROM subcategorySnapshot WHERE snapshotId = ?", arguments: [snapshotId])

        for row in categoryTotals {
            try row.insert(db)
        }
        for row in subcategories {
            try row.insert(db)
        }

        try db.execute(
            sql: "UPDATE snapshot SET state = 'complete' WHERE id = ?",
            arguments: [snapshotId]
        )

        return .commit
    }
}
```

## Bottom line

The best-documented answer to your audit is:
- Use `withTaskCancellationHandler` to propagate cancellation to the scanner and any unstructured cancellable resource, but do not rely on it alone for DB cleanup. [developer.apple](https://developer.apple.com/documentation/swift/withtaskcancellationhandler(operation:oncancel:isolation:))
- Use cooperative cancellation checks during scanning and cancellation-aware `AsyncSequence` termination so nested subtree refreshes stop promptly. [github](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0298-asyncsequence.md)
- Make every logically indivisible replacement or publish step one GRDB write transaction. [mintlify](https://www.mintlify.com/groue/GRDB.swift/api/database-pool)
- Do not let orphan cleanup reason over transient states produced by multi-step writes; either exclude pending state or publish atomically from staging. [sqlite](https://sqlite.org/foreignkeys.html)

If you want, I can turn this into a concrete refactor plan for your three services with GRDB method signatures and SQL schema changes.

phase 6:
Use a two-layer plan: automate everything Apple explicitly supports through `xcodebuild`, XCTest async tests, notification observation, and Instruments traces; keep UI perception, real sleep/wake behavior, launch-at-login approval UX, and animation/flicker regressions as manual proof points because Apple’s docs give observability patterns, not full end-to-end simulation guarantees. [developer.apple](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html)

## Official sources

For **FSEvents**, Apple’s File System Events Programming Guide is the key source: create a stream with `FSEventStreamCreate` or `FSEventStreamCreateRelativeToDevice`, schedule it on a run loop with `FSEventStreamScheduleWithRunLoop`, then start it with `FSEventStreamStart`, which makes run-loop-driven watcher tests and event-coalescing validation the documented baseline.  Apple positions FSEvents as a way for apps to “detect changes in the file system,” which supports your watcher-phase proof strategy but still leaves event interpretation and debounce policy as app-level inference rather than Apple-specified business logic. [developer.apple](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/Introduction/Introduction.html)

For **async cancellation**, Apple’s XCTest async-testing docs support `async` test methods and expectations for asynchronous code, while Swift’s `Task.cancel()` docs state cancellation flags the task as cancelled and runs cancellation handlers, which is the official basis for testing cooperative cancellation and cleanup behavior.  That means you can prove cancellation correctness for scan tasks only if your code checks cancellation and verifies post-cancel invariants like “no orphan snapshots” and “no cleanup of fresh rows,” because cooperative response is required by the model rather than implied automatically. [developer.apple](https://developer.apple.com/documentation/xctest/asynchronous-tests-and-expectations)

For **app lifecycle and device events**, Apple-documented `NSWorkspace` notifications are the right verification hook for mount and unmount behavior, and practical observation of wake-related app behavior fits the same notification-observer model even when true system sleep/wake remains partially manual in practice.  For **launch at login**, Apple’s documented modern API is `SMAppService`, with `register()`, `unregister()`, and status inspection via `SMAppService.mainApp.status`, so the proof point is API state plus visible UI handling of enablement failure or disabled status. [stackoverflow](https://stackoverflow.com/questions/12409458/detect-when-a-volume-is-mounted-on-os-x)

For **migration correctness**, Apple’s closest official guidance is Core Data migration documentation rather than SQLite itself: lightweight migration can be performed in situ by issuing SQL when the store is SQLite, and more complex migration requires explicit migration management.  That does not directly validate GRDB migrations, so migration proof for your stack is partly **practical inference**: use Apple’s migration principles for fixture-based forward-compat checks, but treat duplicate-row prevention and interrupted-replace safety as application/database invariants validated by your own tests. [developer.apple](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreDataVersioning/Articles/vmLightweightMigration.html)

For **SwiftUI animation correctness**, Apple’s official performance guidance is mainly through Instruments rather than a “correct animation” spec; Time Profiler and newer SwiftUI profiling tools help identify long body updates, hangs, and main-thread work, but visual flicker absence is still a manual regression check.  So animation proof should be split into official instrumentation for main-thread and SwiftUI-update churn, plus manual visual confirmation that the previous flicker repro no longer reproduces. [developer.apple](https://developer.apple.com/la/videos/play/wwdc2019/411/)

## CLI patterns

Apple TN2339 documents the command-line testing pattern: use `xcodebuild build-for-testing` to produce build products plus an `.xctestrun` file, then `xcodebuild test-without-building` to run tests either from a scheme or directly from that `.xctestrun` file.  Apple explicitly notes `build-for-testing` maps to Xcode’s “Build For Testing,” and `test-without-building` maps to “Test Without Building,” which is the cleanest documented automation pattern for a macOS verification lane. [developer.apple](https://developer.apple.com/library/archive/technotes/tn2339/_index.html)

Example documented patterns, adapted for macOS, are:

```bash
xcodebuild \
  -project YourApp.xcodeproj \
  -scheme YourApp \
  -destination 'platform=macOS' \
  build-for-testing
```


```bash
xcodebuild \
  -project YourApp.xcodeproj \
  -scheme YourApp \
  -destination 'platform=macOS' \
  test-without-building
```


```bash
xcodebuild \
  test-without-building \
  -xctestrun path/to/YourApp_macosx.xctestrun \
  -destination 'platform=macOS'
```


You can also narrow scope with Apple-documented selectors such as `-only-testing:` and `-skip-testing:` when watcher-only, migration-only, or cancellation-only gates need isolated proof.  In your repo, that maps well to keeping `make build` and `make test` as wrappers, but the docs-backed version for CI evidence should preserve the underlying `xcodebuild` invocation in logs or scripts. [developer.apple](https://developer.apple.com/library/archive/technotes/tn2339/_index.html)

Automatable checks from official docs include:
- Build success with `xcodebuild`. [developer.apple](https://developer.apple.com/library/archive/technotes/tn2339/_index.html)
- XCTest async/unit tests for watcher logic, cancellation, fixture migrations, and DB invariants. [developer.apple](https://developer.apple.com/documentation/xctest/asynchronous-tests-and-expectations)
- Notification-observer tests for mount/unmount or app lifecycle events your code emits/handles. [leopard-adc.pepas](https://leopard-adc.pepas.com/documentation/Cocoa/Reference/ApplicationKit/Classes/NSWorkspace_Class/NSWorkspace_Class.pdf)
- Instruments traces for CPU, main-thread, and file activity analysis. [developer.apple](https://developer.apple.com/la/videos/play/wwdc2019/411/)

Manual checks remain necessary for:
- Real UI flicker/perceived animation quality. [developer.apple](https://developer.apple.com/videos/play/wwdc2025/306/)
- Real machine sleep/wake interactions across menu bar app state. [developer.apple](https://developer.apple.com/la/videos/play/wwdc2019/411/)
- Launch-at-login consent/failure UX visibility in System Settings context. [nilcoalescing](https://nilcoalescing.com/blog/LaunchAtLoginSetting/)
- External drive attach/detach smoke behavior on actual hardware. [leopard-adc.pepas](https://leopard-adc.pepas.com/documentation/Cocoa/Reference/ApplicationKit/Classes/NSWorkspace_Class/NSWorkspace_Class.pdf)

## Performance proof

For **CPU spikes** and **main-thread churn**, Apple’s primary official tool is Instruments **Time Profiler**, which samples the running process many times per second and shows which functions are executing during a selected interval.  That makes it the strongest docs-backed proof for “what caused the spike” after your existing `npm run monitor` catches that a spike happened. [developer.apple](https://developer.apple.com/la/videos/play/wwdc2019/411/)

For **filesystem event storms** and file I/O observation, the relevant Apple tooling is Instruments’ **File Activity** template plus FSEvents semantics from the programming guide.  FSEvents tells you how events are delivered to your watcher, while File Activity lets you inspect the app’s file reads/writes during scan and replace flows, which is the closest official proof source for “storm” observation short of custom app logging. [stackoverflow](https://stackoverflow.com/questions/3131043/monitoring-file-read-activity-of-applications-under-mac-os-x)

For **SQLite write behavior**, Apple does not provide a SQLite-specific migration/proof framework for GRDB, so the practical Apple-backed approach is indirect: use File Activity to observe DB file churn and Time Profiler to identify write-heavy call stacks.  Apple’s Core Data SQLite migration docs are still useful conceptually because they explicitly describe in-situ SQL migration for SQLite stores, supporting fixture-based migration verification as a proof style even though your concrete API is GRDB. [stackoverflow](https://stackoverflow.com/questions/3131043/monitoring-file-read-activity-of-applications-under-mac-os-x)

A good official-plus-practical performance sequence is:
1. Use your monitor to detect CPU/RSS/DB-growth anomalies.  
2. Reproduce under Instruments Time Profiler to attribute CPU and main-thread work. [developer.apple](https://developer.apple.com/la/videos/play/wwdc2019/411/)
3. Add File Activity to inspect DB and scan-related file operations. [stackoverflow](https://stackoverflow.com/questions/3131043/monitoring-file-read-activity-of-applications-under-mac-os-x)
4. Correlate with FSEvents callback volume and scan scheduling in app logs, which is practical inference rather than directly Apple-provided proof. [developer.apple](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html)

## Simulation and observation

Apple clearly documents **observation** of filesystem changes through FSEvents streams and of mount/unmount through `NSWorkspace` notifications.  That means filesystem and removable-volume validation can be partly automated by driving temporary directory mutations or by attaching/removing test volumes while asserting your observers fire and state transitions remain correct. [developer.apple](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html)

Apple’s docs retrieved here do **not** provide an equally strong official CLI for simulating full system sleep/wake, so sleep/wake should stay in the “observe and manually validate” bucket unless you already have an internal harness.  For docs-backed proof, the safer statement is that Apple provides instrumentation and notification observation, but not a complete sanctioned end-to-end sleep simulator comparable to XCTest UI automation. [leopard-adc.pepas](https://leopard-adc.pepas.com/documentation/Cocoa/Reference/ApplicationKit/Classes/NSWorkspace_Class/NSWorkspace_Class.pdf)

Concrete observation code patterns supported by the docs are:

```swift
import XCTest
@testable import YourAppModule

final class WatcherTests: XCTestCase {
    func testScanCancelsCleanly() async throws {
        let scanner = Scanner()
        let task = Task { try await scanner.fullScan() }

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            // Assert post-cancel invariants here.
        }
    }
}
```
This is grounded in XCTest async tests and Swift task cancellation, though your exact invariants are app-defined. [developer.apple](https://developer.apple.com/documentation/swift/task/cancel())

```swift
import AppKit

final class VolumeObserver {
    private var tokens: [NSObjectProtocol] = []

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        tokens.append(
            nc.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: nil) { note in
                print("mounted:", note.userInfo?["NSDevicePath"] ?? "")
            }
        )
        tokens.append(
            nc.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: nil) { note in
                print("unmounted:", note.userInfo?["NSDevicePath"] ?? "")
            }
        )
    }
}
```
The notification names are the documented hook for mount/unmount observation. [stackoverflow](https://stackoverflow.com/questions/12409458/detect-when-a-volume-is-mounted-on-os-x)

```swift
import ServiceManagement

func setLaunchAtLogin(_ enabled: Bool) throws {
    if enabled {
        try SMAppService.mainApp.register()
    } else {
        try SMAppService.mainApp.unregister()
    }
}

func refreshLaunchAtLoginState() -> Bool {
    SMAppService.mainApp.status == .enabled
}
```
This matches the documented SMAppService usage pattern. [theevilbit.github](https://theevilbit.github.io/posts/smappservice/)

## Verification matrix

| Phase | Automate | Manual | Official source | Commands / code |
|---|---|---|---|---|
| Phase 1 | `xcodebuild` build/test, watcher-focused XCTest, FSEvents-driven temp-dir mutation tests, monitor run in CI/local.  [developer.apple](https://developer.apple.com/library/archive/technotes/tn2339/_index.html) | Confirm scan completion does not immediately retrigger another scan, because debounce/rescan policy is app-specific behavior beyond Apple’s FSEvents contract.  [developer.apple](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html) | FSEvents Programming Guide; TN2339; XCTest async tests.  [developer.apple](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html) | `xcodebuild -project YourApp.xcodeproj -scheme YourApp -destination 'platform=macOS' build-for-testing && xcodebuild -project YourApp.xcodeproj -scheme YourApp -destination 'platform=macOS' test-without-building`; `npm run monitor -- --samples 20 --interval 5`.  [developer.apple](https://developer.apple.com/library/archive/technotes/tn2339/_index.html) |
| Phase 2 | Async cancellation tests for scan tasks; DB invariant tests for no orphan snapshots and cleanup safety after cancellation.  [developer.apple](https://developer.apple.com/documentation/xctest/asynchronous-tests-and-expectations) | Manual cancel-during-scan exercise to prove user-visible cancellation timing and UI state.  [developer.apple](https://developer.apple.com/documentation/xctest/asynchronous-tests-and-expectations) | XCTest async expectations; Swift `Task.cancel()`.  [developer.apple](https://developer.apple.com/documentation/xctest/asynchronous-tests-and-expectations) | Use `async` XCTest methods and cancel the task under test; assert surviving rows/snapshots post-cancel.  [developer.apple](https://developer.apple.com/documentation/xctest/asynchronous-tests-and-expectations) |
| Phase 3 | Observer tests for `NSWorkspace.didMountNotification` / `didUnmountNotification`; launch-at-login API state tests around `SMAppService.mainApp.status`.  [leopard-adc.pepas](https://leopard-adc.pepas.com/documentation/Cocoa/Reference/ApplicationKit/Classes/NSWorkspace_Class/NSWorkspace_Class.pdf) | Settings toggle smoke test, real sleep/wake cycle, real external drive mount/unmount, and visible launch-at-login failure path in UI.  [leopard-adc.pepas](https://leopard-adc.pepas.com/documentation/Cocoa/Reference/ApplicationKit/Classes/NSWorkspace_Class/NSWorkspace_Class.pdf) | NSWorkspace notifications; SMAppService docs/pattern.  [leopard-adc.pepas](https://leopard-adc.pepas.com/documentation/Cocoa/Reference/ApplicationKit/Classes/NSWorkspace_Class/NSWorkspace_Class.pdf) | Observe workspace notifications in test harness; call `SMAppService.mainApp.register()` / `unregister()` and inspect `.status`.  [nilcoalescing](https://nilcoalescing.com/blog/LaunchAtLoginSetting/) |
| Phase 4 | Fixture-based migration tests, startup-open on older DB fixtures, uniqueness/integrity tests around interrupted replace flows.  [developer.apple](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreDataVersioning/Articles/vmLightweightMigration.html) | Clean launch on a representative existing user DB if fixture coverage is incomplete.  [developer.apple](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreDataVersioning/Articles/vmLightweightMigration.html) | Apple migration guidance for SQLite-backed stores as a model for migration-proof structure.  [developer.apple](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreDataVersioning/Articles/vmLightweightMigration.html) | Run targeted migration suite with `-only-testing:` on migration test targets.  [developer.apple](https://developer.apple.com/library/archive/technotes/tn2339/_index.html) |
| Phase 5 | Regression tests for defaults keys and deterministic non-UI state transitions; Instruments traces to check main-thread work around drill-down paths.  [developer.apple](https://developer.apple.com/library/archive/technotes/tn2339/_index.html) | Manual flicker repro and settings open/close smoke test, because absence of visual flicker is not fully specifiable by XCTest.  [developer.apple](https://developer.apple.com/la/videos/play/wwdc2019/411/) | Instruments Time Profiler / SwiftUI profiling guidance.  [developer.apple](https://developer.apple.com/la/videos/play/wwdc2019/411/) | Profile drill-down with Instruments Time Profiler; inspect main-thread call graph during the formerly bad interval.  [developer.apple](https://developer.apple.com/la/videos/play/wwdc2019/411/) |
| Phase 6 | Full `xcodebuild` test sweep, monitor overnight run, Instruments spot profiles for CPU spikes, File Activity for DB/write and scan churn.  [developer.apple](https://developer.apple.com/library/archive/technotes/tn2339/_index.html) | Clean install beta sweep on fresh machine/user profile and overnight behavioral sanity review.  [developer.apple](https://developer.apple.com/la/videos/play/wwdc2019/411/) | TN2339; Instruments Time Profiler; File Activity.  [developer.apple](https://developer.apple.com/library/archive/technotes/tn2339/_index.html) | `xcodebuild ... build-for-testing`; `xcodebuild ... test-without-building`; `npm run monitor -- --samples 20 --interval 5` or longer-run variant.  [developer.apple](https://developer.apple.com/library/archive/technotes/tn2339/_index.html) |

A compact docs-backed script layout would be:

```bash
set -euo pipefail

xcodebuild \
  -project YourApp.xcodeproj \
  -scheme YourApp \
  -destination 'platform=macOS' \
  build-for-testing

xcodebuild \
  -project YourApp.xcodeproj \
  -scheme YourApp \
  -destination 'platform=macOS' \
  test-without-building \
  -only-testing:YourAppTests/WatcherTests \
  -only-testing:YourAppTests/CancellationTests \
  -only-testing:YourAppTests/MigrationTests
```
The action pattern and test filtering are documented by Apple; the specific suite names are your repo-level adaptation. [developer.apple](https://developer.apple.com/library/archive/technotes/tn2339/_index.html)

For your repo, I would classify the evidence as:
- **Official verification methods:** `xcodebuild` build/test actions, XCTest async tests, `NSWorkspace` notifications, `SMAppService`, Instruments Time Profiler, File Activity, FSEvents API usage. [nilcoalescing](https://nilcoalescing.com/blog/LaunchAtLoginSetting/)
- **Practical inference:** “no immediate rescan,” “no visual flicker,” “duplicate snapshot rows impossible after interrupted replace,” and “overnight beta looks stable,” because those are product invariants built on top of Apple primitives rather than something Apple directly certifies. [developer.apple](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreDataVersioning/Articles/vmLightweightMigration.html)

Would you like this turned into a copy-paste CI checklist with per-phase exit criteria and exact shell snippets?
