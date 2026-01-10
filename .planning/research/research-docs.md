# macOS Disk Usage Scanner - Comprehensive Research Documentation

## Phase 1: Foundation Research

### GRDB.swift Database Patterns

#### 1. **Async/Await with Batch Insert Performance**

**Key Findings:**
- **DatabaseQueue vs DatabasePool**: Use `DatabaseQueue` for simple apps; switch to `DatabasePool` for multi-threaded performance
- `DatabasePool` enables WAL (Write-Ahead Logging) mode for better concurrency
- **Performance Optimization for Batch Inserts**:
  - Use `inTransaction` wrapper instead of sequential `inDatabase` calls (significantly faster)
  - Wrap multiple inserts in a single transaction block
  - `inTransaction` auto-commits on success, auto-rollback on error
  - Performance multiplier: 12s → 0.8s for 10,000 document inserts

**Best Practice Code Pattern:**
```swift
try dbQueue.inTransaction { db in
    for item in largeArray {
        try item.insert(db)  // All in single transaction
    }
    return .commit
}
```

#### 2. **Singleton Database Manager Pattern**

**Recommended Approach:**
```swift
class DatabaseManager {
    static let shared = DatabaseManager()
    var dbQueue: DatabaseQueue!
    
    private init() {
        dbQueue = try! DatabaseQueue(path: "/path/to/db.sqlite")
        // Configure and create tables
    }
}
```

**Advantages:**
- Single database connection
- Resource efficient
- Thread-safe access
- Essential for SwiftUI + macOS integration

#### 3. **Table Associations & Foreign Keys**

**Association Types:**
- `BelongsTo`: Many-to-One relationship
- `HasMany`: One-to-Many relationship  
- `HasOne`: One-to-One relationship
- `HasManyThrough` / `HasOneThrough`: Complex relationships

**Auto-Inference Rules:**
- GRDB automatically infers foreign keys from database schema
- Requires: foreign key defined in DB + association declared in Swift models
- For non-standard naming, use `key:` and `using:` parameters

**Example - File to Folder:**
```swift
struct FileRecord: TableRecord, EncodableRecord {
    static let folder = belongsTo(Folder.self)
}

struct Folder: TableRecord {
    static let files = hasMany(FileRecord.self)
}
```

#### 4. **Migration Patterns & Schema Versioning**

**Key Considerations:**
- Use `Database.execute()` for schema changes
- Version tracking via metadata table
- Safe migration with rollback capability
- Use `writeInTransaction` for multi-step migrations

---

### Swift Concurrency Best Practices

#### 1. **MainActor Isolation in SwiftUI**

**Key Principles:**
- Only `View.body` is `@MainActor` by default (Xcode 16+)
- Don't mark entire View type with `@MainActor` unless necessary
- Use `nonisolated` for methods that don't need main thread
- SwiftUI automatically inherits main actor isolation for `@Published` properties

**View Model Pattern (Swift 6+):**
```swift
@Observable
class ViewModel {
    @MainActor var data: [Item] = []
    
    func fetchData() async {
        // Do background work
        let items = await loadItems()
        // Automatically runs on MainActor when updating @MainActor properties
        self.data = items
    }
    
    nonisolated func expensiveComputation() -> Int {
        // Runs on background thread, no UI updates
        return heavyCalculation()
    }
}
```

#### 2. **Actor-Isolated Database Access**

**Pattern for Thread-Safe Database:**
```swift
actor DatabaseAccessor {
    private let dbQueue: DatabaseQueue
    
    // All methods automatically serialized
    func insert(_ record: Record) throws {
        try dbQueue.write { db in
            try record.insert(db)
        }
    }
    
    func fetchAll() throws -> [Record] {
        try dbQueue.read { db in
            try Record.fetchAll(db)
        }
    }
}

// Use with isolated parameter for efficient batching:
try await database.transaction { db in
    try item1.insert(db)
    try item2.insert(db)
    try item3.insert(db)  // All serialized in single access
}
```

#### 3. **Error Propagation in SwiftUI**

**Best Practices:**
- Wrap errors in `@Published` state for UI display
- Use `@MainActor` on error handler methods
- Never suppress errors in background tasks
- Provide user-friendly error messages

```swift
@Observable
class FileScanner {
    @MainActor var error: Error?
    
    func scan() async {
        do {
            // scanning logic
        } catch {
            self.error = error  // Automatic main thread dispatch
        }
    }
}
```

---

### Xcode Project Setup

