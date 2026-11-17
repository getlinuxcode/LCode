import Foundation

// MARK: - Text

public struct Text: View, _PrimitiveView, Equatable {
    public typealias Body = Never

    public enum Case: Hashable, Sendable { case uppercase, lowercase }

    let content: String
    var font: Font?
    var weight: Font.Weight?
    var isItalic = false
    var strike = false
    var underlined = false
    var color: Color?

    public init<S: StringProtocol>(_ content: S) {
        self.content = String(content)
    }

    public init(verbatim content: String) {
        self.content = content
    }

    public func font(_ font: Font?) -> Text { var t = self; t.font = font; return t }
    public func fontWeight(_ weight: Font.Weight?) -> Text { var t = self; t.weight = weight; return t }
    public func bold() -> Text { fontWeight(.bold) }
    public func bold(_ isActive: Bool) -> Text { isActive ? bold() : self }
    public func italic() -> Text { var t = self; t.isItalic = true; return t }
    public func strikethrough(_ isActive: Bool = true, color: Color? = nil) -> Text { var t = self; t.strike = isActive; return t }
    public func underline(_ isActive: Bool = true, color: Color? = nil) -> Text { var t = self; t.underlined = isActive; return t }
    public func monospacedDigit() -> Text { self }
    public func kerning(_ kerning: CGFloat) -> Text { self }
    public func tracking(_ tracking: CGFloat) -> Text { self }
    public func foregroundColor(_ color: Color?) -> Text { var t = self; t.color = color; return t }
    public func foregroundStyle(_ color: Color) -> Text { foregroundColor(color) }

    public func _makeNodes(_ context: BuildContext) -> [LayoutNode] {
        let env = context.environment
        var resolved = font ?? env.font ?? .body
        if let w = weight ?? env.fontWeight { resolved.weight = w }
        if isItalic || env.isItalic { resolved.isItalic = true }
        resolved.isStrikethrough = strike
        resolved.isUnderline = underlined
        var fg = (color ?? env.foregroundColor ?? .primary).resolvingTint(env)
        if !env.isEnabled { fg = .tertiaryLabel }
        var string = content
        switch env.textCase {
        case .uppercase: string = string.uppercased()
        case .lowercase: string = string.lowercased()
        case nil: break
        }
        return [TextNode(string, font: resolved, color: fg, alignment: env.multilineTextAlignment)]
    }
}

// MARK: - Stacks

public struct VStack<Content: View>: View, _PrimitiveView {
    public typealias Body = Never
    let alignment: HorizontalAlignment
    let spacing: CGFloat?
    let content: Content

    public init(alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.alignment = alignment
        self.spacing = spacing
        self.content = content()
    }

    public func _makeNodes(_ context: BuildContext) -> [LayoutNode] {
        [StackNode(axis: .vertical, crossAlignment: alignment.fraction, spacing: spacing,
                   children: LSimUI._makeNodes(content, context.child("VStack")))]
    }
}

public struct HStack<Content: View>: View, _PrimitiveView {
    public typealias Body = Never
    let alignment: VerticalAlignment
    let spacing: CGFloat?
    let content: Content

    public init(alignment: VerticalAlignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.alignment = alignment
        self.spacing = spacing
        self.content = content()
    }

    public func _makeNodes(_ context: BuildContext) -> [LayoutNode] {
        [StackNode(axis: .horizontal, crossAlignment: alignment.fraction, spacing: spacing,
                   children: LSimUI._makeNodes(content, context.child("HStack")))]
    }
}

public struct ZStack<Content: View>: View, _PrimitiveView {
    public typealias Body = Never
    let alignment: Alignment
    let content: Content

    public init(alignment: Alignment = .center, @ViewBuilder content: () -> Content) {
        self.alignment = alignment
        self.content = content()
    }

    public func _makeNodes(_ context: BuildContext) -> [LayoutNode] {
        [ZStackNode(alignment: alignment, children: LSimUI._makeNodes(content, context.child("ZStack")))]
    }
}

public struct Spacer: View, _PrimitiveView {
    public typealias Body = Never
    let minLength: CGFloat?

    public init(minLength: CGFloat? = nil) {
        self.minLength = minLength
    }

    public func _makeNodes(_ context: BuildContext) -> [LayoutNode] {
        [SpacerNode(minLength: minLength ?? StackNode.defaultSpacing)]
    }
}

public struct Divider: View, _PrimitiveView {
    public typealias Body = Never
    public init() {}
    public func _makeNodes(_ context: BuildContext) -> [LayoutNode] { [DividerNode()] }
}

// MARK: - Colors and shapes

extension Color: View, _PrimitiveView {
    public typealias Body = Never
    public func _makeNodes(_ context: BuildContext) -> [LayoutNode] {
        [ShapeNode(.rectangle, color: self)]
    }
}

public protocol Shape: View, _PrimitiveView where Body == Never {
    var _kind: ShapeKind { get }
}

extension Shape {
    public func _makeNodes(_ context: BuildContext) -> [LayoutNode] {
        [ShapeNode(_kind, color: context.environment.foregroundColor ?? .primary)]
    }

    public func fill(_ color: Color) -> _FilledShape { _FilledShape(kind: _kind, color: color) }
    public func foregroundColor(_ color: Color) -> _FilledShape { fill(color) }
}

public struct _FilledShape: View, _PrimitiveView {
    public typealias Body = Never
    let kind: ShapeKind
    let color: Color
    public func _makeNodes(_ context: BuildContext) -> [LayoutNode] { [ShapeNode(kind, color: color)] }
}

public struct Rectangle: Shape {
    public init() {}
    public var _kind: ShapeKind { .rectangle }
}

public struct RoundedRectangle: Shape {
    let cornerRadius: CGFloat
    public init(cornerRadius: CGFloat, style: RoundedCornerStyle = .continuous) {
        self.cornerRadius = cornerRadius
    }
    public var _kind: ShapeKind { .roundedRectangle(cornerRadius: cornerRadius) }
}

public enum RoundedCornerStyle: Sendable { case circular, continuous }

public struct Capsule: Shape {
    public init(style: RoundedCornerStyle = .continuous) {}
    public var _kind: ShapeKind { .capsule }
}

public struct Circle: Shape {
    public init() {}
    public var _kind: ShapeKind { .circle }
}

public struct Ellipse: Shape {
    public init() {}
    public var _kind: ShapeKind { .ellipse }
}
