import Foundation

// Contrôles de saisie et d'affichage. Les dimensions sont des estimations au gabarit iOS 26,
// destinées à être recalées par le banc de calibration.

// MARK: - Outils communs

/// Premier texte d'un sous-arbre (libellés d'options de Picker).
func firstText(in node: LayoutNode) -> String? {
    if let t = node as? TextNode { return t.string }
    if let s = node as? SingleChildNode { return firstText(in: s.child) }
    if let s = node as? StackNode { return s.children.lazy.compactMap(firstText(in:)).first }
    if let z = node as? ZStackNode { return z.children.lazy.compactMap(firstText(in:)).first }
    return nil
}

func group(_ nodes: [LayoutNode], axis: Axis = .horizontal) -> LayoutNode {
    nodes.count == 1 ? nodes[0] : StackNode(axis: axis, crossAlignment: 0.5, spacing: nil, children: nodes)
}

/// Ligne « libellé … contrôle » (Toggle, Stepper, Picker, DatePicker).
func controlRow(_ label: [LayoutNode], _ trailing: LayoutNode) -> LayoutNode {
    var children = label
    children.append(SpacerNode(minLength: 8))
    children.append(trailing)
    return StackNode(axis: .horizontal, crossAlignment: 0.5, spacing: nil, children: children)
}

/// Dans une ligne de liste, iOS ne compte pas la hauteur du contrôle (interrupteur, stepper) : la ligne prend
/// la hauteur du libellé et le contrôle déborde, centré (mesuré sur iPhone : cadre de 20,3 pt dans un Form).
final class RowOverflowNode: SingleChildNode {
    override func computeSize(_ p: ProposedViewSize, _ lc: LayoutContext) -> CGSize {
        CGSize(width: child.sizeThatFits(p, lc).width, height: 0)
    }
    override func draw(in rect: CGRect, _ lc: LayoutContext, _ list: inout DisplayList) {
        let s = child.sizeThatFits(.unspecified, lc)
        child.render(in: CGRect(x: rect.minX, y: rect.midY - s.height / 2, width: rect.width, height: s.height), lc, &list)
    }
}

/// Nœud de taille fixe dessiné par une fermeture.
final class DrawNode: LayoutNode {
    let size: (ProposedViewSize) -> CGSize
    let paint: (CGRect, LayoutContext, inout DisplayList) -> Void
    init(size: @escaping (ProposedViewSize) -> CGSize, draw: @escaping (CGRect, LayoutContext, inout DisplayList) -> Void) {
        self.size = size
        self.paint = draw
    }
    override func computeSize(_ p: ProposedViewSize, _ lc: LayoutContext) -> CGSize { size(p) }
    override func draw(in rect: CGRect, _ lc: LayoutContext, _ list: inout DisplayList) { paint(rect, lc, &list) }
}

extension Color {
    static let systemFill = Color(light: .rgb255(120, 120, 128, 0.2), dark: .rgb255(120, 120, 128, 0.36))
    static let tertiarySystemFill = Color(light: .rgb255(118, 118, 128, 0.12), dark: .rgb255(118, 118, 128, 0.24))
    static let placeholderText = Color(light: .rgb255(60, 60, 67, 0.3), dark: .rgb255(235, 235, 245, 0.3))
}

// MARK: - Label

public struct Label<Title: View, Icon: View>: View, _PrimitiveView {
    public typealias Body = Never
    let title: Title
    let icon: Icon

    public init(@ViewBuilder title: () -> Title, @ViewBuilder icon: () -> Icon) {
        self.title = title()
        self.icon = icon()
    }

    public func _makeNodes(_ context: BuildContext) -> [LayoutNode] {
        let ctx = context.child("Label")
        var iconCtx = ctx.child("icon")
        // Dans une liste, l'icône prend la teinte (comme les réglages iOS).
        if context.environment.isInList { iconCtx.environment.foregroundColor = context.environment.tint ?? .accentColor }
        let iconNodes = LSimUI._makeNodes(icon, iconCtx)
        let titleNodes = LSimUI._makeNodes(title, ctx.child("title"))
        switch context.environment.labelStyle {
        case .iconOnly: return [group(iconNodes)]
        case .titleOnly: return [group(titleNodes)]
        default:
            return [StackNode(axis: .horizontal, crossAlignment: 0.5, spacing: 8, children: iconNodes + titleNodes)]
        }
    }
}

extension Label where Title == Text, Icon == Image {
    public init<S: StringProtocol>(_ title: S, systemImage: String) {
        self.init(title: { Text(title) }, icon: { Image(systemName: systemImage) })
    }

    public init<S: StringProtocol>(_ title: S, image: String) {
        self.init(title: { Text(title) }, icon: { Image(image) })
    }
}

