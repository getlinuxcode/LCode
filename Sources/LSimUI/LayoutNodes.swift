import Foundation

/// Nœud de layout. Protocole en deux temps, comme SwiftUI :
/// 1. `sizeThatFits` : le parent propose une taille, l'enfant choisit la sienne ;
/// 2. `render` : le parent place l'enfant dans un rectangle et l'enfant émet ses instructions de dessin.
open class LayoutNode {
    public var layoutPriority: Double = 0
    private var cache: [ProposedViewSize: CGSize] = [:]

    public init() {}

    public final func sizeThatFits(_ proposal: ProposedViewSize, _ lc: LayoutContext) -> CGSize {
        if let cached = cache[proposal] { return cached }
        let size = computeSize(proposal, lc)
        cache[proposal] = size
        return size
    }

    open func computeSize(_ proposal: ProposedViewSize, _ lc: LayoutContext) -> CGSize { .zero }
    /// Dessin du nœud dans le rectangle donné (à surcharger).
    open func draw(in rect: CGRect, _ lc: LayoutContext, _ list: inout DisplayList) {}

    /// Identité stable (chemin dans l'arbre de vues), animation implicite et transition, posées à la
    /// construction ; elles permettent d'animer le nœud d'une image à l'autre.
    var identity: String?
    var animation: Animation?
    var transition: AnyTransition?
    /// Clé du nœud dans l'image en cours (pour animer ses grandeurs propres, comme l'opacité).
    var frameKey: String?

    /// Point d'entrée du rendu : applique l'animation du cadre et les transitions, puis dessine.
    public final func render(in rect: CGRect, _ lc: LayoutContext, _ list: inout DisplayList) {
        guard let animator = lc.animator, let identity else { return draw(in: rect, lc, &list) }
        let key = animator.key(identity)
        frameKey = key
        let now = animator.frameTime
        let v = animator.present(key, [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)],
                                 animation: animation, now: now)
        let presented = CGRect(x: v[0], y: v[1], width: max(0, v[2]), height: max(0, v[3]))
        // Apparition pendant une transaction animée : transition (fondu par défaut) sur la racine du
        // sous-arbre inséré seulement.
        if let progress = animator.insertionProgress(key, animation: transition?.animation ?? animation),
           progress < 1 {
            let kinds = transition?.insertion ?? [.opacity]
            var dx: CGFloat = 0, dy: CGFloat = 0, scale: CGFloat = 1, alpha = 1.0
            let screen = lc.screen == .zero ? presented : lc.screen
            for kind in kinds {
                switch kind {
                case .identity: break
                case .opacity: alpha *= progress
                case let .scale(s): scale *= CGFloat(s + (1 - s) * progress)
                case let .move(edge):
                    let k = CGFloat(1 - progress)
                    switch edge {
                    case .leading: dx -= (presented.maxX - screen.minX) * k
                    case .trailing: dx += (screen.maxX - presented.minX) * k
                    case .top: dy -= (presented.maxY - screen.minY) * k
                    case .bottom: dy += (screen.maxY - presented.minY) * k
                    }
                case .slide: dx -= (presented.maxX - screen.minX) * CGFloat(1 - progress)
                case let .offset(x, y): dx += x * CGFloat(1 - progress); dy += y * CGFloat(1 - progress)
                }
            }
            list.append(.pushTransform(dx: dx, dy: dy, scale: scale, anchor: CGPoint(x: presented.midX, y: presented.midY)))
            if alpha < 1 { list.append(.pushOpacity(max(0, alpha))) }
            animator.enterInserted()
            draw(in: presented, lc, &list)
            animator.leaveInserted()
            if alpha < 1 { list.append(.popOpacity) }
            list.append(.popTransform)
            return
        }
        draw(in: presented, lc, &list)
    }

    /// Axe d'expansion d'un Spacer / Divider (défini par la pile parente).
    var stackAxis: Axis?
    var isSpacer: Bool { false }
    /// Une image (éventuellement enveloppée de modificateurs) : SwiftUI l'espace différemment.
    var isImage: Bool { (self as? SingleChildNode)?.child.isImage ?? false }
    /// `.ignoresSafeArea()` quelque part dans la chaîne de modificateurs : le conteneur (écran de navigation)
    /// lui donne tout l'écran, barres et zones sûres comprises.
    var ignoresSafeArea: Bool { (self as? SingleChildNode)?.child.ignoresSafeArea ?? false }
    /// Rectangle où le contenu est réellement dessiné (après `.offset`) : zone de toucher, comme SwiftUI.
    func drawnRect(for rect: CGRect) -> CGRect { (self as? SingleChildNode)?.child.drawnRect(for: rect) ?? rect }
}

