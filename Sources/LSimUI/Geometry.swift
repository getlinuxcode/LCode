import Foundation

public enum Axis: Hashable, Sendable {
    case horizontal, vertical

    var other: Axis { self == .horizontal ? .vertical : .horizontal }
}

/// Taille proposée par un parent à un enfant. `nil` = taille idéale, `.infinity` = maximum.
public struct ProposedViewSize: Hashable, Sendable {
    public var width: CGFloat?
    public var height: CGFloat?

    public init(width: CGFloat?, height: CGFloat?) {
        self.width = width
        self.height = height
    }

    public init(_ size: CGSize) {
        self.init(width: size.width, height: size.height)
    }

    public static let zero = ProposedViewSize(width: 0, height: 0)
    public static let unspecified = ProposedViewSize(width: nil, height: nil)
    public static let infinity = ProposedViewSize(width: .infinity, height: .infinity)

    public func replacingUnspecifiedDimensions(by size: CGSize = CGSize(width: 10, height: 10)) -> CGSize {
        CGSize(width: width ?? size.width, height: height ?? size.height)
    }

    subscript(axis: Axis) -> CGFloat? {
        get { axis == .horizontal ? width : height }
        set { if axis == .horizontal { width = newValue } else { height = newValue } }
    }

    init(along: CGFloat?, cross: CGFloat?, axis: Axis) {
        if axis == .horizontal { self.init(width: along, height: cross) } else { self.init(width: cross, height: along) }
    }
}

extension CGSize {
    subscript(axis: Axis) -> CGFloat {
        get { axis == .horizontal ? width : height }
        set { if axis == .horizontal { width = newValue } else { height = newValue } }
    }

    init(along: CGFloat, cross: CGFloat, axis: Axis) {
        if axis == .horizontal { self.init(width: along, height: cross) } else { self.init(width: cross, height: along) }
    }
}

extension CGPoint {
    init(along: CGFloat, cross: CGFloat, axis: Axis) {
        if axis == .horizontal { self.init(x: along, y: cross) } else { self.init(x: cross, y: along) }
    }
}

public struct EdgeInsets: Hashable, Sendable {
    public var top: CGFloat, leading: CGFloat, bottom: CGFloat, trailing: CGFloat

    public init(top: CGFloat = 0, leading: CGFloat = 0, bottom: CGFloat = 0, trailing: CGFloat = 0) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }

    var horizontal: CGFloat { leading + trailing }
    var vertical: CGFloat { top + bottom }
}

public enum Edge: Int8, CaseIterable, Sendable {
    case top, leading, bottom, trailing

    public struct Set: OptionSet, Sendable {
        public let rawValue: Int8
        public init(rawValue: Int8) { self.rawValue = rawValue }
        public init(_ edge: Edge) { self.rawValue = 1 << edge.rawValue }

        public static let top = Set(.top)
        public static let leading = Set(.leading)
        public static let bottom = Set(.bottom)
        public static let trailing = Set(.trailing)
        public static let horizontal: Set = [.leading, .trailing]
        public static let vertical: Set = [.top, .bottom]
        public static let all: Set = [.horizontal, .vertical]
    }
}

// MARK: - Alignements

public struct HorizontalAlignment: Hashable, Sendable {
    let fraction: CGFloat
    public static let leading = HorizontalAlignment(fraction: 0)
    public static let center = HorizontalAlignment(fraction: 0.5)
    public static let trailing = HorizontalAlignment(fraction: 1)
}

public struct VerticalAlignment: Hashable, Sendable {
    let fraction: CGFloat
    public static let top = VerticalAlignment(fraction: 0)
    public static let center = VerticalAlignment(fraction: 0.5)
    public static let bottom = VerticalAlignment(fraction: 1)
    // Approximation : les lignes de base sont traitées comme le centre / le bas.
    public static let firstTextBaseline = VerticalAlignment(fraction: 0.5)
    public static let lastTextBaseline = VerticalAlignment(fraction: 1)
}

public struct Alignment: Hashable, Sendable {
    public var horizontal: HorizontalAlignment
    public var vertical: VerticalAlignment

    public init(horizontal: HorizontalAlignment, vertical: VerticalAlignment) {
        self.horizontal = horizontal
        self.vertical = vertical
    }

    public static let center = Alignment(horizontal: .center, vertical: .center)
    public static let leading = Alignment(horizontal: .leading, vertical: .center)
    public static let trailing = Alignment(horizontal: .trailing, vertical: .center)
    public static let top = Alignment(horizontal: .center, vertical: .top)
    public static let bottom = Alignment(horizontal: .center, vertical: .bottom)
    public static let topLeading = Alignment(horizontal: .leading, vertical: .top)
    public static let topTrailing = Alignment(horizontal: .trailing, vertical: .top)
    public static let bottomLeading = Alignment(horizontal: .leading, vertical: .bottom)
    public static let bottomTrailing = Alignment(horizontal: .trailing, vertical: .bottom)

    /// Position d'un enfant de taille `size` dans `rect`.
    func place(_ size: CGSize, in rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX + (rect.width - size.width) * horizontal.fraction,
            y: rect.minY + (rect.height - size.height) * vertical.fraction,
            width: size.width,
            height: size.height
        )
    }
}

public enum TextAlignment: Hashable, Sendable {
    case leading, center, trailing
}
