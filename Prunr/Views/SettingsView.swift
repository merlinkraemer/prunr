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

            FolderLimitsSettingsTab(settingsStore: settingsStore)
                .tabItem {
                    Label("Folder Limits", systemImage: "stop.circle")
                }
                .tag(2)

            AboutSettingsTab()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
                .tag(3)
        }
        .frame(width: 480, height: 440)
    }
}

// MARK: - General Tab

private struct GeneralSettingsTab: View {
    @Bindable var settingsStore: SettingsStore

    var body: some View {
        VStack(spacing: 0) {
            // Startup section
            VStack(alignment: .leading, spacing: 12) {
                Text("Startup")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Toggle("Launch Prunr at Login", isOn: $settingsStore.launchAtLogin)
                    .toggleStyle(.switch)
            }
            .padding()

            Spacer()

            // Explanation
            VStack(alignment: .leading, spacing: 8) {
                Text("Configure path settings and folder limits in their respective tabs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()

            Spacer()
        }
    }
}

// MARK: - Paths Tab

private struct PathsSettingsTab: View {
    @Bindable var settingsStore: SettingsStore
    @State private var showingFilePicker = false
    @State private var showingBasePathPicker = false
    @State private var pathsChanged = false
    @State private var showingSavedNotice = false
    @State private var baselineService = BaselineService.shared
    @State private var isResetting = false
    @State private var showDeleteSnapshotsConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            // Main base path section
            VStack(alignment: .leading, spacing: 8) {
                Text("Main Base Directory")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.top, 12)

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
                .padding(.horizontal)

                Text("This is the primary folder Prunr watches. For now, keep this on your dev folder to keep scans fast.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }

            Divider()

            // Common paths section
            VStack(alignment: .leading, spacing: 8) {
                Text("Common Paths")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.top, 12)

                if settingsStore.availableCommonPaths.isEmpty {
                    Text("No common paths found on this machine yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                } else {
                    List {
                        ForEach(settingsStore.availableCommonPaths) { path in
                            Toggle(isOn: Binding(
                                get: { settingsStore.isCommonPathSelected(path) },
                                set: { selected in
                                    settingsStore.setCommonPathSelected(path, selected: selected)
                                    pathsChanged = true
                                }
                            )) {
                                HStack(spacing: 8) {
                                    Image(systemName: "archivebox.fill")
                                        .foregroundStyle(.teal)
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
                            .toggleStyle(.switch)
                        }
                    }
                    .frame(height: 120)
                    .listStyle(.plain)
                }
            }

            Divider()

            // Scan Paths section
            VStack(alignment: .leading, spacing: 8) {
                Text("Scan Paths")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.top, 12)

                List {
                    // Built-in paths with toggles
                    ForEach([settingsStore.mainTrackedPath] + settingsStore.selectedCommonPaths) { path in
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
                        .toggleStyle(.switch)
                    }

                    // Custom paths with toggles
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
                            .toggleStyle(.switch)

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
                .listStyle(.plain)
            }

            if pathsChanged {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Paths changed — click Delete All Snapshots to apply")
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
                    Text("Snapshots deleted!")
                        .font(.caption)
                }
                .padding(8)
            }

            Divider()

            // Action buttons
            HStack {
                Button {
                    showingFilePicker = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.bordered)
                .help("Add custom scan path")
                .accessibilityLabel("Add scan path")

                Spacer()

                // Delete All Snapshots button
                Button {
                    showDeleteSnapshotsConfirmation = true
                } label: {
                    HStack(spacing: 6) {
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
                .accessibilityLabel("Delete all snapshots")
                .accessibilityHint("Removes all stored scan history")
            }
            .padding(12)
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
                    pathsChanged = false
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
        .fileImporter(
            isPresented: $showingBasePathPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                settingsStore.setMainBasePath(url)
                pathsChanged = true
            }
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

// MARK: - Folder Limits Tab

private struct FolderLimitsSettingsTab: View {
    @Bindable var settingsStore: SettingsStore
    @State private var newBoundary = ""

    var body: some View {
        VStack(spacing: 0) {
            // Explanation section
            VStack(alignment: .leading, spacing: 8) {
                Text("Folder Limits")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Text("When drilling into folders, scanning stops at these names. This keeps node_modules, .git, and build folders as single items instead of showing thousands of files inside.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()

            Divider()

            List {
                // Standard folder limits with toggles
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
                    .toggleStyle(.switch)
                }

                // Custom folder limits with toggles and remove button
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
                        .toggleStyle(.switch)

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
            .listStyle(.plain)

            Divider()

            // Add custom folder limit
            HStack {
                TextField("Folder name (e.g., .myenv)", text: $newBoundary)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))

                Button {
                    settingsStore.addBoundary(newBoundary)
                    newBoundary = ""
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.bordered)
                .disabled(newBoundary.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("Add custom folder limit")
                .accessibilityLabel("Add folder limit")
            }
            .padding(12)
        }
    }
}

// MARK: - About Tab

private struct AboutSettingsTab: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            // App icon and name
            VStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 80, height: 80)

                Text("Prunr")
                    .font(.title)
                    .fontWeight(.bold)

                Text("Version 1.0")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Quit button
            Button("Quit Prunr") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderedProminent)

            Spacer()
        }
        .padding()
    }
}

#Preview {
    SettingsView()
}
