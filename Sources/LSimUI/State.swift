import Foundation

/// Persistent storage for a @State value, owned by the graph.
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
                print("[LSimUI] Warning: @State modified outside the view tree — ignored.")
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

/// The view graph: persistent state, button actions, invalidation.
public final class ViewGraph {
    private var storages: [String: StateStorage] = [:]
    private var touchedKeys: Set<String> = []
    private var appeared: Set<String> = []
    private var pendingAppear: [() -> Void] = []
    private var currentAppear: Set<String> = []

    /// Actions registered during the last build (hit area id → action).
    public private(set) var actions: [String: () -> Void] = [:]
    /// Currently pressed area (for button highlight).
    public var pressedID: String?
    /// Called when state changes and a new render is needed.
    public var onInvalidate: (() -> Void)?

    public init() {}

    // MARK: Input and drags

    /// Text field currently focused (receives the keyboard).
    public var focusedID: String?
    struct TextInput {
        let get: () -> String
        let set: (String) -> Void
        let submit: () -> Void
    }
    private(set) var textInputs: [String: TextInput] = [:]
    /// Controls that track the finger (Slider): receive the pointer position, in screen points.
    public private(set) var dragHandlers: [String: (CGPoint) -> Void] = [:]
    /// Horizontally scrolling areas (the drag then uses the x delta).
    public internal(set) var horizontalScrolls: Set<String> = []
    /// GeometryReader frames from the last pass (their content depends on their size).
    var geometryFrames: [String: CGRect] = [:]
    /// Presentations (sheets, alerts) collected during the build, drawn above everything.
    public internal(set) var presentations: [LayoutNode] = []

    func registerTextInput(_ id: String, get: @escaping () -> String, set: @escaping (String) -> Void, submit: @escaping () -> Void) {
        textInputs[id] = TextInput(get: get, set: set, submit: submit)
    }

    func registerDrag(_ id: String, _ handler: @escaping (CGPoint) -> Void) {
        dragHandlers[id] = handler
    }

    /// Drag tracked by a system view (swipe back, sheet): translation since the start, then translation
    /// and velocity (points/s) on release.
    public struct PanHandler {
        public let changed: (CGSize) -> Void
        public let ended: (CGSize, CGSize) -> Void
    }
    public private(set) var panHandlers: [String: PanHandler] = [:]

    func registerPan(_ id: String, changed: @escaping (CGSize) -> Void, ended: @escaping (CGSize, CGSize) -> Void) {
        panHandlers[id] = PanHandler(changed: changed, ended: ended)
    }

    public var hasFocusedTextField: Bool { focusedID.flatMap { textInputs[$0] } != nil }

    /// Key typed into the focused field.
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

    /// Return: submits the field (onSubmit) and dismisses the keyboard.
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
        // Change made inside `withAnimation`: the next frame animates it.
        if let animation = Transaction.current { animator.pending = animation }
        onInvalidate?()
    }

    /// Presented values from frame to frame (animations).
    public let animator = Animator()

    /// Builds the layout nodes of a root view.
    /// - Parameter app: optional root object (the `App` struct) whose state is installed before `root`.
    public func build<Root: View>(environment: EnvironmentValues, app: Any? = nil, root: () -> Root) -> [LayoutNode] {
        actions = [:]
        textInputs = [:]
        dragHandlers = [:]
        panHandlers = [:]
        presentations = []
        touchedKeys = []
        currentAppear = []
        pendingAppear = []
        if let app {
            installDynamicProperties(of: app, BuildContext(path: "App", environment: environment, graph: self))
        }
        let ctx = BuildContext(path: "", environment: environment, graph: self)
        let nodes = _makeNodes(root(), ctx)
        // State of views that disappeared is released, as in SwiftUI, except hidden screens of a
        // navigation stack, which stay alive under the visible one.
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

    // MARK: - Navigation and scrolling

    private var retainedPrefixes: [String] = []
    /// Combine objects (ObservableObject) tracked by the graph.
    var observed: [ObjectIdentifier: ObservedEntry] = [:]

    /// Keeps the state of a subtree not built in this pass (hidden screen in a stack).
    func retain(prefix: String) {
        retainedPrefixes.append(prefix)
    }

    /// Persistent object for a key (created on first access).
    func persistent<T: AnyObject>(_ key: String, _ make: () -> T) -> T {
        touchedKeys.insert(key)
        if let existing = storages[key]?.value as? T { return existing }
        let object = make()
        storages[key] = StateStorage(value: object, graph: self)
        return object
    }

    public func scrollOffset(_ id: String) -> CGFloat {
        touchedKeys.insert(id)
        return storages[id]?.value as? CGFloat ?? 0
    }

    /// Writes the offset without triggering a render (used during layout to clamp it).
    func setScrollOffsetSilently(_ id: String, _ value: CGFloat) {
        if let s = storages[id] { s.value = value } else { storages[id] = StateStorage(value: value, graph: self) }
    }

    /// Scrolls an area (called by the host on drag or mouse wheel).
    public func scroll(_ id: String, by delta: CGFloat) {
        let current = storages[id]?.value as? CGFloat ?? 0
        setScrollOffsetSilently(id, max(0, current + delta))
        invalidate()
    }
}
