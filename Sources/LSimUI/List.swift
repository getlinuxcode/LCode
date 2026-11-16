import Foundation

extension Axis {
    public struct Set: OptionSet, Sendable {
        public let rawValue: Int8
        public init(rawValue: Int8) { self.rawValue = rawValue }
        public static let horizontal = Set(rawValue: 1)
        public static let vertical = Set(rawValue: 2)
    }
}

extension Color {
    static let systemGroupedBackground = Color(light: .rgb255(242, 242, 247), dark: RGBA(0, 0, 0))
    static let secondarySystemGroupedBackground = Color(light: RGBA(1, 1, 1), dark: .rgb255(28, 28, 30))
    static let rowHighlight = Color(light: .rgb255(209, 209, 214), dark: .rgb255(58, 58, 60))
    static let chevronGray = Color(light: .rgb255(60, 60, 67, 0.3), dark: .rgb255(235, 235, 245, 0.3))
}

/// Mesures du style `.insetGrouped`, relevées sur iPhone 17 Pro Max sous iOS 27.2,
/// en Liquid Glass (SDK ≥ 26) et en mode compatibilité.
public enum ListMetrics {
    static var glass: Bool { DesignStyle.current == .liquidGlass }

    public static var margin: CGFloat { 20 }
    public static var cornerRadius: CGFloat { glass ? 26 : 10 }
    public static var rowMinHeight: CGFloat { glass ? 52 : 44 }
    public static var rowPaddingH: CGFloat { 20 }
    public static var rowPaddingV: CGFloat { glass ? 15 : 8.5 }
    /// Espace avant la première section (avec / sans en-tête).
    public static var topInsetWithHeader: CGFloat { glass ? 8.5 : 13 }
    public static var topInset: CGFloat { 20 }
    public static var sectionSpacing: CGFloat { 35 }
    public static var headerBottomGap: CGFloat { glass ? 10 : 6 }
    public static var footerTopGap: CGFloat { 7 }
    /// En-tête de section : majuscules en footnote (compatibilité), casse normale en 17 pt medium (Liquid Glass).
    public static var headerFont: Font { glass ? .system(size: 17, weight: .medium) : .footnote }
    public static var headerTextCase: Text.Case? { glass ? nil : .uppercase }
    /// Le séparateur s'arrête avant le bord droit de la carte en Liquid Glass.
    public static var separatorTrailingInset: CGFloat { glass ? 20 : 0 }
    /// Rectangle du tracé du chevron (l'encre déborde de la moitié du trait) et marge droite de son encre.
    public static var chevronSize: CGSize { glass ? CGSize(width: 4.7, height: 9.5) : CGSize(width: 7, height: 12) }
    public static var chevronTrailing: CGFloat { glass ? 23 : 20 }
    public static var bottomInset: CGFloat { 20 }
}

// MARK: - Défilement

/// Conteneur défilant verticalement. Prend toute la place proposée.
final class ScrollNode: LayoutNode {
    let id: String
    let content: LayoutNode
    let graph: ViewGraph
    let background: Color?
    let centerContent: Bool
    /// En-tête défilant avec le contenu (grand titre de navigation).
    var header: LayoutNode?
    var bottomInset: CGFloat = 0
    /// Marge haute du contenu (le contenu défile sous la barre de navigation).
    var topInset: CGFloat = 0
    /// Position demandée par `.scrollPosition` : comme sur iOS, y est compté depuis l'état où le grand
    /// titre est replié (y = 0 : contenu juste sous la barre ; négatif : grand titre en partie déployé).
    var pendingRequest: CGFloat?

    init(id: String, content: LayoutNode, graph: ViewGraph, background: Color?, centerContent: Bool) {
        self.id = id
        self.content = content
        self.graph = graph
        self.background = background
        self.centerContent = centerContent
        super.init()
        // Marque le décalage comme utilisé pendant la construction, sinon le nettoyage
        // de fin de passe le supprimerait (il n'est relu qu'au moment du dessin).
        _ = graph.scrollOffset(id)
    }

