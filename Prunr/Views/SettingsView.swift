import SwiftUI
import AppKit

/// Settings window for Prunr with tabbed interface
struct SettingsView: View {
    @State private var settingsStore = SettingsStore.shared
    @State private var scanService = ScanService.shared
    @State private var selectedTab = UserDefaults.standard.integer(forKey: "settingsSelectedTab")
    @State private var isApplyingScopeChanges = false

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                if scanService.isScanning {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text("Scan running — scope and rules are locked until it finishes.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.gray.opacity(0.08))
                }

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
                .disabled(isApplyingScopeChanges)
            }
            .frame(width: 520, height: 480)

            if isApplyingScopeChanges {
                Color.black.opacity(0.12)
                    .ignoresSafeArea()
                    .allowsHitTesting(true)
            }
        }
    }
}

// MARK: - General Tab

private struct GeneralSettingsTab: View {
    @Bindable var settingsStore: SettingsStore
    @State private var baselineService = BaselineService.shared
    @State private var permissionsService = PermissionsService.shared
    @State private var scanService = ScanService.shared
    @State private var isResetting = false
    @State private var isCompactingDatabase = false
    @State private var showDeleteSnapshotsConfirmation = false
    @State private var showingSavedNotice = false
    @State private var compactedNotice = ""
    @State private var hasFullDiskAccess = false
    @State private var blockedFullDiskAccessLocations: [String] = []

