import Foundation
import SwiftUI

// Pages de calibration de la barre d'onglets Liquid Glass (iOS 26+) : vraie TabView, contenu en damier
// sous la barre (verre visible). Géométrie relevée par les couches iOS et les pixels.
//  - tab.bar.3 / tab.bar.4 : trois ou quatre onglets, le premier sélectionné ;
//  - tab.bar.search : trois onglets et l'onglet de recherche (rôle .search), à part sur iOS 26.

enum TabCatalog {
    @available(iOS 26, *)
    static var pages: [CatalogPage] {
        [
            CatalogPage(id: "tab.bar.3") { AnyView(TabBarPage(count: 3, search: false)) },
            CatalogPage(id: "tab.bar.4") { AnyView(TabBarPage(count: 4, search: false)) },
            CatalogPage(id: "tab.bar.search") { AnyView(TabBarPage(count: 3, search: true)) },
        ]
    }
}

@available(iOS 26, *)
struct TabBarPage: View {
    let count: Int
    let search: Bool
    static let tabs: [(String, String)] = [
        ("Accueil", "house.fill"), ("Favoris", "star.fill"), ("Messages", "message.fill"), ("Réglages", "gearshape.fill"),
    ]

    var body: some View {
        TabView {
            ForEach(0..<count, id: \.self) { i in
                Tab(Self.tabs[i].0, systemImage: Self.tabs[i].1) {
                    ScrollView {
                        CodedBackground(kind: .checker, width: 440, height: 1200)
                            .calibrate("tab.content.\(i)")
                    }
                }
            }
            if search {
                Tab("Recherche", systemImage: "magnifyingglass", role: .search) {
                    Text("Recherche")
                }
            }
        }
    }
}
