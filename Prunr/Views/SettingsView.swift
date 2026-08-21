import SwiftUI
import AppKit

extension Notification.Name {
    static let focusFeedback = Notification.Name("com.prunr.focusFeedback")
}

/// One settings pane. The tab bar itself is a native `NSToolbar` (preference
/// style, big icons) driven by `SettingsWindowController`; this enum is the
/// shared source of truth for the panes and their toolbar items.
enum SettingsTab: Int, CaseIterable {
    case general
    case scanScope
    case troubleshooting = 3

    var title: String {
        switch self {
        case .general: return "General"
        case .scanScope: return "Scan Scope"
        case .troubleshooting: return "Troubleshooting"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gear"
        case .scanScope: return "folder"
        case .troubleshooting: return "wrench.and.screwdriver"
        }
    }

    var toolbarIdentifier: NSToolbarItem.Identifier {
        NSToolbarItem.Identifier("settings.tab.\(rawValue)")
    }

    static func from(toolbarIdentifier identifier: NSToolbarItem.Identifier) -> SettingsTab? {
        allCases.first { $0.toolbarIdentifier == identifier }
    }
}

/// Tracks the selected settings pane. The `NSToolbar` writes to it (AppKit) and
/// `SettingsView` observes it (SwiftUI), so the SwiftUI tree stays alive across
/// tab switches and per-pane state (e.g. pending scope changes) is preserved.
@MainActor
@Observable
final class SettingsSelectionModel {
    var tab: SettingsTab {
        didSet { UserDefaults.standard.set(tab.rawValue, forKey: "settingsSelectedTab") }
    }

    init() {
        let raw = UserDefaults.standard.integer(forKey: "settingsSelectedTab")
        // Scan Rules used raw value 2. Keep people who last opened it in the
        // now-consolidated Scan Scope tab instead of stranding them on General.
        tab = raw == 2 ? .scanScope : (SettingsTab(rawValue: raw) ?? .general)
    }
}

/// Content for the currently-selected settings pane. The tab bar lives on the
/// window's `NSToolbar` (see `SettingsWindowController`), not in here, so we get
/// the native System-Settings-style icon tab bar without a SwiftUI `Settings`
/// scene (which would reintroduce the idle-layout hosting views from bug #9).
struct SettingsView: View {
    @State private var settingsStore = SettingsStore.shared
    @State private var scanService = ScanService.shared
    let selection: SettingsSelectionModel
    @State private var isApplyingScopeChanges = false