#### 1. **XcodeGen Configuration for macOS**

**Key Features:**
- YAML-based project specification
- Version control friendly (no .pbxproj conflicts)
- Perfect for team collaboration

**Minimal project.yml for macOS + SwiftUI:**
```yaml
name: DiskUsageScanner
targets:
  DiskUsageScanner:
    type: application
    platform: macOS
    deploymentTarget: "12.0"
    sources:
      - path: Sources
    settings:
      SWIFT_VERSION: "5.9"
      CODE_SIGN_IDENTITY: "-"  # Development only
```

#### 2. **SPM Integration with GRDB.swift**

**Package.swift Setup:**
```swift
.package(url: "https://github.com/groue/GRDB.swift.git", from: "6.0.0"),
```

**Target Dependencies:**
- Add to your app target's dependencies
- Link binary frameworks if needed
- GRDB provides all SQLite functionality built-in

---

## Phase 2: Scanner & Storage Research

### FileManager & Performance Optimization

#### 1. **URL-Based vs String-Based Enumeration**

**Critical Performance Difference:**
- **URL-based**: 3x faster than string-based enumeration
- Test case: 541,879 files
  - String enumerator: 118.6 seconds
  - URL enumerator: 40.6 seconds
- **Why**: URL APIs are newer, optimized; String APIs soft-deprecated

**Optimal Pattern:**
```swift
let url = URL(fileURLWithPath: "/start/path")
let enumerator = FileManager.default.enumerator(
    at: url, 
    includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
    options: [.skipsHiddenFiles, .skipsPackageDescendants]
)

while let fileURL = enumerator?.nextObject() as? URL {
    // Process file
}
```

#### 2. **ResourceKey Performance Optimization**

**Caching File Properties:**
```swift
let keysToFetch = [URLResourceKey.fileSizeKey, 
                   URLResourceKey.isDirectoryKey,
                   URLResourceKey.isSymbolicLinkKey]

let enumerator = FileManager.default.enumerator(
    at: startURL,
    includingPropertiesForKeys: keysToFetch
)
```

**Benefits:**
- Properties cached on returned URLs
- Avoids redundant filesystem calls
- Significant performance gain for large scans

#### 3. **Recursive Directory Traversal with Async/Await**

**Non-Recursive Queue-Based Approach (Prevents Stack Overflow):**
```swift
func scanDirectory(_ path: String) async throws -> [FileInfo] {
    var foundFiles: [FileInfo] = []
    var folders = [path]
    
    while !folders.isEmpty {
        let current = folders.removeFirst()
        let contents = try FileManager.default.contentsOfDirectory(atPath: current)
        
        for item in contents {
            let fullPath = (current as NSString).appendingPathComponent(item)
            
            if FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir) {
                if isDir.boolValue {
                    folders.append(fullPath)
                } else {
                    foundFiles.append(FileInfo(path: fullPath))
                }
            }
        }
        
        // Yield to event loop periodically
        try await Task.yield()
    }
    
    return foundFiles
}
```

**Progress Reporting via AsyncSequence:**
```swift
func scanWithProgress(_ path: String) -> AsyncStream<ScanProgress> {
    AsyncStream { continuation in
        Task {
            var scanned = 0
            let contents = try FileManager.default.contentsOfDirectory(atPath: path)
            for item in contents {
                // scan item...
                scanned += 1
                continuation.yield(ScanProgress(scanned: scanned, total: contents.count))
            }
            continuation.finish()
        }
    }
}
```

#### 4. **Hidden Files & Performance**

**Optimization Tips:**
- Use `.skipsHiddenFiles` option in enumerator for faster scanning
- Hidden files add processing overhead
- Consider two-pass approach: quick scan (visible only), optional detailed scan

#### 5. **Full Disk Access & Info.plist**

**Required for Accessing Protected Directories:**

Info.plist entries needed:
```xml
<key>NSLocalNetworkUsageDescription</key>
<string>App needs to access all files for disk usage analysis</string>

<key>NSBonjourServices</key>
<array/>

<key>NSPrivacyAccessedAPICatagories</key>
<!-- For macOS 11+ privacy manifest -->
```

**Entitlements.plist for Full Disk Access:**
- Set `com.apple.security.files.user-selected.read-write` to enable user selection
- For sandboxed apps, users must grant in System Settings
- Non-sandboxed apps (development): No Sandbox entitlement needed

---

### SQLite & GRDB Storage Optimization

#### 1. **Batch Insert Performance with inTransaction**

