import Foundation

// MARK: - Form

/// Formulaire : sur iPhone, c'est une liste groupée avec marges.
public struct Form<Content: View>: View, _PrimitiveView {
    public typealias Body = Never
    let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public func _makeNodes(_ context: BuildContext) -> [LayoutNode] {
        let content = self.content
        return List { content }._makeNodes(context.child("Form"))
    }
}

// MARK: - Piles « paresseuses » (rendues comme des piles ordinaires)

public struct PinnedScrollableViews: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let sectionHeaders = PinnedScrollableViews(rawValue: 1)
    public static let sectionFooters = PinnedScrollableViews(rawValue: 2)
}

public struct LazyVStack<Content: View>: View, _PrimitiveView {
    public typealias Body = Never
    let stack: VStack<Content>
    public init(alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil, pinnedViews: PinnedScrollableViews = [],
                @ViewBuilder content: () -> Content) {
        stack = VStack(alignment: alignment, spacing: spacing, content: content)
    }
    public func _makeNodes(_ context: BuildContext) -> [LayoutNode] { stack._makeNodes(context) }
}

public struct LazyHStack<Content: View>: View, _PrimitiveView {
    public typealias Body = Never
    let stack: HStack<Content>
    public init(alignment: VerticalAlignment = .center, spacing: CGFloat? = nil, pinnedViews: PinnedScrollableViews = [],
                @ViewBuilder content: () -> Content) {
        stack = HStack(alignment: alignment, spacing: spacing, content: content)
    }
    public func _makeNodes(_ context: BuildContext) -> [LayoutNode] { stack._makeNodes(context) }
}

// MARK: - Grilles

public struct GridItem: Sendable {
    public enum Size: Sendable {
        case fixed(CGFloat)
        case flexible(minimum: CGFloat = 10, maximum: CGFloat = .infinity)
        case adaptive(minimum: CGFloat, maximum: CGFloat = .infinity)
    }
    public var size: Size
    public var spacing: CGFloat?
    public var alignment: Alignment?
    public init(_ size: Size = .flexible(), spacing: CGFloat? = nil, alignment: Alignment? = nil) {
        self.size = size
        self.spacing = spacing
        self.alignment = alignment
    }
}

public struct LazyVGrid<Content: View>: View, _PrimitiveView {
    public typealias Body = Never
    let columns: [GridItem]
    let spacing: CGFloat?
    let content: Content
    public init(columns: [GridItem], alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil,
                pinnedViews: PinnedScrollableViews = [], @ViewBuilder content: () -> Content) {
        self.columns = columns
        self.spacing = spacing
        self.content = content()
    }
    public func _makeNodes(_ context: BuildContext) -> [LayoutNode] {
        [GridNode(axis: .vertical, tracks: columns, lineSpacing: spacing, children: LSimUI._makeNodes(content, context.child("LazyVGrid")))]
    }
}

public struct LazyHGrid<Content: View>: View, _PrimitiveView {
    public typealias Body = Never
    let rows: [GridItem]
    let spacing: CGFloat?
    let content: Content
    public init(rows: [GridItem], alignment: VerticalAlignment = .center, spacing: CGFloat? = nil,
                pinnedViews: PinnedScrollableViews = [], @ViewBuilder content: () -> Content) {
        self.rows = rows
        self.spacing = spacing
        self.content = content()
    }
    public func _makeNodes(_ context: BuildContext) -> [LayoutNode] {
        [GridNode(axis: .horizontal, tracks: rows, lineSpacing: spacing, children: LSimUI._makeNodes(content, context.child("LazyHGrid")))]
    }
}

/// Grille : `axis` = sens de défilement (vertical : colonnes définies, lignes ajoutées au besoin).
final class GridNode: LayoutNode {
    let axis: Axis
    let tracks: [GridItem]
    let lineSpacing: CGFloat?
    let children: [LayoutNode]
    static let defaultSpacing: CGFloat = 8

