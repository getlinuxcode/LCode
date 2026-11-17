// Translation tables, keyed by the English source string. To add a language: add a file
// `Translations+<code>.swift` defining a `[String: String]` table, then register it below.

extension Localization {
    static let translations: [String: [String: String]] = [
        "fr": french,
    ]

    static let names: [String: String] = [
        "en": "English",
        "fr": "Français",
    ]
}
