import Foundation
import SwiftUI

// Calibration catalog: the SAME code runs on the iPhone (real SwiftUI) and in LSim.
// Each variant has a stable ID; the two renders are then compared.
// The on-screen labels of measured pages (button titles, page titles, sample sentences) are kept
// as they were when Tests/Calibration was recorded: their widths are part of the reference frames.

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
        pages.append(CatalogPage(id: "text.regular") { AnyView(TextStylesPage(weight: .regular, name: "regular")) })
        pages.append(CatalogPage(id: "text.semibold") { AnyView(TextStylesPage(weight: .semibold, name: "semibold")) })
        pages.append(CatalogPage(id: "image.styles") { AnyView(ImageStylesPage()) })
        pages.append(CatalogPage(id: "image.scales") { AnyView(ImageScalesPage()) })
        pages.append(CatalogPage(id: "image.resizable") { AnyView(ImageResizablePage()) })
        pages += ControlCatalog.pages
        pages += AnimationCatalog.pages
        pages += TransitionCatalog.pages
        pages += GestureCatalog.pages
        if #available(iOS 26, *) {
            pages.append(CatalogPage(id: "glass.refraction") { AnyView(GlassRefractionPage(background: .checker)) })
            // Coded backgrounds: direct measurement of the glass refraction field and light.
            for (name, bg) in [("low", GlassBackground.low), ("high", .high),
                               ("xcoarse", .rampX(.coarse)), ("xsin", .rampX(.sin)), ("xcos", .rampX(.cos)),
                               ("ycoarse", .rampY(.coarse)), ("ysin", .rampY(.sin)), ("ycos", .rampY(.cos)),
                               ("xsin64", .rampX(.sin64)), ("xcos64", .rampX(.cos64)),
                               ("ysin64", .rampY(.sin64)), ("ycos64", .rampY(.cos64))] {
                pages.append(CatalogPage(id: "glass.field.\(name)") { AnyView(GlassRefractionPage(background: bg)) })
            }
            pages += NavigationCatalog.pages
            pages += TabCatalog.pages
        }
        return pages
    }
}

/// Applies a button style (SwiftUI button styles are distinct types).
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

/// One sample sentence per text style, used to fit per-size tracking.
struct TextStylesPage: View {
    let weight: Font.Weight
    let name: String

    static let styles: [(String, Int, Font)] = [
        ("largeTitle", 34, .largeTitle), ("title", 28, .title), ("title2", 22, .title2), ("title3", 20, .title3),
        ("body", 17, .body), ("callout", 16, .callout), ("subheadline", 15, .subheadline),
        ("footnote", 13, .footnote), ("caption", 12, .caption), ("caption2", 11, .caption2),
        ("system15", 15, .system(size: 15)), ("system14", 14, .system(size: 14)),
    ]

    /// Sample sentence (short enough to fit on one line at every size; must match fit.py).
    static func sample(_ size: Int) -> String {
        size >= 28 ? "Portez ce whisky" : size >= 20 ? "Portez ce vieux whisky" : "Portez ce vieux whisky au juge blond"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Self.styles, id: \.0) { styleName, size, font in
                Text(Self.sample(size))
                    .font(font)
                    .fontWeight(weight)
                    .calibrate("text.\(size).\(styleName).\(name)")
            }
        }
        .padding()
    }
}

/// Common symbols, drawn at several text styles.
enum SymbolSamples {
    static let names = ["globe", "checkmark.circle.fill", "star.fill", "plus", "gear", "heart", "chevron.right"]
}

struct ImageStylesPage: View {
    static let styles: [(String, Font)] = [
        ("largeTitle", .largeTitle), ("title2", .title2), ("body", .body), ("footnote", .footnote), ("caption", .caption),
    ]

    var body: some View {
        VStack(spacing: 18) {
            PageTitle(text: "Image — styles")
            ForEach(Self.styles, id: \.0) { styleName, font in
                HStack(spacing: 14) {
                    ForEach(SymbolSamples.names, id: \.self) { name in
                        Image(systemName: name)
                            .font(font)
                            .calibrate("image.\(styleName).\(name)")
                    }
                }
            }
        }
        .padding()
    }
}

struct ImageScalesPage: View {
    static let scales: [(String, Image.Scale)] = [("small", .small), ("medium", .medium), ("large", .large)]
    static let styles: [(String, Font)] = [("title2", .title2), ("body", .body), ("caption", .caption)]

    var body: some View {
        VStack(spacing: 18) {
            PageTitle(text: "Image — échelles")
            ForEach(Self.styles, id: \.0) { styleName, font in
                ForEach(Self.scales, id: \.0) { scaleName, scale in
                    HStack(spacing: 14) {
                        ForEach(SymbolSamples.names.prefix(5), id: \.self) { name in
                            Image(systemName: name)
                                .font(font)
                                .imageScale(scale)
                                .calibrate("imageScale.\(styleName).\(scaleName).\(name)")
                        }
                    }
                }
            }
        }
        .padding()
    }
}

