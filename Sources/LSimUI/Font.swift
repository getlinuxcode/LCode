import Foundation

public struct Font: Hashable, Sendable {
    public enum Weight: Int, Hashable, Sendable {
        case ultraLight = 100, thin = 200, light = 300, regular = 400, medium = 500
        case semibold = 600, bold = 700, heavy = 800, black = 900
    }

    public enum Design: Hashable, Sendable {
        case `default`, serif, rounded, monospaced
    }

    public enum TextStyle: CaseIterable, Hashable, Sendable {
        case largeTitle, title, title2, title3, headline, subheadline, body, callout, footnote, caption, caption2

        /// Default iOS Dynamic Type sizes ("Large" category).
        var metrics: (size: CGFloat, weight: Weight) {
            switch self {
            case .largeTitle: (34, .regular)
            case .title: (28, .regular)
            case .title2: (22, .regular)
            case .title3: (20, .regular)
            case .headline: (17, .semibold)
            case .subheadline: (15, .regular)
            case .body: (17, .regular)
            case .callout: (16, .regular)
            case .footnote: (13, .regular)
            case .caption: (12, .regular)
            case .caption2: (11, .regular)
            }
        }
    }

    public var size: CGFloat
    public var weight: Weight
    public var design: Design
    public var isItalic: Bool
    /// Decorations (carried by the font to keep rendering simple).
    public var isStrikethrough = false
    public var isUnderline = false

    init(size: CGFloat, weight: Weight = .regular, design: Design = .default, isItalic: Bool = false) {
        self.size = size
        self.weight = weight
        self.design = design
        self.isItalic = isItalic
    }

    public static func system(size: CGFloat, weight: Weight = .regular, design: Design = .default) -> Font {
        Font(size: size, weight: weight, design: design)
    }

    public static func system(_ style: TextStyle, design: Design = .default, weight: Weight? = nil) -> Font {
        let m = style.metrics
        return Font(size: m.size, weight: weight ?? m.weight, design: design)
    }

    public static let largeTitle = system(.largeTitle)
    public static let title = system(.title)
    public static let title2 = system(.title2)
    public static let title3 = system(.title3)
    public static let headline = system(.headline)
    public static let subheadline = system(.subheadline)
    public static let body = system(.body)
    public static let callout = system(.callout)
    public static let footnote = system(.footnote)
    public static let caption = system(.caption)
    public static let caption2 = system(.caption2)

    public func weight(_ weight: Weight) -> Font { var f = self; f.weight = weight; return f }
    public func bold() -> Font { weight(.bold) }
    public func italic() -> Font { var f = self; f.isItalic = true; return f }
    public func monospaced() -> Font { var f = self; f.design = .monospaced; return f }
}
