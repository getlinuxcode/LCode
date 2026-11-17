import Foundation

/// Design profile: every measurable value for an iOS version, loaded from a JSON file
/// (`Sources/LSimUI/Profiles/iOS-27.2.json`) that the calibration bench rewrites automatically.
/// Load order: `LSIM_PROFILE` (JSON path, lets the tuner try values without rebuilding), then the
/// bundled profile, then the fallback values below.
public struct DesignProfile: Codable, Sendable {
    public var name: String
    public var text: TextProfile
    public var button: ButtonProfile
    /// Optional for compatibility with older profiles.
    public var imageSettings: ImageProfile?
    public var image: ImageProfile { imageSettings ?? .fallback }
    /// Liquid Glass material (optional for older profiles).
    public var glassSettings: GlassProfile?
    public var glass: GlassProfile { glassSettings ?? .fallback }
    /// Measured navigation bar (scroll edge effect…), optional.
    public var navigation: NavigationProfile?
    /// Animation preset curves measured on iPhone (default, spring, smooth, snappy, bouncy…).
    public var animations: [String: AnimationSetting]?
    /// System gesture decision rules measured by finger (swipe back, sheet pull-down).
    public var gestures: GestureProfile?

    /// Loaded once, thread-safely (lazy `static let`).
    private static let embedded: DesignProfile = load()
    private static let lock = NSLock()
    nonisolated(unsafe) private static var override: DesignProfile?

    /// Active profile (compatibility style keeps fixed iOS 18 values).
    public static var current: DesignProfile {
        if DesignStyle.current == .compatibility { return .compatibility }
        lock.lock()
        defer { lock.unlock() }
        return override ?? embedded
    }

    /// Overrides the active profile (tests, tuner); `nil` restores the loaded one.
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
                print("[LSim] Unreadable profile (\(path)): \(error) — using the built-in profile.")
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
    /// Tracking (letter spacing, points) per integer size, for SF Pro regular.
    public var tracking: [String: Double]
    /// Tracking for semibold and heavier (≥ 600): iOS's variable font spaces weights differently.
    /// Missing sizes fall back to the regular table.
    public var trackingSemibold: [String: Double]?
    /// Tracking for sizes beyond 40 pt missing from the table (decreases to 0 at 80 pt).
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

/// Symbols: size relative to the font size per `imageScale`, and frame margins around the ink.
public struct ImageProfile: Codable, Sendable {
    public var scaleSmall: Double
    public var scaleMedium: Double
    public var scaleLarge: Double
    /// Horizontal / vertical frame margin around the glyph ink, as a fraction of the font size.
    public var paddingH: Double
    public var paddingV: Double
    /// Default spacing (stack without `spacing:`) between an image and its neighbor.
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

/// Light / dark color pair, components 0…1 (r, g, b, a).
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
        /// Horizontal padding with `.buttonBorderShape(.circle)`.
        public var circlePadH: Double
    }

    /// Label color.
    public enum LabelColor: String, Codable, Sendable, CaseIterable {
        case tint       // tint (red if destructive)
        case primary
        case white
        case inherit    // environment foregroundStyle, else primary
    }

    /// Background fill.
    public enum Fill: String, Codable, Sendable, CaseIterable {
        case none
        case neutralOrTinted   // .bordered: neutral grey, or translucent tint if .tint / destructive
        case solid             // .borderedProminent: solid tint
        case glass
        case glassTinted
    }

    public struct Style: Codable, Sendable, Hashable {
        public var label: LabelColor
        public var destructiveLabel: LabelColor
        /// Font follows `controlSize`.
        public var followsControlSize: Bool
        public var fill: Fill
        public var pressedOpacity: Double
    }

    /// Keys: mini, small, regular, large, extraLarge.
    public var sizes: [String: Size]
    /// Keys: automatic, plain, borderless, bordered, borderedProminent, glass, glassProminent.
    public var styles: [String: Style]
    /// Default shape of buttons with a background: "capsule" or "roundedRectangle".
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
    /// Fallback values (identical to the bundled profile at the time of writing).
    static let fallbackTracking: [String: Double] = [
        "6": 0.24, "7": 0.23, "8": 0.21, "9": 0.17, "10": 0.12, "11": 0.06, "12": 0, "13": -0.08, "14": -0.15,
        "15": -0.23, "16": -0.31, "17": -0.30, "18": -0.44, "19": -0.45, "20": -0.45, "21": -0.36, "22": -0.26,
        "23": -0.10, "24": 0.07, "25": 0.15, "26": 0.22, "27": 0.29, "28": 0.38, "29": 0.40, "30": 0.40,
        "31": 0.39, "32": 0.41, "33": 0.40, "34": 0.40, "35": 0.38, "36": 0.37, "37": 0.36, "38": 0.37,
        "39": 0.38, "40": 0.37,
    ]

    static let fallback = DesignProfile(name: "iOS 27.2 (fallback)",
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

    /// Compatibility mode (apps linked against an SDK before iOS 26): iOS 18 look.
    static let compatibility: DesignProfile = {
        var p = fallback
        p.name = "iOS 18 compatibility"
        let size = ButtonProfile.Size(fontSize: 17, padH: 12, padV: 7, circlePadH: 7)
        p.button.sizes = ["mini": size, "small": size, "regular": size, "large": size, "extraLarge": size]
        p.button.defaultShape = "roundedRectangle"
        return p
    }()
}

/// Liquid Glass navigation bar measurements.
public struct NavigationProfile: Codable, Sendable {
    public var edgeLight: ScrollEdgeTable?
    public var edgeDark: ScrollEdgeTable?
}

/// Scroll edge effect under the bar, row by row: on a grey background, output = α·background + β,
/// with a `blur` std dev (points). `y`: points from the top of the measurement screen, whose bar ends
/// at `referenceBarBottom`.
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

/// Measured animation preset: spring (response, damping) or named Bezier curve and duration.
public struct AnimationSetting: Codable, Sendable {
    public struct Spring: Codable, Sendable { public var response: Double; public var damping: Double }
    public var spring: Spring?
    public var bezier: String?
    public var duration: Double?
    /// Measured delay between the transaction and the first on-screen motion (s); not applied.
    public var lag: Double?
}

/// Release decision for a gesture: projected position = translation + `projection` × velocity, compared
/// with `threshold` × screen width (swipe) or the sheet's travel.
public struct GestureRule: Codable, Sendable {
    public var projection: Double
    public var threshold: Double
}

public struct GestureProfile: Codable, Sendable {
    public var backSwipe: GestureRule?
    public var sheetDismiss: GestureRule?
}