**Benchmark Data (10,000 documents):**
- Without transaction: ~12 seconds
- With `inTransaction`: ~0.8 seconds
- **15x performance improvement**

**Critical Pattern:**
```swift
try dbQueue.inTransaction { db in
    for record in largeArray {
        try record.insert(db)  // Batched, transactional
    }
    return .commit  // Auto-rollback on error
}
```

**Why It Works:**
- Single transaction wraps all inserts
- Reduces overhead per insert dramatically
- Atomic operation (all or nothing)
- Auto-rollback on any error

#### 2. **Index Design for Path & Folder Size Lookups**

**Optimal Schema for File Indexing:**

```sql
CREATE TABLE folders (
    id INTEGER PRIMARY KEY,
    parent_id INTEGER REFERENCES folders(id),
    name TEXT NOT NULL,
    path TEXT UNIQUE NOT NULL,
    total_size INTEGER DEFAULT 0,
    file_count INTEGER DEFAULT 0
);

CREATE INDEX idx_folders_parent ON folders(parent_id);
CREATE INDEX idx_folders_path ON folders(path);

CREATE TABLE files (
    id INTEGER PRIMARY KEY,
    folder_id INTEGER NOT NULL REFERENCES folders(id),
    name TEXT NOT NULL,
    size INTEGER NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_files_folder ON files(folder_id);
CREATE INDEX idx_files_size ON files(size DESC);
```

**Index Performance Impact:**
- Without indexes: 327ms for 1.6M entries
- With indexes: 29.7ms
- **11x improvement**

**Index Trade-offs:**
- Speeds up reads dramatically (SELECT, WHERE)
- Slows down writes (INSERT, UPDATE, DELETE)
- Uses additional disk space
- Balance based on read/write ratio

#### 3. **Datetime Storage & Timezone Handling**

**Best Practice for SQLite:**
- Store all times as UTC in ISO 8601 format
- Let GRDB handle timezone conversion

```swift
struct FileRecord: Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var path: String
    var size: Int64
    var createdAt: Date  // GRDB auto-handles serialization
    var modifiedAt: Date
}
```

**GRDB Automatic Serialization:**
- `Date` → SQLite TIMESTAMP TEXT (ISO 8601)
- Automatic timezone handling on round-trip
- No manual conversion needed

---

### SwiftUI Settings UI Patterns

#### 1. **macOS Form & Settings Views**

**Settings Window Pattern:**
```swift
@main
struct App: App {
    var body: some Scene {
        #if os(macOS)
        Settings {
            SettingsView()
        }
        #endif
    }
}

struct SettingsView: View {
    @AppStorage("scanInterval") var interval: Int = 3600
    
    var body: some View {
        Form {
            Section("Scan Settings") {
                Stepper("Interval (seconds): \(interval)", 
                       value: $interval, 
                       in: 60...86400, 
                       step: 60)
                
                Toggle("Enable Notifications", isOn: $showNotifications)
            }
        }
        .padding()
    }
}
```

**macOS Form vs List:**
- `Form`: Proper settings styling with labels on left
- `List`: Generic list appearance
- Use `Form` for settings windows

#### 2. **TextField in List on macOS**

**Known Issues & Workarounds:**
- TextField focus issues in List on macOS (fixed in Sonoma)
- Workaround: Use `ScrollView` + `VStack` instead of `List`
- Or: Add padding adjustments

```swift
Form {
    Section("Paths") {
        ForEach($paths, id: \.self) { $path in
            TextField("Path", text: $path)
                .padding(.vertical, 4)
        }
    }
}
```

#### 3. **LabeledContent for Settings Layout**

**Two-Column Layout Pattern:**
```swift
Form {
    Section("General") {
        LabeledContent("App Version", value: "1.0.0")
        
        LabeledContent("Theme") {
            Picker(selection: $theme) {
                Text("Light").tag(0)
                Text("Dark").tag(1)
                Text("System").tag(2)
            }
            .pickerStyle(.segmented)
        }
    }
    
    Section("Storage") {
        LabeledContent("Database Size", value: "245 MB")
        
        LabeledContent("Last Scan") {
            HStack {
                Text(lastScanDate)
                Spacer()
                Button("Rescan") { /* ... */ }
            }
        }
    }
}
```

#### 4. **@AppStorage for Persistent Settings**

