import Foundation

/// Runs external commands (swift, xtool, the simulated app).
public enum Shell {
    /// Runs a command and returns its standard output; throws on a non-zero exit status.
    @discardableResult
    public static func capture(_ arguments: [String], cwd: URL? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = cwd }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw LCodeError("`\(arguments.joined(separator: " "))` failed:\n\(message)")
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Runs a command with its output inherited; returns the exit status.
    @discardableResult
    public static func run(_ arguments: [String], cwd: URL? = nil, environment: [String: String] = [:]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = cwd }
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}

extension Shell {
    /// Clears variables inherited from the launcher that break child `swift` commands. Launched through
    /// `swift run` (swiftly's proxy), the process carries SWIFTLY_PROXY_IN_PROGRESS=1, and every `swift build`
    /// it starts then fails with "Circular swiftly proxy invocation".
    public static func sanitizeEnvironment() {
        unsetenv("SWIFTLY_PROXY_IN_PROGRESS")
    }
}