    var body: some View {
        VStack(spacing: 0) {
            if scanService.isScanning {
                scanActivityBanner
            }

            Group {
                switch selection.tab {
                case .general:
                    GeneralSettingsTab(settingsStore: settingsStore)
                case .scanScope:
                    ScanScopeSettingsTab(settingsStore: settingsStore, isApplyingScopeChanges: $isApplyingScopeChanges)
                case .troubleshooting:
                    TroubleshootingSettingsTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 520, height: 480)
        .disabled(isApplyingScopeChanges)
        .overlay {
            if isApplyingScopeChanges {
                Color.black.opacity(0.12)
                    .ignoresSafeArea()
                    .allowsHitTesting(true)
            }
        }
    }

    private var scanActivityBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.system(size: 11))
            Text("Scan running — scan scope changes are available when it finishes.")
                .font(.system(size: 11))
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

// MARK: - General Tab

private struct GeneralSettingsTab: View {
    @Bindable var settingsStore: SettingsStore

    private var appVersionText: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
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

                if MenuBarManager.shared?.isUpdaterAvailable == true {
                    Section("Updates") {
                        Button("Check for Updates…") {
                            MenuBarManager.shared?.checkForUpdates()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .formStyle(.grouped)
            .hiddenScrollIndicators()

            Spacer(minLength: 0)

            Divider()

            Text(appVersionText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
    }
}

// MARK: - Troubleshooting Tab

private struct TroubleshootingSettingsTab: View {
    @State private var baselineService = BaselineService.shared
    @State private var feedbackMessage = ""
    @State private var feedbackEmail = ""
    @State private var feedbackNotice = ""
    @State private var feedbackNoticeIsError = false
    @State private var diagnosticsNotice = ""
    @State private var diagnosticsNoticeIsError = false
    @State private var isSendingFeedback = false
    @State private var isResetting = false
    @State private var isCompactingDatabase = false
    @State private var showDeleteSnapshotsConfirmation = false
    @State private var compactedNotice = ""
    @State private var compactedNoticeIsError = false
    @State private var resetNotice = ""
    @FocusState private var feedbackFocused: Bool

    var body: some View {
        Form {
            Section("Send Feedback") {
                Text("Prunr is in alpha, and your feedback helps shape it. Tell us what’s working, what isn’t, or what you’d love to see.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: $feedbackMessage)
                    .focused($feedbackFocused)
                    .frame(minHeight: 110)
                    .accessibilityLabel("Feedback message")

                TextField("Email for a reply (optional)", text: $feedbackEmail)
                    .textFieldStyle(.roundedBorder)

                Button {
                    sendFeedback()
                } label: {
                    HStack(spacing: 8) {
                        if isSendingFeedback {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "paperplane")
                        }
                        Text(isSendingFeedback ? "Sending…" : "Send Feedback")
                    }
                }
                .disabled(isSendingFeedback || feedbackMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if !feedbackNotice.isEmpty {
                    Text(feedbackNotice)
                        .font(.caption)
                        .foregroundStyle(feedbackNoticeIsError ? .red : .green)
                }

                if feedbackNoticeIsError {
                    Button("Reveal Diagnostics Report in Finder") {
                        _ = MenuBarManager.shared?.generateDiagnosticsReport()
                    }
                }
            }

            Section("Diagnostics") {
                Button {
                    let url = MenuBarManager.shared?.generateDiagnosticsReport()
                    if url != nil {
                        diagnosticsNotice = "Report saved and revealed in Finder. Send it over to help diagnose CPU issues."
                        diagnosticsNoticeIsError = false
                    } else {
                        diagnosticsNotice = "Could not write diagnostics report."
                        diagnosticsNoticeIsError = true
                    }
                } label: {
                    Label("Generate Diagnostics Report", systemImage: "stethoscope")
                }

                if !diagnosticsNotice.isEmpty {
                    Text(diagnosticsNotice)
                        .font(.caption)
                        .foregroundStyle(diagnosticsNoticeIsError ? .red : .secondary)
                }
            }

            Section("Data Maintenance") {
                Text("Prunr automatically keeps its data tidy. Use these only when troubleshooting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    compactDatabase()
                } label: {
                    Label(
                        isCompactingDatabase ? "Compacting Database…" : "Compact Database",
                        systemImage: "externaldrive.badge.timemachine"
                    )
                }
                .disabled(isResetting || isCompactingDatabase)

                if !compactedNotice.isEmpty {
                    Text(compactedNotice)
                        .font(.caption)
                        .foregroundStyle(compactedNoticeIsError ? .red : .green)
                }

                Button(role: .destructive) {
                    showDeleteSnapshotsConfirmation = true
                } label: {
                    Label(
                        isResetting ? "Resetting Prunr…" : "Reset Prunr Data",
                        systemImage: "trash"
                    )
                }
                .disabled(isResetting || isCompactingDatabase)

                if !resetNotice.isEmpty {
                    Text(resetNotice)
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
        }
        .formStyle(.grouped)
        .hiddenScrollIndicators()
        .confirmationDialog(
            "Reset Prunr data?",
            isPresented: $showDeleteSnapshotsConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset Prunr Data", role: .destructive) {
                resetSnapshots()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes saved snapshots and growth history. Your scan folders stay selected.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusFeedback)) { _ in
            feedbackFocused = true
        }
    }

    private func sendFeedback() {
        let message = feedbackMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        guard let diagnostics = MenuBarManager.shared?.prepareDiagnosticsAttachment() else {
            feedbackNotice = "Could not prepare diagnostics. Reveal the report in Finder and send it manually."
            feedbackNoticeIsError = true
            return
        }

        isSendingFeedback = true
        feedbackNotice = ""
        feedbackNoticeIsError = false
        Task {
            do {
                try await FeedbackService.send(
                    message: message,
                    email: feedbackEmail.trimmingCharacters(in: .whitespacesAndNewlines),
                    diagnostics: diagnostics
                )
                feedbackMessage = ""
                feedbackNotice = "Feedback sent. Thank you."
                feedbackNoticeIsError = false
            } catch {
                // Keep message/email so the user can retry; always surface mailto fallback.
                feedbackNotice = FeedbackServiceError.userFacingMessage(for: error)
                feedbackNoticeIsError = true
            }
            isSendingFeedback = false
        }
    }

    private func compactDatabase() {
        isCompactingDatabase = true
        compactedNotice = ""
        compactedNoticeIsError = false

        Task {
            do {
                let report = try await DatabaseCleanupService.shared.compactDatabaseNow()
                let reclaimed = max(0, report.dbBytesBefore - report.dbBytesAfter)
                    + max(0, report.walBytesBefore - report.walBytesAfter)
                compactedNotice = "Reclaimed \(formattedBytes(reclaimed))."
                compactedNoticeIsError = false
            } catch {
                compactedNotice = error.localizedDescription
                compactedNoticeIsError = true
            }
            isCompactingDatabase = false
        }
    }

    private func resetSnapshots() {
        isResetting = true
        resetNotice = ""

        Task {
            if let manager = MenuBarManager.shared {
                await manager.performReset()
            } else {
                try? await baselineService.resetBaseline()
            }
            isResetting = false
            resetNotice = "Prunr data reset. Run a scan to start fresh."
        }
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
    @State private var permissionsService = PermissionsService.shared
    @State private var showingBasePathPicker = false
    @Binding var isApplyingScopeChanges: Bool
    @State private var showApplyConfirmation = false
    @State private var showingAppliedNotice = false
    @State private var applyStatusText = ""
    @State private var showsAllCommonPaths = false
    @State private var hasRequiredScanAccess = false
    @State private var blockedScanAccessLocations: [String] = []
    @State private var permissionRefreshTask: Task<Void, Never>? = nil
    private let initialCommonPathLimit = 5

    private var isScanInProgress: Bool {
        scanService.isScanning
    }

    private var additionalCommonPaths: [TrackedPath] {
        settingsStore.availableCommonPaths
            .filter { !settingsStore.isCoveredByMainScope($0) }
            .sorted { lhs, rhs in
                let lhsSelected = settingsStore.isCommonPathSelected(lhs)
                let rhsSelected = settingsStore.isCommonPathSelected(rhs)
                if lhsSelected != rhsSelected { return lhsSelected }
                if lhs.isRecommendedExtra != rhs.isRecommendedExtra {
                    return lhs.isRecommendedExtra
                }
                return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
    }

    private var visibleCommonPaths: [TrackedPath] {
        guard !showsAllCommonPaths else { return additionalCommonPaths }

        let selected = additionalCommonPaths.filter(settingsStore.isCommonPathSelected)
        let unselected = additionalCommonPaths.filter { !settingsStore.isCommonPathSelected($0) }
        return selected + unselected.prefix(max(0, initialCommonPathLimit - selected.count))
    }

    private var hiddenCommonPathCount: Int {
        max(0, additionalCommonPaths.count - visibleCommonPaths.count)
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

                        GroupBox("Scan Access") {
                            VStack(alignment: .leading, spacing: 8) {
                                Label(
                                    hasRequiredScanAccess
                                        ? "Prunr can access this scan scope"
                                        : "Prunr needs access to part of this scan scope",
                                    systemImage: hasRequiredScanAccess ? "checkmark.circle.fill" : "shield.fill"
                                )
                                .foregroundStyle(hasRequiredScanAccess ? .green : .orange)

                                if !hasRequiredScanAccess && !blockedScanAccessLocations.isEmpty {
                                    Text("Still blocked: \(blockedScanAccessLocations.prefix(4).joined(separator: ", "))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                if !hasRequiredScanAccess {
                                    Button("Open Privacy Settings") {
                                        openScanAccessSettings()
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                            }
                            .padding(.top, 4)
                        }

                        GroupBox("Additional Locations") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Add storage outside your primary folder. Subfolders are already included.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                if additionalCommonPaths.isEmpty {
                                    Text("All available common locations are already included in your scan folder.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    ForEach(visibleCommonPaths) { path in
                                        commonPathToggle(for: path)
                                    }

                                    if hiddenCommonPathCount > 0 {
                                        Button {
                                            withAnimation(.snappy(duration: 0.2)) {
                                                showsAllCommonPaths = true
                                            }
                                        } label: {
                                            Label("Show \(hiddenCommonPathCount) more locations", systemImage: "chevron.down")
                                        }
                                        .buttonStyle(.plain)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.blue)
                                    } else if showsAllCommonPaths, additionalCommonPaths.count > initialCommonPathLimit {
                                        Button {
                                            withAnimation(.snappy(duration: 0.2)) {
                                                showsAllCommonPaths = false
                                            }
                                        } label: {
                                            Label("Show fewer locations", systemImage: "chevron.up")
                                        }
                                        .buttonStyle(.plain)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.blue)
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
        .onAppear {
            refreshScanAccess()
        }
        .onDisappear {
            permissionRefreshTask?.cancel()
        }
        .onChange(of: settingsStore.enabledTrackedPaths) { _, _ in
            refreshScanAccess()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshScanAccess()
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

    private func refreshScanAccess() {
        let roots = settingsStore.enabledTrackedPaths.map(\.url.standardizedFileURL)
        permissionRefreshTask?.cancel()
        permissionRefreshTask = Task {
            let report = await permissionsService.evaluateScanScopeAccessAsync(scanRootURLs: roots)
            guard !Task.isCancelled else { return }
            hasRequiredScanAccess = report.isGranted
            blockedScanAccessLocations = report.blockedLocations
        }
    }

    private func openScanAccessSettings() {
        Task { await permissionsService.requestFullDiskAccess() }
    }
}

#Preview {
    SettingsView(selection: SettingsSelectionModel())
}