**Automatic UserDefaults Binding:**
```swift
struct SettingsView: View {
    @AppStorage("scanPaths") var paths: String = ""
    @AppStorage("autoScan") var autoScan: Bool = true
    @AppStorage("notifyThreshold") var threshold: Int = 100
    
    var body: some View {
        Form {
            TextField("Paths", text: $paths)
            Toggle("Auto Scan", isOn: $autoScan)
            Slider(value: $threshold, in: 1...1000)
        }
    }
}
```

**Advantages:**
- Automatic persistence to UserDefaults
- Type-safe
- No manual save/load needed
- Survives app restarts

---

### Progress Reporting & UI Updates

#### 1. **ProgressView with Async Tasks**

**Pattern for Long-Running Operations:**
```swift
@Observable
class ScannerViewModel {
    @MainActor var isScanning = false
    @MainActor var progress = 0.0
    @MainActor var currentPath = ""
    
    @MainActor
    func startScan() async {
        isScanning = true
        defer { isScanning = false }
        
        do {
            let items = FileManager.default.enumerator(atPath: "/")!
            var count = 0
            
            for case let item as String in items {
                self.currentPath = item
                count += 1
                
                // Update every 1000 files for performance
                if count % 1000 == 0 {
                    self.progress = Double(count) / Double(totalEstimate)
                }
            }
        } catch {
            print("Error: \(error)")
        }
    }
}

struct ScanProgressView: View {
    @State var viewModel = ScannerViewModel()
    
    var body: some View {
        VStack {
            if viewModel.isScanning {
                ProgressView(value: viewModel.progress)
                Text(viewModel.currentPath)
                    .font(.caption)
            }
            Button(viewModel.isScanning ? "Scanning..." : "Start Scan") {
                if !viewModel.isScanning {
                    Task {
                        await viewModel.startScan()
                    }
                }
            }
            .disabled(viewModel.isScanning)
        }
    }
}
```

#### 2. **Publisher-Based Progress with Combine**

**Stream-Based Progress Updates:**
```swift
class ScanService {
    func scanDirectory(_ path: String) -> AnyPublisher<ScanProgress, Error> {
        Future { promise in
            DispatchQueue.global().async {
                do {
                    let enumerator = FileManager.default.enumerator(atPath: path)!
                    var count = 0
                    for _ in enumerator {
                        count += 1
                        let progress = ScanProgress(
                            processed: count,
                            total: estimatedTotal,
                            currentPath: path
                        )
                        // This won't work directly; need AsyncStream
                    }
                } catch {
                    promise(.failure(error))
                }
            }
        }.eraseToAnyPublisher()
    }
}
```

**Preferred: Use AsyncStream with @State**
```swift
struct ScanView: View {
    @State var progress: Double = 0
    
    var body: some View {
        VStack {
            ProgressView(value: progress)
            Button("Scan") {
                Task {
                    for await newProgress in scanner.scanStream() {
                        progress = newProgress
                    }
                }
            }
        }
    }
}
```

---

## Bonus: General Architecture Patterns

### MVVM in SwiftUI with macOS

#### 1. **Service Layer Architecture**

**Three-Layer Pattern:**
```swift
// MODEL
struct FileEntry: Codable {
    let path: String
    let size: Int64
    let isDirectory: Bool
}

// SERVICE (Business Logic)
@Observable
class FileSystemService {
    private let fileManager = FileManager.default
    
    func scanDirectory(_ path: String) async throws -> [FileEntry] {
        var results: [FileEntry] = []
        let enumerator = fileManager.enumerator(atPath: path)!
        
        for case let file as String in enumerator {
            let fullPath = (path as NSString).appendingPathComponent(file)
            let attributes = try fileManager.attributesOfItem(atPath: fullPath)
            
            results.append(FileEntry(
                path: fullPath,
                size: attributes[.size] as? Int64 ?? 0,
                isDirectory: // determine...
            ))
        }
        return results
    }
}

// VIEW MODEL
@Observable
class ScannerViewModel {
    private let service: FileSystemService
    @MainActor var files: [FileEntry] = []
    @MainActor var isLoading = false
    
    init(service: FileSystemService) {
        self.service = service
    }
    
    @MainActor
    func scan(_ path: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            files = try await service.scanDirectory(path)
        } catch {
            // Handle error
        }
    }
}

// VIEW
struct ScanView: View {
    let viewModel: ScannerViewModel
    
    var body: some View {
        List(viewModel.files) { file in
            Text(file.path)
        }
        .task {
            await viewModel.scan("/Users")
        }
    }
}
```

#### 2. **Dependency Injection Pattern**

