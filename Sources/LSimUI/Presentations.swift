import Foundation

// Feuilles, alertes, barre d'outils. Gabarits iOS 26 estimés, à calibrer.

// MARK: - Barre d'outils

public struct ToolbarItemPlacement: Hashable, Sendable {
    enum Side: Hashable { case leading, trailing, principal, bottom }
    let side: Side
    public static let automatic = ToolbarItemPlacement(side: .trailing)
    public static let primaryAction = ToolbarItemPlacement(side: .trailing)
    public static let confirmationAction = ToolbarItemPlacement(side: .trailing)
    public static let cancellationAction = ToolbarItemPlacement(side: .leading)
    public static let destructiveAction = ToolbarItemPlacement(side: .trailing)
    public static let topBarLeading = ToolbarItemPlacement(side: .leading)
    public static let topBarTrailing = ToolbarItemPlacement(side: .trailing)
    public static let navigationBarLeading = ToolbarItemPlacement(side: .leading)
    public static let navigationBarTrailing = ToolbarItemPlacement(side: .trailing)
    public static let principal = ToolbarItemPlacement(side: .principal)
    public static let bottomBar = ToolbarItemPlacement(side: .bottom)
    public static let status = ToolbarItemPlacement(side: .bottom)
    public static let keyboard = ToolbarItemPlacement(side: .bottom)
}

/// Marqueur produit par ToolbarItem, rangé par la NavigationStack.
final class ToolbarItemNode: SingleChildNode {
    let placement: ToolbarItemPlacement
    init(_ child: LayoutNode, placement: ToolbarItemPlacement) {
        self.placement = placement
        super.init(child)
    }
}

public struct ToolbarItem<Content: View>: View, _PrimitiveView {
    public typealias Body = Never
    let placement: ToolbarItemPlacement
    let content: Content
    public init(placement: ToolbarItemPlacement = .automatic, @ViewBuilder content: () -> Content) {
        self.placement = placement
        self.content = content()
    }
    public init(id: String, placement: ToolbarItemPlacement = .automatic, @ViewBuilder content: () -> Content) {
        self.init(placement: placement, content: content)
    }
    public func _makeNodes(_ context: BuildContext) -> [LayoutNode] {
        LSimUI._makeNodes(content, context.child("ToolbarItem")).map { ToolbarItemNode($0, placement: placement) }
    }
}

public struct ToolbarItemGroup<Content: View>: View, _PrimitiveView {
    public typealias Body = Never
    let placement: ToolbarItemPlacement
    let content: Content
    public init(placement: ToolbarItemPlacement = .automatic, @ViewBuilder content: () -> Content) {
        self.placement = placement
        self.content = content()
    }
    public func _makeNodes(_ context: BuildContext) -> [LayoutNode] {
        LSimUI._makeNodes(content, context.child("ToolbarItemGroup")).map { ToolbarItemNode($0, placement: placement) }
    }
}

struct _ToolbarModifier<C: View>: _PrimitiveModifier {
    let content: C
    func _apply(_ context: BuildContext, _ body: (BuildContext) -> [LayoutNode]) -> [LayoutNode] {
        if let sink = context.environment.navigationTitleSink {
            var ctx = context.child("toolbar")
            // iOS 26 : boutons de barre monochromes, dans des pastilles de verre.
            ctx.environment.foregroundColor = ctx.environment.foregroundColor ?? .primary
            // Mesuré sur iPhone (iOS 27.2) : symboles de barre en échelle large
            // (« + » de 17,7 pt d’encre).
            ctx.environment.imageScale = .large
            ctx.environment.font = ctx.environment.font ?? .system(size: 17, weight: .regular)
            ctx.environment.isInList = false
            for node in LSimUI._makeNodes(content, ctx) {
                let item = node as? ToolbarItemNode
                sink.toolbar.append((item?.placement ?? .automatic, item?.child ?? node))
            }
        }
        return body(context)
    }
}

extension View {
    public func toolbar<C: View>(@ViewBuilder content: () -> C) -> some View {
        modifier(_ToolbarModifier(content: content()))
    }
    public func toolbarTitleDisplayMode(_ mode: NavigationBarItem.TitleDisplayMode) -> some View { navigationBarTitleDisplayMode(mode) }
    public func navigationBarBackButtonHidden(_ hidden: Bool = true) -> some View { self }
    public func toolbarBackground<S: ShapeStyle>(_ style: S, for bars: ToolbarPlacement...) -> some View { self }
    public func toolbarBackground(_ visibility: Visibility, for bars: ToolbarPlacement...) -> some View { self }
    public func toolbar(_ visibility: Visibility, for bars: ToolbarPlacement...) -> some View { self }
}

