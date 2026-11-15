import Foundation

// MARK: - Infrastructure

public protocol ViewModifier {
    associatedtype Body: View
    typealias Content = _ViewModifier_Content<Self>
    @ViewBuilder func body(content: Content) -> Body
}

/// Le contenu passé à `ViewModifier.body(content:)`.
public struct _ViewModifier_Content<Modifier: ViewModifier>: View, _PrimitiveView {
    public typealias Body = Never
    let make: (BuildContext) -> [LayoutNode]
    public func _makeNodes(_ context: BuildContext) -> [LayoutNode] { make(context) }
}

/// Modificateur interne qui agit directement sur les nœuds.
public protocol _PrimitiveModifier {
    func _apply(_ context: BuildContext, _ content: (BuildContext) -> [LayoutNode]) -> [LayoutNode]
}

public struct ModifiedContent<Content: View, Modifier>: View, _PrimitiveView {
    public typealias Body = Never
    public var content: Content
    public var modifier: Modifier

    public init(content: Content, modifier: Modifier) {
        self.content = content
        self.modifier = modifier
    }

    public func _makeNodes(_ context: BuildContext) -> [LayoutNode] {
        let content = self.content
        if let primitive = modifier as? _PrimitiveModifier {
            return primitive._apply(context) { LSimUI._makeNodes(content, $0) }
        }
        if let custom = modifier as? any ViewModifier {
            return applyCustom(custom, context)
        }
        return LSimUI._makeNodes(content, context)
    }

    private func applyCustom<M: ViewModifier>(_ modifier: M, _ context: BuildContext) -> [LayoutNode] {
        let content = self.content
        let ctx = context.child(String(describing: M.self))
        installDynamicProperties(of: modifier, ctx)
        let proxy = _ViewModifier_Content<M>(make: { LSimUI._makeNodes(content, $0.child("content")) })
        return LSimUI._makeNodes(modifier.body(content: proxy), ctx)
    }
}

extension View {
    public func modifier<M>(_ modifier: M) -> ModifiedContent<Self, M> {
        ModifiedContent(content: self, modifier: modifier)
    }
}

/// Applique une transformation à chaque nœud produit par le contenu.
struct _NodeModifier: _PrimitiveModifier {
    let transform: (LayoutNode, BuildContext) -> LayoutNode
    func _apply(_ context: BuildContext, _ content: (BuildContext) -> [LayoutNode]) -> [LayoutNode] {
        content(context).map { transform($0, context) }
    }
}

struct _EnvironmentModifier: _PrimitiveModifier {
    let transform: (inout EnvironmentValues) -> Void
    func _apply(_ context: BuildContext, _ content: (BuildContext) -> [LayoutNode]) -> [LayoutNode] {
        content(context.with(transform))
    }
}

// MARK: - Layout

extension View {
    public func padding(_ insets: EdgeInsets) -> some View {
        modifier(_NodeModifier { node, _ in PaddingNode(node, insets: insets) })
    }

    public func padding(_ edges: Edge.Set = .all, _ length: CGFloat? = nil) -> some View {
        let l = length ?? 16
        let insets = EdgeInsets(
            top: edges.contains(.top) ? l : 0,
            leading: edges.contains(.leading) ? l : 0,
            bottom: edges.contains(.bottom) ? l : 0,
            trailing: edges.contains(.trailing) ? l : 0
        )
        return padding(insets)
    }

    public func padding(_ length: CGFloat) -> some View {
        padding(.all, length)
    }

    public func frame(width: CGFloat? = nil, height: CGFloat? = nil, alignment: Alignment = .center) -> some View {
        modifier(_NodeModifier { node, _ in
            FrameNode(node, width: .init(fixed: width), height: .init(fixed: height), alignment: alignment)
        })
    }

    public func frame(
        minWidth: CGFloat? = nil, idealWidth: CGFloat? = nil, maxWidth: CGFloat? = nil,
        minHeight: CGFloat? = nil, idealHeight: CGFloat? = nil, maxHeight: CGFloat? = nil,
        alignment: Alignment = .center
    ) -> some View {
        modifier(_NodeModifier { node, _ in
            FrameNode(
                node,
                width: .init(min: minWidth, ideal: idealWidth, max: maxWidth),
                height: .init(min: minHeight, ideal: idealHeight, max: maxHeight),
                alignment: alignment
            )
        })
    }

    public func layoutPriority(_ value: Double) -> some View {
        modifier(_NodeModifier { node, _ in node.layoutPriority = value; return node })
    }

    public func offset(x: CGFloat = 0, y: CGFloat = 0) -> some View {
        modifier(_NodeModifier { node, _ in OffsetNode(node, offset: CGSize(width: x, height: y)) })
    }

    public func offset(_ offset: CGSize) -> some View {
        self.offset(x: offset.width, y: offset.height)
    }
}

