import Foundation

public enum ButtonRole: Hashable, Sendable {
    case destructive, cancel
}

public enum _ButtonStyleKind: Hashable, Sendable {
    case automatic, plain, borderless, bordered, borderedProminent, glass, glassProminent

    /// Styles dessinés avec un fond (forme + marges).
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
        if env.isEnabled { context.graph.registerAction(id, action) }

        // Toutes les valeurs viennent du profil de design (réécrit par le banc de calibration).
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
        // Le style ne se propage pas aux boutons imbriqués dans le label.
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

        // Dans une List, un bouton sans fond occupe toute la ligne (surbrillance gérée par la liste).
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

/// Rend son enfant carré (côté = la plus grande dimension), pour les boutons circulaires.
final class SquareNode: SingleChildNode {
    override func computeSize(_ p: ProposedViewSize, _ lc: LayoutContext) -> CGSize {
        let s = child.sizeThatFits(p, lc)
        let side = max(s.width, s.height)
        return CGSize(width: side, height: side)
    }

    override func render(in rect: CGRect, _ lc: LayoutContext, _ list: inout DisplayList) {
        let s = child.sizeThatFits(ProposedViewSize(rect.size), lc)
        child.render(in: Alignment.center.place(s, in: rect), lc, &list)
    }
}

/// Fond en verre (approximation : remplissage clair ou teinté, liseré, reflet, ombre douce).
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

    override func render(in rect: CGRect, _ lc: LayoutContext, _ list: inout DisplayList) {
        let dark = lc.colorScheme == .dark
        let p = profile
        list.append(.fill(shape, rect.offsetBy(dx: 0, dy: 1.5), RGBA(0, 0, 0, dark ? p.glassShadowAlphaDark : p.glassShadowAlphaLight)))
        if let tint {
            list.append(.fill(shape, rect, tint.resolve(in: lc.colorScheme)))
            list.append(.stroke(shape, rect.insetBy(dx: 0.75, dy: 0.75), RGBA(1, 1, 1, dark ? p.glassRimAlphaDark : p.glassRimAlphaLight), lineWidth: 1))
            // Le reflet est découpé à la forme (sinon un rectangle apparaît autour de la capsule).
            list.append(.pushClip(shape, rect))
            list.append(.fade(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * 0.5), RGBA(1, 1, 1, 0.08)))
            list.append(.popClip)
        } else {
            list.append(.fill(shape, rect, p.glassFill.color.resolve(in: lc.colorScheme)))
            list.append(.stroke(shape, rect.insetBy(dx: 0.25, dy: 0.25), p.glassStroke.color.resolve(in: lc.colorScheme), lineWidth: 0.5))
        }
    }
}
