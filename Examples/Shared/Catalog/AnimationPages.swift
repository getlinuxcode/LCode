import Foundation
import SwiftUI
#if canImport(QuartzCore)
import QuartzCore
#endif

// Animation calibration pages: a red square (colour detected on the iPhone) moves 260 pt with a given
// animation. On iPhone the page triggers itself 0.4 s after appearing and the app samples the square's
// position every display frame; in LSim a tap triggers it and frames are rendered at the same times.

enum AnimationProbe {
    /// CACurrentMediaTime of the last animation trigger.
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
