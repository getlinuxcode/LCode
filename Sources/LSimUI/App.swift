import Foundation

public protocol App {
    associatedtype Body: Scene
    @SceneBuilder var body: Body { get }
    init()
}

public protocol Scene {
    associatedtype Body: Scene
    @SceneBuilder var body: Body { get }
}

extension Never: Scene {}

@resultBuilder
public enum SceneBuilder {
    public static func buildBlock<S: Scene>(_ scene: S) -> S { scene }
}

/// Scène primitive : fournit la vue racine affichée par le simulateur.
public protocol _PrimitiveScene {
    var _rootView: AnyView { get }
}

public struct WindowGroup<Content: View>: Scene, _PrimitiveScene {
    public typealias Body = Never
    public var body: Never { fatalError() }

    let content: () -> Content

    public init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    public init<S: StringProtocol>(_ title: S, @ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    public var _rootView: AnyView { AnyView(content()) }
}

/// Trouve la vue racine d'une scène (en descendant les scènes composées).
public func _rootView<S: Scene>(of scene: S) -> AnyView {
    if let primitive = scene as? _PrimitiveScene { return primitive._rootView }
    return _rootView(of: scene.body)
}
