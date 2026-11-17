import Foundation

// Liquid Glass (iOS 26+): a material that refracts what is behind it. Rendered by LSimHost, tuned in the
// profile against an iPhone by the calibration bench:
//  - background sampled with a refraction offset: zero at the center, max near the edges (`bezel` band),
//    along the edge normal (lens effect);
//  - background blur, saturation and brightness, then a tinted veil (`tint`);
//  - specular rim, brighter on edges facing the light; soft drop shadow.

/// Settings for one glass variant (regular, clear) in one theme.
public struct GlassParams: Codable, Sendable, Hashable {
    /// Background blur standard deviation, in points.
    public var blur: Double
    /// Max refraction offset near the edge, in points (negative: the lens shrinks).
    public var refraction: Double
    /// Width of the refraction band along the edge, in points.
    public var bezel: Double
    /// Refraction profile curvature (1: linear, 2: quadratic…).
    public var exponent: Double
    public var saturation: Double
    public var brightness: Double
    /// Veil (r, g, b, a) in light / dark.
    public var tintLight: [Double]
    public var tintDark: [Double]
    /// Specular rim: opacity, width (pt), and darkening on the opposite side.
    public var rimLight: Double
    public var rimDark: Double
    public var rimWidth: Double
    public var shadowSide: Double
    /// Drop shadow (opacity in light / dark, vertical offset in points).
    public var shadowLight: Double
    public var shadowDark: Double
    public var shadowOffset: Double
    /// Opacity of a tint applied with `.tint(color)` (optional for older profiles).
    public var tintStrength: Double?
    /// Edge curvature (0: linear profile; toward 1: circular-arc edge, very steep at the rim, which bends
    /// distortions and produces the mirrored-outline effect). Missing: older profile.
    public var curvature: Double?
    /// Max offset, in multiples of `bezel` (past the center the content is flipped: mirror effect).
    public var maxShift: Double?
    /// Bright line on the outer edge (opacity in light / dark).
    public var edgeLineLight: Double?
    public var edgeLineDark: Double?
    /// Tables measured on iPhone (coded backgrounds); take priority over the parametric model.
    public var tableLight: GlassTable?
    public var tableDark: GlassTable?
    /// `.tint(…)` measured on iPhone, per theme: [saturation, brightness, opacity].
    public var tintTransformLight: [Double]?
    public var tintTransformDark: [Double]?
}

/// Measured glass response vs distance to the edge `d` (points, or fraction of half the smaller
/// dimension if `relative`): refraction offset along the normal, background transmission, and added
/// light (r, g, b, 0…1) on the lit / opposite side.
public struct GlassTable: Codable, Sendable, Hashable {
    public var relative: Bool
    public var d: [Double]
    public var shift: [Double]
    public var alpha: [Double]
    public var betaTop: [[Double]]
    public var betaBottom: [[Double]]
    /// Saturation applied to the background before transmission (not measurable with grey backgrounds).
    public var saturation: Double?
    /// Background blur (std dev, points) vs `d`; missing: the variant's `blur` setting.
    public var blur: [Double]?
    /// Outline measured at absolute distance from the edge (dark rim, highlight), and its tinted version.
    public var edge: GlassEdge?
    public var tintedEdge: GlassEdge?
    /// Background blur under a tint (points), measured inside tinted glass.
    public var tintedBlur: Double?

    public init(relative: Bool, d: [Double], shift: [Double], alpha: [Double], betaTop: [[Double]], betaBottom: [[Double]]) {
        self.relative = relative
        self.d = d
        self.shift = shift
        self.alpha = alpha
        self.betaTop = betaTop
        self.betaBottom = betaBottom
    }

    /// Linear interpolation of one column.
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

/// Glass outline: on a grey background, output = α·background + β at distance `d` (points, negative
/// outside); applied as a delta over the interior rendering.
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

/// Glass resolved for a theme, ready to draw.
public struct GlassRender: Hashable, Sendable {
    public var blur: Double, refraction: Double, bezel: Double, exponent: Double
    public var saturation: Double, brightness: Double
    public var tint: RGBA
    public var rimAlpha: Double, rimWidth: Double, shadowSide: Double
    public var shadowAlpha: Double, shadowOffset: Double
    public var curvature: Double?, maxShift: Double, edgeLine: Double
    public var table: GlassTable?
    /// Tint forced by `.tint(color)` (blended after the table, with this opacity).
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

// MARK: - SwiftUI API: Glass, .glassEffect, GlassEffectContainer

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
        // Tinted glass: the tint replaces the veil, opaque enough to be readable.
        let transform = (scheme == .light ? params.tintTransformLight : params.tintTransformDark) ?? [1, 1]
        let strength = transform.count > 2 ? transform[2] : params.tintStrength ?? 0.75
        let tint = tintColor.map { c -> RGBA in
            let r = c.resolve(in: scheme)
            let lum = 0.2126 * r.r + 0.7152 * r.g + 0.0722 * r.b
            // Not clamped: on iPhone the effective tint goes out of gamut (darkens the transmitted background).
            func t(_ v: Double) -> Double { (lum + (v - lum) * transform[0]) * transform[1] }
            return RGBA(t(r.r), t(r.g), t(r.b), min(1, r.a * strength))
        }
        return GlassRender(params, scheme: scheme, tint: tint)
    }
}

/// Glass background of the given shape, sized to the view it wraps.
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

    override func draw(in rect: CGRect, _ lc: LayoutContext, _ list: inout DisplayList) {
        guard glass.variant != .identity else { return }
        list.append(.glass(shape, rect, glass.render(lc.colorScheme)))
    }
}

extension View {
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

/// Groups glass elements (merging and morphing on iOS); a plain container for now.
public struct GlassEffectContainer<Content: View>: View, _PrimitiveView {
    public typealias Body = Never
    let content: Content
    public init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) { self.content = content() }
    public func _makeNodes(_ context: BuildContext) -> [LayoutNode] { LSimUI._makeNodes(content, context) }
}

/// `@Namespace` (matched geometry): unique id per view.
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
