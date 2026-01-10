import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack {
            Image(systemName: "folder.badge.gearshape")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text("Prunr")
                .font(.largeTitle)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
