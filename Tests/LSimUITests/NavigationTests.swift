import Foundation
import Testing
@testable import LSimUI

private let screen = CGRect(x: 0, y: 0, width: 440, height: 956)
private let safe = EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0)

private func renderScreen<V: View>(_ view: V, graph: ViewGraph) -> DisplayList {
    let lc = LayoutContext(measurer: FakeMeasurer(), colorScheme: .light, screen: screen, safeArea: safe)
    let nodes = graph.build(environment: EnvironmentValues()) { view }
    let content = CGRect(x: 0, y: safe.top, width: screen.width, height: screen.height - safe.top - safe.bottom)
    return layoutRoot(nodes, in: content, lc)
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
            .navigationTitle("Racine")
            .navigationDestination(for: Item.self) { item in
                Text("détail \(item.id)").navigationTitle("Détail")
            }
        }
    }
}

@Test func pushPopKeepsRootState() {
    let graph = ViewGraph()
    var list = renderScreen(NavRoot(), graph: graph)
    let ids = hitIDs(list)
    #expect(ids.count == 3)  // bouton + 2 liens

    graph.performAction(ids[0])  // taps = 1
    list = renderScreen(NavRoot(), graph: graph)
    #expect(texts(list).contains { $0.0 == "taps 1" })

    graph.performAction(ids[2])  // ouvre « item 2 »
    list = renderScreen(NavRoot(), graph: graph)
    #expect(texts(list).contains { $0.0 == "détail 2" })
    // Liquid Glass : le bouton retour est une pastille sans libellé (le titre précédent n'est pas affiché).
    #expect(!texts(list).contains { $0.0 == "Racine" })
    let back = hitIDs(list).first { $0.hasSuffix("#back") }
    #expect(back != nil)

    graph.performAction(back!)
    list = renderScreen(NavRoot(), graph: graph)
    // L'état de l'écran racine a survécu à la navigation.
    #expect(texts(list).contains { $0.0 == "taps 1" })
}

@Test func listRowsUseMeasuredMetrics() {
    let graph = ViewGraph()
    let list = renderScreen(List { Text("a"); Text("b") }, graph: graph)
    let rows = texts(list)
    // Lignes de 44 pt minimum (texte de 20 pt + 2 × 8,5 = 37 → 44), marges 20 + 20.
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

    graph.scroll(scrollID, by: 100_000)  // bien au-delà de la fin
    list = renderScreen(many, graph: graph)
    #expect(texts(list).contains { $0.0 == "row 39" })
    #expect(hitIDs(list).allSatisfy { !$0.isEmpty })
}
