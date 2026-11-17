import Foundation

public enum NavigationBarItem {
    public enum TitleDisplayMode: Sendable {
        case automatic, inline, large
    }
}

/// Navigation bar metrics, measured on iPhone 17 Pro Max (iOS 27.2).
public enum NavigationMetrics {
    public static var barHeight: CGFloat = 44
    /// Vertical center of the bar content (inline title, back button), from the top of the bar.
    public static var barContentCenterY: CGFloat = 17.5
    public static var largeTitleHeight: CGFloat = 52
    public static var largeTitleLeading: CGFloat = 20
    public static var largeTitleFont = Font.system(size: 34, weight: .bold)
    public static var inlineTitleFont = Font.system(size: 17, weight: .semibold)
    /// Back button "‹ Previous title".
    public static var backChevronRect = CGRect(x: 14.2, y: -8.85, width: 9.7, height: 17.7)
    public static var backChevronLineWidth: CGFloat = 3
    public static var backTitleX: CGFloat = 36
    public static var backTitleFont = Font.system(size: 17)
    /// Scroll offset at which the large title gives way to the inline title.
    public static var collapseThreshold: CGFloat = 44

    // Liquid Glass (iOS 26+), measured on iOS 27.2.
    public static var glassBarContentCenterY: CGFloat = 22
    public static var glassButtonSize: CGFloat = 44
    public static var glassButtonLeading: CGFloat = 20
    /// Measured on iPhone: 11 × 18.7 pt ink (same ink area).
    public static var glassChevronSize = CGSize(width: 11.0, height: 18.7)
    public static var glassChevronLineWidth: CGFloat = 2.6
    /// The chevron is not optically centered in the pill: shifted left.
    public static var glassChevronOffsetX: CGFloat = -1.5
    public static var glassBarHeight: CGFloat = 54
    /// Bar material blur radius (std dev, points).
    public static var glassMaterialBlur: CGFloat = 5
    /// The Liquid Glass large title sits slightly lower under the bar.
    public static var glassLargeTitleTopOffset: CGFloat = 2.7

    /// Stack transitions measured on iPhone (iOS 27.2).
    public static var pushAnimation = Animation.spring(response: 0.25, dampingFraction: 1.06)
    public static var popAnimation = Animation.spring(response: 0.21, dampingFraction: 1.24)
    /// How far the screen underneath recedes (fraction of the width).
    public static var parallax: CGFloat = 0.3

    static var currentBarHeight: CGFloat {
        DesignStyle.current == .liquidGlass ? glassBarHeight : barHeight
    }

    static var contentCenterY: CGFloat {
        DesignStyle.current == .liquidGlass ? glassBarContentCenterY : barContentCenterY
    }
}

/// Persistent navigation stack (one per NavigationStack).
public final class NavigationModel {
    enum Entry {
        case view(AnyView)
        case value(Any, ObjectIdentifier)
    }

    var path: [(id: Int, entry: Entry)] = []
    var destinations: [ObjectIdentifier: (Any) -> AnyView] = [:]
    /// Title of each screen (0 = root, else entry id), for the back button label.
    var titles: [Int: String] = [:]
    private var nextID = 0
    weak var graph: ViewGraph?

    func push(_ entry: Entry) {
        let outgoing = path.last
        nextID += 1
        path.append((nextID, entry))
        beginTransition(push: true, outgoing: outgoing)
        graph?.invalidate()
    }

    func pop() {
        guard !path.isEmpty else { return }
        let popped = path.removeLast()
        beginTransition(push: false, outgoing: popped)
        onPop?()
        graph?.invalidate()
    }

    /// A screen in a transition: the root or a stack entry.
    typealias Screen = (id: Int, entry: Entry)?

    /// Transition between the top screen and the one below (both built until it ends). The top screen's
    /// presence goes from `from` to `to` (1: in place, 0: gone to the right) on a spring starting at
    /// `velocity` (presence per second).
    struct Transition {
        var top: Screen
        var bottom: Screen
        var from: Double
        var to: Double
        var velocity: Double
        var start: Double
        var animation: Animation

        func presence(at now: Double) -> (value: Double, done: Bool) {
            guard let r = animation.displacement(at: now - start, d0: from - to, v0: velocity) else { return (to, true) }
            return (to + r.d, false)
        }
    }
    var transition: Transition?
    /// Screen width (recorded at draw time), to convert the gesture to presence.
    var width: CGFloat = 440
    /// Swipe back in progress: presence of the top screen (follows the finger).
    var dragPresence: Double?

    func beginTransition(push: Bool, outgoing: (id: Int, entry: Entry)?) {
        let now = graph?.animator.clock() ?? 0
        if push {
            transition = Transition(top: path.last, bottom: outgoing, from: 0, to: 1, velocity: 0, start: now,
                                    animation: NavigationMetrics.pushAnimation)
        } else {
            transition = Transition(top: outgoing, bottom: path.last, from: 1, to: 0, velocity: 0, start: now,
                                    animation: NavigationMetrics.popAnimation)
        }
    }

