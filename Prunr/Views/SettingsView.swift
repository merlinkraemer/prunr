import SwiftUI
import AppKit

extension Notification.Name {
    static let focusFeedback = Notification.Name("com.prunr.focusFeedback")
}

enum SettingsTab: Int, CaseIterable {
    case general = 0
    case folder = 1
    case feedback = 3
    case developer = 4

    var title: String {
        switch self {
        case .general: return "General"
        case .folder: return "Folder"
        case .feedback: return "Feedback"
        case .developer: return "Developer"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gear"
        case .folder: return "folder"
        case .feedback: return "bubble.left"
        case .developer: return "hammer"
        }
    }

    var toolbarIdentifier: NSToolbarItem.Identifier {
        NSToolbarItem.Identifier("settings.tab.\(rawValue)")
    }

    static func from(toolbarIdentifier identifier: NSToolbarItem.Identifier) -> SettingsTab? {
        allCases.first { $0.toolbarIdentifier == identifier }
    }

    static func visibleTabs(devMode: Bool) -> [SettingsTab] {
        devMode ? allCases : allCases.filter { $0 != .developer }
    }

    static func restored(rawValue: Int, devMode: Bool) -> SettingsTab {
        let legacyScanRules = 2
        let tab = rawValue == legacyScanRules ? .folder : (SettingsTab(rawValue: rawValue) ?? .general)
        return visibleTabs(devMode: devMode).contains(tab) ? tab : .general
    }
}

@MainActor
@Observable
final class SettingsSelectionModel {
    var tab: SettingsTab {
        didSet { UserDefaults.standard.set(tab.rawValue, forKey: "settingsSelectedTab") }
    }

    convenience init() {
        self.init(devMode: DevMode.shared.isEnabled)
    }

    init(devMode: Bool) {
        tab = SettingsTab.restored(
            rawValue: UserDefaults.standard.integer(forKey: "settingsSelectedTab"),
            devMode: devMode
        )
    }
}

struct SettingsView: View {
    @State private var settingsStore = SettingsStore.shared
    @State private var devMode = DevMode.shared
    let selection: SettingsSelectionModel
    @State private var isApplyingScopeChanges = false

    private var shownTab: SettingsTab {
        SettingsTab.visibleTabs(devMode: devMode.isEnabled).contains(selection.tab) ? selection.tab : .general
    }

    var body: some View {
        Group {
            switch shownTab {
            case .general:
                GeneralSettingsTab(settingsStore: settingsStore)
            case .folder:
                FolderSettingsTab(settingsStore: settingsStore, isApplyingScopeChanges: $isApplyingScopeChanges)
            case .feedback:
                FeedbackSettingsTab()
            case .developer:
                DeveloperSettingsTab()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(width: 560, height: 480)
        .disabled(isApplyingScopeChanges)
        .overlay {
            if isApplyingScopeChanges {
                Color.black.opacity(0.12)
                    .ignoresSafeArea()
                    .allowsHitTesting(true)
            }
        }
    }
}

private struct SettingsRow<Trailing: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
    }
}

private enum SettingsDates {
    static func relative(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter.string(from: date)
    }

    static func watchingSince(feed: ChangeFeedResult?) -> Date? {
        feed?.feed?.watchingSince ?? HistoryStart.stored()
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @Bindable var settingsStore: SettingsStore
    @State private var manager = MenuBarManager.shared
    @State private var checksAutomatically = MenuBarManager.shared?.automaticallyChecksForUpdates ?? false
    @State private var showStartOverConfirmation = false
    @State private var isStartingOver = false
    @State private var startOverNotice = ""

    private var isUpdaterAvailable: Bool {
        manager?.isUpdaterAvailable == true
    }

    private var versionText: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "Prunr \(short) (\(build))"
    }

    private var updateStatusText: String? {
        guard isUpdaterAvailable, let manager else { return nil }
        if manager.isUpdateAvailable, let version = manager.availableUpdateShortVersion {
            return "Version \(version) is available."
        }
        guard let lastCheck = manager.lastUpdateCheckDate else { return "Not checked yet." }
        return "Up to date. Last checked \(SettingsDates.relative(lastCheck))."
    }

