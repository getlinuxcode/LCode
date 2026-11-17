import Foundation

/// Profil de design : toutes les valeurs mesurables d'une version d'iOS, chargées depuis un fichier JSON
/// (`Sources/LSimUI/Profiles/iOS-27.2.json`) que le banc de calibration réécrit automatiquement.
///
/// Ordre de chargement : `LSIM_PROFILE` (chemin d'un JSON, utilisé par le correcteur pour essayer
/// des valeurs sans recompiler), puis le profil embarqué, puis les valeurs de repli ci-dessous.
public struct DesignProfile: Codable, Sendable {
    public var name: String
    public var text: TextProfile
    public var button: ButtonProfile
    /// Optionnel pour rester compatible avec les profils plus anciens.
    public var imageSettings: ImageProfile?
    public var image: ImageProfile { imageSettings ?? .fallback }
    /// Matériau Liquid Glass (optionnel pour rester compatible avec les profils plus anciens).
    public var glassSettings: GlassProfile?
    public var glass: GlassProfile { glassSettings ?? .fallback }
    /// Barre de navigation mesurée (effet de bord de défilement…), optionnelle.
    public var navigation: NavigationProfile?
    /// Courbes des préréglages d'animation mesurées sur iPhone (default, spring, smooth, snappy, bouncy…).
    public var animations: [String: AnimationSetting]?
    /// Règles de décision des gestes système mesurées au doigt (retour par balayage, feuille tirée).
    public var gestures: GestureProfile?

    /// Chargé une seule fois, de façon sûre entre fils (initialisation paresseuse d'un `static let`).
    private static let embedded: DesignProfile = load()
    private static let lock = NSLock()
    nonisolated(unsafe) private static var override: DesignProfile?

    /// Profil actif (le style de compatibilité garde ses valeurs iOS 18 fixes).
    public static var current: DesignProfile {
        if DesignStyle.current == .compatibility { return .compatibility }
        lock.lock()
        defer { lock.unlock() }
        return override ?? embedded
    }

    /// Remplace le profil actif (tests, correcteur) ; `nil` revient au profil chargé.
    public static func use(_ profile: DesignProfile?) {
        lock.lock()
        override = profile
        lock.unlock()
    }