    init(axis: Axis, tracks: [GridItem], lineSpacing: CGFloat?, children: [LayoutNode]) {
        self.axis = axis
        self.tracks = tracks
        self.lineSpacing = lineSpacing
        self.children = children
    }

    /// Tailles des pistes (colonnes en grille verticale) pour l'étendue disponible.
    private func trackSizes(_ available: CGFloat) -> [(size: CGFloat, spacing: CGFloat)] {
        var expanded: [(GridItem.Size, CGFloat)] = []
        let fixedTotal = tracks.reduce(CGFloat(0)) { acc, t in
            if case let .fixed(w) = t.size { return acc + w + (t.spacing ?? Self.defaultSpacing) }
            return acc
        }
        for t in tracks {
            let spacing = t.spacing ?? Self.defaultSpacing
            if case let .adaptive(minimum, maximum) = t.size {
                let room = max(0, available - fixedTotal)
                let count = max(1, Int((room + spacing) / (minimum + spacing)))
                for _ in 0..<count { expanded.append((.flexible(minimum: minimum, maximum: maximum), spacing)) }
            } else {
                expanded.append((t.size, spacing))
            }
        }
        let spacingTotal = expanded.dropLast().reduce(CGFloat(0)) { $0 + $1.1 }
        var remaining = available - spacingTotal
        var flexibleCount = 0
        for (size, _) in expanded {
            if case let .fixed(w) = size { remaining -= w } else { flexibleCount += 1 }
        }
        let share = flexibleCount > 0 ? max(0, remaining) / CGFloat(flexibleCount) : 0
        return expanded.map { size, spacing in
            switch size {
            case let .fixed(w): return (w, spacing)
            case let .flexible(minimum, maximum), let .adaptive(minimum, maximum): return (min(max(share, minimum), maximum), spacing)
            }
        }
    }

    private func layout(_ cross: CGFloat, _ lc: LayoutContext) -> (sizes: [(size: CGFloat, spacing: CGFloat)], lines: [CGFloat]) {
        let sizes = trackSizes(cross)
        let n = max(sizes.count, 1)
        var lines: [CGFloat] = []
        for start in stride(from: 0, to: children.count, by: n) {
            var line: CGFloat = 0
            for (k, child) in children[start..<min(start + n, children.count)].enumerated() {
                let s = child.sizeThatFits(ProposedViewSize(along: nil, cross: sizes[k].size, axis: axis), lc)
                line = max(line, s[axis])
            }
            lines.append(line)
        }
        return (sizes, lines)
    }

    override func computeSize(_ p: ProposedViewSize, _ lc: LayoutContext) -> CGSize {
        let cross = p[axis.other].flatMap { $0.isFinite ? $0 : nil } ?? 300
        let (sizes, lines) = layout(cross, lc)
        let crossUsed = sizes.reduce(CGFloat(0)) { $0 + $1.size } + sizes.dropLast().reduce(CGFloat(0)) { $0 + $1.spacing }
        let along = lines.reduce(0, +) + CGFloat(max(0, lines.count - 1)) * (lineSpacing ?? Self.defaultSpacing)
        return CGSize(along: along, cross: min(cross, crossUsed), axis: axis)
    }

    override func render(in rect: CGRect, _ lc: LayoutContext, _ list: inout DisplayList) {
        let cross = rect.size[axis.other]
        let (sizes, lines) = layout(cross, lc)
        let n = max(sizes.count, 1)
        var along = axis == .vertical ? rect.minY : rect.minX
        for (row, line) in lines.enumerated() {
            var c = axis == .vertical ? rect.minX : rect.minY
            for k in 0..<n {
                let index = row * n + k
                guard index < children.count else { break }
                let cell = CGRect(origin: CGPoint(along: along, cross: c, axis: axis), size: CGSize(along: line, cross: sizes[k].size, axis: axis))
                let s = children[index].sizeThatFits(ProposedViewSize(cell.size), lc)
                children[index].render(in: Alignment.center.place(s, in: cell), lc, &list)
                c += sizes[k].size + sizes[k].spacing
            }
            along += line + (lineSpacing ?? Self.defaultSpacing)
        }
    }
}

