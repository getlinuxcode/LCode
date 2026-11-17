import Foundation
import SwiftUI

// Liquid Glass tab bar calibration pages (iOS 26+): a real TabView with checkerboard content under the bar
// (glass visible). Geometry comes from the iOS layers and pixels.
//  - tab.bar.3 / tab.bar.4: three or four tabs, the first selected;
//  - tab.bar.search: three tabs plus the search tab (role .search), separate on iOS 26.

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
        ("Home", "house.fill"), ("Favorites", "star.fill"), ("Messages", "message.fill"), ("Settings", "gearshape.fill"),
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
                Tab("Search", systemImage: "magnifyingglass", role: .search) {
                    Text("Search")
                }
            }
        }
    }
}
