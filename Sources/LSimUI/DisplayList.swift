import Foundation

public enum ShapeKind: Hashable, Sendable {
    case rectangle
    case roundedRectangle(cornerRadius: CGFloat)
    case capsule
    case ellipse
    case circle
}

/// Liste d'instructions de dessin, indépendante du backend graphique.
public enum DisplayItem {
    case fill(ShapeKind, CGRect, RGBA)
    case stroke(ShapeKind, CGRect, RGBA, lineWidth: CGFloat)
    case text(String, Font, CGRect, RGBA, TextAlignment)
    /// Symbole SF Symbols, ajusté au rectangle.
    case symbol(String, Font, Image.Scale, CGRect, RGBA)
    /// Image du catalogue d'assets (fichier PNG, JPEG, SVG…), étirée au rectangle.
    case image(String, CGRect)
    /// Chevron (›) ou flèche de retour (‹) dessinés en traits.
    case chevron(CGRect, RGBA, lineWidth: CGFloat, pointingLeft: Bool)
    case pushOpacity(Double)
    case popOpacity
    /// Translation et mise à l'échelle autour d'un point (transitions).
    case pushTransform(dx: CGFloat, dy: CGFloat, scale: CGFloat, anchor: CGPoint)
    case popTransform
    case pushClip(ShapeKind, CGRect)
    case popClip
    /// Fondu vertical d'une couleur opaque (en haut) vers transparent (en bas).
    case fade(CGRect, RGBA)
    /// Matière : floute ce qui est déjà dessiné dans la zone, puis applique un voile coloré.
    case backdrop(CGRect, blur: CGFloat, tint: RGBA, shape: ShapeKind = .rectangle)
    /// Effet de bord de défilement mesuré : flou progressif, transmission et voile ligne par ligne.
    /// Le second rectangle situe la table (son y = 0 est en haut de ce rectangle, décalé de `shift`).
    case scrollEdge(CGRect, ScrollEdgeTable, shift: CGFloat)
    /// Dégradé linéaire dans une forme : couleurs, positions (0…1), points de départ et d'arrivée.
    case linearGradient(ShapeKind, CGRect, [RGBA], [CGFloat], CGPoint, CGPoint)
    /// Liquid Glass : réfraction, flou, saturation, voile et liseré sur ce qui est déjà dessiné.
    case glass(ShapeKind, CGRect, GlassRender)
    /// Zone interactive (bouton, onTapGesture). Les dernières zones dessinées sont au-dessus.
    case hitRegion(id: String, CGRect)
    /// Repère de mesure (`accessibilityIdentifier`) : cadre de la vue identifiée.
    case marker(id: String, CGRect)
    /// Zone de geste de glisser (retour par balayage, feuille tirée vers le bas) ; `vertical` : sens du geste.
    case panRegion(id: String, CGRect, vertical: Bool)
    /// Zone défilable : identifiant d'état, zone visible.
    case scrollRegion(id: String, CGRect)
}

public struct DisplayList {
    public var items: [DisplayItem] = []
    private var clips: [CGRect] = []

    public init() {}

    mutating func append(_ item: DisplayItem) {
        switch item {
        case let .pushClip(_, rect):
            clips.append(clips.last.map { $0.intersection(rect) } ?? rect)
        case .popClip:
            _ = clips.popLast()
        case let .hitRegion(id, rect):
            // Une zone interactive masquée par un découpage (liste défilée) n'est pas touchable.
            let visible = clips.last.map { $0.intersection(rect) } ?? rect
            guard !visible.isNull, !visible.isEmpty else { return }
            items.append(.hitRegion(id: id, visible))
            return
        case let .scrollRegion(id, rect):
            let visible = clips.last.map { $0.intersection(rect) } ?? rect
            items.append(.scrollRegion(id: id, visible))
            return
        default:
            break
        }
        items.append(item)
    }

    /// Ajoute les éléments d'une autre liste en respectant les découpages en cours.
    mutating func append(contentsOf other: DisplayList) {
        for item in other.items { append(item) }
    }