    var offset: CGFloat { graph.scrollOffset(id) }

    override func computeSize(_ p: ProposedViewSize, _ lc: LayoutContext) -> CGSize {
        let width = p.width ?? content.sizeThatFits(.unspecified, lc).width
        let height = p.height ?? content.sizeThatFits(ProposedViewSize(width: width, height: nil), lc).height
        return CGSize(width: width.isFinite ? width : 0, height: height.isFinite ? height : 0)
    }

    override func draw(in rect: CGRect, _ lc: LayoutContext, _ list: inout DisplayList) {
        let viewport = lc.extendingIntoSafeArea(rect)
        if let background {
            list.append(.fill(.rectangle, viewport, background.resolve(in: lc.colorScheme)))
        }
        let headerSize = header?.sizeThatFits(ProposedViewSize(width: rect.width, height: nil), lc) ?? .zero
        let contentSize = content.sizeThatFits(ProposedViewSize(width: rect.width, height: nil), lc)
        let total = topInset + headerSize.height + contentSize.height + bottomInset
        let maxOffset = max(0, total - rect.height)
        if let request = pendingRequest {
            graph.setScrollOffsetSilently(id, request.isFinite ? request + headerSize.height : maxOffset)
            pendingRequest = nil
        }
        let offset = min(max(0, graph.scrollOffset(id)), maxOffset)
        graph.setScrollOffsetSilently(id, offset)

        list.append(.pushClip(.rectangle, viewport))
        var y = rect.minY + topInset - offset
        if let header {
            header.render(in: CGRect(x: rect.minX, y: y, width: rect.width, height: headerSize.height), lc, &list)
            y += headerSize.height
        }
        let x = centerContent ? rect.minX + (rect.width - contentSize.width) / 2 : rect.minX
        content.render(in: CGRect(x: x, y: y, width: contentSize.width, height: contentSize.height), lc, &list)
        list.append(.popClip)
        list.append(.scrollRegion(id: id, viewport))
    }
}

public struct ScrollView<Content: View>: View, _PrimitiveView {
    public typealias Body = Never
    let content: Content
    let horizontal: Bool

    public init(_ axes: Axis.Set = .vertical, showsIndicators: Bool = true, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.horizontal = axes == .horizontal
    }

    public func _makeNodes(_ context: BuildContext) -> [LayoutNode] {
        var ctx = context.child("ScrollView")
        ctx.environment.scrollPosition = nil   // la position ne concerne que cette zone, pas les zones imbriquées
        let children = LSimUI._makeNodes(content, ctx)
        if horizontal {
            let stack = StackNode(axis: .horizontal, crossAlignment: 0.5, spacing: nil, children: children)
            context.graph.horizontalScrolls.insert(ctx.path + "#scroll")
            return [HorizontalScrollNode(id: ctx.path + "#scroll", content: stack, graph: context.graph)]
        }
        let stack = StackNode(axis: .vertical, crossAlignment: 0.5, spacing: nil, children: children)
        let id = ctx.path + "#scroll"
        var pending: CGFloat?
        // `.scrollPosition($position)` : chaque nouvelle demande déplace le contenu une fois.
        if let position = context.environment.scrollPosition {
            let applied = context.graph.persistent(id + "#request") { AppliedScrollRequest() }
            let request = position.wrappedValue
            if request.generation != applied.generation, let y = request.requestedY {
                applied.generation = request.generation
                pending = y
            }
        }
        let node = ScrollNode(id: id, content: stack, graph: context.graph, background: nil, centerContent: true)
        node.pendingRequest = pending
        return [node]
    }
}

/// Défilement horizontal : hauteur du contenu, largeur proposée.
final class HorizontalScrollNode: LayoutNode {
    let id: String
    let content: LayoutNode
    let graph: ViewGraph

