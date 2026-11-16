import Foundation

public enum NavigationBarItem {
    public enum TitleDisplayMode: Sendable {
        case automatic, inline, large
    }
}

/// Mesures de la barre de navigation, relevées sur iPhone 17 Pro Max sous iOS 27.2.
public enum NavigationMetrics {
    public static var barHeight: CGFloat = 44
    /// Centre vertical du contenu de la barre (titre centré, bouton retour), depuis le haut de la barre.
    public static var barContentCenterY: CGFloat = 17.5
    public static var largeTitleHeight: CGFloat = 52
    public static var largeTitleLeading: CGFloat = 20
    public static var largeTitleFont = Font.system(size: 34, weight: .bold)
    public static var inlineTitleFont = Font.system(size: 17, weight: .semibold)
    /// Bouton retour « ‹ Titre précédent ».
    public static var backChevronRect = CGRect(x: 14.2, y: -8.85, width: 9.7, height: 17.7)
    public static var backChevronLineWidth: CGFloat = 3
    public static var backTitleX: CGFloat = 36
    public static var backTitleFont = Font.system(size: 17)
    /// Défilement à partir duquel le grand titre laisse place au titre centré.
    public static var collapseThreshold: CGFloat = 44

    // Liquid Glass (iOS 26+), mesuré sur iOS 27.2.
    public static var glassBarContentCenterY: CGFloat = 22
    public static var glassButtonSize: CGFloat = 44
    public static var glassButtonLeading: CGFloat = 20
    public static var glassChevronSize = CGSize(width: 10.1, height: 18.2)
    public static var glassChevronLineWidth: CGFloat = 2.4
    /// Le chevron n'est pas centré optiquement dans la pastille : décalé vers la gauche.
    public static var glassChevronOffsetX: CGFloat = -1.8
    public static var glassBarHeight: CGFloat = 54
    /// Rayon du flou de la matière de barre (écart-type, en points).
    public static var glassMaterialBlur: CGFloat = 5
    /// Le grand titre Liquid Glass est un peu plus bas sous la barre.
    public static var glassLargeTitleTopOffset: CGFloat = 2.7

    static var currentBarHeight: CGFloat {
        DesignStyle.current == .liquidGlass ? glassBarHeight : barHeight
    }

    static var contentCenterY: CGFloat {
        DesignStyle.current == .liquidGlass ? glassBarContentCenterY : barContentCenterY
    }
}

/// Pile de navigation persistante (une par NavigationStack).
public final class NavigationModel {
    enum Entry {
        case view(AnyView)
        case value(Any, ObjectIdentifier)
    }

    var path: [(id: Int, entry: Entry)] = []
    var destinations: [ObjectIdentifier: (Any) -> AnyView] = [:]
    /// Titre de chaque écran (0 = racine, sinon identifiant d'entrée), pour le libellé du bouton retour.
    var titles: [Int: String] = [:]
    private var nextID = 0
    weak var graph: ViewGraph?

    func push(_ entry: Entry) {
        nextID += 1
        path.append((nextID, entry))
        graph?.invalidate()
    }

    func pop() {
        guard !path.isEmpty else { return }
        path.removeLast()
        onPop?()
        graph?.invalidate()
    }

    /// Ajout sans nouveau rendu (pile initiale d'une NavigationStack liée).
    func pushSilently(_ entry: Entry) {
        nextID += 1
        path.append((nextID, entry))
    }

    var didSyncPath = false
    var onPop: (() -> Void)?
}

/// Informations remontées par l'écran affiché vers sa NavigationStack (titre, mode).
final class NavigationTitleSink {
    var title: String?
    var displayMode: NavigationBarItem.TitleDisplayMode = .automatic
    /// Éléments de barre d'outils déclarés par l'écran affiché.
    var toolbar: [(placement: ToolbarItemPlacement, node: LayoutNode)] = []
}

extension EnvironmentValues {
    var navigation: NavigationModel? {
        get { self[NavigationKey.self] }
        set { self[NavigationKey.self] = newValue }
    }
    var navigationTitleSink: NavigationTitleSink? {
        get { self[TitleSinkKey.self] }
        set { self[TitleSinkKey.self] = newValue }
    }
    var isInList: Bool {
        get { self[InListKey.self] }
        set { self[InListKey.self] = newValue }
    }
}

private struct NavigationKey: EnvironmentKey { static let defaultValue: NavigationModel? = nil }
private struct TitleSinkKey: EnvironmentKey { static let defaultValue: NavigationTitleSink? = nil }
private struct InListKey: EnvironmentKey { static let defaultValue = false }

