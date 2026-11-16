import Foundation

public protocol View {
    associatedtype Body: View
    @ViewBuilder var body: Body { get }
}

extension Never: View {
    public typealias Body = Never
    public var body: Never { fatalError() }
}

extension View where Body == Never {
    public var body: Never { fatalError("\(Self.self) est une vue primitive : son body ne doit pas être appelé") }
}

/// Vue primitive : sait produire directement ses nœuds de layout.
public protocol _PrimitiveView {
    func _makeNodes(_ context: BuildContext) -> [LayoutNode]
}

/// Contexte de construction : position dans l'arbre (identité), environnement, graphe.
public struct BuildContext {
    public var path: String
    public var environment: EnvironmentValues
    public let graph: ViewGraph

    public func child(_ component: String) -> BuildContext {
        var c = self
        c.path += "/" + component
        return c
    }

    func with(_ transform: (inout EnvironmentValues) -> Void) -> BuildContext {
        var c = self
        transform(&c.environment)
        return c
    }
}

/// Transforme une vue (primitive ou composée) en nœuds de layout.
public func _makeNodes<V: View>(_ view: V, _ context: BuildContext) -> [LayoutNode] {
    let nodes: [LayoutNode]
    if let primitive = view as? _PrimitiveView {
        nodes = primitive._makeNodes(context)
    } else {
        let ctx = context.child(String(describing: V.self))
        installDynamicProperties(of: view, ctx)
        nodes = _makeNodes(view.body, ctx)
    }
    // Identité stable pour les animations : chemin de construction (le plus profond l'emporte), rang et type.
    for (i, node) in nodes.enumerated() where node.identity == nil {
        node.identity = "\(context.path)#\(i):\(type(of: node))"
        node.animation = context.environment.animation
        node.transition = context.environment.transition
    }
    return nodes
}

// MARK: - Propriétés dynamiques (@State, @Environment…)

public struct _InstallContext {
    public let key: String
    public let graph: ViewGraph
    public let environment: EnvironmentValues
}

protocol _DynamicProperty {
    func _install(_ context: _InstallContext)
}

func installDynamicProperties(of subject: Any, _ ctx: BuildContext) {
    for (index, child) in Mirror(reflecting: subject).children.enumerated() {
        guard let property = child.value as? _DynamicProperty else { continue }
        let label = child.label ?? "\(index)"
        property._install(_InstallContext(key: ctx.path + "#" + label, graph: ctx.graph, environment: ctx.environment))
    }
}