    init(id: String, content: LayoutNode, graph: ViewGraph) {
        self.id = id
        self.content = content
        self.graph = graph
        super.init()
        _ = graph.scrollOffset(id)
    }

    override func computeSize(_ p: ProposedViewSize, _ lc: LayoutContext) -> CGSize {
        let natural = content.sizeThatFits(ProposedViewSize(width: nil, height: p.height), lc)
        let width = p.width.flatMap { $0.isFinite ? $0 : nil } ?? natural.width
        return CGSize(width: width, height: natural.height)
    }

    override func draw(in rect: CGRect, _ lc: LayoutContext, _ list: inout DisplayList) {
        let natural = content.sizeThatFits(ProposedViewSize(width: nil, height: rect.height), lc)
        let offset = min(max(0, graph.scrollOffset(id)), max(0, natural.width - rect.width))
        graph.setScrollOffsetSilently(id, offset)
        list.append(.pushClip(.rectangle, rect))
        content.render(in: CGRect(x: rect.minX - offset, y: rect.minY, width: natural.width, height: rect.height), lc, &list)
        list.append(.popClip)
        list.append(.scrollRegion(id: id, rect))
    }
}

// MARK: - List et Section

/// Ligne interactive d'une liste (Button ou NavigationLink) : toute la ligne est touchable.
final class RowActionNode: SingleChildNode {
    let id: String
    let isLink: Bool
    init(_ child: LayoutNode, id: String, isLink: Bool) {
        self.id = id
        self.isLink = isLink
        super.init(child)
    }

    override func draw(in rect: CGRect, _ lc: LayoutContext, _ list: inout DisplayList) {
        child.render(in: rect, lc, &list)
        list.append(.hitRegion(id: id, rect))
    }
}

/// Marqueur produit par `Section`, regroupé par `List`.
final class SectionNode: LayoutNode {
    let header: LayoutNode?
    let rows: [LayoutNode]
    let footer: LayoutNode?
    init(header: LayoutNode?, rows: [LayoutNode], footer: LayoutNode?) {
        self.header = header
        self.rows = rows
        self.footer = footer
    }
}

final class ListContentNode: LayoutNode {
    let sections: [SectionNode]
    let pressedID: String?

    init(sections: [SectionNode], pressedID: String?) {
        self.sections = sections
        self.pressedID = pressedID
    }

    private typealias M = ListMetrics

    private func spacing(before index: Int) -> CGFloat {
        let hasHeader = sections[index].header != nil
        if index == 0 { return hasHeader ? M.topInsetWithHeader : M.topInset }
        return hasHeader ? M.sectionSpacing - M.topInsetWithHeader : M.sectionSpacing
    }

    private func contentWidth(_ rowWidth: CGFloat, _ row: LayoutNode) -> CGFloat {
        let chevron = (row as? RowActionNode)?.isLink == true ? M.chevronSize.width + 12 : 0
        return max(0, rowWidth - 2 * M.rowPaddingH - chevron)
    }

    private func rowHeight(_ row: LayoutNode, _ rowWidth: CGFloat, _ lc: LayoutContext) -> CGFloat {
        let size = row.sizeThatFits(ProposedViewSize(width: contentWidth(rowWidth, row), height: nil), lc)
        return max(M.rowMinHeight, size.height + 2 * M.rowPaddingV)
    }

    private func textBlockHeight(_ node: LayoutNode?, _ width: CGFloat, _ lc: LayoutContext) -> CGFloat {
        guard let node else { return 0 }
        return node.sizeThatFits(ProposedViewSize(width: width - 2 * M.rowPaddingH, height: nil), lc).height
    }