public enum _LabelStyleKind: Hashable, Sendable { case automatic, iconOnly, titleOnly, titleAndIcon }
public protocol LabelStyle { var _kind: _LabelStyleKind { get } }
public struct DefaultLabelStyle: LabelStyle { public init() {}; public var _kind: _LabelStyleKind { .automatic } }
public struct IconOnlyLabelStyle: LabelStyle { public init() {}; public var _kind: _LabelStyleKind { .iconOnly } }
public struct TitleOnlyLabelStyle: LabelStyle { public init() {}; public var _kind: _LabelStyleKind { .titleOnly } }
public struct TitleAndIconLabelStyle: LabelStyle { public init() {}; public var _kind: _LabelStyleKind { .titleAndIcon } }
extension LabelStyle where Self == DefaultLabelStyle { public static var automatic: Self { .init() } }
extension LabelStyle where Self == IconOnlyLabelStyle { public static var iconOnly: Self { .init() } }
extension LabelStyle where Self == TitleOnlyLabelStyle { public static var titleOnly: Self { .init() } }
extension LabelStyle where Self == TitleAndIconLabelStyle { public static var titleAndIcon: Self { .init() } }

extension View {
    public func labelStyle<S: LabelStyle>(_ style: S) -> some View {
        modifier(_EnvironmentModifier { $0.labelStyle = style._kind })
    }
}

// MARK: - Toggle

public struct Toggle<Label: View>: View, _PrimitiveView {
    public typealias Body = Never
    let isOn: Binding<Bool>
    let label: Label

    public init(isOn: Binding<Bool>, @ViewBuilder label: () -> Label) {
        self.isOn = isOn
        self.label = label()
    }

    public func _makeNodes(_ context: BuildContext) -> [LayoutNode] {
        let id = context.path + "/Toggle"
        let isOn = self.isOn
        let on = isOn.wrappedValue
        let enabled = context.environment.isEnabled
        if enabled { context.graph.registerAction(id) { isOn.wrappedValue.toggle() } }
        let tint = context.environment.tint ?? .green
        // Interrupteur iOS 27 (couches mesurées) : cadre de 61 × 28, piste de 63 pt qui déborde à droite,
        // curseur blanc de 37 × 24 ; piste éteinte gris (120, 120, 128) à 43 % (clair) / 58 % (sombre).
        let control = DrawNode(size: { _ in CGSize(width: 61, height: 28) }) { frame, lc, list in
            let rect = CGRect(x: frame.minX, y: frame.minY, width: 63, height: frame.height)
            let offTrack = Color(light: .rgb255(120, 120, 128, 0.43), dark: .rgb255(120, 120, 128, 0.58))
            let track = on ? tint : offTrack
            if !enabled { list.append(.pushOpacity(0.4)) }
            list.append(.fill(.capsule, rect, track.resolve(in: lc.colorScheme)))
            let knob = CGSize(width: 37, height: 24)
            let x = on ? rect.maxX - 2 - knob.width : rect.minX + 2
            let knobRect = CGRect(x: x, y: rect.midY - knob.height / 2, width: knob.width, height: knob.height)
            list.append(.fill(.capsule, knobRect.offsetBy(dx: 0, dy: 1), RGBA(0, 0, 0, 0.08)))
            list.append(.fill(.capsule, knobRect, RGBA(1, 1, 1)))
            if !enabled { list.append(.popOpacity) }
            list.append(.hitRegion(id: id, rect))
        }
        var labelCtx = context.child("label")
        labelCtx.environment.isInList = false
        let labelNodes = LSimUI._makeNodes(label, labelCtx)
        if context.environment.labelsHidden { return [control] }
        // Désactivé : seul l'interrupteur s'estompe, le libellé reste (mesuré sur iPhone).
        return [controlRow(labelNodes, context.environment.isInList ? RowOverflowNode(control) : control)]
    }
}

extension Toggle where Label == Text {
    public init<S: StringProtocol>(_ title: S, isOn: Binding<Bool>) {
        self.init(isOn: isOn) { Text(title) }
    }
}

// MARK: - TextField / SecureField

public struct TextField<Label: View>: View, _PrimitiveView {
    public typealias Body = Never
    let placeholder: String
    let text: Binding<String>
    let secure: Bool

    init(placeholder: String, text: Binding<String>, secure: Bool) {
        self.placeholder = placeholder
        self.text = text
        self.secure = secure
    }

    public func _makeNodes(_ context: BuildContext) -> [LayoutNode] {
        let id = context.path + "/TextField"
        let graph = context.graph
        let env = context.environment
        let text = self.text
        let submit = env.onSubmit
        graph.registerAction(id) {
            graph.focusedID = id
            graph.invalidate()
        }
        graph.registerTextInput(id, get: { text.wrappedValue }, set: { text.wrappedValue = $0 }, submit: { submit?() })
        let focused = graph.focusedID == id
        let value = text.wrappedValue
        let shown = value.isEmpty ? placeholder : (secure ? String(repeating: "•", count: value.count) : value)
        let color: Color = value.isEmpty ? .placeholderText : (env.foregroundColor ?? .primary)
        var font = env.font ?? .body
        if let w = env.fontWeight { font.weight = w }
        let textNode = TextNode(shown, font: font, color: color, alignment: env.multilineTextAlignment)
        let tint = env.tint ?? .accentColor
        let bordered = env.textFieldStyle == .roundedBorder

        return [TextFieldNode(text: textNode, id: id, focused: focused, caretColor: tint, bordered: bordered,
                              caretAtEnd: !value.isEmpty)]
    }
}