    static func load() -> DesignProfile {
        let decoder = JSONDecoder()
        if let path = ProcessInfo.processInfo.environment["LSIM_PROFILE"] {
            do {
                return try decoder.decode(DesignProfile.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            } catch {
                print("[LSim] Profil illisible (\(path)) : \(error) — profil embarqué utilisé.")
            }
        }
        if let url = Bundle.module.url(forResource: "iOS-27.2", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let profile = try? decoder.decode(DesignProfile.self, from: data) {
            return profile
        }
        return .fallback
    }
}

public struct TextProfile: Codable, Sendable {
    /// Approche (espacement des lettres, en points) par corps entier, pour SF Pro en graisse normale.
    public var tracking: [String: Double]
    /// Approche des graisses semi-grasses et plus (≥ 600) : la police variable d'iOS espace
    /// différemment selon la graisse. Les corps absents reprennent la table normale.
    public var trackingSemibold: [String: Double]?
    /// Approche des corps absents de la table au-delà de 40 pt (décroît vers 0 à 80 pt).
    public var largeSizeTracking: Double

    public func tracking(forSize size: Double, weight: Int = 400) -> Double {
        let key = String(Int(size.rounded()))
        if weight >= 600, let value = trackingSemibold?[key] { return value }
        if let value = tracking[key] { return value }
        let k = Int(size.rounded())
        if k < 6 { return tracking["6"] ?? 0 }
        return max(0, largeSizeTracking * (1 - Double(k - 40) / 40))
    }
}

/// Symboles : taille relative au corps de la police selon `imageScale`, et marges du cadre autour de l'encre.
public struct ImageProfile: Codable, Sendable {
    public var scaleSmall: Double
    public var scaleMedium: Double
    public var scaleLarge: Double
    /// Marge horizontale / verticale du cadre autour de l'encre du glyphe, en fraction du corps.
    public var paddingH: Double
    public var paddingV: Double
    /// Espacement par défaut (pile sans `spacing:`) entre une image et sa voisine.
    public var stackSpacing: Double?

    public static let fallback = ImageProfile(scaleSmall: 0.78, scaleMedium: 1, scaleLarge: 1.29, paddingH: 0, paddingV: 0.09, stackSpacing: 8)

    public func factor(_ scale: Image.Scale) -> Double {
        switch scale {
        case .small: scaleSmall
        case .medium: scaleMedium
        case .large: scaleLarge
        }
    }
}

/// Paire de couleurs claire / sombre, en composantes 0…1 (r, g, b, a).
public struct ColorPair: Codable, Sendable, Hashable {
    public var light: [Double]
    public var dark: [Double]

    var color: Color {
        func rgba(_ c: [Double]) -> RGBA { RGBA(c[0], c[1], c[2], c.count > 3 ? c[3] : 1) }
        return Color(light: rgba(light), dark: rgba(dark))
    }

    static func gray(_ l: Double, _ d: Double, alpha: Double = 1) -> ColorPair {
        ColorPair(light: [l / 255, l / 255, l / 255, alpha], dark: [d / 255, d / 255, d / 255, alpha])
    }
}

public struct ButtonProfile: Codable, Sendable {
    public struct Size: Codable, Sendable, Hashable {
        public var fontSize: Double
        public var padH: Double
        public var padV: Double
        /// Marge horizontale avec `.buttonBorderShape(.circle)`.
        public var circlePadH: Double
    }

    /// Couleur du libellé.
    public enum LabelColor: String, Codable, Sendable, CaseIterable {
        case tint       // teinte (ou rouge si destructif)
        case primary    // couleur primaire
        case white
        case inherit    // couleur de l'environnement (foregroundStyle), sinon primaire
    }

    /// Remplissage du fond.
    public enum Fill: String, Codable, Sendable, CaseIterable {
        case none
        case neutralOrTinted   // .bordered : gris neutre, ou teinte translucide si .tint / destructif
        case solid             // .borderedProminent : teinte pleine
        case glass             // verre clair
        case glassTinted       // verre teinté
    }

    public struct Style: Codable, Sendable, Hashable {
        public var label: LabelColor
        public var destructiveLabel: LabelColor
        /// La police suit `controlSize`.
        public var followsControlSize: Bool
        public var fill: Fill
        public var pressedOpacity: Double
    }

    /// Clés : mini, small, regular, large, extraLarge.
    public var sizes: [String: Size]
    /// Clés : automatic, plain, borderless, bordered, borderedProminent, glass, glassProminent.
    public var styles: [String: Style]
    /// Forme par défaut des boutons à fond : "capsule" ou "roundedRectangle".
    public var defaultShape: String
    public var roundedRectangleRadius: Double
    public var neutralFill: ColorPair
    public var tintFillAlphaLight: Double
    public var tintFillAlphaDark: Double
    public var disabledGlassTintedFill: ColorPair
    public var glassFill: ColorPair
    public var glassStroke: ColorPair
    public var glassShadowAlphaLight: Double
    public var glassShadowAlphaDark: Double
    public var glassRimAlphaLight: Double
    public var glassRimAlphaDark: Double

    func size(_ s: ControlSize) -> Size {
        let key: String
        switch s {
        case .mini: key = "mini"
        case .small: key = "small"
        case .regular: key = "regular"
        case .large: key = "large"
        case .extraLarge: key = "extraLarge"
        }
        return sizes[key] ?? sizes["regular"] ?? Size(fontSize: 17, padH: 12, padV: 7, circlePadH: 7)
    }

    func style(_ kind: _ButtonStyleKind) -> Style {
        let key: String
        switch kind {
        case .automatic: key = "automatic"
        case .plain: key = "plain"
        case .borderless: key = "borderless"
        case .bordered: key = "bordered"
        case .borderedProminent: key = "borderedProminent"
        case .glass: key = "glass"
        case .glassProminent: key = "glassProminent"
        }
        return styles[key] ?? Style(label: .tint, destructiveLabel: .tint, followsControlSize: true, fill: .none, pressedOpacity: 0.25)
    }
}

extension DesignProfile {
    /// Valeurs de repli (identiques au profil embarqué au moment de l'écriture).
    static let fallbackTracking: [String: Double] = [
        "6": 0.24, "7": 0.23, "8": 0.21, "9": 0.17, "10": 0.12, "11": 0.06, "12": 0, "13": -0.08, "14": -0.15,
        "15": -0.23, "16": -0.31, "17": -0.30, "18": -0.44, "19": -0.45, "20": -0.45, "21": -0.36, "22": -0.26,
        "23": -0.10, "24": 0.07, "25": 0.15, "26": 0.22, "27": 0.29, "28": 0.38, "29": 0.40, "30": 0.40,
        "31": 0.39, "32": 0.41, "33": 0.40, "34": 0.40, "35": 0.38, "36": 0.37, "37": 0.36, "38": 0.37,
        "39": 0.38, "40": 0.37,
    ]

    static let fallback = DesignProfile(name: "iOS 27.2 (repli)",
                                        text: TextProfile(tracking: fallbackTracking, largeSizeTracking: 0.37),
                                        button: ButtonProfile(
        sizes: [
            "mini": .init(fontSize: 15, padH: 10, padV: 5, circlePadH: 7),
            "small": .init(fontSize: 15, padH: 10, padV: 5, circlePadH: 7),
            "regular": .init(fontSize: 17, padH: 12, padV: 7, circlePadH: 7),
            "large": .init(fontSize: 17, padH: 20, padV: 15, circlePadH: 7),
            "extraLarge": .init(fontSize: 17, padH: 20, padV: 15, circlePadH: 7),
        ],
        styles: [
            "automatic": .init(label: .tint, destructiveLabel: .tint, followsControlSize: true, fill: .none, pressedOpacity: 0.25),
            "plain": .init(label: .inherit, destructiveLabel: .tint, followsControlSize: false, fill: .none, pressedOpacity: 0.25),
            "borderless": .init(label: .tint, destructiveLabel: .tint, followsControlSize: true, fill: .none, pressedOpacity: 0.25),
            "bordered": .init(label: .tint, destructiveLabel: .tint, followsControlSize: true, fill: .neutralOrTinted, pressedOpacity: 0.25),
            "borderedProminent": .init(label: .white, destructiveLabel: .white, followsControlSize: true, fill: .solid, pressedOpacity: 0.7),
            "glass": .init(label: .primary, destructiveLabel: .primary, followsControlSize: true, fill: .glass, pressedOpacity: 0.25),
            "glassProminent": .init(label: .white, destructiveLabel: .white, followsControlSize: true, fill: .glassTinted, pressedOpacity: 0.7),
        ],
        defaultShape: "capsule",
        roundedRectangleRadius: 7,
        neutralFill: ColorPair(light: [120 / 255, 120 / 255, 128 / 255, 0.16], dark: [120 / 255, 120 / 255, 128 / 255, 0.32]),
        tintFillAlphaLight: 0.18,
        tintFillAlphaDark: 0.25,
        disabledGlassTintedFill: .gray(224, 55),
        glassFill: ColorPair(light: [0.976, 0.976, 0.976, 0.97], dark: [0.17, 0.17, 0.18, 0.96]),
        glassStroke: ColorPair(light: [0, 0, 0, 0.22], dark: [1, 1, 1, 0.18]),
        glassShadowAlphaLight: 0.05,
        glassShadowAlphaDark: 0.25,
        glassRimAlphaLight: 0.3,
        glassRimAlphaDark: 0.18
    ))

    /// Mode compatibilité (apps liées avec un SDK antérieur à iOS 26) : style iOS 18.
    static let compatibility: DesignProfile = {
        var p = fallback
        p.name = "compatibilité iOS 18"
        let size = ButtonProfile.Size(fontSize: 17, padH: 12, padV: 7, circlePadH: 7)
        p.button.sizes = ["mini": size, "small": size, "regular": size, "large": size, "extraLarge": size]
        p.button.defaultShape = "roundedRectangle"
        return p
    }()
}

/// Mesures de la barre de navigation Liquid Glass.
public struct NavigationProfile: Codable, Sendable {
    public var edgeLight: ScrollEdgeTable?
    public var edgeDark: ScrollEdgeTable?
}

/// Effet de bord de défilement sous la barre, ligne par ligne : sur fond gris, sortie = α·fond + β, avec
/// un flou d'écart-type `blur` (points). `y` : points depuis le haut de l'écran de mesure, dont la barre
/// se termine à `referenceBarBottom`.
public struct ScrollEdgeTable: Codable, Sendable, Hashable {
    public var y: [Double]
    public var alpha: [Double]
    public var beta: [[Double]]
    public var blur: [Double]
    public var referenceBarBottom: Double?

    public func value(_ column: [Double], at x: Double) -> Double {
        GlassTable(relative: false, d: y, shift: [], alpha: [], betaTop: [], betaBottom: []).value(column, at: x)
    }
}

/// Préréglage d'animation mesuré : ressort (réponse, amortissement) ou courbe de Bézier nommée et durée.
public struct AnimationSetting: Codable, Sendable {
    public struct Spring: Codable, Sendable { public var response: Double; public var damping: Double }
    public var spring: Spring?
    public var bezier: String?
    public var duration: Double?
    /// Délai entre la transaction et le premier mouvement à l'écran (s), mesuré ; non appliqué.
    public var lag: Double?
}

/// Décision au lâcher d'un geste : position projetée = déplacement + `projection` × vitesse, comparée à
/// `threshold` × largeur de l'écran (balayage) ou course de la feuille.
public struct GestureRule: Codable, Sendable {
    public var projection: Double
    public var threshold: Double
}

public struct GestureProfile: Codable, Sendable {
    public var backSwipe: GestureRule?
    public var sheetDismiss: GestureRule?
}