/// `.ignoresSafeArea()` : occupe tout l'écran (le conteneur l'y place) ; ailleurs, déborde dans les
/// zones sûres qu'il touche.
final class IgnoresSafeAreaNode: SingleChildNode {
    override var ignoresSafeArea: Bool { true }

    override func computeSize(_ p: ProposedViewSize, _ lc: LayoutContext) -> CGSize {
        child.sizeThatFits(p, lc)
    }

    override func draw(in rect: CGRect, _ lc: LayoutContext, _ list: inout DisplayList) {
        let r = lc.extendingIntoSafeArea(rect)
        let s = child.sizeThatFits(ProposedViewSize(r.size), lc)
        child.render(in: Alignment.center.place(s, in: r), lc, &list)
    }
}

struct _IgnoresSafeAreaModifier: _PrimitiveModifier {
    func _apply(_ context: BuildContext, _ content: (BuildContext) -> [LayoutNode]) -> [LayoutNode] {
        let nodes = content(context)
        let child = nodes.count == 1 ? nodes[0] : StackNode(axis: .vertical, crossAlignment: 0.5, spacing: nil, children: nodes)
        return [IgnoresSafeAreaNode(child)]
    }
}

public struct SafeAreaRegions: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let container = SafeAreaRegions(rawValue: 1)
    public static let keyboard = SafeAreaRegions(rawValue: 2)
    public static let all: SafeAreaRegions = [.container, .keyboard]
}

extension View {
    public func ignoresSafeArea(_ regions: SafeAreaRegions = .all, edges: Edge.Set = .all) -> some View {
        modifier(_IgnoresSafeAreaModifier())
    }
}

// MARK: - Feuilles

final class TextNode: LayoutNode {
    let string: String
    let font: Font
    let color: Color
    let alignment: TextAlignment

    init(_ string: String, font: Font, color: Color, alignment: TextAlignment) {
        self.string = string
        self.font = font
        self.color = color
        self.alignment = alignment
    }

    override func computeSize(_ p: ProposedViewSize, _ lc: LayoutContext) -> CGSize {
        let size = lc.measurer.measure(string, font: font, maxWidth: p.width.flatMap { $0.isFinite ? $0 : nil })
        // Comme iOS : arrondi au pixel physique supérieur (1/3 pt sur un écran @3x), pas au point entier.
        let scale = lc.displayScale
        return CGSize(width: (size.width * scale).rounded(.up) / scale, height: (size.height * scale).rounded(.up) / scale)
    }

    override func draw(in rect: CGRect, _ lc: LayoutContext, _ list: inout DisplayList) {
        list.append(.text(string, font, rect, color.resolve(in: lc.colorScheme), alignment))
    }
}

final class ShapeNode: LayoutNode {
    let kind: ShapeKind
    let color: Color

    init(_ kind: ShapeKind, color: Color) {
        self.kind = kind
        self.color = color
    }

    override func computeSize(_ p: ProposedViewSize, _ lc: LayoutContext) -> CGSize {
        // Une forme accepte toute la place proposée ; 10 pt en taille idéale (comme SwiftUI).
        let size = p.replacingUnspecifiedDimensions()
        if kind == .circle {
            let side = min(size.width, size.height)
            return CGSize(width: size.width.isFinite ? size.width : side, height: size.height.isFinite ? size.height : side)
        }
        return size
    }