/// Champ de texte : prend la largeur proposée ; curseur d'insertion quand il est actif.
final class TextFieldNode: LayoutNode {
    let text: TextNode
    let id: String
    let focused: Bool
    let caretColor: Color
    let bordered: Bool
    let caretAtEnd: Bool

    init(text: TextNode, id: String, focused: Bool, caretColor: Color, bordered: Bool, caretAtEnd: Bool) {
        self.text = text
        self.id = id
        self.focused = focused
        self.caretColor = caretColor
        self.bordered = bordered
        self.caretAtEnd = caretAtEnd
    }

    private var insets: EdgeInsets { bordered ? EdgeInsets(top: 7, leading: 8, bottom: 7, trailing: 8) : EdgeInsets() }

    override func computeSize(_ p: ProposedViewSize, _ lc: LayoutContext) -> CGSize {
        let line = text.sizeThatFits(.unspecified, lc)
        let width = p.width.flatMap { $0.isFinite ? $0 : nil } ?? max(line.width, 100)
        // Champ iOS (mesuré) : ligne de 22 pt pour un texte de 17 pt (20,3 pt), plus 2 × 6 pt avec bordure (34 pt).
        let fieldLine = line.height * 22 / 20.333
        return CGSize(width: width, height: fieldLine + (bordered ? 12 : 0))
    }

    override func draw(in rect: CGRect, _ lc: LayoutContext, _ list: inout DisplayList) {
        if bordered {
            list.append(.fill(.roundedRectangle(cornerRadius: 6), rect, Color.secondarySystemGroupedBackground.resolve(in: lc.colorScheme)))
            list.append(.stroke(.roundedRectangle(cornerRadius: 6), rect.insetBy(dx: 0.25, dy: 0.25),
                                Color.separator.resolve(in: lc.colorScheme), lineWidth: 0.5))
        }
        let inner = CGRect(x: rect.minX + insets.leading, y: rect.minY + insets.top,
                           width: rect.width - insets.horizontal, height: rect.height - insets.vertical)
        let s = text.sizeThatFits(ProposedViewSize(width: inner.width, height: nil), lc)
        let textRect = CGRect(x: inner.minX, y: inner.midY - s.height / 2, width: min(s.width, inner.width), height: s.height)
        text.render(in: textRect, lc, &list)
        if focused {
            let x = caretAtEnd ? textRect.maxX + 1 : inner.minX
            list.append(.fill(.capsule, CGRect(x: x, y: inner.midY - s.height / 2 + 1, width: 2, height: s.height - 2),
                              caretColor.resolve(in: lc.colorScheme)))
        }
        list.append(.hitRegion(id: id, rect))
    }
}

extension TextField where Label == Text {
    public init<S: StringProtocol>(_ title: S, text: Binding<String>) {
        self.init(placeholder: String(title), text: text, secure: false)
    }

    public init<S: StringProtocol>(_ title: S, text: Binding<String>, prompt: Text?) {
        self.init(placeholder: prompt?.content ?? String(title), text: text, secure: false)
    }

    public init<S: StringProtocol>(_ title: S, text: Binding<String>, axis: Axis) {
        self.init(placeholder: String(title), text: text, secure: false)
    }
}

public struct SecureField<Label: View>: View, _PrimitiveView {
    public typealias Body = Never
    let field: TextField<Label>
    public func _makeNodes(_ context: BuildContext) -> [LayoutNode] { field._makeNodes(context) }
}

extension SecureField where Label == Text {
    public init<S: StringProtocol>(_ title: S, text: Binding<String>) {
        field = TextField(placeholder: String(title), text: text, secure: true)
    }
}

public enum _TextFieldStyleKind: Hashable, Sendable { case automatic, plain, roundedBorder }
public protocol TextFieldStyle { var _kind: _TextFieldStyleKind { get } }
public struct DefaultTextFieldStyle: TextFieldStyle { public init() {}; public var _kind: _TextFieldStyleKind { .automatic } }
public struct PlainTextFieldStyle: TextFieldStyle { public init() {}; public var _kind: _TextFieldStyleKind { .plain } }
public struct RoundedBorderTextFieldStyle: TextFieldStyle { public init() {}; public var _kind: _TextFieldStyleKind { .roundedBorder } }
extension TextFieldStyle where Self == DefaultTextFieldStyle { public static var automatic: Self { .init() } }
extension TextFieldStyle where Self == PlainTextFieldStyle { public static var plain: Self { .init() } }
extension TextFieldStyle where Self == RoundedBorderTextFieldStyle { public static var roundedBorder: Self { .init() } }

public struct UIKeyboardType: Sendable { public static let `default` = UIKeyboardType(), numberPad = UIKeyboardType(), decimalPad = UIKeyboardType(), emailAddress = UIKeyboardType(), URL = UIKeyboardType(), phonePad = UIKeyboardType() }
public struct TextInputAutocapitalization: Sendable { public static let never = Self(), words = Self(), sentences = Self(), characters = Self() }
public struct SubmitLabel: Sendable { public static let done = Self(), go = Self(), send = Self(), search = Self(), next = Self(), `return` = Self() }

