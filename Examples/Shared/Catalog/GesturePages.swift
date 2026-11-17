import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// Entraîneur de gestes (iPhone) : l'utilisateur fait des retours par balayage, puis tire une feuille vers
// le bas, en variant longueur et vitesse. Au lâcher de chaque geste, on relève le déplacement et la
// vitesse (reconnaisseur de glisser posé sur la fenêtre, simultané aux gestes du système), puis l'issue
// (écran retiré ou non, feuille fermée ou non). Le lot est envoyé au PC, qui en tire la règle de décision.

enum GestureCatalog {
    static var pages: [CatalogPage] {
        [CatalogPage(id: "gesture.trainer") { AnyView(GestureTrainerPage()) }]
    }
}

struct GestureTrainerPage: View {
    enum Phase { case back, sheet, done }
    static let trialsPerGesture = 12
    @State private var phase = Phase.back
    @State private var path = [1]
    @State private var sheetShown = false
    @State private var count = 0
    @State private var message = ""

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 12) {
                Text(phase == .done ? "Terminé ✓" : "Revenu en arrière")
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle("Accueil")
            .navigationDestination(for: Int.self) { _ in
                VStack(spacing: 16) {
                    Text("Retour par balayage \(min(count + 1, Self.trialsPerGesture)) / \(Self.trialsPerGesture)")
                        .font(.headline)
                    Text(count % 2 == 0
                         ? "Ce geste-ci : balayez lentement et lâchez AVANT la moitié de l'écran. L'écran doit revenir."
                         : "Ce geste-ci : allez au bout, lentement ou d'un coup sec (variez).")
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
                .navigationTitle("Balayage")
            }
        }
        .sheet(isPresented: $sheetShown) {
            VStack(spacing: 16) {
                Text("Feuille \(min(count + 1, Self.trialsPerGesture)) / \(Self.trialsPerGesture)").font(.headline)
                Text(count % 2 == 0
                     ? "Ce geste-ci : tirez lentement, peu (un quart de l'écran), et lâchez. La feuille doit revenir."
                     : "Ce geste-ci : tirez franchement, loin ou d'un coup sec (variez).")
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
            .presentationDetents([.large])
        }
        .task { await runTrials() }
    }

    @MainActor
    func runTrials() async {
        #if canImport(UIKit)
        // Fenêtre : celle de la scène active (sinon la première disponible).
        var window: UIWindow?
        for _ in 0..<50 {
            window = CalibrationRunner.keyWindow()
                ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first
            if window != nil { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let window else { message = "Fenêtre introuvable"; return }
        let recorder = GestureRecorder(window: window)
        var back: [[String: Double]] = []
        var sheet: [[String: Double]] = []
        let size = window.bounds.size
        var handled = 0
        func trial(_ done: Bool) -> [String: Double] {
            // Dernier glisser relevé (s'il y en a un de nouveau), sinon valeurs nulles.
            let sample = recorder.samples.count > handled ? recorder.samples.last : nil
            handled = recorder.samples.count
            return ["dx": Double(sample?.translation.x ?? 0), "dy": Double(sample?.translation.y ?? 0),
                    "vx": Double(sample?.velocity.x ?? 0), "vy": Double(sample?.velocity.y ?? 0),
                    "width": Double(size.width), "height": Double(size.height), "done": done ? 1 : 0,
                    "measured": sample == nil ? 0 : 1]
        }
        while phase != .done {
            try? await Task.sleep(for: .milliseconds(100))
            message = "gestes relevés : \(recorder.samples.count)"
            if phase == .back {
                if path.isEmpty {
                    // Retour effectué : on laisse l'animation finir, puis on remet l'écran.
                    try? await Task.sleep(for: .milliseconds(400))
                    back.append(trial(true))
                    count += 1
                    if count >= Self.trialsPerGesture {
                        count = 0
                        phase = .sheet
                        try? await Task.sleep(for: .milliseconds(500))
                        sheetShown = true
                    } else {
                        try? await Task.sleep(for: .milliseconds(300))
                        path = [1]
                    }
                } else if recorder.samples.count > handled {
                    // Geste fini sans retour (l'écran est revenu) ?
                    try? await Task.sleep(for: .milliseconds(700))
                    if !path.isEmpty, recorder.samples.last.map({ $0.translation.x > 4 }) == true {
                        back.append(trial(false))
                        count += 1
                    } else if !path.isEmpty {
                        handled = recorder.samples.count
                    }
                }
            } else if phase == .sheet {
                if !sheetShown {
                    try? await Task.sleep(for: .milliseconds(300))
                    sheet.append(trial(true))
                    count += 1
                    if count >= Self.trialsPerGesture {
                        phase = .done
                    } else {
                        try? await Task.sleep(for: .milliseconds(400))
                        sheetShown = true
                    }
                } else if recorder.samples.count > handled {
                    try? await Task.sleep(for: .milliseconds(700))
                    if sheetShown, recorder.samples.last.map({ $0.translation.y > 4 }) == true {
                        sheet.append(trial(false))
                        count += 1
                    } else if sheetShown {
                        handled = recorder.samples.count
                    }
                }
            }
        }
        recorder.remove()
        var machine = utsname()
        uname(&machine)
        let model = withUnsafeBytes(of: &machine.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let payload: [String: Any] = ["run": ISO8601DateFormatter().string(from: Date()), "device": model,
                                      "system": UIDevice.current.systemVersion, "back": back, "sheet": sheet]
        guard let server = CalibrationRunner.server, let url = URL(string: server + "/gestures") else {
            message = "Pas de serveur de calibration"
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        do {
            _ = try await URLSession.shared.data(for: request)
            message = "Envoyé au PC : \(back.count) balayages, \(sheet.count) feuilles."
        } catch {
            message = "Échec de l'envoi : \(error.localizedDescription)"
        }
        #endif
    }
}

#if canImport(UIKit)
/// Relève déplacement et vitesse au lâcher de chaque glisser, sans gêner les gestes du système.
@MainActor
final class GestureRecorder: NSObject, UIGestureRecognizerDelegate {
    struct Sample { let translation: CGPoint; let velocity: CGPoint }
    private(set) var samples: [Sample] = []
    private let window: UIWindow
    private var pan: UIPanGestureRecognizer?

    init(window: UIWindow) {
        self.window = window
        super.init()
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handle(_:)))
        pan.cancelsTouchesInView = false
        pan.delaysTouchesBegan = false
        pan.delaysTouchesEnded = false
        pan.delegate = self
        window.addGestureRecognizer(pan)
        self.pan = pan
    }

    func remove() {
        if let pan { window.removeGestureRecognizer(pan) }
    }

    @objc private func handle(_ g: UIPanGestureRecognizer) {
        guard g.state == .ended || g.state == .cancelled else { return }
        samples.append(Sample(translation: g.translation(in: window), velocity: g.velocity(in: window)))
    }

    nonisolated func gestureRecognizer(_ g: UIGestureRecognizer,
                                       shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
#endif