// MARK: - NavigationPath

/// Pile de valeurs hétérogènes pour `NavigationStack(path:)`.
public struct NavigationPath {
    var elements: [(Any, ObjectIdentifier)] = []
    public init() {}
    public init<S: Sequence>(_ elements: S) where S.Element: Hashable {
        self.elements = elements.map { ($0, ObjectIdentifier(S.Element.self)) }
    }
    public var count: Int { elements.count }
    public var isEmpty: Bool { elements.isEmpty }
    public mutating func append<V: Hashable>(_ value: V) { elements.append((value, ObjectIdentifier(V.self))) }
    public mutating func removeLast(_ k: Int = 1) { elements.removeLast(k) }
}

// MARK: - NavigationStack

public struct NavigationStack<Root: View>: View, _PrimitiveView {
    public typealias Body = Never
    let root: Root
    /// Pile pilotée par le code (`NavigationStack(path: $path)`) : valeurs initiales et retour.
    let boundPath: (values: () -> [(Any, ObjectIdentifier)], pop: () -> Void)?

    public init(@ViewBuilder root: () -> Root) {
        self.root = root()
        boundPath = nil
    }

    public init<D: Hashable>(path: Binding<[D]>, @ViewBuilder root: () -> Root) {
        self.root = root()
        boundPath = (values: { path.wrappedValue.map { ($0, ObjectIdentifier(D.self)) } },
                     pop: { if !path.wrappedValue.isEmpty { path.wrappedValue.removeLast() } })
    }

    public init(path: Binding<NavigationPath>, @ViewBuilder root: () -> Root) {
        self.root = root()
        boundPath = (values: { path.wrappedValue.elements },
                     pop: { if !path.wrappedValue.isEmpty { path.wrappedValue.removeLast() } })
    }

    public func _makeNodes(_ context: BuildContext) -> [LayoutNode] {
        let ctx = context.child("NavigationStack")
        let model = context.graph.persistent(ctx.path + "#nav") { NavigationModel() }
        model.graph = context.graph

        let sink = NavigationTitleSink()
        var pageCtx = ctx
        pageCtx.environment.navigation = model
        pageCtx.environment.navigationTitleSink = sink

        // Pile liée : écrans initiaux (la racine est construite une fois pour déclarer ses destinations).
        if let boundPath {
            model.onPop = boundPath.pop
            if !model.didSyncPath {
                model.didSyncPath = true
                let values = boundPath.values()
                if !values.isEmpty {
                    var rootCtx = pageCtx
                    rootCtx.path = ctx.path + "/root"
                    rootCtx.environment.navigationTitleSink = NavigationTitleSink()
                    _ = LSimUI._makeNodes(root, rootCtx)
                    for value in values { model.pushSilently(.value(value.0, value.1)) }
                }
            }
        }

        // Seul l'écran du dessus est construit ; l'état des écrans masqués est conservé.
        let rootPath = ctx.path + "/root"
        var content: [LayoutNode]
        if let top = model.path.last {
            context.graph.retain(prefix: rootPath)
            for item in model.path.dropLast() { context.graph.retain(prefix: ctx.path + "/page\(item.id)") }
            let page = pageCtx.child("page\(top.id)")
            switch top.entry {
            case let .view(view):
                content = view._makeNodes(page)
            case let .value(value, type):
                content = model.destinations[type].map { $0(value)._makeNodes(page) } ?? []
            }
        } else {
            var rootCtx = pageCtx
            rootCtx.path = rootPath
            content = LSimUI._makeNodes(root, rootCtx)
        }

        let isRoot = model.path.isEmpty
        model.titles[model.path.last?.id ?? 0] = sink.title
        let previousID = model.path.count >= 2 ? model.path[model.path.count - 2].id : 0
        let backTitle = model.titles[previousID] ?? "Retour"
        let large = sink.displayMode == .large || (sink.displayMode == .automatic && isRoot)
        var titleNode: LayoutNode?
        if let title = sink.title, large {
            let text = TextNode(title, font: NavigationMetrics.largeTitleFont, color: .primary, alignment: .leading)
            titleNode = FrameNode(
                PaddingNode(text, insets: EdgeInsets(top: DesignStyle.current == .liquidGlass ? NavigationMetrics.glassLargeTitleTopOffset : 0, leading: NavigationMetrics.largeTitleLeading, bottom: 0, trailing: NavigationMetrics.largeTitleLeading)),
                width: .init(max: .infinity), height: .init(fixed: NavigationMetrics.largeTitleHeight), alignment: .topLeading
            )
        }

        let backID = ctx.path + "#back"
        if !isRoot { context.graph.registerAction(backID) { model.pop() } }

        let page: LayoutNode = content.count == 1
            ? content[0]
            : StackNode(axis: .vertical, crossAlignment: 0.5, spacing: nil, children: content)
        return [NavigationNode(
            page: page, title: sink.title, largeTitle: titleNode,
            backID: isRoot ? nil : backID, backTitle: backTitle, backPressed: context.graph.pressedID == backID,
            tint: context.environment.tint ?? .accentColor,
            leading: sink.toolbar.filter { $0.placement.side == .leading }.map { BarButtonNode($0.node) },
            trailing: sink.toolbar.filter { $0.placement.side == .trailing }.map { BarButtonNode($0.node) }
        )]
    }
}

