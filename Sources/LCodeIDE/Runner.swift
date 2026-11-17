import Foundation
import LCodeKit

/// Compilation et exécution dans le simulateur, en arrière-plan : la sortie arrive ligne par ligne.
final class Runner {
    let project: XtoolProject
    let lcodeRoot: URL
    /// Sortie (compilation, app) et changements d'état, appelés sur le fil principal.
    var onOutput: (String) -> Void = { _ in }
    var onState: (State) -> Void = { _ in }

    enum State: Equatable { case idle, building, running, failed }
    private(set) var state = State.idle
    private var build: Process?
    private var app: Process?
    private var restartPending = false

    init(project: XtoolProject, lcodeRoot: URL) {
        self.project = project
        self.lcodeRoot = lcodeRoot
    }

    /// Environnement des sous-processus : la chaîne Swift de swiftly en tête du PATH.
    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let swiftly = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/swiftly/bin").path
        env["PATH"] = swiftly + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        return env
    }

    private func set(_ s: State) {
        state = s
        onMain { self.onState(s) }
    }

    /// Séquences de couleur du terminal (ESC [ … m) : retirées pour la console.
    private static let ansi = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[A-Za-z]")

    private func emit(_ text: String) {
        let range = NSRange(text.startIndex..., in: text)
        let clean = Self.ansi.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        onMain { self.onOutput(clean) }
    }

    /// Compile puis lance l'app dans le simulateur (arrête d'abord l'exécution en cours).
    func run(device: String, dark: Bool) {
        if build != nil { restartPending = true; return }
        stopApp()
        set(.building)
        emit("▸ Compilation de \(project.name) pour le simulateur…\n")
        let simulator = SimulatorBuild(project: project, lcodeRoot: lcodeRoot)
        simulator.warnings.forEach { emit("⚠︎ \($0)\n") }
        do {
            try simulator.generate()
        } catch {
            emit("✗ \(error)\n")
            set(.failed)
            return
        }
        let started = Date()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swift", "build", "--package-path", simulator.directory.path, "--product", project.appTarget]
        process.environment = Self.environment
        stream(process)
        process.terminationHandler = { [weak self] p in
            guard let self else { return }
            self.build = nil
            if self.restartPending {
                self.restartPending = false
                onMain { self.run(device: device, dark: dark) }
                return
            }
            guard p.terminationStatus == 0 else {
                self.emit("✗ Échec de la compilation.\n")
                self.set(.failed)
                return
            }
            self.emit(String(format: "✓ Compilé en %.1f s.\n", Date().timeIntervalSince(started)))
            self.launch(binary: self.binaryPath(simulator), device: device, dark: dark)
        }
        do {
            try process.run()
            build = process
        } catch {
            emit("✗ Impossible de lancer swift build : \(error)\n")
            set(.failed)
        }
    }

    private func binaryPath(_ simulator: SimulatorBuild) -> URL {
        let bin = (try? Shell.capture(["swift", "build", "--package-path", simulator.directory.path, "--show-bin-path"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? simulator.directory.appendingPathComponent(".build/debug").path
        return URL(fileURLWithPath: bin).appendingPathComponent(project.appTarget)
    }

    private func launch(binary: URL, device: String, dark: Bool) {
        let process = Process()
        process.executableURL = binary
        var env = Self.environment
        env["LSIM_DEVICE"] = device
        if dark { env["LSIM_DARK"] = "1" }
        process.environment = env
        stream(process)
        process.terminationHandler = { [weak self] p in
            guard let self, self.app === p else { return }
            self.app = nil
            self.emit("▸ Simulateur fermé.\n")
            self.set(.idle)
        }
        do {
            try process.run()
            app = process
            emit("▸ \(project.appTarget) tourne dans le simulateur (\(device)).\n")
            set(.running)
        } catch {
            emit("✗ Impossible de lancer l'app : \(error)\n")
            set(.failed)
        }
    }

    /// Arrête l'app (et la compilation en cours).
    func stop() {
        restartPending = false
        build?.terminate()
        stopApp()
        set(.idle)
    }

    private func stopApp() {
        guard let app else { return }
        self.app = nil
        app.terminationHandler = nil
        app.terminate()
    }

    var isRunning: Bool { app != nil }

    /// Sortie standard et d'erreur du processus, transmises au fil de l'eau.
    private func stream(_ process: Process) {
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            self?.emit(String(decoding: data, as: UTF8.self))
        }
    }
}