struct ImageResizablePage: View {
    var body: some View {
        VStack(spacing: 22) {
            PageTitle(text: "Image — redimensionnable")
            HStack(spacing: 16) {
                Image(systemName: "star.fill").resizable().scaledToFit().frame(width: 60, height: 30)
                    .calibrate("resizable.fit.wide")
                Image(systemName: "star.fill").resizable().scaledToFit().frame(width: 30, height: 60)
                    .calibrate("resizable.fit.tall")
                Image(systemName: "globe").resizable().frame(width: 80, height: 50)
                    .calibrate("resizable.stretch")
                Image(systemName: "heart").resizable().scaledToFill().frame(width: 50, height: 50)
                    .calibrate("resizable.fill")
            }
            // Exactly the `xtool new` template.
            VStack {
                Image(systemName: "globe")
                    .imageScale(.large)
                    .foregroundStyle(.tint)
                    .calibrate("template.globe")
                Text("Hello, world!")
                    .calibrate("template.text")
            }
            .padding()
            .calibrate("template.stack")
        }
        .padding()
    }
}

/// High-contrast checkerboard: makes glass refraction visible in every direction.
struct Checkerboard: View {
    let columns: Int
    let rows: Int
    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<columns, id: \.self) { column in
                        ((row + column) % 2 == 0 ? Color.blue : Color.yellow)
                            .frame(width: 14, height: 14)
                    }
                }
            }
        }
    }
}

/// Background behind the glass shapes.
/// Gradients encode position: grey = position in the background. A coarse full-width ramp resolves the
/// ambiguity; two quadrature waves (sine, cosine, 16 pt period) give the fine position through their
/// phase, which glass blur does not move (it only reduces contrast).
enum GlassBackground {
    case checker, low, high
    case rampX(Ramp)
    case rampY(Ramp)
}

/// Coarse ramp, 16 pt wave (sin, cos), or 64 pt wave (resolves the 16 pt ambiguity).
enum Ramp {
    case coarse, sin, cos, sin64, cos64
    var period: Double { self == .sin64 || self == .cos64 ? 64 : 16 }
    var isSine: Bool { self == .sin || self == .sin64 }
}

struct CodedBackground: View {
    let kind: GlassBackground
    let width: Int
    let height: Int

    /// Grey levels limited to 15–70 % so nothing clips through the glass, which lightens or darkens (must match glassfield.py).
    static let lowLevel = 0.15, highLevel = 0.70
    static func gray(_ v: Double) -> Color {
        let g = lowLevel + (highLevel - lowLevel) * v
        return Color(red: g, green: g, blue: g)
    }

    /// Gradient stops: a single ramp, or a 0.5 + 0.5·sin/cos(2π·x / period) wave with 32 stops per period.
    static func stops(length: Int, ramp: Ramp) -> [Gradient.Stop] {
        guard ramp != .coarse else { return [.init(color: gray(0), location: 0), .init(color: gray(1), location: 1)] }
        let count = Int(Double(length) / ramp.period * 32)
        return (0...count).map { i in
            let x = Double(i) * Double(length) / Double(count)
            let phase = 2 * Double.pi * x / ramp.period
            let v = ramp.isSine ? Foundation.sin(phase) : Foundation.cos(phase)
            return .init(color: gray(0.5 + 0.5 * v), location: CGFloat(x / Double(length)))
        }
    }

    var body: some View {
        switch kind {
        case .checker:
            Checkerboard(columns: width / 14, rows: height / 14)
        case .low:
            Self.gray(0).frame(width: CGFloat(width), height: CGFloat(height))
        case .high:
            Self.gray(1).frame(width: CGFloat(width), height: CGFloat(height))
        case let .rampX(ramp):
            LinearGradient(stops: Self.stops(length: width, ramp: ramp), startPoint: .leading, endPoint: .trailing)
                .frame(width: CGFloat(width), height: CGFloat(height))
        case let .rampY(ramp):
            LinearGradient(stops: Self.stops(length: height, ramp: ramp), startPoint: .top, endPoint: .bottom)
                .frame(width: CGFloat(width), height: CGFloat(height))
        }
    }
}

/// Glass shapes over a background (checkerboard, or coded backgrounds to measure refraction).
@available(iOS 26, *)
struct GlassRefractionPage: View {
    let background: GlassBackground

    var body: some View {
        VStack(spacing: 14) {
            PageTitle(text: "Liquid Glass")
            sample("glass.capsule", width: 240, height: 64) { $0.glassEffect(.regular, in: Capsule()) }
            HStack(spacing: 14) {
                sample("glass.circle", width: 92, height: 92, board: (126, 126)) { $0.glassEffect(.regular, in: Circle()) }
                sample("glass.rounded", width: 180, height: 92, board: (224, 126)) { $0.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26)) }
            }
            sample("glass.clear", width: 240, height: 64) { $0.glassEffect(.clear, in: Capsule()) }
            sample("glass.tinted", width: 240, height: 64) { $0.glassEffect(.regular.tint(.blue), in: Capsule()) }
            // Small shapes at bar-button size (44 pt circle, 44 pt-high capsule).
            HStack(spacing: 14) {
                sample("glass.small", width: 44, height: 44, board: (78, 78)) { $0.glassEffect(.regular, in: Circle()) }
                sample("glass.pill", width: 110, height: 44, board: (144, 78)) { $0.glassEffect(.regular, in: Capsule()) }
            }
        }
        .padding()
    }

    func sample<V: View>(_ id: String, width: CGFloat, height: CGFloat, board: (Int, Int) = (308, 98),
                         glass: (AnyView) -> V) -> some View {
        ZStack {
            CodedBackground(kind: background, width: board.0, height: board.1)
                .calibrate("board." + id)
            glass(AnyView(Color.clear.frame(width: width, height: height)))
                .calibrate(id)
        }
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
            if page >= 0 && page < pages.count {
                // New identity per page: otherwise SwiftUI reuses the previous view and onGeometryChange
                // does not fire again for identical frames.
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
