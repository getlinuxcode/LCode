import Foundation

/// Couleur résolue (composantes 0…1).
public struct RGBA: Hashable, Sendable {
    public var r: Double, g: Double, b: Double, a: Double

    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    func withAlpha(_ alpha: Double) -> RGBA { RGBA(r, g, b, alpha) }

    static func rgb255(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> RGBA {
        RGBA(r / 255, g / 255, b / 255, a)
    }
}

public enum ColorScheme: Hashable, Sendable, CaseIterable {
    case light, dark
}

public protocol ShapeStyle {}

/// Couleur SwiftUI : une variante claire et une variante sombre (comme les couleurs système iOS).
public struct Color: Hashable, Sendable, ShapeStyle {
    var light: RGBA
    var dark: RGBA

    init(light: RGBA, dark: RGBA) {
        self.light = light
        self.dark = dark
    }

    public init(red: Double, green: Double, blue: Double, opacity: Double = 1) {
        let c = RGBA(red, green, blue, opacity)
        self.init(light: c, dark: c)
    }

    public init(white: Double, opacity: Double = 1) {
        self.init(red: white, green: white, blue: white, opacity: opacity)
    }

    public func resolve(in scheme: ColorScheme) -> RGBA {
        scheme == .light ? light : dark
    }

    /// `.blue.gradient` : dégradé automatique d'iOS (un peu plus clair en haut).
    public var gradient: LinearGradient {
        func lighter(_ c: RGBA) -> RGBA { RGBA(c.r + (1 - c.r) * 0.18, c.g + (1 - c.g) * 0.18, c.b + (1 - c.b) * 0.18, c.a) }
        return LinearGradient(colors: [Color(light: lighter(light), dark: lighter(dark)), self], startPoint: .top, endPoint: .bottom)
    }

    public func opacity(_ opacity: Double) -> Color {
        var c = self
        c.light.a *= opacity
        c.dark.a *= opacity
        return c
    }

    private static func system(_ l: (Double, Double, Double), _ d: (Double, Double, Double)) -> Color {
        Color(light: .rgb255(l.0, l.1, l.2), dark: .rgb255(d.0, d.1, d.2))
    }

    // Couleurs système iOS 26+ (palette mise à jour avec Liquid Glass), clair / sombre.
    public static let red = system((255, 56, 60), (255, 66, 69))
    public static let orange = system((255, 141, 40), (255, 146, 48))
    public static let yellow = system((255, 204, 0), (255, 214, 0))
    public static let green = system((52, 199, 89), (48, 209, 88))
    public static let mint = system((0, 200, 179), (0, 218, 195))
    public static let teal = system((0, 195, 208), (0, 210, 224))
    public static let cyan = system((0, 192, 232), (60, 211, 254))
    public static let blue = system((0, 136, 255), (0, 145, 255))
    public static let indigo = system((97, 85, 245), (109, 124, 255))
    public static let purple = system((203, 48, 224), (219, 52, 242))
    public static let pink = system((255, 45, 85), (255, 55, 95))
    public static let brown = system((172, 127, 94), (183, 138, 102))
    public static let gray = system((142, 142, 147), (142, 142, 147))
    public static let black = Color(white: 0)
    public static let white = Color(white: 1)
    public static let clear = Color(white: 0, opacity: 0)

    public static let primary = Color(light: RGBA(0, 0, 0), dark: RGBA(1, 1, 1))
    public static let secondary = Color(light: .rgb255(60, 60, 67, 0.6), dark: .rgb255(235, 235, 245, 0.6))
    /// Couleur d'accent : « AccentColor » du catalogue d'assets s'il la définit, sinon le bleu système.
    public static var accentColor: Color { AssetCatalog.shared.color("AccentColor") ?? blue }

    /// Couleur du catalogue d'assets (`Name.colorset`) ; absente : transparente, signalée dans la sortie (comme iOS).
    public init(_ name: String, bundle: Bundle? = nil) {
        if let c = AssetCatalog.shared.color(name) {
            self = c
        } else {
            AssetCatalog.shared.warnMissing("color", name)
            self = .clear
        }
    }
    /// `.tint` : la teinte de l'environnement (ou la couleur d'accent). Valeur repère résolue à la construction.
    public static let tint = Color(light: RGBA(-1, -1, -1, 1), dark: RGBA(-1, -1, -1, 1))

    func resolvingTint(_ env: EnvironmentValues) -> Color {
        self == .tint ? (env.tint ?? .accentColor) : self
    }

    // Couleurs sémantiques utilisées en interne.
    static let systemBackground = Color(light: RGBA(1, 1, 1), dark: RGBA(0, 0, 0))
    static let separator = Color(light: .rgb255(60, 60, 67, 0.29), dark: .rgb255(84, 84, 88, 0.6))
    static let secondarySystemFill = Color(light: .rgb255(120, 120, 128, 0.16), dark: .rgb255(120, 120, 128, 0.32))
    static let tertiaryLabel = Color(light: .rgb255(60, 60, 67, 0.3), dark: .rgb255(235, 235, 245, 0.3))
}
