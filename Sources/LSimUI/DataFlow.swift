import Foundation

// MARK: - Objets dans l'environnement : .environment(objet) / @Environment(Type.self)

extension EnvironmentValues {
    func object<T: AnyObject>(_ type: T.Type) -> T {
        guard let object = objects[ObjectIdentifier(type)] as? T else {
            fatalError("Aucun objet \(T.self) dans l'environnement : ajoutez .environment(…) à une vue parente.")
        }
        return object
    }
}

extension View {
    /// Place un objet observable dans l'environnement (lu par `@Environment(Type.self)`).
    public func environment<T: AnyObject>(_ object: T?) -> some View {
        modifier(_EnvironmentModifier { env in
            if let object { env.objects[ObjectIdentifier(T.self)] = object }
        })
    }
}

// MARK: - @Bindable

/// Liaisons vers les propriétés d'un objet observable : `@Bindable var store = store` puis `$store.titre`.
@propertyWrapper
@dynamicMemberLookup
public struct Bindable<Value> {
    public var wrappedValue: Value

    public init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
    public init(_ wrappedValue: Value) { self.wrappedValue = wrappedValue }
    public init(projectedValue: Bindable<Value>) { self = projectedValue }

    public var projectedValue: Bindable<Value> { self }

    public subscript<Subject>(dynamicMember keyPath: ReferenceWritableKeyPath<Value, Subject>) -> Binding<Subject> {
        let object = wrappedValue
        return Binding(get: { object[keyPath: keyPath] }, set: { object[keyPath: keyPath] = $0 })
    }
}

// MARK: - @AppStorage

/// Valeur persistée dans les préférences (UserDefaults) ; la vue est redessinée quand elle change.
@propertyWrapper
public struct AppStorage<Value>: _DynamicProperty {
    final class Box { weak var graph: ViewGraph? }

    let key: String
    let store: UserDefaults
    let read: (Any?) -> Value?
    let write: (Value) -> Any?
    let defaultValue: Value
    let box = Box()

    public init(wrappedValue: Value, _ key: String, store: UserDefaults? = nil) {
        self.key = key
        self.store = store ?? .standard
        self.defaultValue = wrappedValue
        self.read = { $0 as? Value }
        self.write = { $0 }
    }

    public var wrappedValue: Value {
        get { read(store.object(forKey: key)) ?? defaultValue }
        nonmutating set {
            store.set(write(newValue), forKey: key)
            box.graph?.invalidate()
        }
    }

    public var projectedValue: Binding<Value> {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0 })
    }

    func _install(_ context: _InstallContext) {
        box.graph = context.graph
    }
}

extension AppStorage where Value: RawRepresentable {
    public init(wrappedValue: Value, _ key: String, store: UserDefaults? = nil) {
        self.key = key
        self.store = store ?? .standard
        self.defaultValue = wrappedValue
        self.read = { ($0 as? Value.RawValue).flatMap(Value.init(rawValue:)) }
        self.write = { $0.rawValue }
    }
}

// MARK: - ForEach($tableau) { $élément in … }

extension Binding: Sequence where Value: MutableCollection {
    public typealias Element = Binding<Value.Element>
    public typealias Iterator = IndexingIterator<Binding<Value>>
}

extension Binding: Collection where Value: MutableCollection {
    public typealias Index = Value.Index
    public typealias Indices = Value.Indices
    public var startIndex: Index { wrappedValue.startIndex }
    public var endIndex: Index { wrappedValue.endIndex }
    public var indices: Indices { wrappedValue.indices }
    public func index(after i: Index) -> Index { wrappedValue.index(after: i) }

    public subscript(position: Index) -> Binding<Value.Element> {
        Binding<Value.Element>(get: { wrappedValue[position] }, set: { wrappedValue[position] = $0 })
    }
}

extension Binding: BidirectionalCollection where Value: BidirectionalCollection & MutableCollection {
    public func index(before i: Index) -> Index { wrappedValue.index(before: i) }
}

extension Binding: RandomAccessCollection where Value: RandomAccessCollection & MutableCollection {}

extension Binding: Identifiable where Value: Identifiable {
    public var id: Value.ID { wrappedValue.id }
}

extension RangeReplaceableCollection where Self: MutableCollection {
    /// Supprime les éléments aux positions données (utilisé avec `.onDelete`).
    public mutating func remove(atOffsets offsets: IndexSet) {
        for offset in offsets.sorted(by: >) {
            remove(at: index(startIndex, offsetBy: offset))
        }
    }

    /// Déplace des éléments (utilisé avec `.onMove`).
    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.sorted().map { self[index(startIndex, offsetBy: $0)] }
        remove(atOffsets: source)
        let shift = source.filter { $0 < destination }.count
        insert(contentsOf: moving, at: index(startIndex, offsetBy: destination - shift))
    }
}

public struct UnitPoint: Hashable, Sendable {
    public var x: CGFloat, y: CGFloat
    public init(x: CGFloat, y: CGFloat) { self.x = x; self.y = y }
    public static let center = UnitPoint(x: 0.5, y: 0.5)
    public static let top = UnitPoint(x: 0.5, y: 0)
    public static let bottom = UnitPoint(x: 0.5, y: 1)
    public static let leading = UnitPoint(x: 0, y: 0.5)
    public static let trailing = UnitPoint(x: 1, y: 0.5)
    public static let topLeading = UnitPoint(x: 0, y: 0)
    public static let topTrailing = UnitPoint(x: 1, y: 0)
    public static let bottomLeading = UnitPoint(x: 0, y: 1)
    public static let bottomTrailing = UnitPoint(x: 1, y: 1)
}


// MARK: - Tâches asynchrones : .task

struct _TaskModifier: _PrimitiveModifier {
    let action: @Sendable () async -> Void
    let id: AnyHashable?
    func _apply(_ context: BuildContext, _ content: (BuildContext) -> [LayoutNode]) -> [LayoutNode] {
        // Lancée à l'apparition (et relancée quand `id` change), comme dans SwiftUI.
        let key = context.path + "/task" + (id.map { "#\($0)" } ?? "")
        let action = self.action
        context.graph.registerAppear(key) { Task { await action() } }
        return content(context)
    }
}

extension View {
    public func task(priority: TaskPriority = .userInitiated, _ action: @escaping @Sendable () async -> Void) -> some View {
        modifier(_TaskModifier(action: action, id: nil))
    }

    public func task<T: Equatable>(id value: T, priority: TaskPriority = .userInitiated,
                                   _ action: @escaping @Sendable () async -> Void) -> some View {
        modifier(_TaskModifier(action: action, id: AnyHashable("\(value)")))
    }
}

// MARK: - dismiss

public struct DismissAction: Sendable {
    let action: @Sendable () -> Void
    public func callAsFunction() { action() }
}

private struct DismissKey: EnvironmentKey {
    static let defaultValue = DismissAction(action: {})
}

extension EnvironmentValues {
    public var dismiss: DismissAction {
        get { self[DismissKey.self] }
        set { self[DismissKey.self] = newValue }
    }
}