public enum Visibility: Hashable, Sendable { case automatic, visible, hidden }
public struct ToolbarPlacement: Hashable, Sendable {
    public static let navigationBar = ToolbarPlacement(), tabBar = ToolbarPlacement(), bottomBar = ToolbarPlacement(), automatic = ToolbarPlacement()
}

/// Bouton de barre iOS 26 : contenu au centre d'une pastille de verre (cercle de 44 pt, ou capsule pour du texte).
final class BarButtonNode: SingleChildNode {
    static let size: CGFloat = 44

    override func computeSize(_ p: ProposedViewSize, _ lc: LayoutContext) -> CGSize {
        let s = child.sizeThatFits(.unspecified, lc)
        // Un symbole tient dans un cercle de 44 pt (mesuré sur iPhone) ; un libellé élargit la capsule.
        return CGSize(width: max(Self.size, s.width + 20), height: Self.size)
    }

    override func draw(in rect: CGRect, _ lc: LayoutContext, _ list: inout DisplayList) {
        GlassShapeNode(.capsule, tint: nil, profile: DesignProfile.current.button).render(in: rect, lc, &list)
        let s = child.sizeThatFits(.unspecified, lc)
        child.render(in: Alignment.center.place(s, in: rect), lc, &list)
    }
}

// MARK: - Feuilles

public struct PresentationDetent: Hashable, Sendable {
    let fraction: CGFloat
    public static let medium = PresentationDetent(fraction: 0.5)
    public static let large = PresentationDetent(fraction: 1)
    public static func fraction(_ f: CGFloat) -> PresentationDetent { PresentationDetent(fraction: f) }
    public static func height(_ h: CGFloat) -> PresentationDetent { PresentationDetent(fraction: -h) }
}

/// Réglages d'une feuille, remplis par les modificateurs `presentation…` de son contenu.
final class SheetConfig {
    var detents: [PresentationDetent] = [.large]
}

private struct SheetConfigKey: EnvironmentKey { static let defaultValue: SheetConfig? = nil }
private struct PresentationDismissKey: EnvironmentKey { static let defaultValue: (() -> Void)? = nil }

extension EnvironmentValues {
    var sheetConfig: SheetConfig? {
        get { self[SheetConfigKey.self] }
        set { self[SheetConfigKey.self] = newValue }
    }
    /// Fermeture de l'alerte en cours : les boutons d'une alerte la ferment après leur action.
    var presentationDismiss: (() -> Void)? {
        get { self[PresentationDismissKey.self] }
        set { self[PresentationDismissKey.self] = newValue }
    }
}

struct _SheetModifier<S: View>: _PrimitiveModifier {
    let isPresented: Binding<Bool>
    let onDismiss: (() -> Void)?
    let sheet: () -> S

    func _apply(_ context: BuildContext, _ content: (BuildContext) -> [LayoutNode]) -> [LayoutNode] {
        let nodes = content(context)
        guard isPresented.wrappedValue else { return nodes }
        let isPresented = self.isPresented, onDismiss = self.onDismiss
        let close = { isPresented.wrappedValue = false; onDismiss?() }
        var ctx = context.child("sheet")
        let config = SheetConfig()
        ctx.environment.sheetConfig = config
        ctx.environment.dismiss = DismissAction(action: { close() })
        ctx.environment.navigationTitleSink = nil
        ctx.environment.navigation = nil
        ctx.environment.isInList = false
        let sheetNodes = LSimUI._makeNodes(sheet(), ctx)
        let dimID = ctx.path + "#dim"
        context.graph.registerAction(dimID, close)
        context.graph.presentations.append(SheetNode(content: group(sheetNodes, axis: .vertical), detent: config.detents.first ?? .large, dimID: dimID))
        return nodes
    }
}