    override func draw(in rect: CGRect, _ lc: LayoutContext, _ list: inout DisplayList) {
        var r = rect
        if kind == .circle {
            let side = min(rect.width, rect.height)
            r = Alignment.center.place(CGSize(width: side, height: side), in: rect)
        }
        list.append(.fill(kind, r, color.resolve(in: lc.colorScheme)))
    }
}

final class SpacerNode: LayoutNode {
    let minLength: CGFloat
    init(minLength: CGFloat) { self.minLength = minLength }

    override var isSpacer: Bool { true }

    override func computeSize(_ p: ProposedViewSize, _ lc: LayoutContext) -> CGSize {
        guard let axis = stackAxis else {
            // Hors pile : s'étend dans les deux directions.
            return CGSize(width: max(minLength, p.width ?? minLength), height: max(minLength, p.height ?? minLength))
        }
        let along = max(minLength, p[axis] ?? minLength)
        return CGSize(along: along, cross: 0, axis: axis)
    }
}

final class DividerNode: LayoutNode {
    let thickness: CGFloat = 1.0 / 3.0  // un pixel physique sur un écran @3x

    override func computeSize(_ p: ProposedViewSize, _ lc: LayoutContext) -> CGSize {
        // Dans une VStack (ou hors pile) le séparateur est horizontal.
        let lineAxis: Axis = stackAxis == .horizontal ? .vertical : .horizontal
        let along = p[lineAxis] ?? 10
        return CGSize(along: along.isFinite ? along : 10, cross: thickness, axis: lineAxis)
    }

    override func draw(in rect: CGRect, _ lc: LayoutContext, _ list: inout DisplayList) {
        list.append(.fill(.rectangle, rect, Color.separator.resolve(in: lc.colorScheme)))
    }
}

// MARK: - Piles

final class StackNode: LayoutNode {
    let axis: Axis
    let crossAlignment: CGFloat
    let spacing: CGFloat?
    let children: [LayoutNode]

    static let defaultSpacing: CGFloat = 8

    init(axis: Axis, crossAlignment: CGFloat, spacing: CGFloat?, children: [LayoutNode]) {
        self.axis = axis
        self.crossAlignment = crossAlignment
        self.spacing = spacing
        self.children = children
        super.init()
        for child in children where child is SpacerNode || child is DividerNode {
            child.stackAxis = axis
        }
    }

    private func totalSpacing() -> CGFloat {
        guard children.count > 1 else { return 0 }
        return (1..<children.count).reduce(0) { $0 + spacing(before: $1) }
    }

    private func spacing(before index: Int) -> CGFloat {
        guard index > 0 else { return 0 }
        if let spacing { return spacing }
        return Self.defaultSpacing(between: children[index - 1], and: children[index], axis: axis)
    }

    /// Espacement par défaut entre deux voisins (SwiftUI l'adapte selon les types de vues).
    /// Mesuré : dans une pile verticale, une image touche sa voisine ; l'horizontal reste à 8 pt.
    static func defaultSpacing(between a: LayoutNode, and b: LayoutNode, axis: Axis) -> CGFloat {
        if a.isSpacer || b.isSpacer { return 0 }
        if axis == .vertical, a.isImage || b.isImage, let s = DesignProfile.current.image.stackSpacing { return CGFloat(s) }
        return defaultSpacing
    }

