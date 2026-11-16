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

// MARK: - Animations (acceptées ; les changements sont pour l'instant appliqués sans transition)

public struct Animation: Equatable, Sendable {
    let name: String
    public static let `default` = Animation(name: "default")
    public static let linear = Animation(name: "linear")
    public static let easeIn = Animation(name: "easeIn")
    public static let easeOut = Animation(name: "easeOut")
    public static let easeInOut = Animation(name: "easeInOut")
    public static let spring = Animation(name: "spring")
    public static let bouncy = Animation(name: "bouncy")
    public static let smooth = Animation(name: "smooth")
    public static let snappy = Animation(name: "snappy")
    public static let interactiveSpring = Animation(name: "interactiveSpring")
    public static func linear(duration: Double) -> Animation { .linear }
    public static func easeIn(duration: Double) -> Animation { .easeIn }
    public static func easeOut(duration: Double) -> Animation { .easeOut }
    public static func easeInOut(duration: Double) -> Animation { .easeInOut }
    public static func spring(response: Double = 0.5, dampingFraction: Double = 0.825, blendDuration: Double = 0) -> Animation { .spring }
    public static func spring(duration: Double, bounce: Double = 0) -> Animation { .spring }
    public func speed(_ speed: Double) -> Animation { self }
    public func delay(_ delay: Double) -> Animation { self }
    public func repeatCount(_ count: Int, autoreverses: Bool = true) -> Animation { self }
    public func repeatForever(autoreverses: Bool = true) -> Animation { self }
}

@discardableResult
public func withAnimation<Result>(_ animation: Animation? = .default, _ body: () throws -> Result) rethrows -> Result {
    try body()
}

public struct AnyTransition: Sendable {
    public static let identity = AnyTransition()
    public static let opacity = AnyTransition()
    public static let slide = AnyTransition()
    public static let scale = AnyTransition()
    public static func scale(scale: CGFloat, anchor: UnitPoint = .center) -> AnyTransition { AnyTransition() }
    public static func move(edge: Edge) -> AnyTransition { AnyTransition() }
    public static func push(from edge: Edge) -> AnyTransition { AnyTransition() }
    public static func asymmetric(insertion: AnyTransition, removal: AnyTransition) -> AnyTransition { AnyTransition() }
    public func combined(with other: AnyTransition) -> AnyTransition { self }
    public func animation(_ animation: Animation?) -> AnyTransition { self }
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

extension View {
    public func animation<V: Equatable>(_ animation: Animation?, value: V) -> some View { self }
    public func transition(_ t: AnyTransition) -> some View { self }
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