**Avoiding Singletons:**
```swift
@main
struct App: App {
    @State private var fileService = FileSystemService()
    @State private var databaseService = DatabaseService()
    
    var body: some Scene {
        WindowGroup {
            let viewModel = ScannerViewModel(
                fileService: fileService,
                databaseService: databaseService
            )
            ContentView(viewModel: viewModel)
        }
    }
}

struct ContentView: View {
    let viewModel: ScannerViewModel
    
    var body: some View {
        // View code
    }
}
```

#### 3. **Error Handling Pattern**

**Custom Error Types:**
```swift
enum ScanError: LocalizedError {
    case accessDenied(path: String)
    case invalidPath(String)
    case systemError(OSError)
    
    var errorDescription: String? {
        switch self {
        case .accessDenied(let path):
            return "Access denied: \(path)"
        case .invalidPath(let path):
            return "Invalid path: \(path)"
        case .systemError(let error):
            return error.localizedDescription
        }
    }
}

@Observable
class ViewModel {
    @MainActor var error: ScanError?
    
    @MainActor
    func scan() async {
        do {
            // scanning...
        } catch let error as ScanError {
            self.error = error
        }
    }
}
```

---

### Menu Bar Applications

#### 1. **MenuBarExtra Setup & Lifecycle**

**Basic Menu Bar App:**
```swift
@main
struct App: App {
    var body: some Scene {
        MenuBarExtra("Disk Usage", systemImage: "internaldrive") {
            MenuBarContentView()
        }
        .menuBarExtraStyle(.window)  // or .menu
    }
}

struct MenuBarContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("System Storage")
                .font(.headline)
            
            ProgressView(value: 0.65)
            Text("65% Used")
                .font(.caption)
            
            Divider()
            
            Button("Open Full App") {
                // Launch main window
            }
            
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding()
        .frame(minWidth: 250)
    }
}
```

#### 2. **Menu Bar Styles**

**Options:**
- `.automatic`: System chooses based on context
- `.menu`: Native menu (simpler, compact)
- `.window`: Popover window (more flexible UI)

```swift
MenuBarExtra("Title", systemImage: "icon") {
    Content()
}
.menuBarExtraStyle(.window)  // Use .window for complex UI
```

#### 3. **Lifecycle & Activation Policy**

**Key Challenge:** MenuBarExtra only activates when clicked

**Workaround - Using WindowGroup + MenuBarExtra:**
```swift
@main
struct App: App {
    var body: some Scene {
        WindowGroup {
            EmptyView()
                .hidden()  // Hidden main window
        }
        
        MenuBarExtra("App", systemImage: "gearshape") {
            MenuView()
        }
        .menuBarExtraStyle(.window)
    }
}
```

**Background Execution:**
- Set `LSUIElement` in Info.plist to YES for background-only mode
- No Dock icon if using background mode
- Requires WindowGroup for some features

#### 4. **No Dock Icon Configuration**

**Info.plist:**
```xml
<key>LSUIElement</key>
<true/>  <!-- Hides Dock icon, runs in background -->
```

**Activation Policy Code:**
```swift
NSApp.setActivationPolicy(.accessory)  // No Dock icon
NSApp.setActivationPolicy(.regular)    // Normal with Dock
```

---

## Summary Table: Performance Characteristics

| Operation | Performance | Notes |
|-----------|-------------|-------|
| URL-based enumeration | 40.6s (541K files) | 3x faster than string |
| String enumeration | 118.6s (541K files) | Deprecated, slower |
| Batch insert (transactional) | 0.8s (10K items) | 15x faster than sequential |
| Sequential insert | 12s (10K items) | No transaction overhead |
| Indexed query (1.6M items) | 29.7ms | vs 327ms unindexed |
| Non-indexed query (1.6M) | 327ms | Linear performance degradation |

---

## Key Implementation Checklist

- [ ] Set up DatabaseQueue singleton
- [ ] Use URL-based FileManager enumeration
- [ ] Implement batch transactions for inserts
- [ ] Create indexes on frequently-queried columns
- [ ] Use @Observable for view models (Swift 5.9+)
- [ ] Mark UI-updating methods with @MainActor
- [ ] Implement error handling with custom error types
- [ ] Use AsyncStream for progress updates
- [ ] Configure MenuBarExtra with .window style
- [ ] Set up Full Disk Access entitlements
- [ ] Implement proper @AppStorage for settings
- [ ] Use Combine or AsyncStream for progress binding

