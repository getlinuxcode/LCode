import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// Gesture trainer (iPhone): the user does back swipes, then drags a sheet down, varying length and speed.
// At each release we record translation and velocity (a pan recognizer on the window, simultaneous with
// the system gestures), then the outcome (screen popped or not, sheet dismissed or not). The batch goes
// to the PC, which derives the decision rule from it.

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
                Text(phase == .done ? "Done ✓" : "Went back")
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle("Home")
            .navigationDestination(for: Int.self) { _ in
                VStack(spacing: 16) {
                    Text("Back swipe \(min(count + 1, Self.trialsPerGesture)) / \(Self.trialsPerGesture)")
                        .font(.headline)
                    Text(count % 2 == 0
                         ? "This one: swipe slowly and release BEFORE the middle of the screen. The screen should come back."
                         : "This one: go all the way, slowly or with a quick flick (vary it).")
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
                .navigationTitle("Swipe")
            }
        }
        .sheet(isPresented: $sheetShown) {
            VStack(spacing: 16) {
                Text("Sheet \(min(count + 1, Self.trialsPerGesture)) / \(Self.trialsPerGesture)").font(.headline)
                Text(count % 2 == 0
                     ? "This one: pull slowly, a little (a quarter of the screen), and release. The sheet should come back."
                     : "This one: pull firmly, far or with a quick flick (vary it).")
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
        // Active scene's window, else the first available one.
        var window: UIWindow?
        for _ in 0..<50 {
            window = CalibrationRunner.keyWindow()
                ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first
            if window != nil { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let window else { message = "Window not found"; return }
        let recorder = GestureRecorder(window: window)
        var back: [[String: Double]] = []
        var sheet: [[String: Double]] = []
        let size = window.bounds.size
        var handled = 0
        func trial(_ done: Bool) -> [String: Double] {
            // Last recorded drag (if a new one exists), else zeros.
            let sample = recorder.samples.count > handled ? recorder.samples.last : nil
            handled = recorder.samples.count
            return ["dx": Double(sample?.translation.x ?? 0), "dy": Double(sample?.translation.y ?? 0),
                    "vx": Double(sample?.velocity.x ?? 0), "vy": Double(sample?.velocity.y ?? 0),
                    "width": Double(size.width), "height": Double(size.height), "done": done ? 1 : 0,
                    "measured": sample == nil ? 0 : 1]
        }
        while phase != .done {
            try? await Task.sleep(for: .milliseconds(100))
            message = "gestures recorded: \(recorder.samples.count)"
            if phase == .back {
                if path.isEmpty {
                    // Popped: let the animation finish, then push the screen again.
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
                    // Gesture ended without popping (screen came back)?
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
            message = "No calibration server"
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        do {
            _ = try await URLSession.shared.data(for: request)
            message = "Sent to the PC: \(back.count) swipes, \(sheet.count) sheets."
        } catch {
            message = "Upload failed: \(error.localizedDescription)"
        }
        #endif
    }
}

#if canImport(UIKit)
/// Records translation and velocity at the end of each drag, without interfering with system gestures.
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