    override func computeSize(_ p: ProposedViewSize, _ lc: LayoutContext) -> CGSize {
        let width = p.width.flatMap { $0.isFinite ? $0 : nil } ?? 375
        let rowWidth = width - 2 * M.margin
        var y: CGFloat = 0
        for (i, section) in sections.enumerated() {
            y += spacing(before: i)
            if section.header != nil { y += textBlockHeight(section.header, rowWidth, lc) + M.headerBottomGap }
            y += section.rows.reduce(0) { $0 + rowHeight($1, rowWidth, lc) }
            if section.footer != nil { y += M.footerTopGap + textBlockHeight(section.footer, rowWidth, lc) }
        }
        return CGSize(width: width, height: y + M.bottomInset)
    }

    override func draw(in rect: CGRect, _ lc: LayoutContext, _ list: inout DisplayList) {
        let rowX = rect.minX + M.margin
        let rowWidth = rect.width - 2 * M.margin
        let textX = rowX + M.rowPaddingH
        let textWidth = rowWidth - 2 * M.rowPaddingH
        var y = rect.minY

        for (i, section) in sections.enumerated() {
            y += spacing(before: i)
            if let header = section.header {
                let h = textBlockHeight(header, rowWidth, lc)
                let s = header.sizeThatFits(ProposedViewSize(width: textWidth, height: nil), lc)
                header.render(in: CGRect(x: textX, y: y, width: s.width, height: h), lc, &list)
                y += h + M.headerBottomGap
            }

            let heights = section.rows.map { rowHeight($0, rowWidth, lc) }
            let sectionRect = CGRect(x: rowX, y: y, width: rowWidth, height: heights.reduce(0, +))
            if !section.rows.isEmpty {
                list.append(.fill(.roundedRectangle(cornerRadius: M.cornerRadius), sectionRect,
                                  Color.secondarySystemGroupedBackground.resolve(in: lc.colorScheme)))
                list.append(.pushClip(.roundedRectangle(cornerRadius: M.cornerRadius), sectionRect))
            }
            for (index, row) in section.rows.enumerated() {
                let rowRect = CGRect(x: rowX, y: y, width: rowWidth, height: heights[index])
                let action = row as? RowActionNode
                if let action, action.id == pressedID {
                    list.append(.fill(.rectangle, rowRect, Color.rowHighlight.resolve(in: lc.colorScheme)))
                }
                let cw = contentWidth(rowWidth, row)
                let size = row.sizeThatFits(ProposedViewSize(width: cw, height: nil), lc)
                let contentRect = CGRect(x: textX, y: rowRect.midY - size.height / 2, width: min(size.width, cw), height: size.height)
                // Le contenu est d'abord rendu à part pour trouver où commence le premier texte :
                // iOS aligne le séparateur sur ce texte (et non sur l'icône éventuelle).
                var rowItems = DisplayList()
                (action?.child ?? row).render(in: contentRect, lc, &rowItems)
                let separatorX = rowItems.items.lazy.compactMap { item -> CGFloat? in
                    if case let .text(_, _, r, _, _) = item { return r.minX } else { return nil }
                }.first ?? textX
                if let action {
                    list.append(contentsOf: rowItems)
                    if action.isLink {
                        let c = M.chevronSize
                        let chevron = CGRect(x: rowRect.maxX - M.chevronTrailing - 1 - c.width, y: rowRect.midY - c.height / 2, width: c.width, height: c.height)
                        list.append(.chevron(chevron, Color.chevronGray.resolve(in: lc.colorScheme), lineWidth: 2, pointingLeft: false))
                    }
                    list.append(.hitRegion(id: action.id, rowRect))
                } else {
                    list.append(contentsOf: rowItems)
                }
                if index < section.rows.count - 1 {
                    let line = CGRect(x: separatorX, y: rowRect.maxY - 1.0 / 3.0, width: rowRect.maxX - M.separatorTrailingInset - separatorX, height: 1.0 / 3.0)
                    list.append(.fill(.rectangle, line, Color.separator.resolve(in: lc.colorScheme)))
                }
                y += heights[index]
            }
            if !section.rows.isEmpty { list.append(.popClip) }
            if let footer = section.footer {
                y += M.footerTopGap
                let h = textBlockHeight(footer, rowWidth, lc)
                footer.render(in: CGRect(x: textX, y: y, width: textWidth, height: h), lc, &list)
                y += h
            }
        }
    }
}

