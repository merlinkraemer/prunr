import SwiftUI
import AppKit

/// Settings window for Prunr with tabbed interface
struct SettingsView: View {
    @State private var settingsStore = SettingsStore.shared
    @State private var selectedTab = UserDefaults.standard.integer(forKey: "settingsSelectedTab")
    @State private var isApplyingScopeChanges = false

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsTab(settingsStore: settingsStore)
                .tabItem { Label("General", systemImage: "gear") }
                .tag(0)

            ScanScopeSettingsTab(settingsStore: settingsStore, isApplyingScopeChanges: $isApplyingScopeChanges)
                .tabItem { Label("Scan Scope", systemImage: "folder") }
                .tag(1)

            ScanRulesSettingsTab(settingsStore: settingsStore)
                .tabItem { Label("Scan Rules", systemImage: "line.3.horizontal.decrease.circle") }
                .tag(2)
        }
        .frame(width: 520, height: 480)
        .disabled(isApplyingScopeChanges)
    }
}

// MARK: - General Tab

private struct GeneralSettingsTab: View {
    @Bindable var settingsStore: SettingsStore
    @State private var baselineService = BaselineService.shared
    @State private var isResetting = false
    @State private var showDeleteSnapshotsConfirmation = false
    @State private var showingSavedNotice = false

    private var appVersionText: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.1"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "Version \(short) (\(build))"
    }

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
            }
            .formStyle(.grouped)

            Spacer(minLength: 0)

            Divider()

            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 28, height: 28)

                Text("Prunr")
                    .font(.system(size: 13, weight: .semibold))

                Text(appVersionText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
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
    @State private var baselineService = BaselineService.shared
    @State private var scanService = ScanService.shared
    @State private var showingBasePathPicker = false
    @Binding var isApplyingScopeChanges: Bool
    @State private var showApplyConfirmation = false
    @State private var showingAppliedNotice = false
    @State private var applyStatusText = ""

    private var isScanInProgress: Bool {
        scanService.isScanning
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                    GroupBox("Primary Scan Folder") {
                        VStack(alignment: .leading, spacing: 10) {
                            if isScanInProgress {
                                Label("Scan is running. Scope controls are temporarily locked.", systemImage: "lock.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

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
                                    .disabled(isScanInProgress)
                                }
                            }
                            .padding(.top, 4)
                        }

                        GroupBox("Common Paths") {
                            VStack(alignment: .leading, spacing: 10) {
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
                                            HStack(spacing: 8) {
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text(path.displayName)
                                                        .font(.system(size: 13, weight: .medium))
                                                    Text(path.url.path)
                                                        .font(.system(size: 11, design: .monospaced))
                                                        .foregroundStyle(.secondary)
                                                        .lineLimit(1)
                                                        .truncationMode(.middle)
                                                }
                                                Spacer(minLength: 0)
                                            }
                                        }
                                        .toggleStyle(.switch)
                                        .disabled(isScanInProgress)
                                    }
                                }
                            }
                            .padding(.top, 4)
                        }
                    }
                    .padding()
                }

            if settingsStore.hasPendingScopeChanges {
                Divider()

                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)

                        Text("Scope changed. Apply to reset snapshots and start fresh.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer()

                        Button {
                            showApplyConfirmation = true
                        } label: {
                            HStack(spacing: 6) {
                                if isApplyingScopeChanges {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "checkmark.circle")
                                }
                                Text("Apply")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isApplyingScopeChanges || isScanInProgress)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.orange.opacity(0.08))
                }

                if settingsStore.hasPendingScopeChanges && isScanInProgress {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                        Text("Apply is available when the current scan finishes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }

                if showingAppliedNotice {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Scope applied. Snapshot reloaded.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
            .disabled(isApplyingScopeChanges)

            if isApplyingScopeChanges {
                ZStack {
                    Color.black.opacity(0.08)
                        .ignoresSafeArea()

                    VStack(spacing: 0) {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.blue)

                            Text("Resetting snapshots")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.primary)

                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)

                        Divider()

                        VStack(spacing: 12) {
                            ProgressView()
                                .controlSize(.large)

                            Text(applyStatusText.isEmpty ? "Cleaning data and preparing for a new scan." : applyStatusText)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 240)

                            Text("Run a new scan from the menu bar to rebuild your baseline.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 240)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(nsColor: .windowBackgroundColor))
                            .shadow(radius: 8)
                    )
                }
            }
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
        .confirmationDialog(
            "Apply scope changes?",
            isPresented: $showApplyConfirmation,
            titleVisibility: .visible
        ) {
            Button("Apply and Reset Snapshots", role: .destructive) {
                isApplyingScopeChanges = true
                applyStatusText = "Resetting old snapshots..."

                Task {
                    do {
                        try await baselineService.resetBaseline()
                        applyStatusText = "Cleaning up..."
                        await DatabaseCleanupService.shared.performAutoCleanup()

                        settingsStore.clearPendingScopeChanges()
                        showingAppliedNotice = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            showingAppliedNotice = false
                        }
                    } catch {
                        // Keep existing scope pending if apply fails
                    }

                    isApplyingScopeChanges = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Changing scan scope can invalidate previous comparisons. Applying will delete existing snapshots.")
        }
    }
}

// MARK: - Scan Rules Tab

private struct ScanRulesSettingsTab: View {
    @Bindable var settingsStore: SettingsStore
    @State private var scanService = ScanService.shared
    @State private var newBoundary = ""
    @State private var newIgnoreName = ""

    private var isScanInProgress: Bool {
        scanService.isScanning
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    Text("Use rules to control what gets scanned: stop expanding large folders, or ignore names entirely.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if isScanInProgress {
                        Label("Rules are locked while a scan is running.", systemImage: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
            .disabled(isScanInProgress)
        }
    }
}

#Preview {
    SettingsView()
}
