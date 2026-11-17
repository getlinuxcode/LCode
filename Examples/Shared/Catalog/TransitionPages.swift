import Foundation
import SwiftUI
#if canImport(QuartzCore)
import QuartzCore
#endif

// Transitions système mesurées image par image : un carré vert (écran de départ) et un carré rouge
// (écran d'arrivée ou feuille), relevés à chaque image sur iPhone. Le déclenchement est automatique sur
// iPhone (après 0,4 s, ou 1,2 s pour les fermetures, le temps que l'ouverture se termine) ; dans LSim,
// un toucher sur le carré visible le déclenche.

enum TransitionCatalog {
    static var pages: [CatalogPage] {
        [
            CatalogPage(id: "anim.push") { AnyView(NavTransitionPage(push: true)) },
            CatalogPage(id: "anim.pop") { AnyView(NavTransitionPage(push: false)) },
            CatalogPage(id: "anim.sheet") { AnyView(SheetTransitionPage(present: true, medium: false)) },
            CatalogPage(id: "anim.sheetMedium") { AnyView(SheetTransitionPage(present: true, medium: true)) },
            CatalogPage(id: "anim.sheetDismiss") { AnyView(SheetTransitionPage(present: false, medium: false)) },
        ]
    }

    static func mark() {
        #if canImport(QuartzCore)
        AnimationProbe.triggerTime = CACurrentMediaTime()
        #endif
    }
}

struct Square: View {
    let red: Bool
    var body: some View {
        Color(red: red ? 1 : 0, green: red ? 0 : 1, blue: 0).frame(width: 60, height: 60)
            .calibrate(red ? "anim.red" : "anim.green")
    }
}

struct NavTransitionPage: View {
    let push: Bool
    @State private var path: [Int]

    init(push: Bool) {
        self.push = push
        _path = State(initialValue: push ? [] : [1])
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack(alignment: .topLeading) {
                Color.clear
                Square(red: false).offset(x: 40, y: 200).onTapGesture { trigger() }
            }
            .navigationTitle("Départ")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Int.self) { _ in
                ZStack(alignment: .topLeading) {
                    Color.clear
                    Square(red: true).offset(x: 40, y: 200).onTapGesture { trigger() }
                }
                .navigationTitle("Arrivée")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task {
            #if canImport(UIKit)
            try? await Task.sleep(for: .milliseconds(push ? 400 : 1200))
            trigger()
            #endif
        }
    }

    func trigger() {
        TransitionCatalog.mark()
        if push { if path.isEmpty { path.append(1) } } else { path.removeAll() }
    }
}

struct SheetTransitionPage: View {
    let present: Bool
    let medium: Bool
    @State private var shown: Bool

    init(present: Bool, medium: Bool) {
        self.present = present
        self.medium = medium
        _shown = State(initialValue: !present)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            Square(red: false).offset(x: 40, y: 200).onTapGesture { trigger() }
        }
        .sheet(isPresented: $shown) {
            ZStack(alignment: .topLeading) {
                Color.clear
                Square(red: true).offset(x: 40, y: 40).onTapGesture { trigger() }
            }
            .presentationDetents(medium ? [.medium] : [.large])
        }
        .task {
            #if canImport(UIKit)
            try? await Task.sleep(for: .milliseconds(present ? 400 : 1200))
            trigger()
            #endif
        }
    }

    func trigger() {
        TransitionCatalog.mark()
        shown = present
    }
}