    /// End of swipe: pop (screen removed) or cancel (screen restored), starting from the finger's position
    /// and velocity. Decided by projected position (position + 0.2 s of velocity).
    func endBackSwipe(translation: CGFloat, velocity: CGFloat, width: CGFloat) {
        guard let presence = dragPresence, !path.isEmpty else { dragPresence = nil; return }
        dragPresence = nil
        let now = graph?.animator.clock() ?? 0
        let v = -Double(velocity / max(width, 1))
        let rule = DesignProfile.current.gestures?.backSwipe ?? GestureRule(projection: 0.2, threshold: 0.5)
        let projected = (Double(translation) + rule.projection * Double(velocity)) / Double(max(width, 1))
        let below: Screen = path.count >= 2 ? path[path.count - 2] : nil
        if projected > rule.threshold {
            let popped = path.removeLast()
            transition = Transition(top: popped, bottom: below, from: presence, to: 0, velocity: v, start: now,
                                    animation: NavigationMetrics.popAnimation)
            onPop?()
        } else {
            transition = Transition(top: path.last, bottom: below, from: presence, to: 1, velocity: v, start: now,
                                    animation: NavigationMetrics.popAnimation)
        }
        graph?.invalidate()
    }

    /// Append without re-rendering (initial path of a bound NavigationStack).
    func pushSilently(_ entry: Entry) {
        nextID += 1
        path.append((nextID, entry))
    }

    var didSyncPath = false
    var onPop: (() -> Void)?
}

/// Info passed up from the visible screen to its NavigationStack (title, mode).
final class NavigationTitleSink {
    var title: String?
    var displayMode: NavigationBarItem.TitleDisplayMode = .automatic
    /// Toolbar items declared by the visible screen.
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

/// Heterogeneous value stack for `NavigationStack(path:)`.
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
    /// Programmatic stack (`NavigationStack(path: $path)`): initial values and pop.
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

        var pageCtx = ctx
        pageCtx.environment.navigation = model

        // Bound stack: initial screens (the root is built once to declare its destinations), then follow
        // binding changes (append: push; removal: pop), with a transition.
        if let boundPath {
            model.onPop = boundPath.pop
            let values = boundPath.values()
            if !model.didSyncPath {
                model.didSyncPath = true
                if !values.isEmpty {
                    var rootCtx = pageCtx
                    rootCtx.path = ctx.path + "/root"
                    rootCtx.environment.navigationTitleSink = NavigationTitleSink()
                    _ = LSimUI._makeNodes(root, rootCtx)
                    for value in values { model.pushSilently(.value(value.0, value.1)) }
                }
            } else if values.count > model.path.count {
                for value in values[model.path.count...] {
                    let outgoing = model.path.last
                    model.pushSilently(.value(value.0, value.1))
                    model.beginTransition(push: true, outgoing: outgoing)
                }
            } else if values.count < model.path.count {
                while model.path.count > values.count {
                    let popped = model.path.removeLast()
                    model.beginTransition(push: false, outgoing: popped)
                    model.dragPresence = nil
                }
            }
        }

        // Build the top screen (and the outgoing one during a transition); hidden screens keep their state.
        let rootPath = ctx.path + "/root"
        if !model.path.isEmpty {
            context.graph.retain(prefix: rootPath)
            for item in model.path.dropLast() { context.graph.retain(prefix: ctx.path + "/page\(item.id)") }
        }
        let backID = ctx.path + "#back"
        if !model.path.isEmpty { context.graph.registerAction(backID) { model.pop() } }