// MARK: - GeometryReader

public enum CoordinateSpace: Hashable, Sendable {
    case global, local
    case named(String)
}

public struct GeometryProxy: Sendable {
    public let size: CGSize
    let origin: CGPoint
    public var safeAreaInsets: EdgeInsets { EdgeInsets() }
    public func frame(in space: CoordinateSpace) -> CGRect {
        space == .local ? CGRect(origin: .zero, size: size) : CGRect(origin: origin, size: size)
    }
}

/// Le contenu dépend de la taille finale : il est construit avec la taille de la passe précédente,
/// et une nouvelle passe est demandée si la taille a changé.
public struct GeometryReader<Content: View>: View, _PrimitiveView {
    public typealias Body = Never
    let content: (GeometryProxy) -> Content

    public init(@ViewBuilder content: @escaping (GeometryProxy) -> Content) { self.content = content }

    public func _makeNodes(_ context: BuildContext) -> [LayoutNode] {
        let key = context.path + "/GeometryReader"
        let frame = context.graph.geometryFrames[key] ?? .zero
        let proxy = GeometryProxy(size: frame.size, origin: frame.origin)
        let nodes = LSimUI._makeNodes(content(proxy), context.child("GeometryReader"))
        return [GeometryNode(children: nodes, key: key, graph: context.graph)]
    }
}

final class GeometryNode: LayoutNode {
    let children: [LayoutNode]
    let key: String
    let graph: ViewGraph

    init(children: [LayoutNode], key: String, graph: ViewGraph) {
        self.children = children
        self.key = key
        self.graph = graph
    }

    override func computeSize(_ p: ProposedViewSize, _ lc: LayoutContext) -> CGSize {
        p.replacingUnspecifiedDimensions()
    }

    override func render(in rect: CGRect, _ lc: LayoutContext, _ list: inout DisplayList) {
        if graph.geometryFrames[key] != rect {
            graph.geometryFrames[key] = rect
            graph.invalidate()
        }
        for child in children {
            let s = child.sizeThatFits(ProposedViewSize(rect.size), lc)
            child.render(in: CGRect(origin: rect.origin, size: s), lc, &list)
        }
    }
}

// MARK: - TabView

/// Onglets déclarés dans une TabView (collectés pendant la construction).
final class TabCollector {
    struct Item {
        let title: String
        let systemImage: String?
        let value: AnyHashable?
        let build: (BuildContext) -> [LayoutNode]
    }
    var items: [Item] = []
}

private struct TabCollectorKey: EnvironmentKey { static let defaultValue: TabCollector? = nil }

extension EnvironmentValues {
    var tabCollector: TabCollector? {
        get { self[TabCollectorKey.self] }
        set { self[TabCollectorKey.self] = newValue }
    }
}

/// `Tab("Titre", systemImage: "…") { contenu }` (iOS 18+).
public struct Tab<Value: Hashable, Content: View>: View, _PrimitiveView {
    public typealias Body = Never
    let title: String
    let systemImage: String?
    let value: Value?
    let content: Content

    public func _makeNodes(_ context: BuildContext) -> [LayoutNode] {
        let content = self.content
        context.environment.tabCollector?.items.append(.init(
            title: title, systemImage: systemImage, value: value.map { AnyHashable($0) },
            build: { LSimUI._makeNodes(content, $0) }))
        return []
    }
}

extension Tab where Value == Never {
    public init<S: StringProtocol>(_ title: S, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = String(title)
        self.systemImage = systemImage
        self.value = nil
        self.content = content()
    }

    public init<S: StringProtocol>(_ title: S, image: String, @ViewBuilder content: () -> Content) {
        self.init(title, systemImage: image, content: content)
    }
}

extension Tab {
    public init<S: StringProtocol>(_ title: S, systemImage: String, value: Value, @ViewBuilder content: () -> Content) {
        self.title = String(title)
        self.systemImage = systemImage
        self.value = value
        self.content = content()
    }
}

