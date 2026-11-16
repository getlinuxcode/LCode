import Foundation

/// Image : symbole SF Symbols (`Image(systemName:)`) ou image nommée.
///
/// Les symboles sont dessinés avec le glyphe correspondant des polices SF Pro de l'utilisateur ;
/// la table nom → glyphe est construite par le banc de calibration à partir de son iPhone.
public struct Image: View, _PrimitiveView, Equatable {
    public typealias Body = Never

    public enum Scale: Hashable, Sendable { case small, medium, large }
    public enum TemplateRenderingMode: Hashable, Sendable { case template, original }
    public enum ResizingMode: Hashable, Sendable { case tile, stretch }

    enum Source: Equatable {
        case system(String)
        case named(String)
    }

    let source: Source
    var isResizable = false

    public init(systemName: String) { source = .system(systemName) }
    public init(_ name: String) { source = .named(name) }
    public init(decorative name: String) { source = .named(name) }

    public func resizable(capInsets: EdgeInsets = EdgeInsets(), resizingMode: ResizingMode = .stretch) -> Image {
        var i = self
        i.isResizable = true
        return i
    }

    public func renderingMode(_ mode: TemplateRenderingMode?) -> Image { self }
    public func symbolRenderingMode(_ mode: SymbolRenderingMode?) -> Image { self }

    public func _makeNodes(_ context: BuildContext) -> [LayoutNode] {
        let env = context.environment
        var font = env.font ?? .body
        if let w = env.fontWeight { font.weight = w }
        let color = env.isEnabled ? (env.foregroundColor ?? .primary) : .tertiaryLabel
        switch source {
        case let .system(name):
            return [SymbolNode(name: name, font: font, scale: env.imageScale, color: color.resolvingTint(env),
                               resizable: isResizable, contentMode: env.imageContentMode)]
        case let .named(name):
            // Les images de l'app (catalogue d'assets) ne sont pas encore prises en charge : cadre de substitution.
            return [MissingImageNode(name: name, resizable: isResizable)]
        }
    }
}

public struct SymbolRenderingMode: Hashable, Sendable {
    let id: Int
    public static let monochrome = SymbolRenderingMode(id: 0)
    public static let hierarchical = SymbolRenderingMode(id: 1)
    public static let palette = SymbolRenderingMode(id: 2)
    public static let multicolor = SymbolRenderingMode(id: 3)
}

public enum ContentMode: Hashable, Sendable { case fit, fill }

extension View {
    public func imageScale(_ scale: Image.Scale) -> some View {
        modifier(_EnvironmentModifier { $0.imageScale = scale })
    }

    public func symbolRenderingMode(_ mode: SymbolRenderingMode?) -> some View { self }

    public func aspectRatio(_ ratio: CGFloat? = nil, contentMode: ContentMode) -> some View {
        modifier(_EnvironmentModifier { $0.imageContentMode = contentMode })
    }

    public func scaledToFit() -> some View { aspectRatio(contentMode: .fit) }
    public func scaledToFill() -> some View { aspectRatio(contentMode: .fill) }
}

/// Mesures d'un symbole fournies par le moteur de rendu.
public struct SymbolMetrics: Sendable {
    /// Taille du cadre du symbole à cette police et cette échelle.
    public var size: CGSize
    public init(size: CGSize) { self.size = size }
}

final class SymbolNode: LayoutNode {
    let name: String
    let font: Font
    let scale: Image.Scale
    let color: Color
    let resizable: Bool
    let contentMode: ContentMode

    init(name: String, font: Font, scale: Image.Scale, color: Color, resizable: Bool, contentMode: ContentMode) {
        self.name = name
        self.font = font
        self.scale = scale
        self.color = color
        self.resizable = resizable
        self.contentMode = contentMode
    }

    override var isImage: Bool { true }

    func natural(_ lc: LayoutContext) -> CGSize {
        if let m = lc.measurer.measureSymbol(name, font: font, scale: scale) { return m.size }
        // Symbole inconnu (table absente) : carré du corps de la police.
        let side = font.size * CGFloat(DesignProfile.current.image.factor(scale))
        return CGSize(width: side, height: side)
    }

    override func computeSize(_ p: ProposedViewSize, _ lc: LayoutContext) -> CGSize {
        let n = natural(lc)
        guard resizable else { return n }
        // Image redimensionnable : prend la place proposée (en gardant le rapport si scaledToFit/Fill).
        let proposed = p.replacingUnspecifiedDimensions(by: n)
        guard n.width > 0, n.height > 0 else { return proposed }
        let kw = proposed.width / n.width, kh = proposed.height / n.height
        let k = contentMode == .fit ? min(kw, kh) : max(kw, kh)
        return CGSize(width: (n.width * k).isFinite ? n.width * k : proposed.width,
                      height: (n.height * k).isFinite ? n.height * k : proposed.height)
    }

    override func draw(in rect: CGRect, _ lc: LayoutContext, _ list: inout DisplayList) {
        list.append(.symbol(name, font, scale, rect, color.resolve(in: lc.colorScheme)))
    }
}

final class MissingImageNode: LayoutNode {
    let name: String
    let resizable: Bool
    init(name: String, resizable: Bool) {
        self.name = name
        self.resizable = resizable
    }

    override func computeSize(_ p: ProposedViewSize, _ lc: LayoutContext) -> CGSize {
        resizable ? p.replacingUnspecifiedDimensions(by: CGSize(width: 40, height: 40)) : CGSize(width: 40, height: 40)
    }

    override func draw(in rect: CGRect, _ lc: LayoutContext, _ list: inout DisplayList) {
        list.append(.fill(.roundedRectangle(cornerRadius: 4), rect, Color.gray.opacity(0.2).resolve(in: lc.colorScheme)))
        list.append(.stroke(.roundedRectangle(cornerRadius: 4), rect, Color.gray.resolve(in: lc.colorScheme), lineWidth: 1))
    }
}
