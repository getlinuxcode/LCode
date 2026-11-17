import Foundation
import LCodeKit

/// Builds and runs in the background (simulator or iPhone), streaming output.
final class Runner {
    var project: XtoolProject
    let lcodeRoot: URL
    /// Output (build, app, device log) and state callbacks, on the main thread.
    var onOutput: (String) -> Void = { _ in }
    var onAppOutput: (String) -> Void = { _ in }
    var onDeviceLog: (String) -> Void = { _ in }
    /// Full output of the last build (for the issue list).
    private(set) var lastBuildOutput = ""
    var onBuildFinished: (String) -> Void = { _ in }
    var onState: (State) -> Void = { _ in }
    var onSigningIssues: ([SigningIssue]) -> Void = { _ in }

    enum State: Equatable { case idle, building, running, failed }
    private(set) var state = State.idle
    private var build: Process?
    private var app: Process?
    private var restartPending = false
    /// Embedded screen the app is served to (otherwise it opens its own simulator window).
    var screen: SimulatorScreen?
    private var appInput: FileHandle?

    init(project: XtoolProject, lcodeRoot: URL) {
        self.project = project
        self.lcodeRoot = lcodeRoot
    }

    /// Child process environment, with swiftly's toolchain first in PATH.
    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let swiftly = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/swiftly/bin").path
        env["PATH"] = swiftly + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        env["SWIFTLY_PROXY_IN_PROGRESS"] = nil
        return env
    }

    private func set(_ s: State) {
        state = s
        onMain { self.onState(s) }
    }

    /// Terminal escape sequences, stripped for the console.
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

    /// Builds and launches the app in the simulator, stopping any current run first.
    func run(device: String, dark: Bool) {
        if build != nil { restartPending = true; return }
        stopApp()
        buildBuffer = ""
        set(.building)
        emit(tr("▸ Building %@ for the simulator…", project.name) + "\n")
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
                self.emit(tr("✗ Build failed.") + "\n")
                self.set(.failed)
                return
            }
            self.emit(tr("✓ Built in %.1f s.", Date().timeIntervalSince(started)) + "\n")
            self.launch(binary: self.binaryPath(simulator), device: device, dark: dark)
        }
        do {
            try process.run()
            build = process
        } catch {
            emit(tr("✗ Couldn’t start swift build: %@", "\(error)") + "\n")
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
        env.merge(project.simulatorEnvironment) { _, n in n }
        if let screen {
            env["LSIM_SERVE_FRAME"] = screen.framePath
            env["LSIM_FRAME_SCALE"] = String(screen.scaleForNewProcess())
            process.environment = env
            serveStreams(process, screen: screen)
        } else {
            process.environment = env
            stream(process, app: true)
        }
        process.terminationHandler = { [weak self] p in
            guard let self, self.app === p else { return }
            self.app = nil
            self.emit(tr("▸ Simulator closed.") + "\n")
            self.set(.idle)
        }
        do {
            try process.run()
            app = process
            emit(tr("▸ %@ is running in the simulator (%@).", project.appTarget, device) + "\n")
            set(.running)
        } catch {
            emit(tr("✗ Couldn’t launch the app: %@", "\(error)") + "\n")
            set(.failed)
        }
    }

    /// Stops the app and any build in progress.
    func stop() {
        restartPending = false
        build?.terminate()
        stopApp()
        set(.idle)
    }

    private func stopApp() {
        guard let app else { return }
        try? appInput?.write(contentsOf: Data("quit\n".utf8))
        appInput = nil
        self.app = nil
        app.terminationHandler = nil
        app.terminate()
    }

    var isRunning: Bool { app != nil }

    /// Sends a gesture or command (scheme dark…) to the app served in the IDE.
    func sendToApp(_ command: String) {
        try? appInput?.write(contentsOf: Data((command + "\n").utf8))
    }

    /// App served in the IDE: frame announcements (`\u{1}frame …`) go to the screen, other output to the app
    /// console; gestures go through its standard input.
    private func serveStreams(_ process: Process, screen: SimulatorScreen) {
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        appInput = input.fileHandleForWriting
        var buffer = Data()
        output.fileHandleForReading.readabilityHandler = { [weak self, weak screen] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            buffer.append(data)
            var text = ""
            while let nl = buffer.firstIndex(of: 10) {
                let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...nl)
                if let frame = SimulatorScreen.parseFrame(line) {
                    onMain { screen?.load(frame) }
                } else {
                    text += line + "\n"
                }
            }
            if !text.isEmpty { self?.emitApp(text) }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            self?.emitApp(String(decoding: data, as: UTF8.self))
        }
    }

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

    /// Builds, signs and installs on the chosen iPhone (xtool), then follows its system log.
    func runOnDevice(udid: String, network: Bool) {
        if build != nil { return }
        stopApp()
        buildBuffer = ""
        set(.building)
        if !project.hasSDKVersionFix {
            emit(tr("⚠︎ Package.swift does not declare the SDK version: iOS will show the app without Liquid Glass.") + "\n")
        }
        emit(tr("▸ Building, signing and installing on iPhone (%@)…", network ? "Wi-Fi" : "USB") + "\n")
        let env = DeviceConnection.environment()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["xtool", "dev", "run", "--udid", udid, network ? "--network" : "--usb"]
        process.currentDirectoryURL = project.root
        process.environment = Self.environment.merging(env) { _, n in n }
        // No stdin: without an account, xtool fails instead of waiting for invisible input.
        process.standardInput = FileHandle.nullDevice
        stream(process)
        process.terminationHandler = { [weak self] p in
            guard let self else { return }
            self.build = nil
            self.lastBuildOutput = self.buildBuffer
            let output = self.buildBuffer
            onMain { self.onBuildFinished(output) }
            if p.terminationStatus == 0 || output.contains("Installed") || output.contains("Installing") && !output.contains("error:") {
                self.emit(tr("✓ Installed. Tap the app icon on the iPhone to launch it.") + "\n")
                onMain { self.onSigningIssues([]) }
                self.set(.idle)
                self.startDeviceLog(udid: udid, env: env)
            } else {
                self.emit(tr("✗ Failed (exit code %d).", Int(p.terminationStatus)) + "\n")
                let issues = SigningIssue.extract(from: output)
                onMain { self.onSigningIssues(issues) }
                self.set(.failed)
            }
        }
        do {
            try process.run()
            build = process
        } catch {
            emit(tr("✗ xtool not found: %@", "\(error)") + "\n")
            set(.failed)
        }
    }

    /// iPhone system log filtered to the app (idevicesyslog).
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
