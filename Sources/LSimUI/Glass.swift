import Foundation

// Liquid Glass (iOS 26+) : matériau qui réfracte ce qui passe derrière lui.
//
// Modèle (rendu par LSimHost, réglages dans le profil, ajustés sur iPhone par le banc) :
//  - l'arrière-plan est échantillonné avec un décalage de réfraction : nul au centre, maximal près
//    des bords (bande de largeur `bezel`), le long de la normale au bord — effet de lentille ;
//  - flou, saturation et luminosité de l'arrière-plan, puis voile coloré (`tint`) ;
//  - liseré spéculaire : plus clair sur les bords orientés vers la lumière ;
//  - ombre portée douce.

/// Réglages d'une variante de verre (regular, clear), pour un thème.
public struct GlassParams: Codable, Sendable, Hashable {
    /// Écart-type du flou de l'arrière-plan, en points.
    public var blur: Double
    /// Décalage maximal de réfraction près du bord, en points (négatif : la lentille rétrécit).
    public var refraction: Double
    /// Largeur de la bande de réfraction le long du bord, en points.
    public var bezel: Double
    /// Courbure du profil de réfraction (1 : linéaire, 2 : quadratique…).
    public var exponent: Double
    public var saturation: Double
    public var brightness: Double
    /// Voile (r, g, b, a) en clair / en sombre.
    public var tintLight: [Double]
    public var tintDark: [Double]
    /// Liseré spéculaire : opacité, largeur (pt), et assombrissement du côté opposé.
    public var rimLight: Double
    public var rimDark: Double
    public var rimWidth: Double
    public var shadowSide: Double
    /// Ombre portée (opacité en clair / sombre, décalage vertical en points).
    public var shadowLight: Double
    public var shadowDark: Double
    public var shadowOffset: Double
    /// Opacité d'une teinte appliquée avec `.tint(couleur)` (optionnel pour les anciens profils).
    public var tintStrength: Double?
    /// Courbure du bord (0 : profil linéaire ; vers 1 : bord en arc de cercle, pente très forte au bord,
    /// ce qui courbe les déformations et produit l'effet miroir du contour). Absent : ancien profil.
    public var curvature: Double?
    /// Décalage maximal, en multiples de `bezel` (au-delà du centre : le contenu est renvoyé, effet miroir).
    public var maxShift: Double?
    /// Filet lumineux au bord extérieur (opacité en clair / sombre).
    public var edgeLineLight: Double?
    public var edgeLineDark: Double?
    /// Tables mesurées sur iPhone (fonds codés) ; prioritaires sur le modèle paramétrique.
    public var tableLight: GlassTable?
    public var tableDark: GlassTable?
    /// Teinte `.tint(…)` mesurée sur iPhone, par thème : [saturation, luminosité, opacité].
    public var tintTransformLight: [Double]?
    public var tintTransformDark: [Double]?
}

/// Comportement mesuré du verre en fonction de la distance au bord `d` (points, ou fraction de la
/// demi-plus-petite dimension si `relative`) : décalage de réfraction le long de la normale,
/// transmission du fond, et lumière ajoutée (r, g, b de 0 à 1) côté éclairé / côté opposé.
public struct GlassTable: Codable, Sendable, Hashable {
    public var relative: Bool
    public var d: [Double]
    public var shift: [Double]
    public var alpha: [Double]
    public var betaTop: [[Double]]
    public var betaBottom: [[Double]]
    /// Saturation appliquée au fond avant transmission (non mesurable avec des fonds gris).
    public var saturation: Double?
    /// Flou du fond (écart-type en points) en fonction de `d` ; absent : réglage `blur` de la variante.
    public var blur: [Double]?
    /// Contour mesuré à distance absolue du bord (liseré sombre, reflet), et sa version teintée.
    public var edge: GlassEdge?
    public var tintedEdge: GlassEdge?
    /// Flou du fond sous une teinte (points), mesuré à l'intérieur du verre teinté.
    public var tintedBlur: Double?

    public init(relative: Bool, d: [Double], shift: [Double], alpha: [Double], betaTop: [[Double]], betaBottom: [[Double]]) {
        self.relative = relative
        self.d = d
        self.shift = shift
        self.alpha = alpha
        self.betaTop = betaTop
        self.betaBottom = betaBottom
    }

