import Foundation

/// Stockage persistant d'une valeur @State, détenu par le graphe.
final class StateStorage {
    var value: Any
    weak var graph: ViewGraph?

    init(value: Any, graph: ViewGraph) {
        self.value = value
        self.graph = graph
    }

    func set(_ newValue: Any) {
        value = newValue
        graph?.invalidate()
    }
}

@propertyWrapper
public struct State<Value>: _DynamicProperty {
    final class Box {
        let initial: Value
        var storage: StateStorage?
        init(_ initial: Value) { self.initial = initial }
    }

    let box: Box

    public init(wrappedValue: Value) {
        box = Box(wrappedValue)
    }

    public init(initialValue: Value) {
        self.init(wrappedValue: initialValue)
    }

    public var wrappedValue: Value {
        get { (box.storage?.value as? Value) ?? box.initial }
        nonmutating set {
            if let storage = box.storage {
                storage.set(newValue)
            } else {
                print("[LSimUI] Avertissement : modification d'un @State hors de l'arbre de vues — ignorée.")
            }
        }
    }

    public var projectedValue: Binding<Value> {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0 })
    }

    func _install(_ context: _InstallContext) {
        box.storage = context.graph.stateStorage(for: context.key, initial: box.initial)
    }
}

extension State where Value: ExpressibleByNilLiteral {
    public init() { self.init(wrappedValue: nil) }
}

@propertyWrapper
@dynamicMemberLookup
public struct Binding<Value> {
    let getter: () -> Value
    let setter: (Value) -> Void

    public init(get: @escaping () -> Value, set: @escaping (Value) -> Void) {
        getter = get
        setter = set
    }

    public init(projectedValue: Binding<Value>) {
        self = projectedValue
    }

    public static func constant(_ value: Value) -> Binding<Value> {
        Binding(get: { value }, set: { _ in })
    }

    public var wrappedValue: Value {
        get { getter() }
        nonmutating set { setter(newValue) }
    }

    public var projectedValue: Binding<Value> { self }

    public subscript<Subject>(dynamicMember keyPath: WritableKeyPath<Value, Subject>) -> Binding<Subject> {
        Binding<Subject>(
            get: { getter()[keyPath: keyPath] },
            set: { newValue in
                var value = getter()
                value[keyPath: keyPath] = newValue
                setter(value)
            }
        )
    }
}

/// Le graphe de vues : état persistant, actions des boutons, invalidation.
public final class ViewGraph {
    private var storages: [String: StateStorage] = [:]
    private var touchedKeys: Set<String> = []
    private var appeared: Set<String> = []
    private var pendingAppear: [() -> Void] = []
    private var currentAppear: Set<String> = []

    /// Actions enregistrées lors de la dernière construction (identifiant de zone → action).
    public private(set) var actions: [String: () -> Void] = [:]
    /// Zone actuellement pressée (pour l'effet de surbrillance des boutons).
    public var pressedID: String?
    /// Appelé quand l'état change et qu'un nouveau rendu est nécessaire.
    public var onInvalidate: (() -> Void)?

    public init() {}

    // MARK: Saisie et glissers

    /// Champ de texte actuellement actif (reçoit le clavier).
    public var focusedID: String?
    struct TextInput {
        let get: () -> String
        let set: (String) -> Void
        let submit: () -> Void
    }
    private(set) var textInputs: [String: TextInput] = [:]
    /// Contrôles qui suivent le doigt (Slider) : reçoivent la position du pointeur, en points écran.
    public private(set) var dragHandlers: [String: (CGPoint) -> Void] = [:]
    /// Zones défilant horizontalement (le glisser utilise alors le déplacement en x).
    public internal(set) var horizontalScrolls: Set<String> = []
    /// Cadres des GeometryReader lors de la dernière passe (leur contenu dépend de leur taille).
    var geometryFrames: [String: CGRect] = [:]
    /// Présentations (feuilles, alertes) collectées pendant la construction, dessinées au-dessus de tout.
    public internal(set) var presentations: [LayoutNode] = []

    func registerTextInput(_ id: String, get: @escaping () -> String, set: @escaping (String) -> Void, submit: @escaping () -> Void) {
        textInputs[id] = TextInput(get: get, set: set, submit: submit)
    }

