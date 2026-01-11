import SwiftUI

/// Root view container providing Finder-style sidebar layout with NavigationSplitView
struct RootView: View {
    /// Currently selected path from the sidebar
    @State private var selectedPath: TrackedPath?

    /// Currently selected category for drill-down
    @State private var selectedCategory: DeltaCategory?

    /// Controls visibility of sidebar and detail columns
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// Shared view model for the detail content
    @State private var viewModel = MainViewModel()

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
            // Detail column - Main content with scan results view
            if let selectedPath = selectedPath {
                DetailContentView(
                    viewModel: viewModel,
                    selectedPath: selectedPath,
                    selectedCategory: $selectedCategory
                )
            } else {
                emptyDetailPlaceholder
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: selectedPath) { _, newPath in
            // When path changes, reset the view model and load new data
            if let newPath = newPath {
                Task { @MainActor in
                    await viewModel.updatePath(newPath)
                }
            }
        }
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

/// Main content view for a selected path
/// Shows comparison controls and the scan results view
struct DetailContentView: View {
    /// Shared view model (passed from RootView)
    /// With @Observable, we use @State to observe the reference
    @State var viewModel: MainViewModel

    let selectedPath: TrackedPath

    /// Binding for selected category (passed to RootView)
    @Binding var selectedCategory: DeltaCategory?

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

            // Main content - scan results or category detail
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

            // Rescan button
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task {
                        await viewModel.scanCurrentState()
                    }
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.isScanning)
                .help("Scan the current state of this path")
            }
        }
        .navigationTitle(selectedPath.displayName)
        .task {
            // Set the selected path in the view model (first time only)
            if viewModel.selectedPath?.id != selectedPath.id {
                viewModel.selectedPath = selectedPath

                // Register actions with AppActions for menu commands
                AppActions.shared.scanAction = {
                    Task {
                        await viewModel.scanCurrentState()
                    }
                }
                #if DEBUG
                AppActions.shared.generateTestDataAction = {
                    Task {
                        await viewModel.generateTestData()
                    }
                }
                #endif

                // Load snapshots and perform initial comparison
                await viewModel.loadSnapshots()
                await viewModel.compareSince()
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
                .controlSize(.small)
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

    /// Main content showing scan results, category detail, or empty state
    @ViewBuilder
    private var contentView: some View {
        if viewModel.deltas.isEmpty && !viewModel.isScanning {
            emptyState
        } else if let category = selectedCategory {
            // Show category detail view
            CategoryDetailView(
                category: category,
                deltas: viewModel.deltas,
                onBack: {
                    selectedCategory = nil
                }
            )
        } else {
            // Show scan results with categories
            ScanResultsView(
                deltas: viewModel.deltas,
                selectedCategory: $selectedCategory
            )
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

                Text("Create your first snapshot to see disk usage changes")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                // Prominent "Scan Now" button for first-time users
                Button {
                    Task {
                        await viewModel.scanCurrentState()
                    }
                } label: {
                    Label("Scan Now", systemImage: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                }
                .controlSize(.large)
                .disabled(viewModel.isScanning)
                .help("Start scanning this folder (⌘R)")

            } else {
                Text("No changes found")
                    .font(.headline)
                Text("Try changing the comparison interval or scanning again")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                // Smaller "Rescan" button for subsequent use
                Button {
                    Task {
                        await viewModel.scanCurrentState()
                    }
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .controlSize(.regular)
                .disabled(viewModel.isScanning)
                .help("Create a new snapshot to compare (⌘R)")
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    RootView()
}