    private var appVersionText: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "Version \(short) (\(build))"
    }

    private var hasEnabledScanPath: Bool {
        !settingsStore.enabledTrackedPaths.isEmpty
    }

    private var isScanInProgress: Bool {
        scanService.isScanning
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Startup") {
                    Toggle("Launch Prunr at Login", isOn: $settingsStore.launchAtLogin)
                        .toggleStyle(.switch)
                }

                Section("Permissions") {
                    HStack {
                        Image(systemName: hasFullDiskAccess ? "checkmark.circle.fill" : "shield.fill")
                            .foregroundStyle(hasFullDiskAccess ? .green : .orange)
                        
                        Text(hasFullDiskAccess ? "Full Disk Access granted" : "Full Disk Access required")
                    }

                    if !hasFullDiskAccess && !blockedFullDiskAccessLocations.isEmpty {
                        Text("Still blocked: \(blockedFullDiskAccessLocations.prefix(4).joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    if !hasFullDiskAccess {
                        Button("Open Full Disk Access") {
                            openFullDiskAccessSettings()
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Show Prunr in Finder") {
                            permissionsService.revealCurrentAppInFinder()
                        }
                        .buttonStyle(.bordered)
                    }
                    
                    Text("Required to scan system and user locations accurately.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Scanning") {
                    Text("Prunr tracks file changes in real time. A periodic full rescan ensures long-term accuracy.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Text("Periodic full rescan")
                            .font(.system(size: 13))

                        Spacer()

                        Picker("", selection: $settingsStore.automaticFullScanIntervalHours) {
                            Text("Daily").tag(24)
                            Text("Every 2 days").tag(48)
                            Text("Every 3 days").tag(72)
                            Text("Weekly").tag(168)
                            Text("Every 2 weeks").tag(336)
                        }
                        .pickerStyle(.menu)
                        .frame(width: 140)
                    }

                    HStack {
                        Text("Category history")
                            .font(.system(size: 13))

                        Spacer()

                        Picker("", selection: $settingsStore.categoryHistoryRetentionDays) {
                            Text("7 days").tag(7)
                            Text("14 days").tag(14)
                            Text("30 days").tag(30)
                            Text("60 days").tag(60)
                            Text("90 days").tag(90)
                        }
                        .pickerStyle(.menu)
                        .frame(width: 120)
                    }

                    Button {
                        MenuBarManager.shared?.showPopover()
                        Task {
                            await MenuBarManager.shared?.loadInventory()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if isScanInProgress {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                            Text("Scan Now")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isScanInProgress || !hasEnabledScanPath)

                    if isScanInProgress, let manager = MenuBarManager.shared {
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(value: max(0.0, min(1.0, manager.scanProgressPercentage)))
                                .tint(.blue)

                            Text("Scanning — \(Int(manager.scanProgressPercentage * 100))%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !hasEnabledScanPath {
                        Text("Enable at least one scan path in Scan Scope first.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Troubleshooting") {
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

                    Button {
                        isCompactingDatabase = true
                        compactedNotice = ""

                        Task {
                            do {
                                let report = try await DatabaseCleanupService.shared.compactDatabaseNow()
                                let reclaimedDbBytes = max(0, report.dbBytesBefore - report.dbBytesAfter)
                                let reclaimedWalBytes = max(0, report.walBytesBefore - report.walBytesAfter)
                                let reclaimedTotal = reclaimedDbBytes + reclaimedWalBytes

                                compactedNotice = "Reclaimed \(formattedBytes(reclaimedTotal))."
                            } catch {
                                compactedNotice = "Compaction failed: \(error.localizedDescription)"
                            }

                            isCompactingDatabase = false
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if isCompactingDatabase {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "externaldrive.badge.timemachine")
                            }
                            Text("Compact Database")
                        }
                    }
                    .disabled(isResetting || isCompactingDatabase)

                    if !compactedNotice.isEmpty {
                        Text(compactedNotice)
                            .font(.caption)
                            .foregroundStyle(compactedNotice.hasPrefix("Compaction failed") ? .red : .green)
                    }

                    if showingSavedNotice {
                        Label("Snapshots deleted", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
            }
            .formStyle(.grouped)
            .hiddenScrollIndicators()

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
                    if let manager = MenuBarManager.shared {
                        await manager.performReset()
                    } else {
                        try? await baselineService.resetBaseline()
                    }
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
        .onAppear {
            refreshFullDiskAccess()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshFullDiskAccess()
        }
    }

    private func refreshFullDiskAccess() {
        let report = permissionsService.fullDiskAccessReport
        hasFullDiskAccess = report.isGranted
        blockedFullDiskAccessLocations = report.deniedLocations
    }

    private func openFullDiskAccessSettings() {
        Task { await permissionsService.requestFullDiskAccess() }
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
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

    private var recommendedCommonPaths: [TrackedPath] {
        settingsStore.recommendedCommonPaths
    }

    private var optionalCommonPaths: [TrackedPath] {
        settingsStore.optionalCommonPaths
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

                        GroupBox("Recommended Extras") {
                            VStack(alignment: .leading, spacing: 10) {
                                if recommendedCommonPaths.isEmpty {
                                    Text("No recommended extras found on this machine.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    ForEach(recommendedCommonPaths) { path in
                                        commonPathToggle(for: path)
                                    }
                                }
                            }
                            .padding(.top, 4)
                        }

                        GroupBox("Other Common Paths") {
                            VStack(alignment: .leading, spacing: 10) {
                                if optionalCommonPaths.isEmpty {
                                    Text("No other common paths found on this machine.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    ForEach(optionalCommonPaths) { path in
                                        commonPathToggle(for: path)
                                    }
                                }
                            }
                            .padding(.top, 4)
                        }
                    }
                    .padding()
                }
                .hiddenScrollIndicators()

            if settingsStore.hasPendingScopeChanges && !isApplyingScopeChanges {
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
                                Image(systemName: "checkmark.circle")
                                Text("Apply")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isScanInProgress)
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
                    .frame(maxWidth: 320)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(nsColor: .windowBackgroundColor))
                            .shadow(radius: 8)
                    )
                    .padding(20)
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
                        if let manager = MenuBarManager.shared {
                            applyStatusText = "Applying new scope..."
                            try await manager.applyScopeChanges()
                        } else {
                            try await baselineService.resetBaseline()
                            applyStatusText = "Cleaning up..."
                            await DatabaseCleanupService.shared.performAutoCleanup()
                        }

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

    @ViewBuilder
    private func commonPathToggle(for path: TrackedPath) -> some View {
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
            .hiddenScrollIndicators()
            .disabled(isScanInProgress)
        }
    }
}

#Preview {
    SettingsView()
}
