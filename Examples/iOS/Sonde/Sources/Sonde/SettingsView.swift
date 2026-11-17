import SwiftUI

struct SettingsView: View {
    @AppStorage("notifications") private var notifications = true
    @State private var volume = 0.5
    @State private var priority = TaskItem.Priority.normal
    @State private var date = Date()
    @State private var count = 3

    var body: some View {
        NavigationStack {
            Form {
                Section("General") {
                    Toggle("Notifications", isOn: $notifications)
                    Slider(value: $volume, in: 0...1)
                    Stepper("Count: \(count)", value: $count, in: 0...10)
                    Picker("Priority", selection: $priority) {
                        ForEach(TaskItem.Priority.allCases) { Text($0.rawValue).tag($0) }
                    }
                    DatePicker("Date", selection: $date)
                }
                Section {
                    ProgressView(value: volume)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 60))]) {
                        ForEach(0..<6) { i in
                            RoundedRectangle(cornerRadius: 8).fill(.blue.gradient).frame(height: 60)
                                .overlay { Text("\(i)").font(.caption.bold()) }
                        }
                    }
                    GeometryReader { proxy in
                        Text("Width \(Int(proxy.size.width))")
                    }
                    .frame(height: 30)
                    ScrollView(.horizontal) { LazyHStack { ForEach(0..<10) { Text("\($0)") } } }
                    Link("Website", destination: URL(string: "https://example.com")!)
                    AsyncImage(url: URL(string: "https://example.com/a.png"))
                }
            }
            .navigationTitle("Settings")
        }
    }
}