extension View {
    public func textFieldStyle<S: TextFieldStyle>(_ style: S) -> some View {
        modifier(_EnvironmentModifier { $0.textFieldStyle = style._kind })
    }
    public func onSubmit(of triggers: SubmitTriggers = .text, _ action: @escaping () -> Void) -> some View {
        modifier(_EnvironmentModifier { $0.onSubmit = action })
    }
    public func keyboardType(_ type: UIKeyboardType) -> some View { self }
    public func textInputAutocapitalization(_ a: TextInputAutocapitalization?) -> some View { self }
    public func autocorrectionDisabled(_ disable: Bool = true) -> some View { self }
    public func submitLabel(_ label: SubmitLabel) -> some View { self }
    public func labelsHidden() -> some View { modifier(_EnvironmentModifier { $0.labelsHidden = true }) }
}

public struct SubmitTriggers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let text = SubmitTriggers(rawValue: 1)
    public static let search = SubmitTriggers(rawValue: 2)
}

/// `@FocusState` : accepté ; le focus réel est géré par le simulateur (toucher un champ).
@propertyWrapper
public struct FocusState<Value: Hashable>: _DynamicProperty {
    let state: State<Value>
    public init() where Value == Bool { state = State(wrappedValue: false) }
    public init<T: Hashable>() where Value == T? { state = State(wrappedValue: nil) }
    public var wrappedValue: Value {
        get { state.wrappedValue }
        nonmutating set { state.wrappedValue = newValue }
    }
    public var projectedValue: Binding<Value> { state.projectedValue }
    func _install(_ context: _InstallContext) { state._install(context) }
}

extension View {
    public func focused(_ condition: Binding<Bool>) -> some View { self }
    public func focused<V: Hashable>(_ binding: Binding<V?>, equals value: V) -> some View { self }
}

// MARK: - Slider

public struct Slider<Label: View>: View, _PrimitiveView {
    public typealias Body = Never
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let step: Double?
    /// Libellés des valeurs extrêmes (`minimumValueLabel` / `maximumValueLabel`), de part et d'autre.
    var minimumLabel: AnyView?
    var maximumLabel: AnyView?

    public func _makeNodes(_ context: BuildContext) -> [LayoutNode] {
        let track = makeTrack(context)
        guard minimumLabel != nil || maximumLabel != nil else { return track }
        var labelCtx = context.child("valueLabels")
        labelCtx.environment.foregroundColor = labelCtx.environment.foregroundColor ?? .primary
        var children: [LayoutNode] = []
        if let minimumLabel { children += LSimUI._makeNodes(minimumLabel, labelCtx.child("min")) }
        children += track
        if let maximumLabel { children += LSimUI._makeNodes(maximumLabel, labelCtx.child("max")) }
        return [StackNode(axis: .horizontal, crossAlignment: 0.5, spacing: nil, children: children)]
    }

    func makeTrack(_ context: BuildContext) -> [LayoutNode] {
        let id = context.path + "/Slider"
        let value = self.value, range = self.range, step = self.step
        let span = max(range.upperBound - range.lowerBound, .ulpOfOne)
        let fraction = min(1, max(0, (value.wrappedValue - range.lowerBound) / span))
        let tint = context.environment.tint ?? .accentColor
        let thumb = CGSize(width: 37, height: 24)
        var trackRect = CGRect.zero
        context.graph.registerDrag(id) { point in
            guard trackRect.width > 0 else { return }
            var f = (point.x - trackRect.minX - thumb.width / 2) / max(trackRect.width - thumb.width, 1)
            f = min(1, max(0, f))
            var v = range.lowerBound + Double(f) * span
            if let step, step > 0 { v = (v / step).rounded() * step }
            value.wrappedValue = v
        }
        return [DrawNode(size: { p in CGSize(width: p.width.flatMap { $0.isFinite ? $0 : nil } ?? 200, height: 31) }) { rect, lc, list in
            trackRect = rect
            let track = CGRect(x: rect.minX, y: rect.midY - 3, width: rect.width, height: 6)
            list.append(.fill(.capsule, track, Color.systemFill.resolve(in: lc.colorScheme)))
            let x = rect.minX + (rect.width - thumb.width) * CGFloat(fraction)
            list.append(.fill(.capsule, CGRect(x: track.minX, y: track.minY, width: x - track.minX + thumb.width / 2, height: 6),
                              tint.resolve(in: lc.colorScheme)))
            let knob = CGRect(x: x, y: rect.midY - thumb.height / 2, width: thumb.width, height: thumb.height)
            // Ombre douce tout autour du curseur (visible sur fond blanc), plus marquée vers le bas.
            list.append(.fill(.capsule, knob.insetBy(dx: -1, dy: -1).offsetBy(dx: 0, dy: 1), RGBA(0, 0, 0, 0.06)))
            list.append(.fill(.capsule, knob.insetBy(dx: -0.5, dy: -0.5), RGBA(0, 0, 0, 0.06)))
            list.append(.fill(.capsule, knob, RGBA(1, 1, 1)))
            list.append(.hitRegion(id: id, rect))
        }]
    }
}