    private var watchingSince: Date? {
        SettingsDates.watchingSince(feed: manager?.changeFeed)
    }

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch Prunr at login", isOn: $settingsStore.launchAtLogin)
                    .toggleStyle(.switch)
            }

            Section("Updates") {
                if isUpdaterAvailable {
                    Toggle("Check for updates automatically", isOn: $checksAutomatically)
                        .toggleStyle(.switch)
                        .onChange(of: checksAutomatically) { _, enabled in
                            manager?.automaticallyChecksForUpdates = enabled
                        }
                }

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(versionText)
                            .onTapGesture {
                                if NSEvent.modifierFlags.contains(.option) {
                                    DevMode.shared.toggle()
                                }
                            }
                        if let updateStatusText {
                            Text(updateStatusText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    if isUpdaterAvailable {
                        Button("Check Now") {
                            manager?.checkForUpdates()
                        }
                    }
                }
            }

            Section("History") {
                SettingsRow(
                    title: "Prunr keeps \(GrowthJournalService.historyWindowDays) days of changes",
                    detail: "Older days drop off the list on their own."
                ) {
                    if let watchingSince {
                        Text(EpisodeBuilder.watchingSinceLabel(watchingSince, calendar: .current))
                            .foregroundStyle(.secondary)
                    }
                }

                SettingsRow(
                    title: "Start over",
                    detail: startOverNotice.isEmpty ? "Clears the change history. Your folder stays the same." : startOverNotice
                ) {
                    Button(isStartingOver ? "Starting Over…" : "Start Over…") {
                        showStartOverConfirmation = true
                    }
                    .disabled(isStartingOver)
                }
            }
        }
        .formStyle(.grouped)
        .hiddenScrollIndicators()
        .onAppear {
            checksAutomatically = manager?.automaticallyChecksForUpdates ?? false
        }
        .confirmationDialog(
            "Start over?",
            isPresented: $showStartOverConfirmation,
            titleVisibility: .visible
        ) {
            Button("Start Over", role: .destructive) {
                startOver()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears the change history. Your folder stays the same.")
        }
    }

    private func startOver() {
        isStartingOver = true
        startOverNotice = ""

        Task {
            if let manager {
                await manager.performReset()
            } else {
                try? await BaselineService.shared.resetBaseline()
            }
            isStartingOver = false
            startOverNotice = "History cleared. Run a scan to start again."
        }
    }
}

// MARK: - Folder

private struct FolderSettingsTab: View {
    @Bindable var settingsStore: SettingsStore
    @State private var manager = MenuBarManager.shared
    @State private var baselineService = BaselineService.shared
    @State private var scanService = ScanService.shared
    @State private var permissionsService = PermissionsService.shared
    @State private var showingBasePathPicker = false
    @Binding var isApplyingScopeChanges: Bool
    @State private var showApplyConfirmation = false
    @State private var showingAppliedNotice = false
    @State private var applyStatusText = ""
    @State private var hasRequiredScanAccess: Bool? = nil
    @State private var blockedScanAccessLocations: [String] = []
    @State private var permissionRefreshTask: Task<Void, Never>? = nil

    private var isScanInProgress: Bool {
        scanService.isScanning
    }

    private var folder: ScanFolderName {
        ScanFolderName(path: settingsStore.mainBasePath)
    }

    private var accessDetail: String {
        guard hasRequiredScanAccess == false else {
            return "Lets Prunr see Mail, Messages and Safari data in \(folder.phrase)."
        }
        guard !blockedScanAccessLocations.isEmpty else {
            return "Needed to see Mail, Messages and Safari data in \(folder.phrase)."
        }
        return "Still blocked: \(blockedScanAccessLocations.prefix(4).joined(separator: ", "))"
    }

