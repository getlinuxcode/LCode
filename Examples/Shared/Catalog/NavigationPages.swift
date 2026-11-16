import Foundation
import SwiftUI

// Pages de calibration de la barre de navigation Liquid Glass (iOS 26+) : écran poussé (bouton retour en
// verre), bouton d'outil, grand titre, contenu défilé à un décalage précis.
//  - nav.bar.<décalage> : damier sous la barre, pour la géométrie du titre et la transition grand titre
//    → titre centré ;
//  - nav.edge.<fond> : fonds codés (gris bas/haut, ondes verticales) défilés loin, pour mesurer ligne par
//    ligne l'effet de bord de défilement (transmission, voile, flou progressif).

enum NavigationCatalog {
    /// Décalages réels du contenu depuis le repos (grand titre déployé). `ScrollPosition(y:)` d'iOS se compte
    /// depuis la barre repliée : y = décalage − hauteur du grand titre (52 pt sur iOS 27).
    static let offsets: [Int] = [0, 8, 16, 24, 32, 40, 48, 56, 70, 120, 352]
    static let largeTitle: CGFloat = 52
    static let edgeBackgrounds: [(String, GlassBackground)] = [
        ("low", .low), ("high", .high), ("xsin", .rampX(.sin)), ("xcos", .rampX(.cos)),
    ]

    @available(iOS 26, *)
    static var pages: [CatalogPage] {
        var pages: [CatalogPage] = []
        for offset in offsets {
            pages.append(CatalogPage(id: "nav.bar.\(offset)") {
                AnyView(NavigationBarPage(offset: CGFloat(offset) - largeTitle, background: .checker))
            })
        }
        for (name, bg) in edgeBackgrounds {
            pages.append(CatalogPage(id: "nav.edge.\(name)") {
                AnyView(NavigationBarPage(offset: 300, background: bg))  // y = 300 : 352 pt réels
            })
        }
        return pages
    }
}

@available(iOS 26, *)
struct NavigationBarPage: View {
    let offset: CGFloat
    let background: GlassBackground
    @State private var path = [1]
    @State private var position: ScrollPosition

    init(offset: CGFloat, background: GlassBackground) {
        self.offset = offset
        self.background = background
        _position = State(initialValue: ScrollPosition(y: offset))
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
                    .onAppear { position.scrollTo(y: offset) }
                }
        }
    }
}
