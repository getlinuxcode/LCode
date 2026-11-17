import Combine
import Foundation

// Objets observables à la manière de Combine (ObservableObject, @Published) : @StateObject, @ObservedObject,
// @EnvironmentObject, .environmentObject(…) et .onReceive(…). Un changement annoncé par `objectWillChange`
// redessine la vue (sur le fil principal, une fois le changement fait).

extension ViewGraph {
    /// Abonne le graphe aux changements d'un objet (une seule fois par objet).
    func observe<T: ObservableObject>(_ object: T) {
        let id = ObjectIdentifier(object)
        if let entry = observed[id], entry.object === object { return }
        let token = object.objectWillChange.sink { [weak self] _ in
            // `objectWillChange` part avant la modification : le rendu se fait après, sur le fil principal.
            DispatchQueue.main.async { self?.invalidate() }
        }
        observed[id] = ObservedEntry(object: object, token: token)
    }
}

struct ObservedEntry {
    weak var object: AnyObject?
    let token: AnyCancellable
}

// MARK: - @StateObject

/// Objet créé une fois pour la vue et gardé tant qu'elle existe.
@propertyWrapper
public struct StateObject<ObjectType: ObservableObject>: _DynamicProperty {
    final class Box {
        let make: () -> ObjectType
        var object: ObjectType?
        init(_ make: @escaping () -> ObjectType) { self.make = make }
    }

    let box: Box

    public init(wrappedValue thunk: @autoclosure @escaping () -> ObjectType) {
        box = Box(thunk)
    }

    public var wrappedValue: ObjectType {
        if let object = box.object { return object }
        let object = box.make()
        box.object = object
        return object
    }

    public var projectedValue: ObservedObject<ObjectType>.Wrapper {
        ObservedObject<ObjectType>.Wrapper(object: wrappedValue)
    }

    func _install(_ context: _InstallContext) {
        let make = box.make
        let object = context.graph.persistent(context.key) { make() }
        box.object = object
        context.graph.observe(object)
    }
}

// MARK: - @ObservedObject

@propertyWrapper
public struct ObservedObject<ObjectType: ObservableObject>: _DynamicProperty {
    /// `$objet.propriété` : liaison vers une propriété de l'objet.
    @dynamicMemberLookup
    public struct Wrapper {
        let object: ObjectType
        public subscript<Subject>(dynamicMember keyPath: ReferenceWritableKeyPath<ObjectType, Subject>) -> Binding<Subject> {
            let object = self.object
            return Binding(get: { object[keyPath: keyPath] }, set: { object[keyPath: keyPath] = $0 })
        }
    }

    public var wrappedValue: ObjectType

    public init(wrappedValue: ObjectType) { self.wrappedValue = wrappedValue }
    public init(initialValue: ObjectType) { self.wrappedValue = initialValue }

    public var projectedValue: Wrapper { Wrapper(object: wrappedValue) }

    func _install(_ context: _InstallContext) {
        context.graph.observe(wrappedValue)
    }
}

// MARK: - @EnvironmentObject

@propertyWrapper
public struct EnvironmentObject<ObjectType: ObservableObject>: _DynamicProperty {
    final class Box { var object: ObjectType? }
    let box = Box()

    public init() {}

    public var wrappedValue: ObjectType {
        guard let object = box.object else {
            fatalError("Aucun objet \(ObjectType.self) dans l'environnement : ajoutez .environmentObject(…) à une vue parente.")
        }
        return object
    }

    public var projectedValue: ObservedObject<ObjectType>.Wrapper {
        ObservedObject<ObjectType>.Wrapper(object: wrappedValue)
    }

    func _install(_ context: _InstallContext) {
        guard let object = context.environment.objects[ObjectIdentifier(ObjectType.self)] as? ObjectType else { return }
        box.object = object
        context.graph.observe(object)
    }
}

extension View {
    /// Place un objet observable (Combine) dans l'environnement, lu par `@EnvironmentObject`.
    public func environmentObject<T: ObservableObject>(_ object: T) -> some View {
        modifier(_EnvironmentModifier { env in env.objects[ObjectIdentifier(T.self)] = object })
    }
}

// MARK: - .onReceive

struct _ReceiveModifier: _PrimitiveModifier {
    let subscribe: (ViewGraph, String) -> Void
    func _apply(_ context: BuildContext, _ content: (BuildContext) -> [LayoutNode]) -> [LayoutNode] {
        // Contenu un cran plus bas : plusieurs .onReceive enchaînés ont chacun leur abonnement.
        subscribe(context.graph, context.path + "/onReceive")
        return content(context.child("onReceive"))
    }
}

/// Abonnement d'une vue, gardé tant qu'elle existe ; l'action la plus récente est appelée.
final class ReceiveSubscription {
    var token: AnyCancellable?
    var action: ((Any) -> Void)?
}

extension View {
    /// Appelle `action` à chaque valeur de l'éditeur (sur le fil principal), tant que la vue existe.
    public func onReceive<P: Publisher>(_ publisher: P, perform action: @escaping (P.Output) -> Void) -> some View
        where P.Failure == Never {
        modifier(_ReceiveModifier { graph, key in
            let subscription = graph.persistent(key) { ReceiveSubscription() }
            subscription.action = { action($0 as! P.Output) }
            if subscription.token == nil {
                subscription.token = publisher.sink { [weak subscription] value in
                    let deliver: () -> Void = { subscription?.action?(value) }
                    if Thread.isMainThread { deliver() } else { DispatchQueue.main.async(execute: deliver) }
                }
            }
        })
    }
}