    /// Zone interactive la plus haute sous le point donné.
    public func hitTest(_ point: CGPoint) -> String? {
        for item in items.reversed() {
            if case let .hitRegion(id, rect) = item, rect.contains(point) { return id }
        }
        return nil
    }

    /// Repères de mesure (identifiant → cadre).
    public var markers: [(id: String, rect: CGRect)] {
        // Les transformations en cours (transitions) s'appliquent aux repères, comme au dessin.
        var stack: [(dx: CGFloat, dy: CGFloat, scale: CGFloat, anchor: CGPoint)] = []
        var out: [(id: String, rect: CGRect)] = []
        for item in items {
            switch item {
            case let .pushTransform(dx, dy, scale, anchor): stack.append((dx, dy, scale, anchor))
            case .popTransform: _ = stack.popLast()
            case let .marker(id, r):
                var rect = r
                for t in stack.reversed() {
                    rect = CGRect(x: t.anchor.x + (rect.minX - t.anchor.x) * t.scale + t.dx,
                                  y: t.anchor.y + (rect.minY - t.anchor.y) * t.scale + t.dy,
                                  width: rect.width * t.scale, height: rect.height * t.scale)
                }
                out.append((id, rect))
            default: break
            }
        }
        return out
    }

    /// Zone défilable la plus haute sous le point donné.
    /// Zone de geste la plus haute sous le point, pour le sens donné.
    public func panTarget(_ point: CGPoint, vertical: Bool) -> String? {
        for item in items.reversed() {
            if case let .panRegion(id, rect, v) = item, v == vertical, rect.contains(point) { return id }
        }
        return nil
    }

    public func scrollTarget(_ point: CGPoint) -> String? {
        for item in items.reversed() {
            if case let .scrollRegion(id, rect) = item, rect.contains(point) { return id }
        }
        return nil
    }
}

/// Mesure du texte : fournie par le backend (Pango) ou par un faux mesureur dans les tests.
public protocol TextMeasurer {
    func measure(_ text: String, font: Font, maxWidth: CGFloat?) -> CGSize
    /// Mesure d'un symbole SF Symbols (nil si le symbole est inconnu).
    func measureSymbol(_ name: String, font: Font, scale: Image.Scale) -> SymbolMetrics?
    /// Taille en pixels d'un fichier image (nil s'il est illisible).
    func measureImage(_ path: String) -> CGSize?
}

extension TextMeasurer {
    public func measureSymbol(_ name: String, font: Font, scale: Image.Scale) -> SymbolMetrics? { nil }
    public func measureImage(_ path: String) -> CGSize? { nil }
}

public final class LayoutContext {
    public let measurer: TextMeasurer
    public let colorScheme: ColorScheme
    /// Écran complet et zones sûres : permet aux fonds (List, barres) de s'étendre sous la barre d'état.
    public let screen: CGRect
    public let safeArea: EdgeInsets
    /// Pixels par point de l'appareil simulé (3 sur les iPhone récents).
    public var displayScale: CGFloat = 3
    /// Animateur du graphe (nil : rendu sans animation).
    public var animator: Animator?

    public init(measurer: TextMeasurer, colorScheme: ColorScheme, screen: CGRect = .zero, safeArea: EdgeInsets = EdgeInsets()) {
        self.measurer = measurer
        self.colorScheme = colorScheme
        self.screen = screen
        self.safeArea = safeArea
    }

    /// Étend un rectangle jusqu'aux bords de l'écran s'il touche les bords de la zone sûre.
    func extendingIntoSafeArea(_ rect: CGRect) -> CGRect {
        guard screen != .zero else { return rect }
        var r = rect
        if abs(rect.minY - (screen.minY + safeArea.top)) < 0.5 {
            r.origin.y = screen.minY
            r.size.height += safeArea.top
        }
        if abs(rect.maxY - (screen.maxY - safeArea.bottom)) < 0.5 {
            r.size.height += safeArea.bottom
        }
        return r
    }
}
