import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// Liquid Glass navigation bar calibration pages (iOS 26+): pushed screen (glass back button), toolbar
// button, large title, content scrolled to a precise offset.
//  - nav.bar.<offset>: checkerboard under the bar, for title geometry and the large → inline transition;
//  - nav.edge.<background>: coded backgrounds scrolled far, to measure the scroll edge effect row by row
//    (transmission, veil, progressive blur).

enum NavigationCatalog {
    /// Content offsets from rest (large title expanded). iOS's `ScrollPosition(y:)` counts from the collapsed
    /// bar (y = offset − 52 pt) and rejects negative y, so the title transition is unreachable that way:
    /// on iPhone the page drives the UIScrollView directly. (Offsets 8–48 pt are not captured: a programmatic
    /// scroll doesn't drag the large title along in the capture, while a finger does; checked by hand.)
    static let offsets: [Int] = [0, 56, 70, 120, 352]
    static let largeTitle: CGFloat = 52
    static let buttonBackgrounds: [(String, GlassBackground)] = [
        ("low", .low), ("high", .high), ("xcoarse", .rampX(.coarse)), ("xsin", .rampX(.sin)), ("xcos", .rampX(.cos)),
        ("ycoarse", .rampY(.coarse)), ("ysin", .rampY(.sin)), ("ycos", .rampY(.cos)),
        ("xsin64", .rampX(.sin64)), ("xcos64", .rampX(.cos64)), ("ysin64", .rampY(.sin64)), ("ycos64", .rampY(.cos64)),
        ("checker", .checker),
    ]
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
        // Bar buttons straight over coded backgrounds (no scrolling, no material): measures the button glass,
        // which adapts to the content beneath it.
        for (name, bg) in buttonBackgrounds {
            pages.append(CatalogPage(id: "nav.button.\(name)") { AnyView(NavigationButtonPage(background: bg)) })
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
    /// Content offset from rest (large title expanded).
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
            Text("Home")
                .navigationTitle("Home")
                .navigationDestination(for: Int.self) { _ in
                    ScrollView {
                        CodedBackground(kind: background, width: 440, height: 1800)
                            .calibrate("nav.content")
                    }
                    .scrollPosition($position)
                    .navigationTitle("Settings")
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
        // Like a finger: offset the UIScrollView, which the bar follows (title transition included).
        let target = offset
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard let scrollView = Self.findScrollView() else { return }
            // True rest position (large title expanded); the adjusted inset excludes the large title.
            let rest = scrollView.contentOffset.y
            // Animated: same path as a real scroll, which the bar (large title) follows frame by frame.
            scrollView.setContentOffset(CGPoint(x: 0, y: rest + target), animated: true)
        }
        #else
        // LSim accepts a negative y (large title partly expanded); iOS does not.
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

/// Pushed screen with a static full-screen coded background (no scroll view, so no edge effect).
@available(iOS 26, *)
struct NavigationButtonPage: View {
    let background: GlassBackground
    @State private var path = [1]

    var body: some View {
        NavigationStack(path: $path) {
            Text("Home")
                .navigationTitle("Home")
                .navigationDestination(for: Int.self) { _ in
                    ZStack(alignment: .topLeading) {
                        CodedBackground(kind: background, width: 440, height: 956)
                            .calibrate("board.nav.button")
                    }
                    .ignoresSafeArea()
                    .navigationTitle("Settings")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {} label: { Image(systemName: "plus") }
                        }
                    }
                }
        }
    }
}
