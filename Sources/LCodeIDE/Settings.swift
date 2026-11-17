import CAdw
import Foundation
import LCodeKit

/// Persistent IDE settings (~/.config/lcode/settings.json): appearance, language, recent projects.
final class Settings {
    static let shared = Settings()

    enum Appearance: String, Codable, CaseIterable {
        case system, light, dark
        var title: String {
            switch self {
            case .system: return tr("Follow System")
            case .light: return tr("Light")
            case .dark: return tr("Dark")
            }
        }
    }

    private struct Stored: Codable {
        var appearance: Appearance = .system
        var recents: [String] = []
        var previewVisible = true
        /// Language code (`en`, `fr`…); nil follows the system.
        var language: String?

        init() {}

        // Tolerates missing keys, so older files keep loading.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            appearance = try c.decodeIfPresent(Appearance.self, forKey: .appearance) ?? .system
            recents = try c.decodeIfPresent([String].self, forKey: .recents) ?? []
            previewVisible = try c.decodeIfPresent(Bool.self, forKey: .previewVisible) ?? true
            language = try c.decodeIfPresent(String.self, forKey: .language)
        }
    }

    private var stored = Stored()
    private let url: URL

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/lcode")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("settings.json")
        // Earlier versions used reglages.json.
        let legacy = dir.appendingPathComponent("reglages.json")
        let source = FileManager.default.fileExists(atPath: url.path) ? url : legacy
        if let data = try? Data(contentsOf: source), let s = try? JSONDecoder().decode(Stored.self, from: data) {
            stored = s
            if source == legacy { save() }
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(stored) { try? data.write(to: url) }
    }

    var appearance: Appearance {
        get { stored.appearance }
        set { stored.appearance = newValue; save(); applyAppearance() }
    }

    var previewVisible: Bool {
        get { stored.previewVisible }
        set { stored.previewVisible = newValue; save() }
    }

    /// Interface language; takes effect on next launch.
    var language: String? {
        get { stored.language }
        set { stored.language = newValue; save() }
    }

    /// Must run before any UI is built.
    func applyLanguage() {
        Localization.preferred = stored.language
    }

    /// Recent projects, newest first, that still exist.
    var recents: [URL] {
        stored.recents.map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Package.swift").path) }
    }

    func noteOpened(_ project: URL) {
        stored.recents.removeAll { $0 == project.path }
        stored.recents.insert(project.path, at: 0)
        stored.recents = Array(stored.recents.prefix(12))
        save()
    }

    func forget(_ project: URL) {
        stored.recents.removeAll { $0 == project.path }
        save()
    }

    func applyAppearance() {
        let scheme: AdwColorScheme
        switch stored.appearance {
        case .system: scheme = ADW_COLOR_SCHEME_DEFAULT
        case .light: scheme = ADW_COLOR_SCHEME_FORCE_LIGHT
        case .dark: scheme = ADW_COLOR_SCHEME_FORCE_DARK
        }
        adw_style_manager_set_color_scheme(adw_style_manager_get_default(), scheme)
    }

    static var isDark: Bool { adw_style_manager_get_dark(adw_style_manager_get_default()) != 0 }
}
