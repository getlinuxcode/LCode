import Foundation
import Testing
@testable import LCodeKit

@Test func normalizesLocaleNames() {
    #expect(Localization.normalize("fr_FR.UTF-8") == "fr")
    #expect(Localization.normalize("fr-CA") == "fr")
    #expect(Localization.normalize("de_DE@euro") == "de")
    #expect(Localization.normalize("C") == "en")
    #expect(Localization.normalize("POSIX") == "en")
    #expect(Localization.normalize("C.UTF-8") == "en")
}

@Test func resolvesLanguageFromEnvironment() {
    #expect(Localization.resolve(environment: ["LANG": "fr_FR.UTF-8"]) == "fr")
    #expect(Localization.resolve(environment: ["LANG": "C"]) == "en")
    #expect(Localization.resolve(environment: ["LANG": "de_DE.UTF-8"]) == "en")
    #expect(Localization.resolve(environment: [:]) == "en")
    // LANGUAGE is a priority list: the first available language wins, and it beats LANG.
    #expect(Localization.resolve(environment: ["LANGUAGE": "de:fr:en", "LANG": "en_US.UTF-8"]) == "fr")
    #expect(Localization.resolve(environment: ["LANGUAGE": "en:fr", "LANG": "fr_FR.UTF-8"]) == "en")
    #expect(Localization.resolve(environment: ["LC_ALL": "fr_FR.UTF-8", "LANG": "en_US.UTF-8"]) == "fr")
    #expect(Localization.resolve(environment: ["LCODE_LANGUAGE": "en", "LANG": "fr_FR.UTF-8"]) == "en")
}

@Test func frenchTableUsesValidFormatPlaceholders() {
    func placeholders(_ s: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"%(\.\d+)?[@dfX%]|%0\d+X"#)
        return regex.matches(in: s, range: NSRange(s.startIndex..., in: s))
            .map { String(s[Range($0.range, in: s)!]) }.filter { $0 != "%%" }
    }
    for (english, french) in Localization.french {
        #expect(placeholders(english) == placeholders(french), "\(english)")
    }
}

@Test func signingTextsHaveFrenchTranslations() {
    var texts = SigningIssue.allMessages + Capability.privacyKeys.map(\.label)
    for cap in Capability.all {
        texts.append(cap.summary)
        texts += cap.usageKeys.map(\.label)
        if let hint = cap.listHint { texts.append(hint) }
        switch cap.support {
        case let .partial(note), let .unsupported(note): texts.append(note)
        case .xtool, .infoPlist: break
        }
    }
    for text in texts { #expect(Localization.french[text] != nil, "\(text)") }
}