    /// Répartit la taille le long de l'axe entre les enfants (algorithme de SwiftUI).
    private func childSizes(_ p: ProposedViewSize, _ lc: LayoutContext) -> [CGSize] {
        let cross = p[axis.other]
        guard let along = p[axis] else {
            return children.map { $0.sizeThatFits(ProposedViewSize(along: nil, cross: cross, axis: axis), lc) }
        }

        let mins = children.map { $0.sizeThatFits(ProposedViewSize(along: 0, cross: cross, axis: axis), lc)[axis] }
        let maxs = children.map { $0.sizeThatFits(ProposedViewSize(along: .infinity, cross: cross, axis: axis), lc)[axis] }

        // Ordre : priorité décroissante, puis du moins flexible au plus flexible ;
        // les Spacers passent en dernier et se partagent le reste.
        let order = children.indices.sorted { a, b in
            let ca = children[a], cb = children[b]
            if ca.isSpacer != cb.isSpacer { return !ca.isSpacer }
            if ca.layoutPriority != cb.layoutPriority { return ca.layoutPriority > cb.layoutPriority }
            return (maxs[a] - mins[a]) < (maxs[b] - mins[b])
        }

        var sizes = Array(repeating: CGSize.zero, count: children.count)
        var remaining = along - totalSpacing()
        var position = 0
        while position < order.count {
            let index = order[position]
            // Enfants restants du même groupe (même priorité, même nature).
            let group = order[position...].prefix {
                children[$0].isSpacer == children[index].isSpacer && children[$0].layoutPriority == children[index].layoutPriority
            }.count
            // On réserve la taille minimale des groupes traités ensuite (spacers, priorités plus faibles).
            let laterMin = order[(position + group)...].reduce(CGFloat(0)) { $0 + mins[$1] }
            let share = max(0, remaining - laterMin) / CGFloat(group)
            let size = children[index].sizeThatFits(ProposedViewSize(along: share, cross: cross, axis: axis), lc)
            sizes[index] = size
            remaining -= size[axis]
            position += 1
        }
        return sizes
    }

    override func computeSize(_ p: ProposedViewSize, _ lc: LayoutContext) -> CGSize {
        guard !children.isEmpty else { return .zero }
        let sizes = childSizes(p, lc)
        let along = sizes.reduce(0) { $0 + $1[axis] } + totalSpacing()
        let cross = sizes.map { $0[axis.other] }.max() ?? 0
        return CGSize(along: along, cross: cross, axis: axis)
    }

    override func draw(in rect: CGRect, _ lc: LayoutContext, _ list: inout DisplayList) {
        let sizes = childSizes(ProposedViewSize(rect.size), lc)
        let crossSize = rect.size[axis.other]
        var cursor: CGFloat = axis == .horizontal ? rect.minX : rect.minY
        let crossOrigin: CGFloat = axis == .horizontal ? rect.minY : rect.minX
        for (i, child) in children.enumerated() {
            cursor += spacing(before: i)
            let size = sizes[i]
            let crossOffset = (crossSize - size[axis.other]) * crossAlignment
            let origin = CGPoint(along: cursor, cross: crossOrigin + crossOffset, axis: axis)
            child.render(in: CGRect(origin: origin, size: size), lc, &list)
            cursor += size[axis]
        }
    }
}

final class ZStackNode: LayoutNode {
    let alignment: Alignment
    let children: [LayoutNode]

    init(alignment: Alignment, children: [LayoutNode]) {
        self.alignment = alignment
        self.children = children
    }

    override func computeSize(_ p: ProposedViewSize, _ lc: LayoutContext) -> CGSize {
        children.reduce(CGSize.zero) { acc, child in
            let s = child.sizeThatFits(p, lc)
            return CGSize(width: max(acc.width, s.width), height: max(acc.height, s.height))
        }
    }

    override func draw(in rect: CGRect, _ lc: LayoutContext, _ list: inout DisplayList) {
        for child in children {
            let s = child.sizeThatFits(ProposedViewSize(rect.size), lc)
            child.render(in: alignment.place(s, in: rect), lc, &list)
        }
    }
}

// MARK: - Modificateurs de layout

class SingleChildNode: LayoutNode {
    let child: LayoutNode
    init(_ child: LayoutNode) {
        self.child = child
        super.init()
        layoutPriority = child.layoutPriority
    }

    override var isSpacer: Bool { false }