extension Slider {
    public init<V: BinaryFloatingPoint, ValueLabel: View>(value: Binding<V>, in range: ClosedRange<V> = 0...1, step: V.Stride? = nil,
                                                          @ViewBuilder label: () -> Label,
                                                          @ViewBuilder minimumValueLabel: () -> ValueLabel,
                                                          @ViewBuilder maximumValueLabel: () -> ValueLabel,
                                                          onEditingChanged: @escaping (Bool) -> Void = { _ in }) where V.Stride: BinaryFloatingPoint {
        self.value = Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = V($0) })
        self.range = Double(range.lowerBound)...Double(range.upperBound)
        self.step = step.map { Double($0) }
        minimumLabel = AnyView(minimumValueLabel())
        maximumLabel = AnyView(maximumValueLabel())
    }

    public init<V: BinaryFloatingPoint>(value: Binding<V>, in range: ClosedRange<V> = 0...1, step: V.Stride? = nil,
                                        @ViewBuilder label: () -> Label,
                                        onEditingChanged: @escaping (Bool) -> Void = { _ in }) where V.Stride: BinaryFloatingPoint {
        self.value = Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = V($0) })
        self.range = Double(range.lowerBound)...Double(range.upperBound)
        self.step = step.map { Double($0) }
    }
}

extension Slider where Label == EmptyView {
    public init<V: BinaryFloatingPoint>(value: Binding<V>, in range: ClosedRange<V> = 0...1, step: V.Stride? = nil,
                                        onEditingChanged: @escaping (Bool) -> Void = { _ in }) where V.Stride: BinaryFloatingPoint {
        self.value = Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = V($0) })
        self.range = Double(range.lowerBound)...Double(range.upperBound)
        self.step = step.map { Double($0) }
    }
}

// MARK: - Stepper

public struct Stepper<Label: View>: View, _PrimitiveView {
    public typealias Body = Never
    let label: Label
    let increment: () -> Void
    let decrement: () -> Void
    /// Boutons actifs (un bouton à la borne de l'intervalle s'estompe, comme sur iPhone).
    var canIncrement = true
    var canDecrement = true

    public init(@ViewBuilder label: () -> Label, onIncrement: (() -> Void)?, onDecrement: (() -> Void)?) {
        self.label = label()
        self.increment = onIncrement ?? {}
        self.decrement = onDecrement ?? {}
    }

    public func _makeNodes(_ context: BuildContext) -> [LayoutNode] {
        let minusID = context.path + "/Stepper-", plusID = context.path + "/Stepper+"
        context.graph.registerAction(minusID, decrement)
        context.graph.registerAction(plusID, increment)
        let pressed = context.graph.pressedID
        let symbolFont = Font.system(size: 17, weight: .medium)
        let minus = SymbolNode(name: "minus", font: symbolFont, scale: .medium, color: .primary, resizable: false, contentMode: .fit)
        let plus = SymbolNode(name: "plus", font: symbolFont, scale: .medium, color: .primary, resizable: false, contentMode: .fit)
        let control = DrawNode(size: { _ in CGSize(width: 94, height: 32) }) { rect, lc, list in
            list.append(.fill(.capsule, rect, Color.tertiarySystemFill.resolve(in: lc.colorScheme)))
            let left = CGRect(x: rect.minX, y: rect.minY, width: rect.width / 2, height: rect.height)
            let right = CGRect(x: rect.midX, y: rect.minY, width: rect.width / 2, height: rect.height)
            // Trait central : 1 × 24 pt (couches mesurées).
            list.append(.fill(.rectangle, CGRect(x: rect.midX - 0.5, y: rect.midY - 12, width: 1, height: 24),
                              Color.separator.resolve(in: lc.colorScheme)))
            for (node, half, id, active) in [(minus, left, minusID, canDecrement), (plus, right, plusID, canIncrement)] {
                let s = node.sizeThatFits(.unspecified, lc)
                let dim = !active ? 0.3 : pressed == id ? 0.3 : 1
                if dim < 1 { list.append(.pushOpacity(dim)) }
                node.render(in: Alignment.center.place(s, in: half), lc, &list)
                if dim < 1 { list.append(.popOpacity) }
                if active { list.append(.hitRegion(id: id, half)) }
            }
        }
        if context.environment.labelsHidden { return [control] }
        var labelCtx = context.child("label")
        labelCtx.environment.isInList = false
        return [controlRow(LSimUI._makeNodes(label, labelCtx), context.environment.isInList ? RowOverflowNode(control) : control)]
    }
}

extension Stepper {
    public init<V: Strideable>(value: Binding<V>, in bounds: ClosedRange<V>, step: V.Stride = 1,
                               @ViewBuilder label: () -> Label, onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.init(label: label,
                  onIncrement: { value.wrappedValue = min(bounds.upperBound, value.wrappedValue.advanced(by: step)) },
                  onDecrement: { value.wrappedValue = max(bounds.lowerBound, value.wrappedValue.advanced(by: -step)) })
        canIncrement = value.wrappedValue < bounds.upperBound
        canDecrement = value.wrappedValue > bounds.lowerBound
    }

