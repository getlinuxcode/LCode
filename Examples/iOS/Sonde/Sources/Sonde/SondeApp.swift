import SwiftUI

@main
struct SondeApp: App {
    @State private var store = TaskStore()
    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
        }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            Tab("Tasks", systemImage: "checklist") { TasksView() }
            Tab("Settings", systemImage: "gear") { SettingsView() }
        }
    }
}
