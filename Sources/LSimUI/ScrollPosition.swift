import Foundation

// Position de défilement pilotée par le code (iOS 18) : `ScrollPosition` et `.scrollPosition($position)`.

public struct ScrollPosition: Hashable, Sendable {
    /// Point demandé (décalage du contenu, 0 = position de repos en haut).
    public private(set) var point: CGPoint?
    public private(set) var edge: Edge?
    public var isPositionedByUser: Bool { false }
    /// Incrémenté à chaque demande : la zone de défilement n'applique qu'une fois chaque demande.
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
        // Défilement vers un identifiant : pas encore suivi par LSim (il faudrait la position des vues).
        generation += 1
    }

    /// Décalage vertical demandé (nil : aucune demande en points), `.infinity` pour le bas.
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

/// Dernière demande appliquée par une zone de défilement (persistante dans le graphe).
final class AppliedScrollRequest {
    var generation = 0
}