extension Tab where Value == Never, Content == EmptyView {
    public init<S: StringProtocol>(_ title: S, systemImage: String, role: TabRole?, @ViewBuilder content: () -> Content) {
        self.init(title, systemImage: systemImage, content: content)
    }
}

public struct TabRole: Hashable, Sendable { public static let search = TabRole() }

/// `.tabItem { Label(…) }` (ancienne API) : déclare la vue comme un onglet.
struct _TabItemModifier<L: View>: _PrimitiveModifier {
    let label: L
    func _apply(_ context: BuildContext, _ content: (BuildContext) -> [LayoutNode]) -> [LayoutNode] {
        guard let collector = context.environment.tabCollector else { return content(context) }
        var labelCtx = context.child("tabItem")
        labelCtx.environment.tabCollector = nil
        let labelNodes = LSimUI._makeNodes(label, labelCtx)
        let title = labelNodes.lazy.compactMap(firstText(in:)).first ?? ""
        let symbol = labelNodes.lazy.compactMap(firstSymbol(in:)).first
        // Le contenu est reconstruit par la TabView quand l'onglet est affiché.
        var buildCtx = context
        buildCtx.environment.tabCollector = nil
        let nodes = content(buildCtx)
        collector.items.append(.init(title: title, systemImage: symbol, value: tagValue(nodes), build: { _ in nodes }))
        return []
    }

    func tagValue(_ nodes: [LayoutNode]) -> AnyHashable? {
        for node in nodes {
            var n: LayoutNode? = node
            while let current = n {
                if let tag = current as? TagNode { return tag.tag }
                n = (current as? SingleChildNode)?.child
            }
        }
        return nil
    }
}

func firstSymbol(in node: LayoutNode) -> String? {
    if let s = node as? SymbolNode { return s.name }
    if let s = node as? SingleChildNode { return firstSymbol(in: s.child) }
    if let s = node as? StackNode { return s.children.lazy.compactMap(firstSymbol(in:)).first }
    return nil
}

extension View {
    public func tabItem<V: View>(@ViewBuilder _ label: () -> V) -> some View {
        modifier(_TabItemModifier(label: label()))
    }
    public func badge(_ count: Int) -> some View { self }
    public func badge<S: StringProtocol>(_ label: S?) -> some View { self }
}

public struct TabView<SelectionValue: Hashable, Content: View>: View, _PrimitiveView {
    public typealias Body = Never
    let selection: Binding<SelectionValue>?
    let content: Content

    public init(selection: Binding<SelectionValue>?, @ViewBuilder content: () -> Content) {
        self.selection = selection
        self.content = content()
    }

    public func _makeNodes(_ context: BuildContext) -> [LayoutNode] {
        let ctx = context.child("TabView")
        let collector = TabCollector()
        var collectCtx = ctx
        collectCtx.environment.tabCollector = collector
        _ = LSimUI._makeNodes(content, collectCtx)
        let items = collector.items
        guard !items.isEmpty else { return [] }

        // Onglet sélectionné : par la liaison si fournie (valeur ou .tag), sinon état interne.
        let indexBox = context.graph.persistent(ctx.path + "#tab") { TabIndexBox() }
        var selected = min(indexBox.index, items.count - 1)
        if let selection {
            let current = AnyHashable(selection.wrappedValue)
            if let i = items.firstIndex(where: { $0.value == current }) { selected = i }
        }
        let graph = context.graph
        var ids: [String] = []
        for (i, item) in items.enumerated() {
            let id = ctx.path + "#tab\(i)"
            ids.append(id)
            let selection = self.selection
            graph.registerAction(id) {
                indexBox.index = i
                if let selection, let value = item.value?.base as? SelectionValue { selection.wrappedValue = value }
                graph.invalidate()
            }
        }
        for i in items.indices where i != selected { graph.retain(prefix: ctx.path + "/tab\(i)") }
        let page = group(items[selected].build(ctx.child("tab\(selected)")), axis: .vertical)
        return [TabBarNode(page: page, items: items.map { ($0.title, $0.systemImage) }, ids: ids, selected: selected,
                           tint: context.environment.tint ?? .accentColor, pressed: graph.pressedID)]
    }
}