    func registerDrag(_ id: String, _ handler: @escaping (CGPoint) -> Void) {
        dragHandlers[id] = handler
    }

    public var hasFocusedTextField: Bool { focusedID.flatMap { textInputs[$0] } != nil }

    /// Frappe au clavier dans le champ actif.
    public func insertText(_ text: String) {
        guard let id = focusedID, let input = textInputs[id] else { return }
        input.set(input.get() + text)
    }

    public func deleteBackward() {
        guard let id = focusedID, let input = textInputs[id] else { return }
        var value = input.get()
        if !value.isEmpty { value.removeLast() }
        input.set(value)
    }

    /// Entrée : valide le champ (onSubmit) et rend le clavier.
    public func submitText() {
        guard let id = focusedID, let input = textInputs[id] else { return }
        focusedID = nil
        input.submit()
        invalidate()
    }

    public func resignFocus() {
        guard focusedID != nil else { return }
        focusedID = nil
        invalidate()
    }

    func stateStorage(for key: String, initial: Any) -> StateStorage {
        touchedKeys.insert(key)
        if let existing = storages[key] { return existing }
        let storage = StateStorage(value: initial, graph: self)
        storages[key] = storage
        return storage
    }

    func registerAction(_ id: String, _ action: @escaping () -> Void) {
        actions[id] = action
    }

    func registerAppear(_ id: String, _ action: @escaping () -> Void) {
        currentAppear.insert(id)
        if !appeared.contains(id) { pendingAppear.append(action) }
    }

    public func invalidate() {
        onInvalidate?()
    }

    /// Construit les nœuds de layout d'une vue racine.
    /// - Parameter app: objet racine optionnel (la structure `App`) dont l'état est installé avant `root`.
    public func build<Root: View>(environment: EnvironmentValues, app: Any? = nil, root: () -> Root) -> [LayoutNode] {
        actions = [:]
        textInputs = [:]
        dragHandlers = [:]
        presentations = []
        touchedKeys = []
        currentAppear = []
        pendingAppear = []
        if let app {
            installDynamicProperties(of: app, BuildContext(path: "App", environment: environment, graph: self))
        }
        let ctx = BuildContext(path: "", environment: environment, graph: self)
        let nodes = _makeNodes(root(), ctx)
        // L'état des vues qui ont disparu est libéré, comme dans SwiftUI — sauf les écrans
        // masqués d'une pile de navigation, qui restent vivants sous l'écran affiché.
        let retained = retainedPrefixes
        storages = storages.filter { key, _ in
            touchedKeys.contains(key) || retained.contains { key.hasPrefix($0) }
        }
        retainedPrefixes = []
        appeared = currentAppear
        let toRun = pendingAppear
        pendingAppear = []
        toRun.forEach { $0() }
        return nodes
    }

    public func performAction(_ id: String) {
        actions[id]?()
    }

    // MARK: - Navigation et défilement

    private var retainedPrefixes: [String] = []

    /// Conserve l'état d'un sous-arbre non construit pendant cette passe (écran masqué d'une pile).
    func retain(prefix: String) {
        retainedPrefixes.append(prefix)
    }

    /// Objet persistant associé à une clé (créé au premier accès).
    func persistent<T: AnyObject>(_ key: String, _ make: () -> T) -> T {
        touchedKeys.insert(key)
        if let existing = storages[key]?.value as? T { return existing }
        let object = make()
        storages[key] = StateStorage(value: object, graph: self)
        return object
    }

    func scrollOffset(_ id: String) -> CGFloat {
        touchedKeys.insert(id)
        return storages[id]?.value as? CGFloat ?? 0
    }

    /// Écrit le décalage sans déclencher de nouveau rendu (utilisé pendant le layout pour le borner).
    func setScrollOffsetSilently(_ id: String, _ value: CGFloat) {
        if let s = storages[id] { s.value = value } else { storages[id] = StateStorage(value: value, graph: self) }
    }

    /// Fait défiler une zone (appelé par l'hôte lors d'un glisser ou de la molette).
    public func scroll(_ id: String, by delta: CGFloat) {
        let current = storages[id]?.value as? CGFloat ?? 0
        setScrollOffsetSilently(id, max(0, current + delta))
        invalidate()
    }
}
