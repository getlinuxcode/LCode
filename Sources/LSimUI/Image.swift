import Foundation

/// Image: SF Symbol (`Image(systemName:)`) or named image. Symbols are drawn with the matching glyph
/// from the user's SF Pro fonts; the name → glyph table is built by the calibration bench from their iPhone.
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
    public init(_ name: String, bundle: Bundle? = nil) { source = .named(name) }
    public init(decorative name: String, bundle: Bundle? = nil) { source = .named(name) }

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
                               resizable: isResizable, contentMode: env.imageContentMode ?? .fit)]
        case let .named(name):
            // App asset catalog image; if missing: draws nothing (like iOS) and is reported in the output.
            guard AssetCatalog.shared.image(name, scheme: .light) != nil || AssetCatalog.shared.image(name, scheme: .dark) != nil else {
                AssetCatalog.shared.warnMissing("image", name)
                return [MissingImageNode(name: name, resizable: isResizable)]
            }
            return [AssetImageNode(name: name, resizable: isResizable, contentMode: env.imageContentMode)]
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

/// Symbol metrics provided by the renderer.
public struct SymbolMetrics: Sendable {
    /// Symbol frame size at this font and scale.
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
        // Unknown symbol (no table): square of the font's body size.
        let side = font.size * CGFloat(DesignProfile.current.image.factor(scale))
        return CGSize(width: side, height: side)
    }

    override func computeSize(_ p: ProposedViewSize, _ lc: LayoutContext) -> CGSize {
        let n = natural(lc)
        guard resizable else { return n }
        // Resizable image: takes the proposed space (keeping the ratio if scaledToFit/Fill).
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

/// Asset catalog image: natural size = pixels / file scale (1x, 2x, 3x).
final class AssetImageNode: LayoutNode {
    let name: String
    let resizable: Bool
    let contentMode: ContentMode?

    init(name: String, resizable: Bool, contentMode: ContentMode?) {
        self.name = name
        self.resizable = resizable
        self.contentMode = contentMode
    }

    override var isImage: Bool { true }

    private func file(_ lc: LayoutContext) -> AssetCatalog.ImageFile? {
        AssetCatalog.shared.image(name, scheme: lc.colorScheme, displayScale: Double(lc.displayScale))
    }

    func natural(_ lc: LayoutContext) -> CGSize {
        guard let f = file(lc), let px = lc.measurer.measureImage(f.path) else { return .zero }
        return CGSize(width: px.width / CGFloat(f.scale), height: px.height / CGFloat(f.scale))
    }

    override func computeSize(_ p: ProposedViewSize, _ lc: LayoutContext) -> CGSize {
        let n = natural(lc)
        guard resizable else { return n }
        let proposed = p.replacingUnspecifiedDimensions(by: n)
        guard n.width > 0, n.height > 0 else { return proposed }
        // Without aspectRatio the image stretches to the proposed space; otherwise the ratio is kept.
        guard let mode = contentMode else { return proposed }
        let kw = proposed.width / n.width, kh = proposed.height / n.height
        let k = mode == .fit ? min(kw, kh) : max(kw, kh)
        return CGSize(width: (n.width * k).isFinite ? n.width * k : proposed.width,
                      height: (n.height * k).isFinite ? n.height * k : proposed.height)
    }

    override func draw(in rect: CGRect, _ lc: LayoutContext, _ list: inout DisplayList) {
        guard let f = file(lc) else { return }
        list.append(.image(f.path, rect))
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
