import SwiftUI

/// Finder-style sidebar showing tracked paths in Favorites and Custom sections
/// Allows adding new paths via file picker and removing custom paths
struct SidebarView: View {
    /// Binding to the currently selected path
    @Binding var selectedPath: TrackedPath?

    /// Shared settings store (single source of truth for paths)
    @State private var settingsStore = SettingsStore.shared

    /// Controls file importer for adding new paths
    @State private var isImporting = false

    var body: some View {
        List(selection: $selectedPath) {
            // Section: Favorites (default paths)
            Section("Favorites") {
                ForEach(activeDefaultPaths) { path in
                    PathRow(path: path)
                        .tag(path)
                }
            }

            // Section: Custom (user-added paths)
            Section("Custom") {
                ForEach(activeCustomPaths) { path in
                    PathRow(path: path)
                        .tag(path)
                }
                .onDelete(perform: deleteCustomPaths)
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isImporting = true
                } label: {
                    Label("Add Path", systemImage: "plus")
                }
                .help("Add a new folder to track")
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
    }

    // MARK: - Actions

    private var activeDefaultPaths: [TrackedPath] {
        settingsStore.allTrackedPaths.filter { $0.isDefault && settingsStore.isPathEnabled($0) }
    }

    private var activeCustomPaths: [TrackedPath] {
        settingsStore.customTrackedPaths.filter { settingsStore.isPathEnabled($0) }
    }

    /// Deletes the custom paths at the specified offsets
    /// - Parameter offsets: IndexSet of paths to delete from custom paths
    private func deleteCustomPaths(at offsets: IndexSet) {
        let customPaths = activeCustomPaths
        for index in offsets {
            let pathToDelete = customPaths[index]
            settingsStore.removeTrackedPath(pathToDelete)
        }
    }

    /// Handles the result of the file importer
    /// - Parameter result: Result containing the selected URLs
    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            if let url = urls.first {
                // Get security-scoped access if needed
                guard url.startAccessingSecurityScopedResource() else {
                    return
                }
                defer {
                    url.stopAccessingSecurityScopedResource()
                }

                // Add the path
                let newPath = TrackedPath(
                    url: url,
                    displayName: url.lastPathComponent,
                    isDefault: false
                )
                settingsStore.addTrackedPath(newPath)
                settingsStore.setPathEnabled(newPath, enabled: true)

                if settingsStore.customTrackedPaths.contains(where: { $0.id == newPath.id }) {
                    selectedPath = newPath
                }
            }
        case .failure(let error):
            print("Failed to import path: \(error)")
        }
    }
}

// MARK: - Path Row View

/// Single row in the sidebar showing a tracked path
struct PathRow: View {
    let path: TrackedPath

    var body: some View {
        Label {
            Text(path.displayName)
        } icon: {
            Image(systemName: "folder.fill")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Preview

#Preview {
    SidebarView(
        selectedPath: .constant(TrackedPath.defaultPaths.first ?? TrackedPath(url: FileManager.default.homeDirectoryForCurrentUser, displayName: "Home"))
    )
}
