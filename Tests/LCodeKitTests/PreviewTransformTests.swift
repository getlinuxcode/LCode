import Testing
@testable import LCodeKit

private let source = """
import SwiftUI

@main
struct DemoApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

struct ContentView: View {
    var body: some View { Text("} #Preview { faux }") }
}

#Preview("Clair") {
    VStack {
        ContentView()
    }
}

#Preview {
    @Previewable @State var on = true
    Toggle("x", isOn: $on)
}
"""

@Test func previewsBecomeFunctionsOnSameLines() {
    let result = PreviewTransform.transform(source, removeMain: true, firstIndex: 0)
    #expect(result.previews.count == 2)
    #expect(result.previews[0] == PreviewInfo(line: 12, name: "Clair", symbol: "__LSimPreview_0"))
    #expect(result.previews[1].line == 18)
    #expect(result.previews[1].name == nil)
    // Mêmes lignes : les erreurs du compilateur pointent sur le vrai fichier.
    #expect(result.text.split(separator: "\n", omittingEmptySubsequences: false).count
            == source.split(separator: "\n", omittingEmptySubsequences: false).count)
    #expect(!result.text.contains("@main"))
    #expect(!result.text.contains("@Previewable"))
    #expect(!result.text.contains("#Preview(") && !result.text.contains("#Preview {\n"))
    // La chaîne qui contient « } #Preview { » est intacte.
    #expect(result.text.contains("Text(\"} #Preview { faux }\")"))
    #expect(result.text.contains("enum __LSimPreview_0 { @ViewBuilder static func body() -> some View {"))
    #expect(result.text.contains("} }"))
}

@Test func mainKeptForSimulatorBuild() {
    let result = PreviewTransform.transform(source, removeMain: false, firstIndex: 5)
    #expect(result.text.contains("@main"))
    #expect(result.previews.map(\.symbol) == ["__LSimPreview_5", "__LSimPreview_6"])
}
