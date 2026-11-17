import Foundation

/// Coloration syntaxique du Swift : découpe le texte en jetons (mots-clés, types, chaînes, nombres,
/// commentaires, attributs), avec des positions en caractères Unicode comme celles de GtkTextBuffer.
enum SwiftHighlighter {
    enum Kind: String, CaseIterable {
        case keyword, type, string, number, comment, attribute, declaration
    }

    struct Token {
        let kind: Kind
        let start: Int
        let end: Int
    }

    static let keywords: Set<String> = [
        "actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch", "class", "continue",
        "convenience", "default", "defer", "deinit", "didSet", "do", "dynamic", "else", "enum", "extension",
        "fallthrough", "false", "fileprivate", "final", "for", "func", "get", "guard", "if", "import", "in",
        "indirect", "init", "inout", "internal", "is", "isolated", "lazy", "let", "macro", "mutating", "nil",
        "nonisolated", "nonmutating", "open", "operator", "optional", "override", "package", "precedencegroup",
        "private", "protocol", "public", "repeat", "required", "rethrows", "return", "self", "Self", "set",
        "some", "static", "struct", "subscript", "super", "switch", "throw", "throws", "true", "try", "typealias",
        "unowned", "var", "weak", "where", "while", "willSet", "consume", "borrowing", "consuming",
    ]

    static func tokens(_ text: String) -> [Token] {
        let c = Array(text.unicodeScalars)
        var out: [Token] = []
        var i = 0
        var previousWord = ""
        func isIdentStart(_ s: Unicode.Scalar) -> Bool { s == "_" || s.properties.isAlphabetic }
        func isIdent(_ s: Unicode.Scalar) -> Bool { isIdentStart(s) || s.properties.numericType != nil }
        while i < c.count {
            let ch = c[i]
            // Commentaires
            if ch == "/", i + 1 < c.count, c[i + 1] == "/" {
                let start = i
                while i < c.count, c[i] != "\n" { i += 1 }
                out.append(Token(kind: .comment, start: start, end: i))
                continue
            }
            if ch == "/", i + 1 < c.count, c[i + 1] == "*" {
                let start = i
                var depth = 0
                while i < c.count {
                    if c[i] == "/", i + 1 < c.count, c[i + 1] == "*" { depth += 1; i += 2; continue }
                    if c[i] == "*", i + 1 < c.count, c[i + 1] == "/" { depth -= 1; i += 2; if depth == 0 { break }; continue }
                    i += 1
                }
                out.append(Token(kind: .comment, start: start, end: i))
                continue
            }
            // Chaînes (simples et multilignes), interpolations comprises dans la chaîne.
            if ch == "\"" {
                let start = i
                let multiline = i + 2 < c.count && c[i + 1] == "\"" && c[i + 2] == "\""
                i += multiline ? 3 : 1
                while i < c.count {
                    if c[i] == "\\" { i += 2; continue }
                    if multiline {
                        if c[i] == "\"", i + 2 < c.count, c[i + 1] == "\"", c[i + 2] == "\"" { i += 3; break }
                    } else if c[i] == "\"" || c[i] == "\n" {
                        i += 1
                        break
                    }
                    i += 1
                }
                out.append(Token(kind: .string, start: start, end: min(i, c.count)))
                continue
            }
            // Attributs : @State, @main, @Observable…
            if ch == "@", i + 1 < c.count, isIdentStart(c[i + 1]) {
                let start = i
                i += 1
                while i < c.count, isIdent(c[i]) { i += 1 }
                out.append(Token(kind: .attribute, start: start, end: i))
                continue
            }
            // Nombres
            if ch.properties.numericType != nil, i == 0 || !isIdent(c[i - 1]) {
                let start = i
                while i < c.count, c[i].properties.numericType != nil || c[i] == "." || c[i] == "_" || c[i] == "x"
                        || ("a"..."f").contains(c[i]) || ("A"..."F").contains(c[i]) {
                    if c[i] == ".", i + 1 < c.count, c[i + 1].properties.numericType == nil { break }
                    i += 1
                }
                out.append(Token(kind: .number, start: start, end: i))
                continue
            }
            // Identifiants : mots-clés, types (majuscule initiale), noms déclarés.
            if isIdentStart(ch) {
                let start = i
                while i < c.count, isIdent(c[i]) { i += 1 }
                let word = String(String.UnicodeScalarView(c[start..<i]))
                if keywords.contains(word) {
                    out.append(Token(kind: .keyword, start: start, end: i))
                } else if ["func", "struct", "class", "enum", "protocol", "actor", "typealias", "case"].contains(previousWord) {
                    out.append(Token(kind: .declaration, start: start, end: i))
                } else if let first = word.unicodeScalars.first, first.properties.isUppercase {
                    out.append(Token(kind: .type, start: start, end: i))
                }
                previousWord = word
                continue
            }
            if !ch.properties.isWhitespace { previousWord = "" }
            i += 1
        }
        return out
    }

    /// Couleurs façon Xcode (thème par défaut), clair et sombre.
    static func color(_ kind: Kind, dark: Bool) -> (color: String, bold: Bool, italic: Bool) {
        switch kind {
        case .keyword: return (dark ? "#FC5FA3" : "#9B2393", true, false)
        case .type: return (dark ? "#5DD8FF" : "#3900A0", false, false)
        case .declaration: return (dark ? "#41A1C0" : "#0F68A0", false, false)
        case .string: return (dark ? "#FC6A5D" : "#C41A16", false, false)
        case .number: return (dark ? "#D0BF69" : "#1C00CF", false, false)
        case .comment: return (dark ? "#6C7986" : "#5D6C79", false, true)
        case .attribute: return (dark ? "#FD8F3F" : "#815F03", false, false)
        }
    }
}