public struct List<Content: View>: View, _PrimitiveView {
    public typealias Body = Never
    let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public func _makeNodes(_ context: BuildContext) -> [LayoutNode] {
        var ctx = context.child("List")
        ctx.environment.isInList = true
        let nodes = LSimUI._makeNodes(content, ctx)

        // Regroupe les lignes hors Section dans des sections implicites.
        var sections: [SectionNode] = []
        var loose: [LayoutNode] = []
        func flush() {
            if !loose.isEmpty { sections.append(SectionNode(header: nil, rows: loose, footer: nil)) }
            loose = []
        }
        for node in nodes {
            if let section = node as? SectionNode { flush(); sections.append(section) } else { loose.append(node) }
        }
        flush()

        let listNode = ListContentNode(sections: sections, pressedID: context.graph.pressedID)
        return [ScrollNode(id: ctx.path + "#scroll", content: listNode, graph: context.graph,
                           background: .systemGroupedBackground, centerContent: false)]
    }
}

extension List {
    public init<Data: RandomAccessCollection, RowContent: View>(
        _ data: Data, @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent
    ) where Content == ForEach<Data, Data.Element.ID, RowContent>, Data.Element: Identifiable {
        self.init { ForEach(data, content: rowContent) }
    }

    public init<Data: RandomAccessCollection, ID: Hashable, RowContent: View>(
        _ data: Data, id: KeyPath<Data.Element, ID>, @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent
    ) where Content == ForEach<Data, ID, RowContent> {
        self.init { ForEach(data, id: id, content: rowContent) }
    }
}

public struct Section<Parent: View, Content: View, Footer: View>: View, _PrimitiveView {
    public typealias Body = Never
    let header: Parent
    let content: Content
    let footer: Footer

    public init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Parent, @ViewBuilder footer: () -> Footer) {
        self.header = header()
        self.content = content()
        self.footer = footer()
    }

    public func _makeNodes(_ context: BuildContext) -> [LayoutNode] {
        let ctx = context.child("Section")
        var textCtx = ctx
        textCtx.environment.isInList = false
        textCtx.environment.foregroundColor = textCtx.environment.foregroundColor ?? .secondary
        textCtx.environment.font = textCtx.environment.font ?? .footnote
        var headerCtx = textCtx.child("header")
        headerCtx.environment.font = context.environment.font ?? ListMetrics.headerFont
        headerCtx.environment.textCase = headerCtx.environment.textCase ?? ListMetrics.headerTextCase
        let headerNodes = LSimUI._makeNodes(header, headerCtx)
        let footerNodes = LSimUI._makeNodes(footer, textCtx.child("footer"))
        let rows = LSimUI._makeNodes(content, ctx.child("content"))
        func single(_ nodes: [LayoutNode]) -> LayoutNode? {
            nodes.isEmpty ? nil : (nodes.count == 1 ? nodes[0] : StackNode(axis: .vertical, crossAlignment: 0, spacing: nil, children: nodes))
        }
        return [SectionNode(header: single(headerNodes), rows: rows, footer: single(footerNodes))]
    }
}

extension Section where Parent == EmptyView, Footer == EmptyView {
    public init(@ViewBuilder content: () -> Content) {
        self.init(content: content, header: { EmptyView() }, footer: { EmptyView() })
    }
}

extension Section where Footer == EmptyView {
    public init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Parent) {
        self.init(content: content, header: header, footer: { EmptyView() })
    }
}

extension Section where Parent == Text, Footer == EmptyView {
    public init<S: StringProtocol>(_ title: S, @ViewBuilder content: () -> Content) {
        self.init(content: content, header: { Text(title) }, footer: { EmptyView() })
    }
}

extension Section where Parent == EmptyView {
    public init(@ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.init(content: content, header: { EmptyView() }, footer: footer)
    }
}