    override func computeSize(_ p: ProposedViewSize, _ lc: LayoutContext) -> CGSize {
        child.sizeThatFits(p, lc)
    }

    override func draw(in rect: CGRect, _ lc: LayoutContext, _ list: inout DisplayList) {
        child.render(in: rect, lc, &list)
    }
}

final class PaddingNode: SingleChildNode {
    let insets: EdgeInsets

    init(_ child: LayoutNode, insets: EdgeInsets) {
        self.insets = insets
        super.init(child)
    }

    override func computeSize(_ p: ProposedViewSize, _ lc: LayoutContext) -> CGSize {
        let inner = ProposedViewSize(
            width: p.width.map { max(0, $0 - insets.horizontal) },
            height: p.height.map { max(0, $0 - insets.vertical) }
        )
        let s = child.sizeThatFits(inner, lc)
        return CGSize(width: s.width + insets.horizontal, height: s.height + insets.vertical)
    }

    override func draw(in rect: CGRect, _ lc: LayoutContext, _ list: inout DisplayList) {
        let inner = CGRect(
            x: rect.minX + insets.leading,
            y: rect.minY + insets.top,
            width: max(0, rect.width - insets.horizontal),
            height: max(0, rect.height - insets.vertical)
        )
        child.render(in: inner, lc, &list)
    }
}

final class FrameNode: SingleChildNode {
    struct Dimension {
        var fixed: CGFloat?
        var min: CGFloat?
        var ideal: CGFloat?
        var max: CGFloat?
    }

    let width: Dimension
    let height: Dimension
    let alignment: Alignment

    init(_ child: LayoutNode, width: Dimension, height: Dimension, alignment: Alignment) {
        self.width = width
        self.height = height
        self.alignment = alignment
        super.init(child)
    }

    private func childProposal(_ proposed: CGFloat?, _ d: Dimension) -> CGFloat? {
        if let fixed = d.fixed { return fixed }
        guard var value = proposed ?? d.ideal else { return nil }
        if let mn = d.min { value = Swift.max(value, mn) }
        if let mx = d.max { value = Swift.min(value, mx) }
        return value
    }

    private func resolve(_ proposed: CGFloat?, _ childSize: CGFloat, _ d: Dimension) -> CGFloat {
        if let fixed = d.fixed { return fixed }
        if d.min == nil && d.max == nil { return childSize }
        var r = childSize
        let p = proposed ?? d.ideal ?? childSize
        if let mx = d.max { r = Swift.min(mx, Swift.max(r, p)) }
        if let mn = d.min { r = Swift.max(mn, Swift.min(r, p)) }
        return r
    }

    override func computeSize(_ p: ProposedViewSize, _ lc: LayoutContext) -> CGSize {
        let cp = ProposedViewSize(width: childProposal(p.width, width), height: childProposal(p.height, height))
        let cs = child.sizeThatFits(cp, lc)
        return CGSize(width: resolve(p.width, cs.width, width), height: resolve(p.height, cs.height, height))
    }

    override func draw(in rect: CGRect, _ lc: LayoutContext, _ list: inout DisplayList) {
        let cp = ProposedViewSize(width: childProposal(rect.width, width), height: childProposal(rect.height, height))
        let cs = child.sizeThatFits(cp, lc)
        child.render(in: alignment.place(cs, in: rect), lc, &list)
    }
}

/// Fond ou superposition : la vue secondaire prend la taille de la vue principale.
final class LayerNode: SingleChildNode {
    let layer: [LayoutNode]
    let alignment: Alignment
    let isBackground: Bool

    init(_ child: LayoutNode, layer: [LayoutNode], alignment: Alignment, isBackground: Bool) {
        self.layer = layer
        self.alignment = alignment
        self.isBackground = isBackground
        super.init(child)
    }

