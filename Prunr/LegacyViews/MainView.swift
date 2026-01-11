import SwiftUI

/// Legacy main view - replaced by RootView with Finder-style sidebar
/// This file is kept for compatibility but is not actively used
struct MainView: View {
    @State private var viewModel = MainViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("This view has been replaced by RootView")
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("Prunr")
        }
    }
}

#Preview {
    MainView()
}
