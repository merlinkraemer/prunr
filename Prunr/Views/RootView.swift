import SwiftUI

/// Root view container providing Finder-style sidebar layout with NavigationSplitView
/// Replaces the previous single-pane NavigationStack approach
struct RootView: View {
    /// Currently selected path from the sidebar
    @State private var selectedPath: TrackedPath?

    /// Controls visibility of sidebar and detail columns
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // Sidebar column
            SidebarView(selectedPath: $selectedPath)
                .navigationSplitViewColumnWidth(
                    min: 150,
                    ideal: 200,
                    max: 300
                )
        } detail: {
            // Detail column - MainView content
            if let selectedPath = selectedPath {
                DetailContentView(selectedPath: selectedPath)
            } else {
                emptyDetailPlaceholder
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    // MARK: - Placeholder Views

    /// Placeholder shown when no path is selected in the sidebar
    private var emptyDetailPlaceholder: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "sidebar.left")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("Select a path to scan")
                .font(.headline)
            Text("Choose a location from the sidebar to view its delta history")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Detail Content View

/// Temporary detail view wrapper for MainView content
/// In future phases, this will become the three-column category view
struct DetailContentView: View {
    let selectedPath: TrackedPath
    @State private var viewModel = MainViewModel()

    var body: some View {
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
            #if DEBUG
            ToolbarItem(placement: .automatic) {
                Button("Generate Data") {
                    Task {
                        await viewModel.generateTestData()
                    }
                }
            }
            #endif

            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task {
                        await viewModel.scan(path: selectedPath.url.path)
                    }
                } label: {
                    Label("Scan", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.isScanning)
            }
        }
        .navigationTitle(selectedPath.displayName)
        .task {
            // Register actions with AppActions for menu commands
            AppActions.shared.scanAction = {
                Task {
                    await viewModel.scan(path: selectedPath.url.path)
                }
            }
            AppActions.shared.refreshAction = {
                Task {
                    await viewModel.refreshSnapshots()
                }
            }
            #if DEBUG
            AppActions.shared.generateTestDataAction = {
                Task {
                    await viewModel.generateTestData()
                }
            }
            #endif

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
    RootView()
}