    override func draw(in rect: CGRect, _ lc: LayoutContext, _ list: inout DisplayList) {
        if !isBackground { child.render(in: rect, lc, &list) }
        for node in layer {
            let s = node.sizeThatFits(ProposedViewSize(rect.size), lc)
            node.render(in: alignment.place(s, in: rect), lc, &list)
        }
        if isBackground { child.render(in: rect, lc, &list) }
    }
}

final class OpacityNode: SingleChildNode {
    let opacity: Double
    init(_ child: LayoutNode, opacity: Double) {
        self.opacity = opacity
        super.init(child)
    }

    override func draw(in rect: CGRect, _ lc: LayoutContext, _ list: inout DisplayList) {
        var opacity = self.opacity
        if let animator = lc.animator, let key = frameKey {
            opacity = animator.present(key + "#opacity", [opacity], animation: animation, now: animator.frameTime)[0]
        }
        guard opacity < 0.999 else { return child.render(in: rect, lc, &list) }
        list.append(.pushOpacity(max(0, opacity)))
        child.render(in: rect, lc, &list)
        list.append(.popOpacity)
    }
}

final class ClipNode: SingleChildNode {
    let shape: ShapeKind
    init(_ child: LayoutNode, shape: ShapeKind) {
        self.shape = shape
        super.init(child)
    }

    override func draw(in rect: CGRect, _ lc: LayoutContext, _ list: inout DisplayList) {
        list.append(.pushClip(shape, rect))
        child.render(in: rect, lc, &list)
        list.append(.popClip)
    }
}

final class OffsetNode: SingleChildNode {
    let offset: CGSize
    init(_ child: LayoutNode, offset: CGSize) {
        self.offset = offset
        super.init(child)
    }

    override func draw(in rect: CGRect, _ lc: LayoutContext, _ list: inout DisplayList) {
        child.render(in: rect.offsetBy(dx: offset.width, dy: offset.height), lc, &list)
    }

    override func drawnRect(for rect: CGRect) -> CGRect {
        child.drawnRect(for: rect.offsetBy(dx: offset.width, dy: offset.height))
    }
}

/// Zone tactile (Button, onTapGesture), avec effet de surbrillance optionnel.
final class TapNode: SingleChildNode {
    let id: String
    let isPressed: Bool
    let pressedOpacity: Double

    init(_ child: LayoutNode, id: String, isPressed: Bool, pressedOpacity: Double) {
        self.id = id
        self.isPressed = isPressed
        self.pressedOpacity = pressedOpacity
        super.init(child)
    }

    override func draw(in rect: CGRect, _ lc: LayoutContext, _ list: inout DisplayList) {
        if isPressed && pressedOpacity < 1 {
            list.append(.pushOpacity(pressedOpacity))
            child.render(in: rect, lc, &list)
            list.append(.popOpacity)
        } else {
            child.render(in: rect, lc, &list)
        }
        list.append(.hitRegion(id: id, child.drawnRect(for: rect)))
    }
}

// MARK: - Racine

/// Dispose les vues racines dans la zone sûre de l'écran (centrées, comme un WindowGroup).
public func layoutRoot(_ nodes: [LayoutNode], in container: CGRect, _ lc: LayoutContext,
                       presentations: [LayoutNode] = []) -> DisplayList {
    let root: LayoutNode = nodes.count == 1 ? nodes[0] : StackNode(axis: .vertical, crossAlignment: 0.5, spacing: nil, children: nodes)
    let size = root.sizeThatFits(ProposedViewSize(container.size), lc)
    let screen = lc.screen == .zero ? container : lc.screen
    func renderAll() -> DisplayList {
        var list = DisplayList()
        root.render(in: Alignment.center.place(size, in: container), lc, &list)
        // Feuilles et alertes : dessinées sur tout l'écran, au-dessus du reste.
        for presentation in presentations {
            presentation.render(in: screen, lc, &list)
        }
        return list
    }
    // Avec un animateur : une ou deux passes (cibles, puis valeurs présentées).
    return lc.animator?.frame(renderAll) ?? renderAll()
}
