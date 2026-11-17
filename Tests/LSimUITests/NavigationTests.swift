import Foundation
import Testing
@testable import LSimUI

private let screen = CGRect(x: 0, y: 0, width: 440, height: 956)
private let safe = EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0)

private func renderScreen<V: View>(_ view: V, graph: ViewGraph) -> DisplayList {
    let lc = LayoutContext(measurer: FakeMeasurer(), colorScheme: .light, screen: screen, safeArea: safe)
    let nodes = graph.build(environment: EnvironmentValues()) { view }
    let content = CGRect(x: 0, y: safe.top, width: screen.width, height: screen.height - safe.top - safe.bottom)
    return layoutRoot(nodes, in: content, lc, presentations: graph.presentations)
}

private func center(of id: String, in list: DisplayList) -> CGPoint? {
    for item in list.items { if case let .hitRegion(i, r) = item, i == id { return CGPoint(x: r.midX, y: r.midY) } }
    return nil
}

private func hitIDs(_ list: DisplayList) -> [String] {
    list.items.compactMap { if case let .hitRegion(id, _) = $0 { id } else { nil } }
}

struct Item: Identifiable, Hashable { let id: Int }

struct NavRoot: View {
    @State var taps = 0
    var body: some View {
        NavigationStack {
            List {
                Button("taps \(taps)") { taps += 1 }
                ForEach([Item(id: 1), Item(id: 2)]) { item in
                    NavigationLink(value: item) { Text("item \(item.id)") }
                }
            }
            .navigationTitle("Root")
            .navigationDestination(for: Item.self) { item in
                Text("detail \(item.id)").navigationTitle("Detail")
            }
        }
    }
}

@Test func pushPopKeepsRootState() {
    let graph = ViewGraph()
    var list = renderScreen(NavRoot(), graph: graph)
    let ids = hitIDs(list)
    #expect(ids.count == 3)  // button + 2 links

    graph.performAction(ids[0])  // taps = 1
    list = renderScreen(NavRoot(), graph: graph)
    #expect(texts(list).contains { $0.0 == "taps 1" })

    graph.performAction(ids[2])  // opens "item 2"
    list = renderScreen(NavRoot(), graph: graph)
    #expect(texts(list).contains { $0.0 == "detail 2" })
    // Liquid Glass: the back button is a pill without a label (the previous title is not shown).
    #expect(!texts(list).contains { $0.0 == "Root" })
    let back = hitIDs(list).first { $0.hasSuffix("#back") }
    #expect(back != nil)

    graph.performAction(back!)
    list = renderScreen(NavRoot(), graph: graph)
    // The root screen's state survived navigation.
    #expect(texts(list).contains { $0.0 == "taps 1" })
}

@Test func listRowsUseMeasuredMetrics() {
    let graph = ViewGraph()
    let list = renderScreen(List { Text("a"); Text("b") }, graph: graph)
    let rows = texts(list)
    // Rows at least 44 pt (20 pt text + 2 × 8.5 = 37 → 44), insets 20 + 20.
    #expect(rows[0].1.minX == ListMetrics.margin + ListMetrics.rowPaddingH)
    #expect(rows[1].1.midY - rows[0].1.midY == ListMetrics.rowMinHeight)
}

@Test func scrollingClampsAndHidesOffscreenRows() {
    let graph = ViewGraph()
    let many = List { ForEach(0..<40) { i in Button("row \(i)") {} } }
    var list = renderScreen(many, graph: graph)
    let scrollID = list.items.compactMap { if case let .scrollRegion(id, _) = $0 { id } else { nil } }.first!
    let visibleBefore = hitIDs(list).count
    #expect(visibleBefore < 40)

    graph.scroll(scrollID, by: 100_000)  // far past the end
    list = renderScreen(many, graph: graph)
    #expect(texts(list).contains { $0.0 == "row 39" })
    #expect(hitIDs(list).allSatisfy { !$0.isEmpty })
}

@Test func scrollOffsetSurvivesRebuild() {
    // Regression: the scroll offset was cleared by end-of-pass cleanup.
    let graph = ViewGraph()
    let many = List { ForEach(0..<40) { i in Text("row \(i)") } }
    var list = renderScreen(many, graph: graph)
    let before = texts(list).first { $0.0 == "row 0" }!.1.minY
    let id = list.items.compactMap { if case let .scrollRegion(id, _) = $0 { id } else { nil } }.first!
    graph.scroll(id, by: 300)
    list = renderScreen(many, graph: graph)
    list = renderScreen(many, graph: graph)
    let after = texts(list).first { $0.0 == "row 0" }!.1.minY
    #expect(before - after == 300)
}

private func panIDs(_ list: DisplayList) -> [String] {
    list.items.compactMap { if case let .panRegion(id, _, _) = $0 { id } else { nil } }
}

@Test func backSwipeBeyondHalfPops() {
    let graph = ViewGraph()
    var list = renderScreen(NavRoot(), graph: graph)
    graph.performAction(hitIDs(list)[2])  // opens "item 2"
    list = renderScreen(NavRoot(), graph: graph)
    let swipe = panIDs(list).first { $0.hasSuffix("#backSwipe") }
    #expect(swipe != nil)

    // Short slow swipe: cancelled, the screen stays.
    graph.panHandlers[swipe!]!.changed(CGSize(width: 80, height: 0))
    graph.panHandlers[swipe!]!.ended(CGSize(width: 80, height: 0), CGSize(width: 50, height: 0))
    list = renderScreen(NavRoot(), graph: graph)
    #expect(texts(list).contains { $0.0 == "detail 2" })

    // Swipe past half the screen: back to the root.
    graph.panHandlers[swipe!]!.changed(CGSize(width: 300, height: 0))
    graph.panHandlers[swipe!]!.ended(CGSize(width: 300, height: 0), CGSize(width: 600, height: 0))
    list = renderScreen(NavRoot(), graph: graph)
    #expect(texts(list).contains { $0.0 == "taps 0" })
}

struct SheetHost: View {
    @State var shown = true
    var body: some View {
        Text(shown ? "open" : "closed")
            .sheet(isPresented: $shown) { Text("content") }
    }
}

@Test func sheetPulledDownDismisses() {
    let graph = ViewGraph()
    var list = renderScreen(SheetHost(), graph: graph)
    let pan = panIDs(list).first { $0.hasSuffix("#pan") }
    #expect(pan != nil)
    graph.panHandlers[pan!]!.changed(CGSize(width: 0, height: 500))
    graph.panHandlers[pan!]!.ended(CGSize(width: 0, height: 500), CGSize(width: 0, height: 900))
    list = renderScreen(SheetHost(), graph: graph)
    #expect(texts(list).contains { $0.0 == "closed" })
}