/// Mise en page d'un écran de navigation : barre + contenu (+ grand titre).
final class NavigationNode: LayoutNode {
    let page: LayoutNode
    let title: String?
    let largeTitle: LayoutNode?
    let backID: String?
    let backTitle: String
    let backPressed: Bool
    let tint: Color

    private typealias M = NavigationMetrics

    let leading: [LayoutNode]
    let trailing: [LayoutNode]

    init(page: LayoutNode, title: String?, largeTitle: LayoutNode?, backID: String?, backTitle: String, backPressed: Bool, tint: Color,
         leading: [LayoutNode] = [], trailing: [LayoutNode] = []) {
        self.leading = leading
        self.trailing = trailing
        self.page = page
        self.title = title
        self.largeTitle = largeTitle
        self.backID = backID
        self.backTitle = backTitle
        self.backPressed = backPressed
        self.tint = tint
    }

    /// Le contenu défilant de l'écran, s'il y en a un (List, ScrollView).
    private var scroll: ScrollNode? {
        var node: LayoutNode? = page
        while let n = node {
            if let s = n as? ScrollNode { return s }
            node = (n as? SingleChildNode)?.child
        }
        return nil
    }

    override func computeSize(_ p: ProposedViewSize, _ lc: LayoutContext) -> CGSize {
        p.replacingUnspecifiedDimensions(by: CGSize(width: 375, height: 600))
    }

    override func render(in rect: CGRect, _ lc: LayoutContext, _ list: inout DisplayList) {
        let bar = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: M.currentBarHeight)
        var contentRect = CGRect(x: rect.minX, y: bar.maxY, width: rect.width, height: rect.height - bar.height)
        var showInlineTitle = largeTitle == nil
        // Grand titre (iOS 27, vérifié au doigt sur iPhone) : il défile net avec le contenu et passe sous
        // les boutons de barre, sans matière ; la matière et le titre centré n'apparaissent qu'une fois le
        // grand titre entièrement passé sous la barre.
        let collapseOffset = DesignStyle.current == .liquidGlass ? M.largeTitleHeight : M.collapseThreshold

        if let largeTitle {
            if let scroll {
                // Le grand titre défile avec le contenu, puis laisse place au titre centré.
                scroll.header = largeTitle
                showInlineTitle = scroll.offset >= collapseOffset
            } else {
                largeTitle.render(in: CGRect(x: rect.minX, y: bar.maxY, width: rect.width, height: M.largeTitleHeight), lc, &list)
                contentRect.origin.y += M.largeTitleHeight
                contentRect.size.height -= M.largeTitleHeight
            }
        }

        if let scroll {
            // Le contenu défilant occupe tout l'écran et passe sous la barre.
            scroll.topInset = bar.height
            page.render(in: rect, lc, &list)
        } else {
            let s = page.sizeThatFits(ProposedViewSize(contentRect.size), lc)
            page.render(in: Alignment.center.place(s, in: contentRect), lc, &list)
        }

