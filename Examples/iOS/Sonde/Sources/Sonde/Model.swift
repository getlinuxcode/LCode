import SwiftUI
import Observation

struct TaskItem: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var done = false
    var priority: Priority = .normal
    enum Priority: String, CaseIterable, Identifiable { case low, normal, high; var id: Self { self } }
}

@Observable
final class TaskStore {
    var tasks: [TaskItem] = [TaskItem(title: "Buy bread"), TaskItem(title: "Call Mary", priority: .high)]
    func add(_ title: String) { tasks.append(TaskItem(title: title)) }
}