// MARK: - Fond, superposition, apparence

struct _LayerModifier<Layer: View>: _PrimitiveModifier {
    let layer: Layer
    let alignment: Alignment
    let isBackground: Bool

    func _apply(_ context: BuildContext, _ content: (BuildContext) -> [LayoutNode]) -> [LayoutNode] {
        content(context).enumerated().map { index, node in
            let layerNodes = LSimUI._makeNodes(layer, context.child(isBackground ? "bg\(index)" : "ov\(index)"))
            return LayerNode(node, layer: layerNodes, alignment: alignment, isBackground: isBackground)
        }
    }
}

extension View {
    public func background<V: View>(alignment: Alignment = .center, @ViewBuilder content: () -> V) -> some View {
        modifier(_LayerModifier(layer: content(), alignment: alignment, isBackground: true))
    }

    public func background<V: View>(_ view: V, alignment: Alignment = .center) -> some View {
        modifier(_LayerModifier(layer: view, alignment: alignment, isBackground: true))
    }

    public func background<S: Shape>(_ color: Color, in shape: S) -> some View {
        modifier(_LayerModifier(layer: shape.fill(color), alignment: .center, isBackground: true))
    }

    public func overlay<V: View>(alignment: Alignment = .center, @ViewBuilder content: () -> V) -> some View {
        modifier(_LayerModifier(layer: content(), alignment: alignment, isBackground: false))
    }

    public func overlay<V: View>(_ view: V, alignment: Alignment = .center) -> some View {
        modifier(_LayerModifier(layer: view, alignment: alignment, isBackground: false))
    }

    public func opacity(_ opacity: Double) -> some View {
        modifier(_NodeModifier { node, _ in OpacityNode(node, opacity: opacity) })
    }

    public func clipShape<S: Shape>(_ shape: S) -> some View {
        modifier(_NodeModifier { node, _ in ClipNode(node, shape: shape._kind) })
    }

    public func cornerRadius(_ radius: CGFloat) -> some View {
        modifier(_NodeModifier { node, _ in ClipNode(node, shape: .roundedRectangle(cornerRadius: radius)) })
    }
}

// MARK: - Environnement

extension View {
    public func font(_ font: Font?) -> some View {
        modifier(_EnvironmentModifier { $0.font = font })
    }

    public func fontWeight(_ weight: Font.Weight?) -> some View {
        modifier(_EnvironmentModifier { $0.fontWeight = weight })
    }

    public func bold(_ isActive: Bool = true) -> some View {
        modifier(_EnvironmentModifier { if isActive { $0.fontWeight = .bold } })
    }

    public func italic(_ isActive: Bool = true) -> some View {
        modifier(_EnvironmentModifier { if isActive { $0.isItalic = true } })
    }

    public func foregroundColor(_ color: Color?) -> some View {
        modifier(_EnvironmentModifier { $0.foregroundColor = color })
    }

    public func foregroundStyle(_ color: Color) -> some View {
        foregroundColor(color)
    }

    public func tint(_ color: Color?) -> some View {
        modifier(_EnvironmentModifier { $0.tint = color })
    }

    public func multilineTextAlignment(_ alignment: TextAlignment) -> some View {
        modifier(_EnvironmentModifier { $0.multilineTextAlignment = alignment })
    }

    public func textCase(_ textCase: Text.Case?) -> some View {
        modifier(_EnvironmentModifier { $0.textCase = textCase })
    }

    public func disabled(_ disabled: Bool) -> some View {
        modifier(_EnvironmentModifier { if disabled { $0.isEnabled = false } })
    }

    public func environment<V>(_ keyPath: WritableKeyPath<EnvironmentValues, V>, _ value: V) -> some View {
        modifier(_EnvironmentModifier { $0[keyPath: keyPath] = value })
    }
}

// MARK: - Interactions et cycle de vie

struct _TapModifier: _PrimitiveModifier {
    let action: () -> Void
    func _apply(_ context: BuildContext, _ content: (BuildContext) -> [LayoutNode]) -> [LayoutNode] {
        let id = context.path + "/tap"
        context.graph.registerAction(id, action)
        return content(context).map { TapNode($0, id: id, isPressed: false, pressedOpacity: 1) }
    }
}

struct _AppearModifier: _PrimitiveModifier {
    let action: () -> Void
    func _apply(_ context: BuildContext, _ content: (BuildContext) -> [LayoutNode]) -> [LayoutNode] {
        context.graph.registerAppear(context.path + "/appear", action)
        return content(context)
    }
}

extension View {
    public func onTapGesture(count: Int = 1, perform action: @escaping () -> Void) -> some View {
        modifier(_TapModifier(action: action))
    }

    public func onAppear(perform action: (() -> Void)? = nil) -> some View {
        modifier(_AppearModifier(action: action ?? {}))
    }
}
