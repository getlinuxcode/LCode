import Foundation

// Programmatic scrolling (iOS 18): `ScrollPosition` and `.scrollPosition($position)`.

public struct ScrollPosition: Hashable, Sendable {
    /// Requested content offset (0 = resting position at the top).
    public private(set) var point: CGPoint?
    public private(set) var edge: Edge?
    public var isPositionedByUser: Bool { false }
    /// Bumped on each request so a scroll view applies each request only once.
    var generation = 0

    public init(edge: Edge? = nil) {
        self.edge = edge
        if edge != nil { generation = 1 }
    }

    public init(point: CGPoint) {
        self.point = point
        generation = 1
    }

    public init(x: CGFloat = 0, y: CGFloat) { self.init(point: CGPoint(x: x, y: y)) }
    public init(x: CGFloat) { self.init(point: CGPoint(x: x, y: 0)) }

    public init<ID: Hashable>(idType: ID.Type = ID.self, edge: Edge? = nil) { self.init(edge: edge) }

    public mutating func scrollTo(point: CGPoint) {
        self.point = point
        edge = nil
        generation += 1
    }

    public mutating func scrollTo(x: CGFloat) { scrollTo(point: CGPoint(x: x, y: point?.y ?? 0)) }
    public mutating func scrollTo(y: CGFloat) { scrollTo(point: CGPoint(x: point?.x ?? 0, y: y)) }
    public mutating func scrollTo(x: CGFloat, y: CGFloat) { scrollTo(point: CGPoint(x: x, y: y)) }

    public mutating func scrollTo(edge: Edge) {
        self.edge = edge
        point = nil
        generation += 1
    }

    public mutating func scrollTo<ID: Hashable>(id: ID, anchor: UnitPoint? = nil) {
        // Scrolling to an id is not supported yet (would need view positions).
        generation += 1
    }

    /// Requested vertical offset (nil: no point-based request), `.infinity` for the bottom.
    var requestedY: CGFloat? {
        if let point { return point.y }
        switch edge {
        case .top?: return 0
        case .bottom?: return .infinity
        default: return nil
        }
    }
}

private struct ScrollPositionKey: EnvironmentKey {
    static let defaultValue: Binding<ScrollPosition>? = nil
}

extension EnvironmentValues {
    var scrollPosition: Binding<ScrollPosition>? {
        get { self[ScrollPositionKey.self] }
        set { self[ScrollPositionKey.self] = newValue }
    }
}

struct _ScrollPositionModifier: _PrimitiveModifier {
    let position: Binding<ScrollPosition>
    func _apply(_ context: BuildContext, _ content: (BuildContext) -> [LayoutNode]) -> [LayoutNode] {
        var ctx = context
        ctx.environment.scrollPosition = position
        return content(ctx)
    }
}

extension View {
    public func scrollPosition(_ position: Binding<ScrollPosition>, anchor: UnitPoint? = nil) -> some View {
        modifier(_ScrollPositionModifier(position: position))
    }
}

/// Last request applied by a scroll view (persisted in the graph).
final class AppliedScrollRequest {
    var generation = 0
}