        func screen(_ item: (id: Int, entry: NavigationModel.Entry)?) -> NavigationNode {
            let sink = NavigationTitleSink()
            var screenCtx = pageCtx
            screenCtx.environment.navigationTitleSink = sink
            var content: [LayoutNode]
            if let item {
                let page = screenCtx.child("page\(item.id)")
                switch item.entry {
                case let .view(view):
                    content = view._makeNodes(page)
                case let .value(value, type):
                    content = model.destinations[type].map { $0(value)._makeNodes(page) } ?? []
                }
            } else {
                var rootCtx = screenCtx
                rootCtx.path = rootPath
                content = LSimUI._makeNodes(root, rootCtx)
            }
            let isRoot = item == nil
            model.titles[item?.id ?? 0] = sink.title
            // Previous screen: the one under the built screen (or the revealed one, for a screen just popped).
            let previousID: Int
            if let item, let index = model.path.firstIndex(where: { $0.id == item.id }) {
                previousID = index >= 1 ? model.path[index - 1].id : 0
            } else {
                previousID = model.path.last?.id ?? 0
            }
            let backTitle = model.titles[previousID] ?? "Back"
            let large = sink.displayMode == .large || (sink.displayMode == .automatic && isRoot)
            var titleNode: LayoutNode?
            if let title = sink.title, large {
                let text = TextNode(title, font: NavigationMetrics.largeTitleFont, color: .primary, alignment: .leading)
                titleNode = FrameNode(
                    PaddingNode(text, insets: EdgeInsets(top: DesignStyle.current == .liquidGlass ? NavigationMetrics.glassLargeTitleTopOffset : 0, leading: NavigationMetrics.largeTitleLeading, bottom: 0, trailing: NavigationMetrics.largeTitleLeading)),
                    width: .init(max: .infinity), height: .init(fixed: NavigationMetrics.largeTitleHeight), alignment: .topLeading
                )
            }
            let page: LayoutNode = content.count == 1
                ? content[0]
                : StackNode(axis: .vertical, crossAlignment: 0.5, spacing: nil, children: content)
            return NavigationNode(
                page: page, title: sink.title, largeTitle: titleNode,
                backID: isRoot ? nil : backID, backTitle: backTitle, backPressed: context.graph.pressedID == backID,
                tint: context.environment.tint ?? .accentColor,
                leading: sink.toolbar.filter { $0.placement.side == .leading }.map { BarButtonNode($0.node) },
                trailing: sink.toolbar.filter { $0.placement.side == .trailing }.map { BarButtonNode($0.node) }
            )
        }

        // Swipe back (iOS 26: from anywhere in the content): the top screen follows the finger.
        let panID = ctx.path + "#backSwipe"
        if !model.path.isEmpty {
            context.graph.registerPan(panID, changed: { translation in
                model.transition = nil
                model.dragPresence = Double(max(0, min(1, 1 - translation.width / max(model.width, 1))))
                model.graph?.invalidate()
            }, ended: { translation, velocity in
                model.endBackSwipe(translation: max(0, translation.width), velocity: velocity.width, width: model.width)
            })
        }

        if let presence = model.dragPresence, !model.path.isEmpty {
            let below: NavigationModel.Screen = model.path.count >= 2 ? model.path[model.path.count - 2] : nil
            return [NavigationTransitionNode(top: screen(model.path.last), bottom: screen(below),
                                             presence: presence, animating: false)]
        }
        if let transition = model.transition {
            let state = transition.presence(at: context.graph.animator.clock())
            if state.done {
                model.transition = nil
            } else {
                let top = screen(transition.top)
                // Top screen that stays (push, cancel): swipe back remains possible.
                if transition.to == 1, !model.path.isEmpty {
                    top.backPanID = panID
                    top.model = model
                }
                return [NavigationTransitionNode(top: top, bottom: screen(transition.bottom),
                                                 presence: state.value, animating: true, target: transition.to)]
            }
        }
        let incoming = screen(model.path.last)
        incoming.backPanID = model.path.isEmpty ? nil : panID
        incoming.model = model
        return [incoming]
    }
}

/// Stack transition: the top screen is offset right by its presence (1: in place, 0: gone); the screen
/// below recedes by 30% of the width (parallax), bars cross-fade. Measured on iPhone: springs without
/// bounce, push response 0.25 / damping 1.06, pop 0.21 / 1.24.
final class NavigationTransitionNode: LayoutNode {
    let top: NavigationNode
    let bottom: NavigationNode
    let presence: Double
    let animating: Bool
    /// Target presence (1: top screen stays, 0: it leaves); without an animator only the final screen is drawn.
    let target: Double

    init(top: NavigationNode, bottom: NavigationNode, presence: Double, animating: Bool, target: Double = 1) {
        self.top = top
        self.bottom = bottom
        self.presence = presence
        self.animating = animating
        self.target = target
    }

    override func computeSize(_ p: ProposedViewSize, _ lc: LayoutContext) -> CGSize {
        p.replacingUnspecifiedDimensions(by: CGSize(width: 375, height: 600))
    }

    override func draw(in rect: CGRect, _ lc: LayoutContext, _ list: inout DisplayList) {
        guard lc.animator != nil else {
            (target >= 0.5 ? top : bottom).render(in: rect, lc, &list)
            return
        }
        if animating { lc.animator?.requestFrame() }
        let s = CGFloat(min(max(presence, -0.2), 1.2))
        let width = (lc.screen == .zero ? rect : lc.screen).width
        bottom.pageOffset = -NavigationMetrics.parallax * width * max(0, s)
        bottom.barAlpha = Double(min(1, max(0, 1 - s)))
        bottom.opaqueBackground = true
        top.pageOffset = width * (1 - s)
        top.barAlpha = Double(min(1, max(0, s)))
        top.opaqueBackground = true
        bottom.render(in: rect, lc, &list)
        top.render(in: rect, lc, &list)
    }
}

