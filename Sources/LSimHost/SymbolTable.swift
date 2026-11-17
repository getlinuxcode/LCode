import Foundation

/// SF Symbol name → SF Pro private-use character (U+100000…).
///
/// Built locally by `tools/calibration/symbols.py` from the user's own iPhone and SF Pro fonts;
/// never shipped with LCode (`~/.local/share/lcode/symbols/iOS-27.2.json`).
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
            print("[LSim] SF Symbols table missing (\(path)): symbols will be drawn as placeholder frames.")
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