    public init<V: Strideable>(value: Binding<V>, step: V.Stride = 1,
                               @ViewBuilder label: () -> Label, onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.init(label: label,
                  onIncrement: { value.wrappedValue = value.wrappedValue.advanced(by: step) },
                  onDecrement: { value.wrappedValue = value.wrappedValue.advanced(by: -step) })
    }
}

extension Stepper where Label == Text {
    public init<S: StringProtocol, V: Strideable>(_ title: S, value: Binding<V>, in bounds: ClosedRange<V>, step: V.Stride = 1) {
        self.init(label: { Text(title) },
                  onIncrement: { value.wrappedValue = min(bounds.upperBound, value.wrappedValue.advanced(by: step)) },
                  onDecrement: { value.wrappedValue = max(bounds.lowerBound, value.wrappedValue.advanced(by: -step)) })
        canIncrement = value.wrappedValue < bounds.upperBound
        canDecrement = value.wrappedValue > bounds.lowerBound
    }

    public init<S: StringProtocol, V: Strideable>(_ title: S, value: Binding<V>, step: V.Stride = 1) {
        self.init(label: { Text(title) },
                  onIncrement: { value.wrappedValue = value.wrappedValue.advanced(by: step) },
                  onDecrement: { value.wrappedValue = value.wrappedValue.advanced(by: -step) })
    }

    public init<S: StringProtocol>(_ title: S, onIncrement: (() -> Void)?, onDecrement: (() -> Void)?) {
        self.init(label: { Text(title) }, onIncrement: onIncrement, onDecrement: onDecrement)
    }
}

// MARK: - Picker (style menu par défaut, et segmenté)

/// `.tag(valeur)` : valeur associée à une option de Picker.
final class TagNode: SingleChildNode {
    let tag: AnyHashable
    init(_ child: LayoutNode, tag: AnyHashable) {
        self.tag = tag
        super.init(child)
    }
}

extension View {
    public func tag<V: Hashable>(_ tag: V, includeOptional: Bool = true) -> some View {
        modifier(_NodeModifier { node, _ in TagNode(node, tag: AnyHashable(tag)) })
    }
}

public enum _PickerStyleKind: Hashable, Sendable { case automatic, menu, segmented, inline, wheel, navigationLink, palette }
public protocol PickerStyle { var _kind: _PickerStyleKind { get } }
public struct DefaultPickerStyle: PickerStyle { public init() {}; public var _kind: _PickerStyleKind { .automatic } }
public struct MenuPickerStyle: PickerStyle { public init() {}; public var _kind: _PickerStyleKind { .menu } }
public struct SegmentedPickerStyle: PickerStyle { public init() {}; public var _kind: _PickerStyleKind { .segmented } }
public struct InlinePickerStyle: PickerStyle { public init() {}; public var _kind: _PickerStyleKind { .inline } }
public struct WheelPickerStyle: PickerStyle { public init() {}; public var _kind: _PickerStyleKind { .wheel } }
public struct NavigationLinkPickerStyle: PickerStyle { public init() {}; public var _kind: _PickerStyleKind { .navigationLink } }
extension PickerStyle where Self == DefaultPickerStyle { public static var automatic: Self { .init() } }
extension PickerStyle where Self == MenuPickerStyle { public static var menu: Self { .init() } }
extension PickerStyle where Self == SegmentedPickerStyle { public static var segmented: Self { .init() } }
extension PickerStyle where Self == InlinePickerStyle { public static var inline: Self { .init() } }
extension PickerStyle where Self == WheelPickerStyle { public static var wheel: Self { .init() } }
extension PickerStyle where Self == NavigationLinkPickerStyle { public static var navigationLink: Self { .init() } }

extension View {
    public func pickerStyle<S: PickerStyle>(_ style: S) -> some View {
        modifier(_EnvironmentModifier { $0.pickerStyle = style._kind })
    }
}

public struct Picker<Label: View, SelectionValue: Hashable, Content: View>: View, _PrimitiveView {
    public typealias Body = Never
    let selection: Binding<SelectionValue>
    let label: Label
    let content: Content

    public init(selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
        self.selection = selection
        self.content = content()
        self.label = label()
    }

