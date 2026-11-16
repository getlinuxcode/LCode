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

/// Mesures des boutons, par taille de contrôle.
public struct ButtonSizeMetrics: Sendable {
    public var font: Font
    public var padding: EdgeInsets
    /// Marge horizontale avec `.buttonBorderShape(.circle)`.
    public var circlePaddingH: CGFloat
    public var defaultCornerRadius: CGFloat
}

/// Mesures relevées sur iOS 27.2 par le banc de calibration (app Catalogue, couches Core Animation).
/// Tous les styles à fond (bordered, borderedProminent, glass, glassProminent) partagent le même gabarit.
public enum ButtonMetrics {
    public static func metrics(_ size: ControlSize) -> ButtonSizeMetrics {
        if DesignStyle.current == .compatibility {
            return .init(font: .body, padding: EdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12), circlePaddingH: 7, defaultCornerRadius: 7)
        }
        switch size {
        case .mini, .small:
            // « Bouton » : 69,3 × 28 pt (texte 15 pt de 49,3 × 18), capsule de rayon 14.
            return .init(font: .system(size: 15), padding: EdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10), circlePaddingH: 7, defaultCornerRadius: 7)
        case .regular:
            // 78,7 × 34,3 pt (texte 17 pt de 54,7 × 20,3), capsule de rayon 17,2.
            return .init(font: .body, padding: EdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12), circlePaddingH: 7, defaultCornerRadius: 7)
        case .large, .extraLarge:
            // 94,7 × 50,3 pt, capsule de rayon 25,2.
            return .init(font: .body, padding: EdgeInsets(top: 15, leading: 20, bottom: 15, trailing: 20), circlePaddingH: 7, defaultCornerRadius: 7)
        }
    }

    /// Remplissage `.bordered` : gris système sans teinte, sinon la teinte à 18 % (clair) / 25 % (sombre).
    static func borderedFill(tint: Color?) -> Color {
        guard let tint else { return .secondarySystemFill }
        return Color(light: tint.light.withAlpha(0.18), dark: tint.dark.withAlpha(0.25))
    }
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
        let size = ButtonMetrics.metrics(env.controlSize)
        var labelCtx = context.child("label")
        switch style {
        case .plain:
            break
        case .borderedProminent, .glassProminent:
            labelCtx.environment.foregroundColor = .white
        case .glass:
            // Mesuré : le texte d'un bouton en verre est en couleur primaire, même destructif.
            labelCtx.environment.foregroundColor = env.foregroundColor ?? .primary
        default:
            labelCtx.environment.foregroundColor = env.foregroundColor ?? tint
        }
        if !env.isEnabled { labelCtx.environment.foregroundColor = .tertiaryLabel }
        // Mesuré : .plain ignore controlSize (reste en 17 pt) ; les autres styles suivent la taille.
        if !env.isInList && style != .plain { labelCtx.environment.font = env.font ?? size.font }
        // Le style ne se propage pas aux boutons imbriqués dans le label.
        labelCtx.environment.buttonStyle = .automatic
        labelCtx.environment.isInList = false

        let labelNodes = LSimUI._makeNodes(label, labelCtx)
        var node: LayoutNode = labelNodes.count == 1
            ? labelNodes[0]
            : StackNode(axis: .vertical, crossAlignment: 0.5, spacing: nil, children: labelNodes)

        if style.hasBackground {
            let prominent = (style == .borderedProminent || style == .glassProminent) && env.isEnabled
            let glass = DesignStyle.current == .liquidGlass
            let shape: ShapeKind
            switch env.buttonBorderShape.kind {
            case .capsule: shape = .capsule
            case .circle: shape = .circle
            case let .roundedRectangle(r): shape = .roundedRectangle(cornerRadius: r ?? size.defaultCornerRadius)
            case .automatic: shape = (glass || style == .glass || style == .glassProminent) ? .capsule : .roundedRectangle(cornerRadius: size.defaultCornerRadius)
            }
            var padding = size.padding
            if shape == .circle {
                // Mesuré : le cadre n'est pas carré, seule la marge horizontale diminue (7 pt).
                padding.leading = size.circlePaddingH
                padding.trailing = size.circlePaddingH
            }
            node = PaddingNode(node, insets: padding)
            let background: LayoutNode
            if style == .glass {
                background = GlassShapeNode(shape)
            } else if style == .glassProminent && !env.isEnabled {
                // Mesuré : verre gris plein (224 en clair, 55 en sombre) avec son reflet.
                background = GlassShapeNode(shape, tint: Color(light: .rgb255(224, 224, 224), dark: .rgb255(55, 55, 55)))
            } else if style == .glassProminent {
                background = GlassShapeNode(shape, tint: tint)
            } else if prominent {
                background = ShapeNode(shape, color: tint)
            } else {
                background = ShapeNode(shape, color: env.isEnabled ? ButtonMetrics.borderedFill(tint: role == .destructive ? .red : env.tint) : .secondarySystemFill)
            }
            node = LayerNode(node, layer: [background], alignment: .center, isBackground: true)
        }

        // Dans une List, un bouton standard occupe toute la ligne (surbrillance gérée par la liste).
        if env.isInList && (style == .automatic || style == .borderless) {
            return [RowActionNode(node, id: id, isLink: false)]
        }

        let pressed = context.graph.pressedID == id
        return [TapNode(node, id: id, isPressed: pressed, pressedOpacity: style == .borderedProminent || style == .glassProminent ? 0.7 : 0.25)]
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

/// Fond en verre (approximation : remplissage clair, liseré, ombre douce).
final class GlassShapeNode: LayoutNode {
    let shape: ShapeKind
    let tint: Color?
    init(_ shape: ShapeKind, tint: Color? = nil) {
        self.shape = shape
        self.tint = tint
    }

    override func computeSize(_ p: ProposedViewSize, _ lc: LayoutContext) -> CGSize {
        p.replacingUnspecifiedDimensions()
    }

    override func render(in rect: CGRect, _ lc: LayoutContext, _ list: inout DisplayList) {
        let dark = lc.colorScheme == .dark
        list.append(.fill(shape, rect.offsetBy(dx: 0, dy: 1.5), RGBA(0, 0, 0, dark ? 0.25 : 0.05)))
        if let tint {
            // Verre teinté : teinte pleine, reflet clair sur le pourtour (plus marqué en haut).
            list.append(.fill(shape, rect, tint.resolve(in: lc.colorScheme)))
            list.append(.stroke(shape, rect.insetBy(dx: 0.75, dy: 0.75), RGBA(1, 1, 1, dark ? 0.18 : 0.3), lineWidth: 1))
            // Le reflet est découpé à la forme (sinon un rectangle apparaît autour de la capsule).
            list.append(.pushClip(shape, rect))
            list.append(.fade(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * 0.5), RGBA(1, 1, 1, 0.08)))
            list.append(.popClip)
        } else {
            list.append(.fill(shape, rect, dark ? RGBA(0.17, 0.17, 0.18, 0.96) : RGBA(0.976, 0.976, 0.976, 0.97)))
            list.append(.stroke(shape, rect.insetBy(dx: 0.25, dy: 0.25), dark ? RGBA(1, 1, 1, 0.18) : RGBA(0, 0, 0, 0.22), lineWidth: 0.5))
        }
    }
}
