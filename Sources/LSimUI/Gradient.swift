import Foundation

// Dégradés : LinearGradient (vue et style de remplissage), Gradient, Color.gradient.

public struct Gradient: Hashable, Sendable {
    public struct Stop: Hashable, Sendable {
        public var color: Color
        public var location: CGFloat
        public init(color: Color, location: CGFloat) {
            self.color = color
            self.location = location
        }
    }

    public var stops: [Stop]

    public init(stops: [Stop]) { self.stops = stops }

    public init(colors: [Color]) {
        let n = max(colors.count - 1, 1)
        stops = colors.enumerated().map { Stop(color: $1, location: CGFloat($0) / CGFloat(n)) }
    }
}

public struct LinearGradient: View, _PrimitiveView, ShapeStyle {
    public typealias Body = Never
    let gradient: Gradient
    let startPoint: UnitPoint
    let endPoint: UnitPoint

    public init(gradient: Gradient, startPoint: UnitPoint, endPoint: UnitPoint) {
        self.gradient = gradient
        self.startPoint = startPoint
        self.endPoint = endPoint
    }

    public init(colors: [Color], startPoint: UnitPoint, endPoint: UnitPoint) {
        self.init(gradient: Gradient(colors: colors), startPoint: startPoint, endPoint: endPoint)
    }

    public init(stops: [Gradient.Stop], startPoint: UnitPoint, endPoint: UnitPoint) {
        self.init(gradient: Gradient(stops: stops), startPoint: startPoint, endPoint: endPoint)
    }

    public func _makeNodes(_ context: BuildContext) -> [LayoutNode] {
        [GradientNode(gradient: gradient, start: startPoint, end: endPoint, shape: .rectangle)]
    }
}

/// Remplit la place proposée avec un dégradé linéaire.
final class GradientNode: LayoutNode {
    let gradient: Gradient
    let start: UnitPoint
    let end: UnitPoint
    let shape: ShapeKind

    init(gradient: Gradient, start: UnitPoint, end: UnitPoint, shape: ShapeKind) {
        self.gradient = gradient
        self.start = start
        self.end = end
        self.shape = shape
    }

    override func computeSize(_ p: ProposedViewSize, _ lc: LayoutContext) -> CGSize {
        p.replacingUnspecifiedDimensions()
    }

    override func draw(in rect: CGRect, _ lc: LayoutContext, _ list: inout DisplayList) {
        let stops = gradient.stops.map { ($0.color.resolve(in: lc.colorScheme), $0.location) }
        let p0 = CGPoint(x: rect.minX + rect.width * start.x, y: rect.minY + rect.height * start.y)
        let p1 = CGPoint(x: rect.minX + rect.width * end.x, y: rect.minY + rect.height * end.y)
        list.append(.linearGradient(shape, rect, stops.map(\.0), stops.map(\.1), p0, p1))
    }
}

extension Shape {
    /// `.fill(LinearGradient(…))`.
    public func fill(_ gradient: LinearGradient) -> some View {
        _GradientShape(kind: _kind, gradient: gradient)
    }
}

struct _GradientShape: View, _PrimitiveView {
    typealias Body = Never
    let kind: ShapeKind
    let gradient: LinearGradient
    func _makeNodes(_ context: BuildContext) -> [LayoutNode] {
        [GradientNode(gradient: gradient.gradient, start: gradient.startPoint, end: gradient.endPoint, shape: kind)]
    }
}
