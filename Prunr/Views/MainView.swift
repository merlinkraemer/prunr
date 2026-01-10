import SwiftUI

// MARK: - Focused Values for Menu Commands

struct ScanActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct RefreshActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

#if DEBUG
struct GenerateTestDataActionKey: FocusedValueKey {
    typealias Value = () -> Void
}
#endif

extension FocusedValues {
    var scanAction: (() -> Void)? {
        get { self[ScanActionKey.self] }
        set { self[ScanActionKey.self] = newValue }
    }

    var refreshAction: (() -> Void)? {
        get { self[RefreshActionKey.self] }
        set { self[RefreshActionKey.self] = newValue }
    }

    #if DEBUG
    var generateTestDataAction: (() -> Void)? {
        get { self[GenerateTestDataActionKey.self] }
        set { self[GenerateTestDataActionKey.self] = newValue }
    }
    #endif
}

/// Main window displaying snapshot comparison and delta list
struct MainView: View {
    @State private var viewModel = MainViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Error banner
                if let error = viewModel.errorMessage {
                    errorBanner(error)
                }

                // Scanning progress
                if viewModel.isScanning {
                    scanningBanner
                }

                // Snapshot selection
                snapshotPickers

                Divider()

                // Main content
                contentView
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task {
                            #if DEBUG
                            // Dev mode: scan a small folder for faster testing
                            let testPath = (NSHomeDirectory() as NSString).appendingPathComponent("Desktop")
                            await viewModel.scan(path: testPath)
                            #else
                            // Release: scan full home directory
                            await viewModel.scan(path: NSHomeDirectory())
                            #endif
                        }
                    } label: {
                        Label("Scan", systemImage: "arrow.clockwise")
                    }
                    .disabled(viewModel.isScanning)
                }
            }
            .navigationTitle("Prunr")
        }
        .task {
            await viewModel.loadSnapshots()
            viewModel.autoSelectSnapshots()
            if viewModel.selectedBeforeSnapshot != nil && viewModel.selectedAfterSnapshot != nil {
                await viewModel.compareSnapshots()
            }
        }
        .onChange(of: viewModel.selectedBeforeSnapshot) {
            Task {
                await viewModel.compareSnapshots()
            }
        }
        .onChange(of: viewModel.selectedAfterSnapshot) {
            Task {
                await viewModel.compareSnapshots()
            }
        }
        .focusedValue(\.scanAction) {
            Task {
                #if DEBUG
                // Dev mode: scan test folder inside project
                await viewModel.scan(path: viewModel.testFolderPath)
                #else
                await viewModel.scan(path: NSHomeDirectory())
                #endif
            }
        }
        .focusedValue(\.refreshAction) {
            Task {
                await viewModel.refreshSnapshots()
            }
        }
        #if DEBUG
        .focusedValue(\.generateTestDataAction) {
            Task {
                await viewModel.generateTestData()
            }
        }
        #endif
    }

    // MARK: - Subviews

    /// Error banner with dismiss and copy buttons
    @ViewBuilder
    private func errorBanner(_ message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.callout)
                .lineLimit(3)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Copy error to clipboard")
            Button {
                viewModel.dismissError()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(.red.opacity(0.1))
    }

    /// Scanning progress banner
    private var scanningBanner: some View {
        HStack {
            ProgressView()
                .scaleEffect(0.7)
            Text("Scanning: \(viewModel.scanProgress)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.blue.opacity(0.05))
    }

    /// Snapshot pickers for before/after selection
    private var snapshotPickers: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading) {
                Text("Before")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Before", selection: $viewModel.selectedBeforeSnapshot) {
                    Text("Select...").tag(nil as Snapshot?)
                    ForEach(viewModel.snapshots) { snapshot in
                        Text(formattedDate(snapshot.createdAt))
                            .tag(snapshot as Snapshot?)
                    }
                }
                .labelsHidden()
            }

            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading) {
                Text("After")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("After", selection: $viewModel.selectedAfterSnapshot) {
                    Text("Select...").tag(nil as Snapshot?)
                    ForEach(viewModel.snapshots) { snapshot in
                        Text(formattedDate(snapshot.createdAt))
                            .tag(snapshot as Snapshot?)
                    }
                }
                .labelsHidden()
            }

            Spacer()
        }
        .padding()
    }

    /// Main content showing either deltas list or empty state
    @ViewBuilder
    private var contentView: some View {
        if viewModel.deltas.isEmpty {
            emptyState
        } else {
            deltasList
        }
    }

    /// Empty state view
    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            if viewModel.snapshots.isEmpty {
                Text("No snapshots yet")
                    .font(.headline)
                Text("Click Scan to create your first snapshot")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if viewModel.snapshots.count == 1 {
                Text("Need two snapshots to compare")
                    .font(.headline)
                Text("Click Scan again to create another snapshot")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("Select two snapshots to compare")
                    .font(.headline)
                Text("Use the pickers above to choose snapshots")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// List of delta rows
    private var deltasList: some View {
        List(viewModel.deltas) { delta in
            DeltaRowView(delta: delta)
        }
        .listStyle(.inset)
    }

    // MARK: - Helpers

    /// Format date for snapshot picker
    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

#Preview {
    MainView()
}