extension View {
    public func sheet<Content: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
                                     @ViewBuilder content: @escaping () -> Content) -> some View {
        modifier(_SheetModifier(isPresented: isPresented, onDismiss: onDismiss, sheet: content))
    }

    public func sheet<Item: Identifiable, Content: View>(item: Binding<Item?>, onDismiss: (() -> Void)? = nil,
                                                         @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        let presented = Binding<Bool>(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
        return modifier(_SheetModifier(isPresented: presented, onDismiss: onDismiss) {
            item.wrappedValue.map { AnyView(content($0)) } ?? AnyView(EmptyView())
        })
    }

    public func fullScreenCover<Content: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
                                               @ViewBuilder content: @escaping () -> Content) -> some View {
        sheet(isPresented: isPresented, onDismiss: onDismiss, content: content)
    }

    public func presentationDetents(_ detents: Set<PresentationDetent>) -> some View {
        modifier(_EnvironmentModifier { env in
            env.sheetConfig?.detents = detents.sorted { $0.fraction < $1.fraction }
        })
    }
    public func presentationDragIndicator(_ visibility: Visibility) -> some View { self }
    public func presentationCornerRadius(_ radius: CGFloat?) -> some View { self }
    public func interactiveDismissDisabled(_ disabled: Bool = true) -> some View { self }
}

/// Mesures des feuilles iOS 26 (estimations à calibrer).
public enum SheetMetrics {
    public static var cornerRadius: CGFloat = 38
    /// Retrait latéral et bas d'une feuille à mi-hauteur (« flottante »).
    public static var floatingInset: CGFloat = 8
    public static var largeTopGap: CGFloat = 10
    public static var dimAlpha: Double = 0.2
}

final class SheetNode: LayoutNode {
    let content: LayoutNode
    let detent: PresentationDetent
    let dimID: String
    private typealias M = SheetMetrics

    init(content: LayoutNode, detent: PresentationDetent, dimID: String) {
        self.content = content
        self.detent = detent
        self.dimID = dimID
    }

    override func draw(in screen: CGRect, _ lc: LayoutContext, _ list: inout DisplayList) {
        list.append(.fill(.rectangle, screen, RGBA(0, 0, 0, lc.colorScheme == .dark ? 0.4 : M.dimAlpha)))
        list.append(.hitRegion(id: dimID, screen))
        let frame: CGRect
        if detent.fraction < 0 || detent.fraction < 1 {
            let height = detent.fraction < 0 ? -detent.fraction : screen.height * detent.fraction
            frame = CGRect(x: screen.minX + M.floatingInset, y: screen.maxY - M.floatingInset - height,
                           width: screen.width - 2 * M.floatingInset, height: height)
        } else {
            let top = screen.minY + lc.safeArea.top + M.largeTopGap
            frame = CGRect(x: screen.minX, y: top, width: screen.width, height: screen.maxY - top)
        }
        let bg = lc.colorScheme == .light ? RGBA(1, 1, 1) : .rgb255(28, 28, 30)
        list.append(.fill(.roundedRectangle(cornerRadius: M.cornerRadius), frame.offsetBy(dx: 0, dy: -1), RGBA(0, 0, 0, 0.06)))
        list.append(.fill(.roundedRectangle(cornerRadius: M.cornerRadius), frame, bg))
        // Bloque les touchers vers ce qui est derrière la feuille.
        list.append(.hitRegion(id: dimID + "-sheet", frame))
        list.append(.pushClip(.roundedRectangle(cornerRadius: M.cornerRadius), frame))
        let inner = frame.insetBy(dx: 0, dy: 0)
        let s = content.sizeThatFits(ProposedViewSize(inner.size), lc)
        content.render(in: Alignment.top.place(CGSize(width: inner.width, height: min(s.height, inner.height)), in: inner)
                        .offsetBy(dx: 0, dy: s.height >= inner.height - 1 ? 0 : 12), lc, &list)
        list.append(.popClip)
    }
}

// MARK: - Alertes

final class AlertButtonNode: SingleChildNode {
    let id: String
    let role: ButtonRole?
    init(_ child: LayoutNode, id: String, role: ButtonRole?) {
        self.id = id
        self.role = role
        super.init(child)
    }
}

private struct InAlertKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var isInAlert: Bool {
        get { self[InAlertKey.self] }
        set { self[InAlertKey.self] = newValue }
    }
}

struct _AlertModifier<A: View, M: View>: _PrimitiveModifier {
    let title: String
    let isPresented: Binding<Bool>
    let actions: () -> A
    let message: () -> M

