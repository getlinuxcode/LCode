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
    /// Chevron (›) ou flèche de retour (‹) dessinés en traits.
    case chevron(CGRect, RGBA, lineWidth: CGFloat, pointingLeft: Bool)
    case pushOpacity(Double)
    case popOpacity
    case pushClip(ShapeKind, CGRect)
    case popClip
    /// Fondu vertical d'une couleur opaque (en haut) vers transparent (en bas).
    case fade(CGRect, RGBA)
    /// Matière : floute ce qui est déjà dessiné dans la zone, puis applique un voile coloré.
    case backdrop(CGRect, blur: CGFloat, tint: RGBA, shape: ShapeKind = .rectangle)
    /// Zone interactive (bouton, onTapGesture). Les dernières zones dessinées sont au-dessus.
    case hitRegion(id: String, CGRect)
    /// Repère de mesure (`accessibilityIdentifier`) : cadre de la vue identifiée.
    case marker(id: String, CGRect)
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
        items.compactMap { if case let .marker(id, r) = $0 { (id, r) } else { nil } }
    }

    /// Zone défilable la plus haute sous le point donné.
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
}

extension TextMeasurer {
    public func measureSymbol(_ name: String, font: Font, scale: Image.Scale) -> SymbolMetrics? { nil }
}

public final class LayoutContext {
    public let measurer: TextMeasurer
    public let colorScheme: ColorScheme
    /// Écran complet et zones sûres : permet aux fonds (List, barres) de s'étendre sous la barre d'état.
    public let screen: CGRect
    public let safeArea: EdgeInsets
    /// Pixels par point de l'appareil simulé (3 sur les iPhone récents).
    public var displayScale: CGFloat = 3

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
