import SwiftUI
import AppKit

/// Settings window for Prunr with tabbed interface
struct SettingsView: View {
    @State private var settingsStore = SettingsStore.shared
    // Read initial tab from UserDefaults for external tab control (ISS-034)
    @State private var selectedTab = UserDefaults.standard.integer(forKey: "settingsSelectedTab")
    
    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsTab(settingsStore: settingsStore)
                .tabItem {
                    Label("General", systemImage: "gear")
                }
                .tag(0)
            
            PathsSettingsTab(settingsStore: settingsStore)
                .tabItem {
                    Label("Paths", systemImage: "folder")
                }
                .tag(1)
            
            BoundariesSettingsTab(settingsStore: settingsStore)
                .tabItem {
                    Label("Boundaries", systemImage: "stop.circle")
                }
                .tag(2)
            
            DebugSettingsTab()
                .tabItem {
                    Label("Debug", systemImage: "ladybug")
                }
                .tag(3)
            
            AboutSettingsTab()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
                .tag(4)
        }
        .frame(width: 450, height: 400)
    }
}

// MARK: - General Tab

private struct GeneralSettingsTab: View {
    @Bindable var settingsStore: SettingsStore
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Startup section
            GroupBox("Startup") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Launch Prunr at Login", isOn: $settingsStore.launchAtLogin)
                        .toggleStyle(.checkbox)
                }
                .padding(8)
            }
            
            // Scanning section
            GroupBox("Scanning") {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Drill-Down Threshold")
                            Spacer()
                            Text("\(Int(settingsStore.drillDownThreshold * 100))%")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $settingsStore.drillDownThreshold, in: 0.5...0.95)
                    }
                    
                    Text("Stop drilling into subfolders when one folder contains this percentage of the parent's total growth.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
            }
            
            Spacer()
        }
        .padding()
    }
}

// MARK: - Paths Tab

private struct PathsSettingsTab: View {
    @Bindable var settingsStore: SettingsStore
    @State private var showingFilePicker = false
    @State private var pathsChanged = false
    @State private var showingSavedNotice = false
    
