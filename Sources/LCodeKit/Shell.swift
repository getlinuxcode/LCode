import Foundation

/// Lancement de commandes externes (swift, xtool, l'app simulée).
public enum Shell {
    /// Exécute une commande et renvoie sa sortie standard ; échoue si le code de retour n'est pas 0.
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
            throw LCodeError("« \(arguments.joined(separator: " ")) » a échoué :\n\(message)")
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Exécute une commande en laissant sa sortie s'afficher ; renvoie le code de retour.
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
