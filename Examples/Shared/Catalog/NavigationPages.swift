import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// Pages de calibration de la barre de navigation Liquid Glass (iOS 26+) : écran poussé (bouton retour en
// verre), bouton d'outil, grand titre, contenu défilé à un décalage précis.
//  - nav.bar.<décalage> : damier sous la barre, pour la géométrie du titre et la transition grand titre
//    → titre centré ;
//  - nav.edge.<fond> : fonds codés (gris bas/haut, ondes verticales) défilés loin, pour mesurer ligne par
//    ligne l'effet de bord de défilement (transmission, voile, flou progressif).

enum NavigationCatalog {
    /// Décalages réels du contenu depuis le repos (grand titre déployé). `ScrollPosition(y:)` d'iOS se compte
    /// depuis la barre repliée (y = décalage − 52 pt) et refuse les y négatifs : la transition du titre
    /// n'est pas atteignable ainsi. Sur iPhone, la page règle donc directement la UIScrollView.
    /// (Les décalages intermédiaires 8 à 48 pt ne sont pas capturés : un défilement lancé par le code ne fait
    /// pas suivre le grand titre sur la capture, alors qu'il suit le doigt ; comportement vérifié à la main.)
    static let offsets: [Int] = [0, 56, 70, 120, 352]
    static let largeTitle: CGFloat = 52
    static let edgeBackgrounds: [(String, GlassBackground)] = [
        ("low", .low), ("high", .high), ("xsin", .rampX(.sin)), ("xcos", .rampX(.cos)),
    ]

    @available(iOS 26, *)
    static var pages: [CatalogPage] {
        var pages: [CatalogPage] = []
        for offset in offsets {
            pages.append(CatalogPage(id: "nav.bar.\(offset)") {
                AnyView(NavigationBarPage(offset: CGFloat(offset), background: .checker))
            })
        }
        for (name, bg) in edgeBackgrounds {
            pages.append(CatalogPage(id: "nav.edge.\(name)") {
                AnyView(NavigationBarPage(offset: 352, background: bg))
            })
        }
        return pages
    }
}

@available(iOS 26, *)
struct NavigationBarPage: View {
    /// Décalage réel du contenu depuis le repos (grand titre déployé).
    let offset: CGFloat
    let background: GlassBackground
    @State private var path = [1]
    @State private var position: ScrollPosition

    init(offset: CGFloat, background: GlassBackground) {
        self.offset = offset
        self.background = background
        _position = State(initialValue: ScrollPosition(y: offset - NavigationCatalog.largeTitle))
    }

    var body: some View {
        NavigationStack(path: $path) {
            Text("Accueil")
                .navigationTitle("Accueil")
                .navigationDestination(for: Int.self) { _ in
                    ScrollView {
                        CodedBackground(kind: background, width: 440, height: 1800)
                            .calibrate("nav.content")
                    }
                    .scrollPosition($position)
                    .navigationTitle("Réglages")
                    .navigationBarTitleDisplayMode(.large)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {} label: { Image(systemName: "plus") }
                        }
                    }
                    .onAppear { scroll() }
                }
        }
    }

    private func scroll() {
        #if canImport(UIKit)
        // Comme un doigt : décalage de la UIScrollView, que la barre suit (transition du titre comprise).
        let target = offset
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard let scrollView = Self.findScrollView() else { return }
            // Repos réel (grand titre déployé) : la marge ajustée, elle, exclut le grand titre.
            let rest = scrollView.contentOffset.y
            // Animé : même circuit qu'un défilement réel, que la barre (grand titre) suit image par image.
            scrollView.setContentOffset(CGPoint(x: 0, y: rest + target), animated: true)
        }
        #else
        // LSim accepte un y négatif (grand titre en partie déployé), iOS non.
        position.scrollTo(y: offset - NavigationCatalog.largeTitle)
        #endif
    }

    #if canImport(UIKit)
    @MainActor
    static func findScrollView() -> UIScrollView? {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        func search(_ view: UIView) -> UIScrollView? {
            if let s = view as? UIScrollView, s.contentSize.height > 1000 { return s }
            for sub in view.subviews { if let s = search(sub) { return s } }
            return nil
        }
        for window in windows { if let s = search(window) { return s } }
        return nil
    }
    #endif
}