final class TabIndexBox { var index = 0 }

extension TabView where SelectionValue == Int {
    public init(@ViewBuilder content: () -> Content) {
        self.selection = nil
        self.content = content()
    }
}

/// Mesures de la barre d'onglets iOS 26 (estimations à calibrer).
public enum TabBarMetrics {
    public static var height: CGFloat = 62
    public static var bottomMargin: CGFloat = 21
    public static var sideMargin: CGFloat = 21
    public static var itemWidth: CGFloat = 94
    public static var iconSize: CGFloat = 24
    public static var labelFont = Font.system(size: 10, weight: .medium)
}

/// Contenu plein écran + barre d'onglets flottante en verre.
final class TabBarNode: LayoutNode {
    let page: LayoutNode
    let items: [(title: String, symbol: String?)]
    let ids: [String]
    let selected: Int
    let tint: Color
    let pressed: String?
    private typealias M = TabBarMetrics

    init(page: LayoutNode, items: [(title: String, symbol: String?)], ids: [String], selected: Int, tint: Color, pressed: String?) {
        self.page = page
        self.items = items
        self.ids = ids
        self.selected = selected
        self.tint = tint
        self.pressed = pressed
    }

    override func computeSize(_ p: ProposedViewSize, _ lc: LayoutContext) -> CGSize {
        p.replacingUnspecifiedDimensions(by: CGSize(width: 375, height: 600))
    }

    override func render(in rect: CGRect, _ lc: LayoutContext, _ list: inout DisplayList) {
        let s = page.sizeThatFits(ProposedViewSize(rect.size), lc)
        page.render(in: s.width >= rect.width - 0.5 && s.height >= rect.height - 0.5 ? rect : Alignment.center.place(s, in: rect), lc, &list)

        let screen = lc.screen == .zero ? rect : lc.screen
        let width = min(screen.width - 2 * M.sideMargin, M.itemWidth * CGFloat(items.count) + 8)
        let bar = CGRect(x: screen.midX - width / 2, y: screen.maxY - M.bottomMargin - M.height, width: width, height: M.height)
        let dark = lc.colorScheme == .dark
        // Barre en vrai verre : le contenu qui passe dessous est réfracté.
        list.append(.glass(.capsule, bar, Glass.regular.render(lc.colorScheme)))

        let itemWidth = (bar.width - 8) / CGFloat(max(items.count, 1))
        for (i, item) in items.enumerated() {
            let cell = CGRect(x: bar.minX + 4 + CGFloat(i) * itemWidth, y: bar.minY + 4, width: itemWidth, height: bar.height - 8)
            if i == selected {
                list.append(.fill(.capsule, cell, dark ? RGBA(1, 1, 1, 0.12) : RGBA(0, 0, 0, 0.06)))
            }
            let color = (i == selected ? tint : Color.primary).resolve(in: lc.colorScheme)
            if pressed == ids[i] { list.append(.pushOpacity(0.5)) }
            if let symbol = item.symbol {
                let iconFont = Font.system(size: 19, weight: .medium)
                let icon = CGRect(x: cell.midX - 14, y: cell.minY + 6, width: 28, height: M.iconSize)
                list.append(.symbol(symbol, iconFont, .medium, icon, color))
            }
            let label = lc.measurer.measure(item.title, font: M.labelFont, maxWidth: nil)
            list.append(.text(item.title, M.labelFont,
                              CGRect(x: cell.midX - label.width / 2, y: cell.maxY - 8 - label.height, width: label.width, height: label.height),
                              color, .center))
            if pressed == ids[i] { list.append(.popOpacity) }
            list.append(.hitRegion(id: ids[i], cell))
        }
    }
}