    /// Interpolation linéaire d'une colonne.
    public func value(_ column: [Double], at x: Double) -> Double {
        guard let first = d.first, let last = d.last, !column.isEmpty else { return 0 }
        if x <= first { return column[0] }
        if x >= last { return column[column.count - 1] }
        var lo = 0, hi = d.count - 1
        while hi - lo > 1 { let mid = (lo + hi) / 2; if d[mid] <= x { lo = mid } else { hi = mid } }
        let t = (x - d[lo]) / max(d[hi] - d[lo], 1e-9)
        return column[lo] + (column[hi] - column[lo]) * t
    }

    public func beta(_ rows: [[Double]], at x: Double) -> (Double, Double, Double) {
        (value(rows.map { $0[0] }, at: x), value(rows.map { $0[1] }, at: x), value(rows.map { $0[2] }, at: x))
    }
}

/// Contour du verre : sur fond gris, sortie = α·fond + β à la distance `d` (points, négative à
/// l'extérieur) ; appliqué en écart par rapport au rendu intérieur.
public struct GlassEdge: Codable, Sendable, Hashable {
    public var d: [Double]
    public var alpha: [Double]
    public var betaTop: [[Double]]
    public var betaBottom: [[Double]]

    public func value(_ column: [Double], at x: Double) -> Double {
        GlassTable(relative: false, d: d, shift: [], alpha: [], betaTop: [], betaBottom: []).value(column, at: x)
    }

    public func beta(_ rows: [[Double]], at x: Double) -> (Double, Double, Double) {
        (value(rows.map { $0[0] }, at: x), value(rows.map { $0[1] }, at: x), value(rows.map { $0[2] }, at: x))
    }
}

public struct GlassProfile: Codable, Sendable {
    public var regular: GlassParams
    public var clear: GlassParams

    public static let fallback = GlassProfile(
        regular: GlassParams(blur: 2.5, refraction: 6, bezel: 10, exponent: 2, saturation: 1.25, brightness: 1.03,
                             tintLight: [1, 1, 1, 0.55], tintDark: [0.11, 0.11, 0.12, 0.55],
                             rimLight: 0.55, rimDark: 0.3, rimWidth: 1.2, shadowSide: 0.06,
                             shadowLight: 0.06, shadowDark: 0.3, shadowOffset: 2),
        clear: GlassParams(blur: 0.5, refraction: 7, bezel: 10, exponent: 2, saturation: 1.1, brightness: 1.0,
                           tintLight: [1, 1, 1, 0.12], tintDark: [0, 0, 0, 0.15],
                           rimLight: 0.6, rimDark: 0.35, rimWidth: 1.2, shadowSide: 0.05,
                           shadowLight: 0.05, shadowDark: 0.25, shadowOffset: 2)
    )
}

/// Verre résolu pour un thème, prêt à être dessiné.
public struct GlassRender: Hashable, Sendable {
    public var blur: Double, refraction: Double, bezel: Double, exponent: Double
    public var saturation: Double, brightness: Double
    public var tint: RGBA
    public var rimAlpha: Double, rimWidth: Double, shadowSide: Double
    public var shadowAlpha: Double, shadowOffset: Double
    public var curvature: Double?, maxShift: Double, edgeLine: Double
    public var table: GlassTable?
    /// Teinte imposée par `.tint(couleur)` (mélangée après la table, avec cette opacité).
    public var tintOverride: RGBA?
    public var tintStrength: Double

    init(_ p: GlassParams, scheme: ColorScheme, tint override: RGBA?) {
        blur = p.blur; refraction = p.refraction; bezel = p.bezel; exponent = p.exponent
        saturation = p.saturation; brightness = p.brightness
        let t = scheme == .light ? p.tintLight : p.tintDark
        tint = override ?? RGBA(t[0], t[1], t[2], t.count > 3 ? t[3] : 1)
        rimAlpha = scheme == .light ? p.rimLight : p.rimDark
        rimWidth = p.rimWidth; shadowSide = p.shadowSide
        shadowAlpha = scheme == .light ? p.shadowLight : p.shadowDark
        shadowOffset = p.shadowOffset
        curvature = p.curvature
        maxShift = p.maxShift ?? 3
        edgeLine = (scheme == .light ? p.edgeLineLight : p.edgeLineDark) ?? 0
        table = scheme == .light ? p.tableLight : p.tableDark
        tintOverride = override
        tintStrength = p.tintStrength ?? 0.75
    }
}