    public func _makeNodes(_ context: BuildContext) -> [LayoutNode] {
        var optionCtx = context.child("options")
        optionCtx.environment.isInList = false
        let options: [(tag: AnyHashable, title: String, node: LayoutNode)] = LSimUI._makeNodes(content, optionCtx).compactMap { node in
            var n: LayoutNode? = node
            while let current = n {
                if let tagged = current as? TagNode { return (tagged.tag, firstText(in: tagged.child) ?? "", tagged.child) }
                n = (current as? SingleChildNode)?.child
            }
            return nil
        }
        let selection = self.selection
        let current = AnyHashable(selection.wrappedValue)
        let index = options.firstIndex { $0.tag == current }
        func select(_ i: Int) {
            if let value = options[i].tag.base as? SelectionValue { selection.wrappedValue = value }
        }

        if context.environment.pickerStyle == .segmented {
            let ids = options.indices.map { context.path + "/Picker#\($0)" }
            for i in options.indices { context.graph.registerAction(ids[i]) { select(i) } }
            let font = Font.system(size: 13, weight: .medium)
            let texts = options.map { TextNode($0.title, font: font, color: .primary, alignment: .center) }
            return [DrawNode(size: { p in CGSize(width: p.width.flatMap { $0.isFinite ? $0 : nil } ?? CGFloat(options.count) * 80, height: 32) }) { rect, lc, list in
                list.append(.fill(.capsule, rect, Color.tertiarySystemFill.resolve(in: lc.colorScheme)))
                let w = rect.width / CGFloat(max(options.count, 1))
                for i in options.indices {
                    let cell = CGRect(x: rect.minX + CGFloat(i) * w, y: rect.minY, width: w, height: rect.height)
                    if i == index {
                        let thumb = cell.insetBy(dx: 2, dy: 2)
                        list.append(.fill(.capsule, thumb.offsetBy(dx: 0, dy: 1), RGBA(0, 0, 0, 0.06)))
                        list.append(.fill(.capsule, thumb, lc.colorScheme == .light ? RGBA(1, 1, 1) : .rgb255(99, 99, 102)))
                    }
                    let s = texts[i].sizeThatFits(ProposedViewSize(width: w - 8, height: nil), lc)
                    texts[i].render(in: Alignment.center.place(s, in: cell), lc, &list)
                    list.append(.hitRegion(id: ids[i], cell))
                }
            }]
        }

        // Style menu : « Libellé … Valeur ⌃⌄ ». Toucher passe à l'option suivante (en attendant le vrai menu).
        let id = context.path + "/Picker"
        if !options.isEmpty {
            context.graph.registerAction(id) { select(((index ?? -1) + 1) % options.count) }
        }
        // Hors liste : bouton teinté « Valeur ⌃⌄ », sans libellé, marges 12 × 7 (106 × 34,3 pt mesurés pour
        // « Semaine ») ; en liste : libellé à gauche, valeur grise à droite.
        let inList = context.environment.isInList
        let valueColor: Color = inList ? .secondary : (context.environment.tint ?? .accentColor)
        let valueText = TextNode(index.map { options[$0].title } ?? "", font: context.environment.font ?? .body,
                                 color: valueColor, alignment: .leading)
        let chevrons = SymbolNode(name: "chevron.up.chevron.down", font: .system(size: 13, weight: .medium), scale: .medium,
                                  color: valueColor, resizable: false, contentMode: .fit)
        let trailing = StackNode(axis: .horizontal, crossAlignment: 0.5, spacing: inList ? 5 : 4, children: [valueText, chevrons])
        if !inList || context.environment.labelsHidden {
            let button = PaddingNode(trailing, insets: EdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12))
            return [TapNode(button, id: id, isPressed: context.graph.pressedID == id, pressedOpacity: 0.5)]
        }
        var labelCtx = context.child("label")
        labelCtx.environment.isInList = false
        let row = controlRow(LSimUI._makeNodes(label, labelCtx), trailing)
        return [TapNode(row, id: id, isPressed: context.graph.pressedID == id, pressedOpacity: 0.5)]
    }
}

extension Picker where Label == Text {
    public init<S: StringProtocol>(_ title: S, selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content) {
        self.init(selection: selection, content: content) { Text(title) }
    }
}

// MARK: - DatePicker (style compact)

public struct DatePickerComponents: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let date = DatePickerComponents(rawValue: 1)
    public static let hourAndMinute = DatePickerComponents(rawValue: 2)
}

public struct DatePicker<Label: View>: View, _PrimitiveView {
    public typealias Body = Never
    let selection: Binding<Date>
    let components: DatePickerComponents
    let label: Label

    public init(selection: Binding<Date>, displayedComponents: DatePickerComponents = [.date, .hourAndMinute],
                @ViewBuilder label: () -> Label) {
        self.selection = selection
        self.components = displayedComponents
        self.label = label()
    }

    public func _makeNodes(_ context: BuildContext) -> [LayoutNode] {
        let date = selection.wrappedValue
        var pills: [LayoutNode] = []
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        if components.contains(.date) {
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            pills.append(pill(formatter.string(from: date)))
        }
        if components.contains(.hourAndMinute) {
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            pills.append(pill(formatter.string(from: date)))
        }
        let trailing = StackNode(axis: .horizontal, crossAlignment: 0.5, spacing: 6, children: pills)
        var labelCtx = context.child("label")
        labelCtx.environment.isInList = false
        return [controlRow(LSimUI._makeNodes(label, labelCtx), trailing)]
    }

