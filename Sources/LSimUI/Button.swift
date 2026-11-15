import Foundation

public enum ButtonRole: Hashable, Sendable {
    case destructive, cancel
}

public enum _ButtonStyleKind: Hashable, Sendable {
    case automatic, plain, borderless, bordered, borderedProminent
}

public struct Button<Label: View>: View, _PrimitiveView {
    public typealias Body = Never
    let role: ButtonRole?
    let action: () -> Void
    let label: Label

    public init(action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.init(role: nil, action: action, label: label)
    }

    public init(role: ButtonRole?, action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.role = role
        self.action = action
        self.label = label()
    }

    public func _makeNodes(_ context: BuildContext) -> [LayoutNode] {
        let env = context.environment
        let id = context.path + "/Button"
        if env.isEnabled { context.graph.registerAction(id, action) }

        let tint: Color = role == .destructive ? .red : (env.tint ?? .accentColor)
        let style = env.buttonStyle
        var labelCtx = context.child("label")
        switch style {
        case .plain:
            break
        case .borderedProminent:
            labelCtx.environment.foregroundColor = .white
        default:
            labelCtx.environment.foregroundColor = env.foregroundColor ?? tint
        }
        if !env.isEnabled { labelCtx.environment.foregroundColor = .tertiaryLabel }
        // Le style ne se propage pas aux boutons imbriqués dans le label.
        labelCtx.environment.buttonStyle = .automatic
        labelCtx.environment.isInList = false

        let labelNodes = LSimUI._makeNodes(label, labelCtx)
        var node: LayoutNode = labelNodes.count == 1
            ? labelNodes[0]
            : StackNode(axis: .vertical, crossAlignment: 0.5, spacing: nil, children: labelNodes)

        switch style {
        case .bordered, .borderedProminent:
            let prominent = style == .borderedProminent && env.isEnabled
            if DesignStyle.current == .liquidGlass {
                // Mesuré sur iOS 27 (Liquid Glass) : capsule de 33,8 pt, teinte pleine
                // (couleur vérifiée après conversion Display P3 → sRVB de la capture).
                let fill: Color = prominent ? tint : .secondarySystemFill
                node = PaddingNode(node, insets: EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10))
                node = LayerNode(node, layer: [ShapeNode(.capsule, color: fill)], alignment: .center, isBackground: true)
            } else {
                // Mode compatibilité : rectangle arrondi de 7 pt, marges 12 × 7 pt (bouton « + » : 35 × 35 pt).
                let fill: Color = prominent ? tint : .secondarySystemFill
                node = PaddingNode(node, insets: EdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12))
                node = LayerNode(node, layer: [ShapeNode(.roundedRectangle(cornerRadius: 7), color: fill)], alignment: .center, isBackground: true)
            }
        default:
            break
        }

        // Dans une List, un bouton standard occupe toute la ligne (surbrillance gérée par la liste).
        if env.isInList && (style == .automatic || style == .borderless) {
            return [RowActionNode(node, id: id, isLink: false)]
        }

        let pressed = context.graph.pressedID == id
        return [TapNode(node, id: id, isPressed: pressed, pressedOpacity: style == .borderedProminent ? 0.7 : 0.25)]
    }
}

extension Button where Label == Text {
    public init<S: StringProtocol>(_ title: S, action: @escaping () -> Void) {
        self.init(role: nil, action: action) { Text(title) }
    }

    public init<S: StringProtocol>(_ title: S, role: ButtonRole?, action: @escaping () -> Void) {
        self.init(role: role, action: action) { Text(title) }
    }
}

// MARK: - Styles

public protocol PrimitiveButtonStyle {
    var _kind: _ButtonStyleKind { get }
}

public struct DefaultButtonStyle: PrimitiveButtonStyle { public init() {}; public var _kind: _ButtonStyleKind { .automatic } }
public struct PlainButtonStyle: PrimitiveButtonStyle { public init() {}; public var _kind: _ButtonStyleKind { .plain } }
public struct BorderlessButtonStyle: PrimitiveButtonStyle { public init() {}; public var _kind: _ButtonStyleKind { .borderless } }
public struct BorderedButtonStyle: PrimitiveButtonStyle { public init() {}; public var _kind: _ButtonStyleKind { .bordered } }
public struct BorderedProminentButtonStyle: PrimitiveButtonStyle { public init() {}; public var _kind: _ButtonStyleKind { .borderedProminent } }

extension PrimitiveButtonStyle where Self == DefaultButtonStyle { public static var automatic: Self { .init() } }
extension PrimitiveButtonStyle where Self == PlainButtonStyle { public static var plain: Self { .init() } }
extension PrimitiveButtonStyle where Self == BorderlessButtonStyle { public static var borderless: Self { .init() } }
extension PrimitiveButtonStyle where Self == BorderedButtonStyle { public static var bordered: Self { .init() } }
extension PrimitiveButtonStyle where Self == BorderedProminentButtonStyle { public static var borderedProminent: Self { .init() } }

extension View {
    public func buttonStyle<S: PrimitiveButtonStyle>(_ style: S) -> some View {
        modifier(_EnvironmentModifier { $0.buttonStyle = style._kind })
    }
}