        // Effet de bord quand le contenu passe sous la barre.
        if let scroll, scroll.offset > 0, largeTitle == nil || scroll.offset >= collapseOffset || DesignStyle.current != .liquidGlass {
            let top = CGRect(x: lc.screen.minX, y: lc.screen.minY, width: lc.screen.width, height: bar.maxY - lc.screen.minY)
            let dark = lc.colorScheme == .dark
            let measured = dark ? DesignProfile.current.navigation?.edgeDark : DesignProfile.current.navigation?.edgeLight
            if DesignStyle.current == .liquidGlass, let measured, let last = measured.y.last {
                // Mesuré sur iPhone, ligne par ligne (flou progressif, voile) ; recalé sur la base de la barre.
                let shift = bar.maxY - lc.screen.minY - CGFloat(measured.referenceBarBottom ?? Double(bar.maxY - lc.screen.minY))
                let zone = CGRect(x: lc.screen.minX, y: lc.screen.minY, width: lc.screen.width, height: CGFloat(last) + shift)
                list.append(.scrollEdge(zone, measured, shift: shift))
            } else if DesignStyle.current == .liquidGlass {
                // Mesuré sur iOS 27 : flou ≈ 5 pt, voile blanc ≈ 65 %, filet à la base de la barre.
                let tint = dark ? RGBA(0.07, 0.07, 0.08, 0.72) : RGBA(0.99, 0.99, 1.0, 0.68)
                list.append(.backdrop(top, blur: M.glassMaterialBlur, tint: tint))
                let line = CGRect(x: top.minX, y: top.maxY - 1.0 / 3.0, width: top.width, height: 1.0 / 3.0)
                list.append(.fill(.rectangle, line, dark ? RGBA(1, 1, 1, 0.15) : .rgb255(60, 60, 67, 0.12)))
            } else {
                list.append(.fade(top.insetBy(dx: 0, dy: 0).offsetBy(dx: 0, dy: 0), Color.systemGroupedBackground.resolve(in: lc.colorScheme)))
            }
        }

        let centerY = bar.minY + M.contentCenterY
        var backWidth: CGFloat = 0
        if backID != nil, DesignStyle.current == .liquidGlass {
            backWidth = M.glassButtonLeading + M.glassButtonSize
        } else if backID != nil {
            let titleSize = lc.measurer.measure(backTitle, font: M.backTitleFont, maxWidth: nil)
            backWidth = M.backTitleX + titleSize.width
        }

        if showInlineTitle, let title {
            let font = M.inlineTitleFont
            let maxWidth = rect.width - 2 * max(backWidth + 8, 60)
            let size = lc.measurer.measure(title, font: font, maxWidth: maxWidth)
            let r = CGRect(x: bar.midX - size.width / 2, y: centerY - size.height / 2, width: size.width, height: size.height)
            list.append(.text(title, font, r, Color.primary.resolve(in: lc.colorScheme), .center))
        }

        // Boutons de barre d'outils (pastilles de verre) : à droite, et à gauche après le bouton retour.
        var right = bar.maxX - M.glassButtonLeading
        for node in trailing.reversed() {
            let size = node.sizeThatFits(.unspecified, lc)
            right -= size.width
            node.render(in: CGRect(x: right, y: centerY - size.height / 2, width: size.width, height: size.height), lc, &list)
            right -= 8
        }
        var left = bar.minX + M.glassButtonLeading + (backID == nil ? 0 : M.glassButtonSize + 8)
        for node in leading {
            let size = node.sizeThatFits(.unspecified, lc)
            node.render(in: CGRect(x: left, y: centerY - size.height / 2, width: size.width, height: size.height), lc, &list)
            left += size.width + 8
        }

        if let backID, DesignStyle.current == .liquidGlass {
            // Bouton retour Liquid Glass : chevron dans une pastille de verre.
            let d = M.glassButtonSize
            let button = CGRect(x: bar.minX + M.glassButtonLeading, y: centerY - d / 2, width: d, height: d)
            let dark = lc.colorScheme == .dark
            if backPressed { list.append(.pushOpacity(0.6)) }
            _ = dark
            list.append(.glass(.circle, button, Glass.regular.render(lc.colorScheme)))
            let c = M.glassChevronSize, w = M.glassChevronLineWidth
            let chevron = CGRect(x: button.midX - c.width / 2 + w / 2 + M.glassChevronOffsetX, y: button.midY - c.height / 2 + w / 2, width: c.width - w, height: c.height - w)
            list.append(.chevron(chevron, Color.primary.resolve(in: lc.colorScheme), lineWidth: w, pointingLeft: true))
            if backPressed { list.append(.popOpacity) }
            list.append(.hitRegion(id: backID, button))
        } else if let backID {
            // Bouton retour : chevron + titre de l'écran précédent, dans la teinte de l'app.
            let color = tint.resolve(in: lc.colorScheme)
            if backPressed { list.append(.pushOpacity(0.25)) }
            let c = M.backChevronRect
            let w = M.backChevronLineWidth
            let chevron = CGRect(x: bar.minX + c.minX + w / 2, y: centerY + c.minY + w / 2, width: c.width - w, height: c.height - w)
            list.append(.chevron(chevron, color, lineWidth: w, pointingLeft: true))
            let titleSize = lc.measurer.measure(backTitle, font: M.backTitleFont, maxWidth: nil)
            let titleRect = CGRect(x: bar.minX + M.backTitleX, y: centerY - titleSize.height / 2, width: titleSize.width, height: titleSize.height)
            list.append(.text(backTitle, M.backTitleFont, titleRect, color, .leading))
            if backPressed { list.append(.popOpacity) }
            list.append(.hitRegion(id: backID, CGRect(x: bar.minX, y: bar.minY, width: backWidth + 8, height: bar.height)))
        }
    }
}

