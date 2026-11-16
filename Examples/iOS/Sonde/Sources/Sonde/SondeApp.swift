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
            Tab("Tâches", systemImage: "checklist") { TasksView() }
            Tab("Réglages", systemImage: "gear") { SettingsView() }
        }
    }
}