    func _apply(_ context: BuildContext, _ content: (BuildContext) -> [LayoutNode]) -> [LayoutNode] {
        let nodes = content(context)
        guard isPresented.wrappedValue else { return nodes }
        let isPresented = self.isPresented
        var ctx = context.child("alert")
        ctx.environment.isInList = false
        ctx.environment.isInAlert = true
        ctx.environment.presentationDismiss = { isPresented.wrappedValue = false }
        var buttons = LSimUI._makeNodes(actions(), ctx.child("actions")).compactMap { $0 as? AlertButtonNode }
        if buttons.isEmpty {
            // Sans action, SwiftUI ajoute un bouton « OK ».
            buttons = LSimUI._makeNodes(Button("OK") {}, ctx.child("ok")).compactMap { $0 as? AlertButtonNode }
        }
        var messageCtx = ctx.child("message")
        messageCtx.environment.isInAlert = false
        messageCtx.environment.font = .footnote
        messageCtx.environment.multilineTextAlignment = .center
        let messageNodes = LSimUI._makeNodes(message(), messageCtx)
        context.graph.presentations.append(AlertNode(title: title, message: messageNodes, buttons: buttons, blockID: ctx.path + "#block"))
        return nodes
    }
}

extension View {
    public func alert<S: StringProtocol, A: View>(_ title: S, isPresented: Binding<Bool>,
                                                  @ViewBuilder actions: @escaping () -> A) -> some View {
        modifier(_AlertModifier(title: String(title), isPresented: isPresented, actions: actions, message: { EmptyView() }))
    }

    public func alert<S: StringProtocol, A: View, M: View>(_ title: S, isPresented: Binding<Bool>,
                                                           @ViewBuilder actions: @escaping () -> A,
                                                           @ViewBuilder message: @escaping () -> M) -> some View {
        modifier(_AlertModifier(title: String(title), isPresented: isPresented, actions: actions, message: message))
    }

    public func confirmationDialog<S: StringProtocol, A: View>(_ title: S, isPresented: Binding<Bool>,
                                                               titleVisibility: Visibility = .automatic,
                                                               @ViewBuilder actions: @escaping () -> A) -> some View {
        alert(title, isPresented: isPresented, actions: actions)
    }
}

/// Mesures des alertes iOS 26 (estimations à calibrer).
public enum AlertMetrics {
    public static var width: CGFloat = 300
    public static var cornerRadius: CGFloat = 34
    public static var padding: CGFloat = 22
    public static var buttonHeight: CGFloat = 48
    public static var buttonSpacing: CGFloat = 10
}

final class AlertNode: LayoutNode {
    let title: String
    let message: [LayoutNode]
    let buttons: [AlertButtonNode]
    let blockID: String
    private typealias M = AlertMetrics

    init(title: String, message: [LayoutNode], buttons: [AlertButtonNode], blockID: String) {
        self.title = title
        self.message = message
        self.buttons = buttons
        self.blockID = blockID
    }

    override func draw(in screen: CGRect, _ lc: LayoutContext, _ list: inout DisplayList) {
        list.append(.fill(.rectangle, screen, RGBA(0, 0, 0, lc.colorScheme == .dark ? 0.45 : 0.2)))
        list.append(.hitRegion(id: blockID, screen))
        let inner = M.width - 2 * M.padding
        let titleFont = Font.system(size: 17, weight: .semibold)
        let titleSize = lc.measurer.measure(title, font: titleFont, maxWidth: inner)
        let messageNode = message.isEmpty ? nil : group(message, axis: .vertical)
        let messageSize = messageNode?.sizeThatFits(ProposedViewSize(width: inner, height: nil), lc) ?? .zero
        let sideBySide = buttons.count == 2
        let buttonRows = sideBySide ? 1 : buttons.count
        let buttonsHeight = CGFloat(buttonRows) * M.buttonHeight + CGFloat(max(0, buttonRows - 1)) * M.buttonSpacing
        let height = M.padding + titleSize.height + (messageNode == nil ? 0 : 6 + messageSize.height) + 18 + buttonsHeight + M.padding
        let card = CGRect(x: screen.midX - M.width / 2, y: screen.midY - height / 2, width: M.width, height: height)
        let dark = lc.colorScheme == .dark
        list.append(.backdrop(card, blur: 12, tint: dark ? RGBA(0.14, 0.14, 0.15, 0.92) : RGBA(1, 1, 1, 0.94),
                              shape: .roundedRectangle(cornerRadius: M.cornerRadius)))

        var y = card.minY + M.padding
        list.append(.text(title, titleFont, CGRect(x: card.midX - titleSize.width / 2, y: y, width: titleSize.width, height: titleSize.height),
                          Color.primary.resolve(in: lc.colorScheme), .center))
        y += titleSize.height
        if let messageNode {
            y += 6
            messageNode.render(in: CGRect(x: card.midX - messageSize.width / 2, y: y, width: messageSize.width, height: messageSize.height), lc, &list)
            y += messageSize.height
        }
        y += 18
        let buttonWidth = sideBySide ? (inner - M.buttonSpacing) / 2 : inner
        for (i, button) in buttons.enumerated() {
            let x = card.minX + M.padding + (sideBySide ? CGFloat(i) * (buttonWidth + M.buttonSpacing) : 0)
            let rect = CGRect(x: x, y: y, width: buttonWidth, height: M.buttonHeight)
            list.append(.fill(.capsule, rect, Color.secondarySystemFill.resolve(in: lc.colorScheme)))
            let s = button.child.sizeThatFits(ProposedViewSize(width: buttonWidth - 16, height: nil), lc)
            button.child.render(in: Alignment.center.place(s, in: rect), lc, &list)
            list.append(.hitRegion(id: button.id, rect))
            if !sideBySide { y += M.buttonHeight + M.buttonSpacing }
        }
    }
}