    var body: some View {
        VStack(spacing: 0) {
            List {
                Section("Tracked Paths") {
                    // Default paths with checkboxes
                    ForEach(TrackedPath.defaultPaths) { path in
                        Toggle(isOn: Binding(
                            get: { settingsStore.isPathEnabled(path) },
                            set: { enabled in
                                settingsStore.setPathEnabled(path, enabled: enabled)
                                pathsChanged = true
                            }
                        )) {
                            HStack(spacing: 8) {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(.blue)
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(path.displayName)
                                        .font(.system(size: 13))
                                    Text(path.url.path)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                    
                    // Custom paths with checkboxes
                    ForEach(settingsStore.customTrackedPaths) { path in
                        HStack {
                            Toggle(isOn: Binding(
                                get: { settingsStore.isPathEnabled(path) },
                                set: { enabled in
                                    settingsStore.setPathEnabled(path, enabled: enabled)
                                    pathsChanged = true
                                }
                            )) {
                                HStack(spacing: 8) {
                                    Image(systemName: "folder.fill")
                                        .foregroundStyle(.orange)
                                        .frame(width: 16)
                                    Text(path.displayName)
                                        .font(.system(size: 13))
                                }
                            }
                            .toggleStyle(.checkbox)
                            
                            Spacer()
                            
                            Button {
                                settingsStore.removeTrackedPath(path)
                                pathsChanged = true
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            
            if pathsChanged {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Paths changed — baseline needs to be recreated")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.1))
            }
            
            if showingSavedNotice {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Saved!")
                        .font(.caption)
                }
                .padding(8)
            }
            
            Divider()
            
            HStack {
                Button {
                    showingFilePicker = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.bordered)
                
                Spacer()
                
                if pathsChanged {
                    Button("Save") {
                        // Settings are auto-saved, but trigger baseline invalidation
                        Task {
                            try? await BaselineService.shared.resetBaseline()
                        }
                        pathsChanged = false
                        showingSavedNotice = true
                        
                        // Hide notice after 2 seconds
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            showingSavedNotice = false
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(8)
        }
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                let path = TrackedPath(
                    url: url,
                    displayName: url.lastPathComponent,
                    isDefault: false
                )
                settingsStore.addTrackedPath(path)
                pathsChanged = true
            }
        }
    }
}


// MARK: - Boundaries Tab

private struct BoundariesSettingsTab: View {
    @Bindable var settingsStore: SettingsStore
    @State private var newBoundary = ""
    
    var body: some View {
        VStack(spacing: 0) {
            List {
                Section("Boundary Folders") {
                    // Standard boundaries with checkboxes
                    ForEach(Array(BoundaryConfig.standardBoundaries).sorted(), id: \.self) { name in
                        Toggle(isOn: Binding(
                            get: { settingsStore.isBoundaryEnabled(name) },
                            set: { enabled in settingsStore.setBoundaryEnabled(name, enabled: enabled) }
                        )) {
                            HStack(spacing: 8) {
                                Image(systemName: "stop.circle")
                                    .foregroundStyle(.gray)
                                    .frame(width: 16)
                                Text(name)
                                    .font(.system(size: 13, design: .monospaced))
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                    
                    // Custom boundaries with checkboxes
                    ForEach(settingsStore.customBoundaries, id: \.self) { name in
                        HStack {
                            Toggle(isOn: .constant(true)) {
                                HStack(spacing: 8) {
                                    Image(systemName: "stop.circle.fill")
                                        .foregroundStyle(.orange)
                                        .frame(width: 16)
                                    Text(name)
                                        .font(.system(size: 13, design: .monospaced))
                                }
                            }
                            .toggleStyle(.checkbox)
                            
                            Spacer()
                            
                            Button {
                                settingsStore.removeBoundary(name)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            
            Divider()
            
            HStack {
                TextField("Folder name (e.g., .myenv)", text: $newBoundary)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                
                Button {
                    settingsStore.addBoundary(newBoundary)
                    newBoundary = ""
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.bordered)
                .disabled(newBoundary.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(8)
        }
    }
}

// MARK: - Debug Tab

private struct DebugSettingsTab: View {
    @State private var isCreating = false
    @State private var statusMessage = ""
    
    private let testDataPath: String = {
        // Use project test_data folder
        let projectPath = "/Users/merlinkramer/dev/projects/prunr/test_data"
        return projectPath
    }()
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox("Test Data") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Create varied test files to simulate disk growth")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    HStack {
                        Text("Path:")
                            .foregroundStyle(.secondary)
                        Text(testDataPath)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    
                    HStack(spacing: 12) {
                        Button {
                            createVariedTestData()
                        } label: {
                            HStack(spacing: 6) {
                                if isCreating {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                } else {
                                    Image(systemName: "plus.circle")
                                }
                                Text(isCreating ? "Created!" : "Create Test Data")
                            }
                        }
                        .disabled(isCreating)
                        
                        Button("Open in Finder") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: testDataPath))
                        }
                        
                        Button("Clean Up") {
                            cleanupTestData()
                        }
                        .foregroundStyle(.red)
                    }
                    
                    if !statusMessage.isEmpty {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(statusMessage.contains("Error") ? .red : .green)
                    }
                }
                .padding(8)
            }
            
            GroupBox("What Gets Created (~10 MB each click)") {
                VStack(alignment: .leading, spacing: 6) {
                    Label("documents/ — 1 MB", systemImage: "doc.text")
                    Label("images/ — 3 MB", systemImage: "photo")
                    Label("cache/ — 1 MB", systemImage: "archivebox")
                    Label("downloads/ — 4 MB", systemImage: "arrow.down.circle")
                    Label("logs/ — 0.5 MB", systemImage: "doc.plaintext")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
            }
            
            Spacer()
        }
        .padding()
    }
    
    private func createVariedTestData() {
        isCreating = true
        statusMessage = "Creating..."
        
        Task {
            if let manager = await MainActor.run(body: { MenuBarManager.shared }) {
                await manager.generateTestData()
                
                await MainActor.run {
                    statusMessage = "Created test data successfully"
                    isCreating = false
                }
            } else {
                await MainActor.run {
                    statusMessage = "Error: MenuBarManager not found"
                    isCreating = false
                }
            }
        }
    }
    
    private func cleanupTestData() {
        do {
            let url = URL(fileURLWithPath: testDataPath)
            try FileManager.default.removeItem(at: url)
            statusMessage = "Cleaned up test data"
        } catch {
            statusMessage = "Error: \(error.localizedDescription)"
        }
    }
}


// MARK: - About Tab

private struct AboutSettingsTab: View {
    @State private var baselineService = BaselineService.shared
    @State private var isResetting = false
    
    var body: some View {
        VStack(spacing: 20) {
            // App icon and name
            VStack(spacing: 8) {
                Image(systemName: "internaldrive")
                    .font(.system(size: 48))
                    .foregroundStyle(.blue)
                
                Text("Prunr")
                    .font(.title)
                    .fontWeight(.bold)
                
                Text("Version 1.0")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Divider()
            
            // Actions
            VStack(spacing: 12) {
                Button {
                    isResetting = true
                    Task {
                        try? await baselineService.resetBaseline()
                        isResetting = false
                    }
                } label: {
                    HStack {
                        if isResetting {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text("Reset Baseline")
                    }
                }
                .disabled(isResetting)
                
                Button("Quit Prunr") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderedProminent)
            }
            
            Spacer()
        }
        .padding()
    }
}

#Preview {
    SettingsView()
}