/// Navigation screen layout: bar + content (+ large title).
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
    /// During a transition: horizontal offset of the screen, bar opacity, opaque background.
    var pageOffset: CGFloat = 0
    var barAlpha: Double = 1
    var opaqueBackground = false
    /// Swipe-back area (top screen of a non-empty stack, outside transitions).
    var backPanID: String?
    weak var model: NavigationModel?

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

    /// The screen's scrolling content, if any (List, ScrollView).
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

    override func draw(in rect: CGRect, _ lc: LayoutContext, _ list: inout DisplayList) {
        let bar = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: M.currentBarHeight)
        var contentRect = CGRect(x: rect.minX, y: bar.maxY, width: rect.width, height: rect.height - bar.height)
        var showInlineTitle = largeTitle == nil
        // Large title (iOS 27, checked by finger on iPhone): scrolls crisply with the content and passes under
        // the bar buttons without material; the material and inline title only appear once the large title
        // is fully under the bar.
        let collapseOffset = DesignStyle.current == .liquidGlass ? M.largeTitleHeight : M.collapseThreshold

        // Transition: the screen (content and large title) is offset, over an opaque background.
        let moving = pageOffset != 0 || opaqueBackground
        if moving {
            list.append(.pushTransform(dx: pageOffset, dy: 0, scale: 1, anchor: .zero))
            if opaqueBackground {
                let screen = lc.screen == .zero ? rect : lc.screen
                list.append(.fill(.rectangle, screen, Color.systemBackground.resolve(in: lc.colorScheme)))
            }
        }

        if let largeTitle {
            if let scroll {
                // The large title scrolls with the content, then gives way to the inline title.
                scroll.header = largeTitle
                showInlineTitle = scroll.offset >= collapseOffset
            } else {
                largeTitle.render(in: CGRect(x: rect.minX, y: bar.maxY, width: rect.width, height: M.largeTitleHeight), lc, &list)
                contentRect.origin.y += M.largeTitleHeight
                contentRect.size.height -= M.largeTitleHeight
            }
        }

        if let scroll {
            // Scrolling content fills the screen and passes under the bar.
            scroll.topInset = bar.height
            page.render(in: rect, lc, &list)
        } else if page.ignoresSafeArea {
            // Full-screen background: extends under the bar and into the safe areas.
            let screen = lc.screen == .zero ? rect : lc.screen
            let s = page.sizeThatFits(ProposedViewSize(screen.size), lc)
            page.render(in: Alignment.center.place(s, in: screen), lc, &list)
        } else {
            let s = page.sizeThatFits(ProposedViewSize(contentRect.size), lc)
            page.render(in: Alignment.center.place(s, in: contentRect), lc, &list)
        }
        if moving { list.append(.popTransform) }
        // The bar (material, titles, buttons) stays in place and cross-fades.
        let fading = barAlpha < 0.999
        if fading { list.append(.pushOpacity(max(0, barAlpha))) }

        // Edge effect when content passes under the bar.
        if let scroll, scroll.offset > 0, largeTitle == nil || scroll.offset >= collapseOffset || DesignStyle.current != .liquidGlass {
            let top = CGRect(x: lc.screen.minX, y: lc.screen.minY, width: lc.screen.width, height: bar.maxY - lc.screen.minY)
            let dark = lc.colorScheme == .dark
            let measured = dark ? DesignProfile.current.navigation?.edgeDark : DesignProfile.current.navigation?.edgeLight
            if DesignStyle.current == .liquidGlass, let measured, let last = measured.y.last {
                // Measured on iPhone row by row (progressive blur, veil); aligned to the bar's bottom.
                let shift = bar.maxY - lc.screen.minY - CGFloat(measured.referenceBarBottom ?? Double(bar.maxY - lc.screen.minY))
                let zone = CGRect(x: lc.screen.minX, y: lc.screen.minY, width: lc.screen.width, height: CGFloat(last) + shift)
                list.append(.scrollEdge(zone, measured, shift: shift))
            } else if DesignStyle.current == .liquidGlass {
                // Measured on iOS 27: blur ≈ 5 pt, white veil ≈ 65%, hairline at the bar's bottom.
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

        // Toolbar buttons (glass pills): on the right, and on the left after the back button.
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
            // Liquid Glass back button: chevron in a glass pill.
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
            // Back button: chevron + previous screen's title, in the app tint.
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
        if fading { list.append(.popOpacity) }
        model?.width = (lc.screen == .zero ? rect : lc.screen).width
        if let backPanID {
            let screen = lc.screen == .zero ? rect : lc.screen
            list.append(.panRegion(id: backPanID, screen, vertical: false))
        }
    }
}

// MARK: - Links and titles

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
