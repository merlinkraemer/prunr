import SwiftUI
import AppKit

/// Settings window for Prunr with tabbed interface
struct SettingsView: View {
    @State private var settingsStore = SettingsStore.shared
    @State private var selectedTab = UserDefaults.standard.integer(forKey: "settingsSelectedTab")

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsTab(settingsStore: settingsStore)
                .tabItem { Label("General", systemImage: "gear") }
                .tag(0)

            ScanScopeSettingsTab(settingsStore: settingsStore)
                .tabItem { Label("Scan Scope", systemImage: "folder") }
                .tag(1)

            ScanRulesSettingsTab(settingsStore: settingsStore)
                .tabItem { Label("Scan Rules", systemImage: "line.3.horizontal.decrease.circle") }
                .tag(2)
        }
        .frame(width: 520, height: 480)
    }
}

// MARK: - General Tab

private struct GeneralSettingsTab: View {
    @Bindable var settingsStore: SettingsStore
    @State private var baselineService = BaselineService.shared
    @State private var isResetting = false
    @State private var showDeleteSnapshotsConfirmation = false
    @State private var showingSavedNotice = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Startup") {
                    Toggle("Launch Prunr at Login", isOn: $settingsStore.launchAtLogin)
                        .toggleStyle(.switch)
                }

                Section("Data") {
                    Text("Delete all snapshots to rebuild history from scratch after major scope or rule changes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button(role: .destructive) {
                        showDeleteSnapshotsConfirmation = true
                    } label: {
                        HStack(spacing: 8) {
                            if isResetting {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "trash")
                            }
                            Text("Delete All Snapshots")
                        }
                    }
                    .disabled(isResetting)

                    if showingSavedNotice {
                        Label("Snapshots deleted", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }

                Section("App") {
                    Text("Prunr 1.0")
                        .foregroundStyle(.secondary)

                    Button("Quit Prunr") {
                        NSApplication.shared.terminate(nil)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .confirmationDialog(
            "Delete all snapshots?",
            isPresented: $showDeleteSnapshotsConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete All Snapshots", role: .destructive) {
                isResetting = true
                Task {
                    try? await baselineService.resetBaseline()
                    isResetting = false
                    showingSavedNotice = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        showingSavedNotice = false
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all saved history and cannot be undone.")
        }
    }
}

// MARK: - Scan Scope Tab

private struct ScanScopeSettingsTab: View {
    @Bindable var settingsStore: SettingsStore
    @State private var showingBasePathPicker = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Primary Scan Folder") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("This is your main monitored path. Keep it at ~/dev while testing for faster scans.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 10) {
                            Image(systemName: "externaldrive.fill")
                                .foregroundStyle(.blue)

                            Text(settingsStore.mainBasePath)
                                .font(.system(size: 12, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer()

                            Button("Change") {
                                showingBasePathPicker = true
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.top, 4)
                }

                GroupBox("Common Paths") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Optional high-growth paths. These are scanned but hidden from the overview path picker.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if settingsStore.availableCommonPaths.isEmpty {
                            Text("No common paths found on this machine.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(settingsStore.availableCommonPaths) { path in
                                Toggle(isOn: Binding(
                                    get: { settingsStore.isCommonPathSelected(path) },
                                    set: { selected in
                                        settingsStore.setCommonPathSelected(path, selected: selected)
                                    }
                                )) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(path.displayName)
                                            .font(.system(size: 13, weight: .medium))
                                        Text(path.url.path)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                                .toggleStyle(.switch)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .padding()
        }
        .fileImporter(
            isPresented: $showingBasePathPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                settingsStore.setMainBasePath(url)
            }
        }
    }
}

// MARK: - Scan Rules Tab

private struct ScanRulesSettingsTab: View {
    @Bindable var settingsStore: SettingsStore
    @State private var newBoundary = ""
    @State private var newIgnoreName = ""

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    Text("Use rules to control what gets scanned: stop expanding large folders, or ignore names entirely.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Stop Expanding Folders") {
                    ForEach(Array(BoundaryConfig.standardBoundaries).sorted(), id: \.self) { name in
                        Toggle(isOn: Binding(
                            get: { settingsStore.isBoundaryEnabled(name) },
                            set: { enabled in settingsStore.setBoundaryEnabled(name, enabled: enabled) }
                        )) {
                            Text(name)
                                .font(.system(size: 13, design: .monospaced))
                        }
                        .toggleStyle(.switch)
                    }

                    ForEach(settingsStore.customBoundaries, id: \.self) { name in
                        HStack {
                            Text(name)
                                .font(.system(size: 13, design: .monospaced))
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

                    HStack {
                        TextField("Folder name (e.g., node_modules)", text: $newBoundary)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13, design: .monospaced))

                        Button {
                            settingsStore.addBoundary(newBoundary)
                            newBoundary = ""
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.bordered)
                        .disabled(newBoundary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                Section("Ignore Names") {
                    ForEach(Array(SettingsStore.defaultScanIgnoreNames).sorted(), id: \.self) { name in
                        Label(name, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 13, design: .monospaced))
                    }

                    ForEach(settingsStore.customScanIgnores, id: \.self) { name in
                        HStack {
                            Text(name)
                                .font(.system(size: 13, design: .monospaced))
                            Spacer()
                            Button {
                                settingsStore.removeScanIgnore(name)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    HStack {
                        TextField("Name to ignore (e.g., .DS_Store)", text: $newIgnoreName)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13, design: .monospaced))

                        Button {
                            settingsStore.addScanIgnore(newIgnoreName)
                            newIgnoreName = ""
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.bordered)
                        .disabled(newIgnoreName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .listStyle(.inset)
        }
    }
}

#Preview {
    SettingsView()
}
