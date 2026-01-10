import SwiftUI

/// Finder-style sidebar showing tracked paths in Favorites and Custom sections
/// Allows adding new paths via file picker and removing custom paths
struct SidebarView: View {
    /// Binding to the currently selected path
    @Binding var selectedPath: TrackedPath?

    /// Path manager for handling tracked paths
    private let pathManager: PathManager

    /// Controls file importer for adding new paths
    @State private var isImporting = false

    init(selectedPath: Binding<TrackedPath?>, pathManager: PathManager = PathManager()) {
        self._selectedPath = selectedPath
        self.pathManager = pathManager
    }

    var body: some View {
        List(selection: $selectedPath) {
            // Section: Favorites (default paths)
            Section("Favorites") {
                ForEach(pathManager.activeDefaults) { path in
                    PathRow(path: path)
                        .tag(path)
                }
            }

            // Section: Custom (user-added paths)
            Section("Custom") {
                ForEach(pathManager.customPaths) { path in
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

    /// Deletes the custom paths at the specified offsets
    /// - Parameter offsets: IndexSet of paths to delete from custom paths
    private func deleteCustomPaths(at offsets: IndexSet) {
        let customPaths = pathManager.customPaths
        for index in offsets {
            let pathToDelete = customPaths[index]
            pathManager.removePath(pathToDelete)
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
                if let newPath = pathManager.addPath(url: url) {
                    // Auto-select the newly added path
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
    let samplePath = TrackedPath.defaultPaths.first ?? TrackedPath(url: FileManager.default.homeDirectoryForCurrentUser, displayName: "Home")
    return SidebarView(
        selectedPath: .constant(samplePath),
        pathManager: PathManager()
    )
}
