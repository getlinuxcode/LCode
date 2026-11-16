import Foundation

/// Table nom de symbole → caractère de la police SF Pro (zone privée U+100000…).
///
/// Construite localement par le banc de calibration (`tools/calibration/symbols.py`) en appariant
/// les symboles dessinés par l'iPhone de l'utilisateur aux glyphes de ses polices SF Pro.
/// Elle n'est jamais distribuée avec LCode : `~/.local/share/lcode/symbols/iOS-27.2.json`.
final class SymbolTable: @unchecked Sendable {
    static let shared = SymbolTable()

    private var codepoints: [String: UInt32] = [:]
    private var aliases: [String: String] = [:]
    private(set) var isLoaded = false

    private init() {
        let path = ProcessInfo.processInfo.environment["LSIM_SYMBOLS"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".local/share/lcode/symbols/iOS-27.2.json")
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("[LSim] Table des SF Symbols absente (\(path)) : les symboles seront remplacés par un cadre.")
            return
        }
        for (name, value) in json["symbols"] as? [String: Any] ?? [:] {
            if let n = value as? NSNumber { codepoints[name] = n.uint32Value }
        }
        aliases = json["aliases"] as? [String: String] ?? [:]
        isLoaded = true
    }

    func character(for name: String) -> String? {
        let key = codepoints[name] != nil ? name : (aliases[name] ?? name)
        guard let cp = codepoints[key], let scalar = Unicode.Scalar(cp) else { return nil }
        return String(Character(scalar))
    }
}
