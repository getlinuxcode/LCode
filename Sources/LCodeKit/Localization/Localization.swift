import Foundation

/// User-interface localization for the LCode IDE.
///
/// Source strings are written in English and used as keys; each language provides a table that maps
/// them to its translation (see `Translations.swift`). Missing entries fall back to English.
/// Command-line output and logs stay in English and never go through `tr`.
///
/// The language comes from the `LCODE_LANGUAGE` override, then the IDE setting (`Localization.preferred`),
/// then the system locale (`LANGUAGE`, `LC_ALL`, `LC_MESSAGES`, `LANG`), then English.
public enum Localization {
    /// Languages with a translation table, besides English.
    public static var available: [String] { ["en"] + translations.keys.sorted() }

    /// Display name of a language, in that language.
    public static func displayName(_ code: String) -> String {
        names[code] ?? code
    }

    /// Language chosen in the IDE settings (`nil` = follow the system).
    nonisolated(unsafe) public static var preferred: String? {
        didSet { cachedLanguage = nil }
    }

    /// Language currently in use (`en`, `fr`…).
    public static var language: String {
        if let cachedLanguage { return cachedLanguage }
        let resolved = resolve()
        cachedLanguage = resolved
        return resolved
    }

    nonisolated(unsafe) private static var cachedLanguage: String?

    static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        var candidates: [String] = []
        if let o = environment["LCODE_LANGUAGE"] { candidates.append(o) }
        if let preferred { candidates.append(preferred) }
        // LANGUAGE is a colon-separated priority list (GNU gettext).
        if let list = environment["LANGUAGE"] { candidates += list.split(separator: ":").map(String.init) }
        for key in ["LC_ALL", "LC_MESSAGES", "LANG"] {
            if let v = environment[key], !v.isEmpty { candidates.append(v) }
        }
        for c in candidates {
            let code = normalize(c)
            if code == "en" || translations[code] != nil { return code }
        }
        return "en"
    }

    /// `fr_FR.UTF-8` → `fr`; `C` / `POSIX` → `en`.
    static func normalize(_ locale: String) -> String {
        let base = locale.split(separator: ".").first.map(String.init) ?? locale
        let lang = (base.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == "@" }).first.map(String.init) ?? base).lowercased()
        return lang == "c" || lang == "posix" ? "en" : lang
    }

    /// Translation of an English source string in the current language.
    public static func translate(_ english: String) -> String {
        guard language != "en", let table = translations[language], let t = table[english] else { return english }
        return t
    }
}

/// Translates an English user-interface string into the current language.
/// Placeholders: `%@` / `%d` in the key, filled with `arguments` (like `String(format:)`).
public func tr(_ english: String, _ arguments: CVarArg...) -> String {
    let template = Localization.translate(english)
    return arguments.isEmpty ? template : String(format: template, arguments: arguments)
}
