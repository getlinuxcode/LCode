import Foundation
import SwiftUI
#if canImport(QuartzCore)
import QuartzCore
#endif

// Pages de calibration des animations : un carré rouge (couleur repérée sur iPhone) se déplace de 260 pt
// avec une animation donnée. Sur iPhone, la page se déclenche seule 0,4 s après son apparition et
// l'app échantillonne la position du carré à chaque image de l'écran ; dans LSim, un toucher la
// déclenche et les images sont rendues aux mêmes instants.

enum AnimationProbe {
    /// Instant (CACurrentMediaTime) du déclenchement de la dernière animation.
    nonisolated(unsafe) static var triggerTime: Double?
}

enum AnimationCatalog {
    static let curves: [(String, Animation)] = [
        ("default", .default), ("spring", .spring), ("easeInOut", .easeInOut), ("linear", .linear),
        ("smooth", .smooth), ("snappy", .snappy), ("bouncy", .bouncy),
        ("springCustom", .spring(response: 0.4, dampingFraction: 0.6)), ("easeOut1", .easeOut(duration: 1)),
    ]

    static var pages: [CatalogPage] {
        curves.map { name, animation in
            CatalogPage(id: "anim.\(name)") { AnyView(AnimationPage(animation: animation)) }
        }
    }
}

struct AnimationPage: View {
    let animation: Animation
    @State private var moved = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white
            Color(red: 1, green: 0, blue: 0)
                .frame(width: 60, height: 60)
                .calibrate("anim.box")
                .offset(x: moved ? 300 : 40, y: 400)
                .onTapGesture { trigger() }
        }
        .task {
            #if canImport(UIKit)
            try? await Task.sleep(for: .milliseconds(400))
            trigger()
            #endif
        }
    }

    func trigger() {
        guard !moved else { return }
        #if canImport(QuartzCore)
        AnimationProbe.triggerTime = CACurrentMediaTime()
        #endif
        withAnimation(animation) { moved = true }
    }
}
