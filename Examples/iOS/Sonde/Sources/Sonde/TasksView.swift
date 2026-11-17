import SwiftUI

struct TasksView: View {
    @Environment(TaskStore.self) private var store
    @State private var newTitle = ""
    @State private var showingSheet = false
    @State private var showAlert = false

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            List {
                ForEach($store.tasks) { $task in
                    HStack {
                        Image(systemName: task.done ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(task.done ? .green : .secondary)
                            .onTapGesture { withAnimation { task.done.toggle() } }
                        Text(task.title).strikethrough(task.done)
                        Spacer()
                        Label(task.priority.rawValue, systemImage: "flag")
                            .labelStyle(.iconOnly)
                    }
                    .swipeActions { Button("Delete", role: .destructive) {} }
                }
                .onDelete { store.tasks.remove(atOffsets: $0) }
            }
            .navigationTitle("Tasks")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSheet = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showingSheet) {
                Form {
                    TextField("Title", text: $newTitle)
                    Button("Add") { store.add(newTitle); showingSheet = false }
                }
                .presentationDetents([.medium])
            }
            .alert("Attention", isPresented: $showAlert) { Button("OK") {} }
            .searchable(text: $newTitle)
            .refreshable { }
            .task { try? await Task.sleep(for: .seconds(1)) }
        }
    }
}
