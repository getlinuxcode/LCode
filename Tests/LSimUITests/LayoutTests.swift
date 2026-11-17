import Foundation
import Testing
@testable import LSimUI

/// Predictable measurer: each character is 10 pt wide, a line is 20 pt tall.
struct FakeMeasurer: TextMeasurer {
    func measure(_ text: String, font: Font, maxWidth: CGFloat?) -> CGSize {
        let full = CGFloat(text.count) * 10
        guard let maxWidth, maxWidth < full, maxWidth > 0 else { return CGSize(width: full, height: 20) }
        let lines = (full / maxWidth).rounded(.up)
        return CGSize(width: maxWidth, height: 20 * lines)
    }
}

func render<V: View>(_ view: V, size: CGSize = CGSize(width: 400, height: 800), graph: ViewGraph = ViewGraph()) -> DisplayList {
    let lc = LayoutContext(measurer: FakeMeasurer(), colorScheme: .light)
    let nodes = graph.build(environment: EnvironmentValues()) { view }
    return layoutRoot(nodes, in: CGRect(origin: .zero, size: size), lc)
}

func texts(_ list: DisplayList) -> [(String, CGRect)] {
    list.items.compactMap { if case let .text(s, _, r, _, _) = $0 { (s, r) } else { nil } }
}

@Test func vstackCentersAndSpaces() {
    let list = render(VStack { Text("abc"); Text("abcdef") })
    let t = texts(list)
    // Total height 20 + 8 + 20 = 48, centered vertically in 800.
    #expect(t[0].1 == CGRect(x: 185, y: 376, width: 30, height: 20))
    #expect(t[1].1 == CGRect(x: 170, y: 404, width: 60, height: 20))
}

@Test func spacerPushesToEdges() {
    let list = render(HStack { Text("ab"); Spacer(); Text("cd") })
    let t = texts(list)
    #expect(t[0].1.minX == 0)
    #expect(t[1].1.maxX == 400)
}

@Test func textTakesPriorityOverSpacer() {
    // A 300 pt text next to a Spacer must not wrap.
    let long = String(repeating: "x", count: 30)
    let list = render(HStack { Text(long); Spacer() })
    #expect(texts(list)[0].1.size == CGSize(width: 300, height: 20))
}

@Test func paddingAndMaxWidthFrame() {
    let list = render(Text("a").padding().frame(maxWidth: .infinity, alignment: .leading))
    let t = texts(list)
    #expect(t[0].1.origin == CGPoint(x: 16, y: 16 + (800 - 52) / 2))
}

@Test func textWrapsWhenTooLong() {
    let list = render(Text(String(repeating: "x", count: 50)), size: CGSize(width: 200, height: 800))
    #expect(texts(list)[0].1.size == CGSize(width: 200, height: 60))
}

struct Counter: View {
    @State var count = 0
    var body: some View {
        Button("count \(count)") { count += 1 }
    }
}

@Test func stateSurvivesRebuildAndButtonsWork() {
    let graph = ViewGraph()
    var invalidated = 0
    graph.onInvalidate = { invalidated += 1 }
    var list = render(Counter(), graph: graph)
    #expect(texts(list)[0].0 == "count 0")
    let id = list.hitTest(CGPoint(x: 200, y: 400))
    #expect(id != nil)
    graph.performAction(id!)
    graph.performAction(id!)
    #expect(invalidated == 2)
    list = render(Counter(), graph: graph)
    #expect(texts(list)[0].0 == "count 2")
}

@Test func conditionalContentResetsState() {
    struct Root: View {
        let show: Bool
        var body: some View {
            if show { Counter() } else { Text("hidden") }
        }
    }
    let graph = ViewGraph()
    var list = render(Root(show: true), graph: graph)
    graph.performAction(list.hitTest(CGPoint(x: 200, y: 400))!)
    list = render(Root(show: false), graph: graph)
    list = render(Root(show: true), graph: graph)
    // As in SwiftUI, a view removed then reinserted starts over from its initial state.
    #expect(texts(list)[0].0 == "count 0")
}

@Test func idModifierResetsState() {
    struct Root: View {
        let key: Int
        var body: some View { Counter().id(key) }
    }
    let graph = ViewGraph()
    var list = render(Root(key: 1), graph: graph)
    graph.performAction(list.hitTest(CGPoint(x: 200, y: 400))!)
    list = render(Root(key: 1), graph: graph)
    #expect(texts(list)[0].0 == "count 1")
    list = render(Root(key: 2), graph: graph)
    #expect(texts(list)[0].0 == "count 0")
}

@Test func embeddedProfileLoads() {
    // The bundled JSON profile must decode (otherwise LSim would silently fall back).
    let url = Bundle.module.url(forResource: "iOS-27.2", withExtension: "json")
    #expect(url != nil)
    let profile = try? JSONDecoder().decode(DesignProfile.self, from: Data(contentsOf: url!))
    #expect(profile?.button.sizes.count == 5)
    #expect(profile?.button.styles.count == 7)
}
