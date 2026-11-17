import Foundation

public enum ButtonRole: Hashable, Sendable {
    case destructive, cancel
}

public enum _ButtonStyleKind: Hashable, Sendable {
    case automatic, plain, borderless, bordered, borderedProminent, glass, glassProminent

    /// Styles drawn with a background (shape + padding).
    var hasBackground: Bool { [.bordered, .borderedProminent, .glass, .glassProminent].contains(self) }
}

public enum ControlSize: CaseIterable, Hashable, Sendable {
    case mini, small, regular, large, extraLarge
}

public struct ButtonBorderShape: Hashable, Sendable {
    enum Kind: Hashable { case automatic, capsule, circle, roundedRectangle(CGFloat?) }
    let kind: Kind
    public static let automatic = ButtonBorderShape(kind: .automatic)
    public static let capsule = ButtonBorderShape(kind: .capsule)
    public static let circle = ButtonBorderShape(kind: .circle)
    public static let roundedRectangle = ButtonBorderShape(kind: .roundedRectangle(nil))
    public static func roundedRectangle(radius: CGFloat) -> ButtonBorderShape { ButtonBorderShape(kind: .roundedRectangle(radius)) }
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
        if env.isInAlert {
            let action = self.action, dismiss = env.presentationDismiss
            context.graph.registerAction(id) { action(); dismiss?() }
            var labelCtx = context.child("label")
            labelCtx.environment.isInAlert = false
            labelCtx.environment.foregroundColor = role == .destructive ? .red : .primary
            labelCtx.environment.font = role == .cancel ? .body : .system(size: 17, weight: .semibold)
            return [AlertButtonNode(group(LSimUI._makeNodes(label, labelCtx)), id: id, role: role)]
        }
        if env.isEnabled { context.graph.registerAction(id, action) }

        // All values come from the design profile (rewritten by the calibration bench).
        let profile = DesignProfile.current.button
        let style = profile.style(env.buttonStyle)
        let size = profile.size(env.controlSize)
        let destructive = role == .destructive
        let tint: Color = destructive ? .red : (env.tint ?? .accentColor)

        var labelCtx = context.child("label")
        switch destructive ? style.destructiveLabel : style.label {
        case .tint: labelCtx.environment.foregroundColor = env.foregroundColor ?? tint
        case .primary: labelCtx.environment.foregroundColor = env.foregroundColor ?? .primary
        case .white: labelCtx.environment.foregroundColor = .white
        case .inherit: break
        }
        if !env.isEnabled { labelCtx.environment.foregroundColor = .tertiaryLabel }
        if !env.isInList && style.followsControlSize {
            labelCtx.environment.font = env.font ?? .system(size: CGFloat(size.fontSize))
        }
        // The style does not propagate to buttons nested in the label.
        labelCtx.environment.buttonStyle = .automatic
        labelCtx.environment.isInList = false

        let labelNodes = LSimUI._makeNodes(label, labelCtx)
        var node: LayoutNode = labelNodes.count == 1
            ? labelNodes[0]
            : StackNode(axis: .vertical, crossAlignment: 0.5, spacing: nil, children: labelNodes)

        if style.fill != .none {
            let radius = CGFloat(profile.roundedRectangleRadius)
            let shape: ShapeKind
            switch env.buttonBorderShape.kind {
            case .capsule: shape = .capsule
            case .circle: shape = .circle
            case let .roundedRectangle(r): shape = .roundedRectangle(cornerRadius: r ?? radius)
            case .automatic: shape = profile.defaultShape == "capsule" ? .capsule : .roundedRectangle(cornerRadius: radius)
            }
            let padH = CGFloat(shape == .circle ? size.circlePadH : size.padH)
            let padV = CGFloat(size.padV)
            node = PaddingNode(node, insets: EdgeInsets(top: padV, leading: padH, bottom: padV, trailing: padH))

            let background: LayoutNode
            switch style.fill {
            case .glass:
                background = GlassShapeNode(shape, tint: nil, profile: profile)
            case .glassTinted:
                background = GlassShapeNode(shape, tint: env.isEnabled ? tint : profile.disabledGlassTintedFill.color, profile: profile)
            case .solid where env.isEnabled:
                background = ShapeNode(shape, color: tint)
            case .neutralOrTinted where env.isEnabled && (env.tint != nil || destructive):
                background = ShapeNode(shape, color: Color(light: tint.light.withAlpha(profile.tintFillAlphaLight),
                                                           dark: tint.dark.withAlpha(profile.tintFillAlphaDark)))
            default:
                background = ShapeNode(shape, color: profile.neutralFill.color)
            }
            node = LayerNode(node, layer: [background], alignment: .center, isBackground: true)
        }

        // In a List, a borderless button fills the row (the list handles highlighting).
        if env.isInList && style.fill == .none && env.buttonStyle != .plain {
            return [RowActionNode(node, id: id, isLink: false)]
        }

        let pressed = context.graph.pressedID == id
        return [TapNode(node, id: id, isPressed: pressed, pressedOpacity: style.pressedOpacity)]
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

public struct GlassButtonStyle: PrimitiveButtonStyle { public init() {}; public var _kind: _ButtonStyleKind { .glass } }
public struct GlassProminentButtonStyle: PrimitiveButtonStyle { public init() {}; public var _kind: _ButtonStyleKind { .glassProminent } }
extension PrimitiveButtonStyle where Self == GlassButtonStyle { public static var glass: Self { .init() } }
extension PrimitiveButtonStyle where Self == GlassProminentButtonStyle { public static var glassProminent: Self { .init() } }

extension View {
    public func buttonStyle<S: PrimitiveButtonStyle>(_ style: S) -> some View {
        modifier(_EnvironmentModifier { $0.buttonStyle = style._kind })
    }

    public func controlSize(_ size: ControlSize) -> some View {
        modifier(_EnvironmentModifier { $0.controlSize = size })
    }

    public func buttonBorderShape(_ shape: ButtonBorderShape) -> some View {
        modifier(_EnvironmentModifier { $0.buttonBorderShape = shape })
    }
}

/// Makes its child square (side = largest dimension), for circular buttons.
final class SquareNode: SingleChildNode {
    override func computeSize(_ p: ProposedViewSize, _ lc: LayoutContext) -> CGSize {
        let s = child.sizeThatFits(p, lc)
        let side = max(s.width, s.height)
        return CGSize(width: side, height: side)
    }

    override func draw(in rect: CGRect, _ lc: LayoutContext, _ list: inout DisplayList) {
        let s = child.sizeThatFits(ProposedViewSize(rect.size), lc)
        child.render(in: Alignment.center.place(s, in: rect), lc, &list)
    }
}

/// Glass background (approximation: light or tinted fill, rim, highlight, soft shadow).
final class GlassShapeNode: LayoutNode {
    let shape: ShapeKind
    let tint: Color?
    let profile: ButtonProfile

    init(_ shape: ShapeKind, tint: Color?, profile: ButtonProfile) {
        self.shape = shape
        self.tint = tint
        self.profile = profile
    }

    override func computeSize(_ p: ProposedViewSize, _ lc: LayoutContext) -> CGSize {
        p.replacingUnspecifiedDimensions()
    }

    override func draw(in rect: CGRect, _ lc: LayoutContext, _ list: inout DisplayList) {
        // Real Liquid Glass material; a "prominent" glass is fully tinted.
        var glass = Glass.regular.render(lc.colorScheme)
        if let tint {
            let t = tint.resolve(in: lc.colorScheme)
            glass.tint = RGBA(t.r, t.g, t.b, 1)
        }
        list.append(.glass(shape, rect, glass))
    }
}