    func pill(_ text: String) -> LayoutNode {
        let t = TextNode(text, font: .body, color: .primary, alignment: .leading)
        let padded = PaddingNode(t, insets: EdgeInsets(top: 6, leading: 11, bottom: 6, trailing: 11))
        return LayerNode(padded, layer: [ShapeNode(.roundedRectangle(cornerRadius: 8), color: .tertiarySystemFill)],
                         alignment: .center, isBackground: true)
    }
}

extension DatePicker where Label == Text {
    public init<S: StringProtocol>(_ title: S, selection: Binding<Date>, displayedComponents: DatePickerComponents = [.date, .hourAndMinute]) {
        self.init(selection: selection, displayedComponents: displayedComponents) { Text(title) }
    }

    public init<S: StringProtocol>(_ title: S, selection: Binding<Date>, in range: ClosedRange<Date>,
                                   displayedComponents: DatePickerComponents = [.date, .hourAndMinute]) {
        self.init(selection: selection, displayedComponents: displayedComponents) { Text(title) }
    }
}

// MARK: - ProgressView

public struct ProgressView<Label: View>: View, _PrimitiveView {
    public typealias Body = Never
    let fraction: Double?
    let label: Label?

    public func _makeNodes(_ context: BuildContext) -> [LayoutNode] {
        let tint = context.environment.tint ?? .accentColor
        let labelNodes = label.map { LSimUI._makeNodes($0, context.child("label")) } ?? []
        let indicator: LayoutNode
        if let fraction {
            indicator = DrawNode(size: { p in CGSize(width: p.width.flatMap { $0.isFinite ? $0 : nil } ?? 200, height: 4) }) { rect, lc, list in
                list.append(.fill(.capsule, rect, Color.systemFill.resolve(in: lc.colorScheme)))
                let w = rect.width * CGFloat(min(1, max(0, fraction)))
                list.append(.fill(.capsule, CGRect(x: rect.minX, y: rect.minY, width: w, height: rect.height), tint.resolve(in: lc.colorScheme)))
            }
        } else {
            // Indicateur d'activité : 8 rayons de gris dégradé (image figée).
            indicator = DrawNode(size: { _ in CGSize(width: 20, height: 20) }) { rect, lc, list in
                for i in 0..<8 {
                    let a = Double(i) / 8 * 2 * .pi
                    let c = CGPoint(x: rect.midX + 6.5 * CGFloat(sin(a)), y: rect.midY - 6.5 * CGFloat(cos(a)))
                    let alpha = 0.25 + 0.75 * Double(i) / 7
                    let base = Color.secondary.resolve(in: lc.colorScheme)
                    list.append(.fill(.circle, CGRect(x: c.x - 1.6, y: c.y - 1.6, width: 3.2, height: 3.2), RGBA(base.r, base.g, base.b, alpha)))
                }
            }
        }
        if labelNodes.isEmpty { return [indicator] }
        return [StackNode(axis: .vertical, crossAlignment: fraction == nil ? 0.5 : 0, spacing: 8, children: (fraction == nil ? [indicator] + labelNodes : labelNodes + [indicator]))]
    }
}

extension ProgressView where Label == EmptyView {
    public init() { fraction = nil; label = nil }
    public init<V: BinaryFloatingPoint>(value: V?, total: V = 1.0) {
        fraction = value.map { Double($0) / Double(total) }
        label = nil
    }
}

extension ProgressView where Label == Text {
    public init<S: StringProtocol>(_ title: S) { fraction = nil; label = Text(title) }
    public init<S: StringProtocol, V: BinaryFloatingPoint>(_ title: S, value: V?, total: V = 1.0) {
        fraction = value.map { Double($0) / Double(total) }
        label = Text(title)
    }
}

// MARK: - Link, AsyncImage

public struct Link<Label: View>: View, _PrimitiveView {
    public typealias Body = Never
    let destination: URL
    let label: Label

    public init(destination: URL, @ViewBuilder label: () -> Label) {
        self.destination = destination
        self.label = label()
    }

    public func _makeNodes(_ context: BuildContext) -> [LayoutNode] {
        let destination = self.destination
        return Button(action: { print("[LSim] Le lien ouvrirait : \(destination.absoluteString)") }, label: { label })._makeNodes(context)
    }
}

extension Link where Label == Text {
    public init<S: StringProtocol>(_ title: S, destination: URL) {
        self.init(destination: destination) { Text(title) }
    }
}

/// Image téléchargée : le simulateur n'effectue pas encore la requête et montre l'espace réservé.
public struct AsyncImage<Content: View>: View, _PrimitiveView {
    public typealias Body = Never
    let placeholder: AnyView

    public func _makeNodes(_ context: BuildContext) -> [LayoutNode] {
        placeholder._makeNodes(context.child("placeholder"))
    }
}

extension AsyncImage where Content == AnyView {
    public init(url: URL?, scale: CGFloat = 1) {
        placeholder = AnyView(Color.gray.opacity(0.2))
    }

    public init<I: View, P: View>(url: URL?, scale: CGFloat = 1, @ViewBuilder content: @escaping (Image) -> I,
                                  @ViewBuilder placeholder: () -> P) {
        self.placeholder = AnyView(placeholder())
    }
}