    private var outsideFolderBytes: Int64 {
        guard let manager else { return 0 }
        let inside = manager.sortedCategories.reduce(Int64(0)) { $0 + $1.currentSizeBytes }
        return max(0, manager.usedBytes - inside)
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                if isScanInProgress {
                    scanActivityBanner
                }

                Form {
                    Section {
                        HStack(spacing: 10) {
                            Image(systemName: folder.isHome ? "house.fill" : "folder.fill")
                                .foregroundStyle(.blue)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(folder.title)
                                Text(folder.displayPath)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Spacer(minLength: 8)

                            Button("Change…") {
                                showingBasePathPicker = true
                            }
                            .disabled(isScanInProgress)
                        }
                    } header: {
                        Text("Folder")
                    } footer: {
                        Text("Prunr lists what grows inside this folder. Changing it starts the history over.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Section("Access") {
                        SettingsRow(title: "Full Disk Access", detail: accessDetail) {
                            switch hasRequiredScanAccess {
                            case true?:
                                Label("Granted", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            case false?:
                                Button("Open Privacy Settings") {
                                    openScanAccessSettings()
                                }
                                .buttonStyle(.borderedProminent)
                            case nil:
                                EmptyView()
                            }
                        }
                    }

                    Section("Not watched") {
                        if outsideFolderBytes > 0 {
                            SettingsRow(
                                title: "\(formattedBytes(outsideFolderBytes)) outside \(folder.phrase)",
                                detail: "Shown as the last row in Categories."
                            ) {
                                Text("System, apps, other users")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text("Everything on this disk is inside \(folder.phrase).")
                        }
                    }
                }
                .formStyle(.grouped)
                .hiddenScrollIndicators()

                if settingsStore.hasPendingScopeChanges && !isApplyingScopeChanges {
                    Divider()

                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)

                        Text(isScanInProgress
                             ? "Apply is available when the current scan finishes."
                             : "Changing the folder starts your history over.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer()

                        Button("Apply") {
                            showApplyConfirmation = true
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isScanInProgress)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.orange.opacity(0.08))
                }

                if showingAppliedNotice {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Folder changed. History starts over.")
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
                applyingOverlay
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
            "Change the folder?",
            isPresented: $showApplyConfirmation,
            titleVisibility: .visible
        ) {
            Button("Change and Start Over", role: .destructive) {
                applyFolderChange()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Changing the folder starts your history over.")
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

    private var scanActivityBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.system(size: 11))
            Text("Scan running. You can change the folder when it finishes.")
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

    private var applyingOverlay: some View {
        ZStack {
            Color.black.opacity(0.08)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.blue)

                    Text("Starting over")
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

                    Text(applyStatusText.isEmpty ? "Clearing the old history." : applyStatusText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 240)

                    Text("Run a new scan from the menu bar to start watching.")
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

    private func applyFolderChange() {
        isApplyingScopeChanges = true
        applyStatusText = "Clearing the old history."

        Task {
            if (try? await performFolderChange()) != nil {
                settingsStore.clearPendingScopeChanges()
                showingAppliedNotice = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    showingAppliedNotice = false
                }
            }
            isApplyingScopeChanges = false
        }
    }

    private func performFolderChange() async throws {
        if let manager {
            applyStatusText = "Switching folders."
            try await manager.applyScopeChanges()
        } else {
            try await baselineService.resetBaseline()
            applyStatusText = "Cleaning up."
            await DatabaseCleanupService.shared.performAutoCleanup()
        }
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

// MARK: - Feedback

private struct FeedbackSettingsTab: View {
    @State private var feedbackMessage = ""
    @State private var feedbackEmail = ""
    @State private var feedbackNotice = ""
    @State private var feedbackNoticeIsError = false
    @State private var diagnosticsNotice = ""
    @State private var isSendingFeedback = false
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
            }

            Section {
                Button("Show Diagnostics Report in Finder") {
                    let url = MenuBarManager.shared?.generateDiagnosticsReport()
                    diagnosticsNotice = url == nil ? "Could not write the diagnostics report." : ""
                }
                .buttonStyle(.link)

                Text(diagnosticsNotice.isEmpty
                     ? "A diagnostics report is attached to your feedback automatically."
                     : diagnosticsNotice)
                    .font(.caption)
                    .foregroundStyle(diagnosticsNotice.isEmpty ? .secondary : Color.red)
            }
        }
        .formStyle(.grouped)
        .hiddenScrollIndicators()
        .onReceive(NotificationCenter.default.publisher(for: .focusFeedback)) { _ in
            feedbackFocused = true
        }
    }

    private func sendFeedback() {
        let message = feedbackMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        guard let diagnostics = MenuBarManager.shared?.prepareDiagnosticsAttachment() else {
            feedbackNotice = "Could not prepare diagnostics. Show the report in Finder and send it manually."
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
                feedbackNotice = FeedbackServiceError.userFacingMessage(for: error)
                feedbackNoticeIsError = true
            }
            isSendingFeedback = false
        }
    }
}

// MARK: - Developer

private struct DeveloperSettingsTab: View {
    @State private var devMode = DevMode.shared
    @State private var manager = MenuBarManager.shared
    @State private var scanService = ScanService.shared
    @State private var perfLogging = PerfLogging.isEnabled()
    @State private var isCompacting = false
    @State private var databaseNotice = ""
    @State private var diagnosticsNotice = ""
    @State private var databaseBytes: Int64? = nil

    private var databaseURL: URL? {
        DatabaseManager.shared.databasePath.map { URL(fileURLWithPath: $0) }
    }

    private var databaseDetail: String {
        guard let databaseURL else { return "Not open" }
        let folder = ScanFolderName(path: databaseURL.deletingLastPathComponent().path).displayPath
        guard let databaseBytes else { return folder }
        return "\(folder) · \(formattedBytes(databaseBytes))"
    }

    private var watchingSinceText: String {
        guard let since = SettingsDates.watchingSince(feed: manager?.changeFeed) else { return "Not started" }
        return EpisodeBuilder.watchingSinceLabel(since, calendar: .current)
    }

    private var lastFullScanText: String {
        guard let date = manager?.lastFullScanCompletedAt else { return "No full scan yet" }
        return "Last full scan \(SettingsDates.relative(date))"
    }

    private var isScanBusy: Bool {
        scanService.isScanning || manager?.isLoading == true || manager?.isAutoScanning == true
    }

    var body: some View {
        Form {
            Section {
                Picker("Show in panel", selection: $devMode.panelPreview) {
                    ForEach(PanelPreview.allCases) { preview in
                        Text(preview.title).tag(preview)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Panel preview")
            } footer: {
                Text("Overrides what the panel shows until you pick Live or quit. No data is touched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Storage balance header", isOn: Binding(
                    get: { devMode.showsBalanceHeader },
                    set: { devMode.setShowsBalanceHeader($0) }
                ))
                .toggleStyle(.switch)
            } header: {
                Text("Experiments")
            } footer: {
                Text("Replaces This week with used storage that follows the scrolled date.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Data") {
                SettingsRow(title: "History start", detail: watchingSinceText) {
                    Button("Reset") {
                        HistoryStart.reset()
                        Task { await manager?.refreshChangeFeed() }
                    }
                }

                SettingsRow(title: "Full scan", detail: lastFullScanText) {
                    Button("Scan Now") {
                        Task { _ = await manager?.loadInventory() }
                    }
                    .disabled(isScanBusy)
                }

                SettingsRow(title: "Database", detail: databaseNotice.isEmpty ? databaseDetail : databaseNotice) {
                    HStack(spacing: 8) {
                        Button(isCompacting ? "Compacting…" : "Compact") {
                            compactDatabase()
                        }
                        .disabled(isCompacting)

                        Button("Show in Finder") {
                            if let databaseURL {
                                NSWorkspace.shared.activateFileViewerSelecting([databaseURL])
                            }
                        }
                        .disabled(databaseURL == nil)
                    }
                }
            }

            Section("Diagnostics") {
                Toggle("Perf logging", isOn: $perfLogging)
                    .toggleStyle(.switch)
                    .onChange(of: perfLogging) { _, enabled in
                        PerfLogging.setEnabled(enabled)
                    }

                SettingsRow(title: "Diagnostics report", detail: diagnosticsNotice.isEmpty ? nil : diagnosticsNotice) {
                    HStack(spacing: 8) {
                        Button("Copy") {
                            copyDiagnostics()
                        }
                        Button("Show Log") {
                            _ = manager?.generateDiagnosticsReport()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .hiddenScrollIndicators()
        .onAppear {
            refreshDatabaseSize()
        }
    }

    private func refreshDatabaseSize() {
        guard let path = databaseURL?.path else {
            databaseBytes = nil
            return
        }
        databaseBytes = [path, path + "-wal"].reduce(Int64(0)) { total, filePath in
            let size = (try? FileManager.default.attributesOfItem(atPath: filePath)[.size] as? Int64) ?? 0
            return total + size
        }
    }

    private func compactDatabase() {
        isCompacting = true
        databaseNotice = ""

        Task {
            do {
                let report = try await DatabaseCleanupService.shared.compactDatabaseNow()
                let reclaimed = max(0, report.dbBytesBefore - report.dbBytesAfter)
                    + max(0, report.walBytesBefore - report.walBytesAfter)
                databaseNotice = "Reclaimed \(formattedBytes(reclaimed))."
            } catch {
                databaseNotice = error.localizedDescription
            }
            refreshDatabaseSize()
            isCompacting = false
        }
    }

    private func copyDiagnostics() {
        guard let data = manager?.prepareDiagnosticsAttachment() else {
            diagnosticsNotice = "Could not write the diagnostics report."
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(String(decoding: data, as: UTF8.self), forType: .string)
        diagnosticsNotice = "Copied to the clipboard."
    }
}

#Preview {
    SettingsView(selection: SettingsSelectionModel())
}