// MARK: - Modificateurs de liste acceptés (sans effet pour l'instant)

public struct HorizontalEdge: Hashable, Sendable {
    public static let leading = HorizontalEdge(), trailing = HorizontalEdge()
}

extension View {
    public func swipeActions<C: View>(edge: HorizontalEdge = .trailing, allowsFullSwipe: Bool = true,
                                      @ViewBuilder content: () -> C) -> some View { self }
    public func searchable(text: Binding<String>, prompt: Text? = nil) -> some View { self }
    public func searchable<S: StringProtocol>(text: Binding<String>, prompt: S) -> some View { self }
    public func refreshable(action: @escaping @Sendable () async -> Void) -> some View { self }
    public func listStyle<S: ListStyle>(_ style: S) -> some View { self }
    public func listRowBackground<V: View>(_ view: V?) -> some View { self }
    public func listRowSeparator(_ visibility: Visibility, edges: VerticalEdge.Set = .all) -> some View { self }
    public func listRowInsets(_ insets: EdgeInsets?) -> some View { self }
    public func scrollContentBackground(_ visibility: Visibility) -> some View { self }
    public func scrollDismissesKeyboard(_ mode: ScrollDismissesKeyboardMode) -> some View { self }
    public func contentShape<S: Shape>(_ shape: S) -> some View { self }
    public func allowsHitTesting(_ enabled: Bool) -> some View { self }
    public func accessibilityLabel<S: StringProtocol>(_ label: S) -> some View { self }
    public func accessibilityHint<S: StringProtocol>(_ hint: S) -> some View { self }
    public func accessibilityHidden(_ hidden: Bool) -> some View { self }
    public func help<S: StringProtocol>(_ text: S) -> some View { self }
    public func sensoryFeedback<T: Equatable>(_ feedback: SensoryFeedback, trigger: T) -> some View { self }
    public func contextMenu<M: View>(@ViewBuilder menuItems: () -> M) -> some View { self }
}

public struct SensoryFeedback: Sendable { public static let success = Self(), warning = Self(), error = Self(), selection = Self(), increase = Self(), decrease = Self(), impact = Self() }
public struct ScrollDismissesKeyboardMode: Sendable { public static let automatic = Self(), immediately = Self(), interactively = Self(), never = Self() }
public enum VerticalEdge: Sendable {
    case top, bottom
    public struct Set: OptionSet, Sendable {
        public let rawValue: Int8
        public init(rawValue: Int8) { self.rawValue = rawValue }
        public static let top = Set(rawValue: 1), bottom = Set(rawValue: 2), all: Set = [.top, .bottom]
    }
}

public protocol ListStyle {}
public struct InsetGroupedListStyle: ListStyle { public init() {} }
public struct GroupedListStyle: ListStyle { public init() {} }
public struct PlainListStyle: ListStyle { public init() {} }
public struct InsetListStyle: ListStyle { public init() {} }
public struct SidebarListStyle: ListStyle { public init() {} }
public struct DefaultListStyle: ListStyle { public init() {} }
extension ListStyle where Self == InsetGroupedListStyle { public static var insetGrouped: Self { .init() } }
extension ListStyle where Self == GroupedListStyle { public static var grouped: Self { .init() } }
extension ListStyle where Self == PlainListStyle { public static var plain: Self { .init() } }
extension ListStyle where Self == InsetListStyle { public static var inset: Self { .init() } }
extension ListStyle where Self == SidebarListStyle { public static var sidebar: Self { .init() } }
extension ListStyle where Self == DefaultListStyle { public static var automatic: Self { .init() } }

extension ForEach {
    public func onDelete(perform action: ((IndexSet) -> Void)?) -> some View { self }
    public func onMove(perform action: ((IndexSet, Int) -> Void)?) -> some View { self }
}