// MARK: - API SwiftUI : Glass, .glassEffect, GlassEffectContainer

public struct Glass: Sendable, Hashable {
    enum Variant: Hashable, Sendable { case regular, clear, identity }
    let variant: Variant
    var tintColor: Color?
    var isInteractive = false

    public static let regular = Glass(variant: .regular)
    public static let clear = Glass(variant: .clear)
    public static let identity = Glass(variant: .identity)

    public func tint(_ color: Color?) -> Glass { var g = self; g.tintColor = color; return g }
    public func interactive(_ isEnabled: Bool = true) -> Glass { var g = self; g.isInteractive = isEnabled; return g }

    func render(_ scheme: ColorScheme) -> GlassRender {
        let profile = DesignProfile.current.glass
        let params = variant == .clear ? profile.clear : profile.regular
        // Verre teinté : la teinte remplace le voile, assez opaque pour être lisible.
        let transform = (scheme == .light ? params.tintTransformLight : params.tintTransformDark) ?? [1, 1]
        let strength = transform.count > 2 ? transform[2] : params.tintStrength ?? 0.75
        let tint = tintColor.map { c -> RGBA in
            let r = c.resolve(in: scheme)
            let lum = 0.2126 * r.r + 0.7152 * r.g + 0.0722 * r.b
            // Sans bornage : sur iPhone, la teinte effective sort de la gamme (assombrit le fond transmis).
            func t(_ v: Double) -> Double { (lum + (v - lum) * transform[0]) * transform[1] }
            return RGBA(t(r.r), t(r.g), t(r.b), min(1, r.a * strength))
        }
        return GlassRender(params, scheme: scheme, tint: tint)
    }
}

/// Fond en verre de la forme donnée, à la taille de la vue qu'il habille.
final class GlassNode: LayoutNode {
    let shape: ShapeKind
    let glass: Glass

    init(shape: ShapeKind, glass: Glass) {
        self.shape = shape
        self.glass = glass
    }

    override func computeSize(_ p: ProposedViewSize, _ lc: LayoutContext) -> CGSize {
        p.replacingUnspecifiedDimensions()
    }

    override func render(in rect: CGRect, _ lc: LayoutContext, _ list: inout DisplayList) {
        guard glass.variant != .identity else { return }
        list.append(.glass(shape, rect, glass.render(lc.colorScheme)))
    }
}

extension View {
    /// `.glassEffect(.regular.tint(.blue), in: .capsule)` (iOS 26).
    public func glassEffect<S: Shape>(_ glass: Glass = .regular, in shape: S, isEnabled: Bool = true) -> some View {
        modifier(_LayerModifier(layer: _GlassLayer(glass: isEnabled ? glass : .identity, shape: shape._kind),
                                alignment: .center, isBackground: true))
    }

    public func glassEffect(_ glass: Glass = .regular, isEnabled: Bool = true) -> some View {
        glassEffect(glass, in: Capsule(), isEnabled: isEnabled)
    }

    public func glassEffectID<ID: Hashable>(_ id: ID?, in namespace: Namespace.ID) -> some View { self }
    public func glassEffectUnion<ID: Hashable>(id: ID?, namespace: Namespace.ID) -> some View { self }
}

struct _GlassLayer: View, _PrimitiveView {
    typealias Body = Never
    let glass: Glass
    let shape: ShapeKind
    func _makeNodes(_ context: BuildContext) -> [LayoutNode] { [GlassNode(shape: shape, glass: glass)] }
}

/// Regroupe des éléments de verre (fusion et morphose sur iOS) ; pour l'instant, conteneur simple.
public struct GlassEffectContainer<Content: View>: View, _PrimitiveView {
    public typealias Body = Never
    let content: Content
    public init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) { self.content = content() }
    public func _makeNodes(_ context: BuildContext) -> [LayoutNode] { LSimUI._makeNodes(content, context) }
}

/// `@Namespace` (animations appariées) : identifiant unique par vue.
@propertyWrapper
public struct Namespace: Sendable {
    public struct ID: Hashable, Sendable { let value: Int }
    nonisolated(unsafe) private static var counter = 0
    public let wrappedValue: ID
    public init() {
        Namespace.counter += 1
        wrappedValue = ID(value: Namespace.counter)
    }
}

extension View {
    public func matchedGeometryEffect<ID: Hashable>(id: ID, in namespace: Namespace.ID, isSource: Bool = true) -> some View { self }
}
