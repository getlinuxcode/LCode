import Foundation
import LCodeKit

/// Compilation et exécution dans le simulateur, en arrière-plan : la sortie arrive ligne par ligne.
final class Runner {
    let project: XtoolProject
    let lcodeRoot: URL
    /// Sorties (compilation, app, journal de l'appareil) et changements d'état, sur le fil principal.
    var onOutput: (String) -> Void = { _ in }
    var onAppOutput: (String) -> Void = { _ in }
    var onDeviceLog: (String) -> Void = { _ in }
    /// Sortie complète de la dernière compilation (pour la liste des problèmes).
    private(set) var lastBuildOutput = ""
    var onBuildFinished: (String) -> Void = { _ in }
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

    private static func clean(_ text: String) -> String {
        Self.ansi.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    private func emit(_ text: String) {
        let clean = Self.clean(text)
        buildBuffer.append(clean)
        onMain { self.onOutput(clean) }
    }

    private func emitApp(_ text: String) {
        let clean = Self.clean(text)
        onMain { self.onAppOutput(clean) }
    }

    private var buildBuffer = ""
    private var syslog: Process?

    /// Compile puis lance l'app dans le simulateur (arrête d'abord l'exécution en cours).
    func run(device: String, dark: Bool) {
        if build != nil { restartPending = true; return }
        stopApp()
        buildBuffer = ""
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
            self.lastBuildOutput = self.buildBuffer
            let output = self.buildBuffer
            onMain { self.onBuildFinished(output) }
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
        stream(process, app: true)
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
    private func stream(_ process: Process, app: Bool = false) {
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            if app { self?.emitApp(text) } else { self?.emit(text) }
        }
    }

    // MARK: - iPhone

    /// Compile, signe et installe sur l'iPhone choisi (xtool), puis suit son journal système.
    func runOnDevice(udid: String, network: Bool) {
        if build != nil { return }
        stopApp()
        buildBuffer = ""
        set(.building)
        if !project.hasSDKVersionFix {
            emit("⚠︎ Le Package.swift ne déclare pas la version du SDK : iOS affichera l'app sans Liquid Glass.\n")
        }
        emit("▸ Compilation, signature et installation sur l'iPhone (\(network ? "Wi-Fi" : "USB"))…\n")
        let env = DeviceConnection.environment()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["xtool", "dev", "run", "--udid", udid, network ? "--network" : "--usb"]
        process.currentDirectoryURL = project.root
        process.environment = Self.environment.merging(env) { _, n in n }
        stream(process)
        process.terminationHandler = { [weak self] p in
            guard let self else { return }
            self.build = nil
            self.lastBuildOutput = self.buildBuffer
            let output = self.buildBuffer
            onMain { self.onBuildFinished(output) }
            if p.terminationStatus == 0 || output.contains("Installed") || output.contains("Installing") && !output.contains("error:") {
                self.emit("✓ Installé. Touchez l'icône de l'app sur l'iPhone pour la lancer.\n")
                self.set(.idle)
                self.startDeviceLog(udid: udid, env: env)
            } else {
                self.emit("✗ Échec (code \(p.terminationStatus)).\n")
                self.set(.failed)
            }
        }
        do {
            try process.run()
            build = process
        } catch {
            emit("✗ xtool introuvable : \(error)\n")
            set(.failed)
        }
    }

    /// Journal système de l'iPhone, filtré sur l'app (idevicesyslog).
    func startDeviceLog(udid: String, env: [String: String]) {
        syslog?.terminate()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["idevicesyslog", "-u", udid, "-p", project.appTarget]
        process.environment = ProcessInfo.processInfo.environment.merging(env) { _, n in n }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            let text = Self.clean(String(decoding: data, as: UTF8.self))
            onMain { self?.onDeviceLog(text) }
        }
        try? process.run()
        syslog = process
    }

    func stopDeviceLog() {
        syslog?.terminate()
        syslog = nil
    }
}
