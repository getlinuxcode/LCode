import SwiftUI

// Catalogue de calibration : le MÊME code s'exécute sur iPhone (vrai SwiftUI) et dans LSim.
// Chaque variante porte un identifiant stable ; on compare ensuite les deux rendus.

struct CatalogPage: Identifiable {
    let id: String
    let content: () -> AnyView
}

enum Catalog {
    static let sizes: [(String, ControlSize)] = [
        ("mini", .mini), ("small", .small), ("regular", .regular), ("large", .large), ("extraLarge", .extraLarge),
    ]

    static var pages: [CatalogPage] {
        var pages: [CatalogPage] = []
        let styles: [(String, AnyButtonStyleApplier)] = [
            ("automatic", .init { AnyView($0.buttonStyle(.automatic)) }),
            ("plain", .init { AnyView($0.buttonStyle(.plain)) }),
            ("bordered", .init { AnyView($0.buttonStyle(.bordered)) }),
            ("borderedProminent", .init { AnyView($0.buttonStyle(.borderedProminent)) }),
            ("glass", .init { view in
                if #available(iOS 26, *) { return AnyView(view.buttonStyle(.glass)) }
                return AnyView(view)
            }),
            ("glassProminent", .init { view in
                if #available(iOS 26, *) { return AnyView(view.buttonStyle(.glassProminent)) }
                return AnyView(view)
            }),
        ]
        for (name, apply) in styles {
            pages.append(CatalogPage(id: "button.\(name)") { AnyView(ButtonStylePage(style: name, apply: apply)) })
        }
        pages.append(CatalogPage(id: "button.shapes") { AnyView(ButtonShapesPage()) })
        pages.append(CatalogPage(id: "button.tints") { AnyView(ButtonTintsPage()) })
        return pages
    }
}

/// Applique un style de bouton (les styles SwiftUI sont des types distincts).
struct AnyButtonStyleApplier {
    let apply: (AnyView) -> AnyView
    init(_ apply: @escaping (AnyView) -> AnyView) { self.apply = apply }
}

struct PageTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.headline)
            .calibrate("title")
    }
}

struct ButtonStylePage: View {
    let style: String
    let apply: AnyButtonStyleApplier

    var body: some View {
        VStack(spacing: 22) {
            PageTitle(text: "Button .\(style)")
            ForEach(Catalog.sizes, id: \.0) { sizeName, size in
                HStack(spacing: 12) {
                    variant(Button("Bouton") {}, "\(sizeName).normal", size)
                    variant(Button("Supprimer", role: .destructive) {}, "\(sizeName).destructive", size)
                    variant(Button("Inactif") {}.disabled(true), "\(sizeName).disabled", size)
                }
            }
        }
        .padding()
    }

    func variant<V: View>(_ view: V, _ id: String, _ size: ControlSize) -> some View {
        apply.apply(AnyView(view))
            .controlSize(size)
            .calibrate("button.\(style).\(id)")
    }
}

struct ButtonShapesPage: View {
    var body: some View {
        VStack(spacing: 22) {
            PageTitle(text: "Formes")
            row("capsule", .capsule)
            row("roundedRectangle", .roundedRectangle)
            row("radius4", .roundedRectangle(radius: 4))
            row("circle", .circle)
        }
        .padding()
    }

    func row(_ name: String, _ shape: ButtonBorderShape) -> some View {
        HStack(spacing: 12) {
            Button("Bordé") {}.buttonStyle(.bordered).buttonBorderShape(shape).calibrate("shape.\(name).bordered")
            Button("Plein") {}.buttonStyle(.borderedProminent).buttonBorderShape(shape).calibrate("shape.\(name).prominent")
            Button("+") {}.buttonStyle(.borderedProminent).buttonBorderShape(shape).calibrate("shape.\(name).symbol")
        }
    }
}

struct ButtonTintsPage: View {
    let tints: [(String, Color)] = [("red", .red), ("green", .green), ("orange", .orange), ("purple", .purple), ("gray", .gray)]

    var body: some View {
        VStack(spacing: 22) {
            PageTitle(text: "Teintes")
            ForEach(tints, id: \.0) { name, color in
                HStack(spacing: 12) {
                    Button("Texte") {}.tint(color).calibrate("tint.\(name).automatic")
                    Button("Bordé") {}.buttonStyle(.bordered).tint(color).calibrate("tint.\(name).bordered")
                    Button("Plein") {}.buttonStyle(.borderedProminent).tint(color).calibrate("tint.\(name).prominent")
                }
            }
        }
        .padding()
    }
}

// MARK: - Application

@main
struct CatalogApp: App {
    var body: some Scene {
        WindowGroup {
            CatalogRoot()
        }
    }
}

struct CatalogRoot: View {
    @State private var page = CatalogRoot.initialPage
    @State private var status = ""

    static var initialPage: Int {
        let env = ProcessInfo.processInfo.environment
        if let id = env["CATALOG_PAGE_ID"], let index = Catalog.pages.firstIndex(where: { $0.id == id }) { return index }
        return Int(env["CATALOG_PAGE"] ?? "") ?? 0
    }

    var body: some View {
        let pages = Catalog.pages
        ZStack {
            if page < pages.count {
                // Nouvelle identité à chaque page : sinon SwiftUI réutilise la vue précédente
                // et onGeometryChange ne se redéclenche pas pour des cadres identiques.
                pages[page].content().id(page)
            }
            #if canImport(UIKit)
            VStack {
                Spacer()
                Text(status).font(.caption2).foregroundStyle(.secondary)
            }
            #endif
        }
        #if canImport(UIKit)
        .task {
            await CalibrationRunner.run(pageCount: pages.count, pageIDs: pages.map(\.id),
                                        show: { page = $0 }, status: { status = $0 })
        }
        #endif
    }
}