// MARK: - Liens et titres

public struct NavigationLink<Label: View, Destination: View>: View, _PrimitiveView {
    public typealias Body = Never
    let label: Label
    let destination: Destination?
    let value: (Any, ObjectIdentifier)?

    public init(@ViewBuilder destination: () -> Destination, @ViewBuilder label: () -> Label) {
        self.label = label()
        self.destination = destination()
        self.value = nil
    }

    public func _makeNodes(_ context: BuildContext) -> [LayoutNode] {
        let id = context.path + "/NavigationLink"
        let model = context.environment.navigation
        if let model {
            if let destination {
                context.graph.registerAction(id) { model.push(.view(AnyView(destination))) }
            } else if let value {
                context.graph.registerAction(id) { model.push(.value(value.0, value.1)) }
            }
        }
        var labelCtx = context.child("label")
        if context.environment.isInList {
            labelCtx.environment.isInList = false
            let nodes = LSimUI._makeNodes(label, labelCtx)
            return [RowActionNode(Self.group(nodes), id: id, isLink: true)]
        }
        labelCtx.environment.foregroundColor = context.environment.foregroundColor ?? context.environment.tint ?? .accentColor
        let nodes = LSimUI._makeNodes(label, labelCtx)
        return [TapNode(Self.group(nodes), id: id, isPressed: context.graph.pressedID == id, pressedOpacity: 0.25)]
    }

    static func group(_ nodes: [LayoutNode]) -> LayoutNode {
        nodes.count == 1 ? nodes[0] : StackNode(axis: .horizontal, crossAlignment: 0.5, spacing: nil, children: nodes)
    }
}

extension NavigationLink where Label == Text {
    public init<S: StringProtocol>(_ title: S, @ViewBuilder destination: () -> Destination) {
        self.init(destination: destination) { Text(title) }
    }
}

extension NavigationLink where Destination == Never {
    public init<P: Hashable>(value: P?, @ViewBuilder label: () -> Label) {
        self.label = label()
        self.destination = nil
        self.value = value.map { ($0, ObjectIdentifier(P.self)) }
    }
}

extension NavigationLink where Destination == Never, Label == Text {
    public init<S: StringProtocol, P: Hashable>(_ title: S, value: P?) {
        self.init(value: value) { Text(title) }
    }
}

struct _NavigationTitleModifier: _PrimitiveModifier {
    let title: String?
    let mode: NavigationBarItem.TitleDisplayMode?
    func _apply(_ context: BuildContext, _ content: (BuildContext) -> [LayoutNode]) -> [LayoutNode] {
        if let sink = context.environment.navigationTitleSink {
            if let title { sink.title = title }
            if let mode { sink.displayMode = mode }
        }
        return content(context)
    }
}

struct _NavigationDestinationModifier: _PrimitiveModifier {
    let type: ObjectIdentifier
    let make: (Any) -> AnyView
    func _apply(_ context: BuildContext, _ content: (BuildContext) -> [LayoutNode]) -> [LayoutNode] {
        context.environment.navigation?.destinations[type] = make
        return content(context)
    }
}

extension View {
    public func navigationTitle<S: StringProtocol>(_ title: S) -> some View {
        modifier(_NavigationTitleModifier(title: String(title), mode: nil))
    }

    public func navigationBarTitleDisplayMode(_ mode: NavigationBarItem.TitleDisplayMode) -> some View {
        modifier(_NavigationTitleModifier(title: nil, mode: mode))
    }

    public func navigationDestination<D: Hashable, C: View>(for data: D.Type, @ViewBuilder destination: @escaping (D) -> C) -> some View {
        modifier(_NavigationDestinationModifier(type: ObjectIdentifier(D.self)) { value in
            AnyView(destination(value as! D))
        })
    }
}
