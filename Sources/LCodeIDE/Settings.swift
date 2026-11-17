import CAdw
import Foundation

/// Réglages persistants de l'IDE (~/.config/lcode/reglages.json) : apparence, projets récents.
final class Settings {
    static let shared = Settings()

    enum Appearance: String, Codable, CaseIterable {
        case system, light, dark
        var title: String {
            switch self {
            case .system: return "Selon le système"
            case .light: return "Clair"
            case .dark: return "Sombre"
            }
        }
    }

    private struct Stored: Codable {
        var appearance: Appearance = .system
        var recents: [String] = []
        var previewVisible = true
    }

    private var stored = Stored()
    private let url: URL

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/lcode")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("reglages.json")
        if let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(Stored.self, from: data) { stored = s }
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

    /// Projets récents (le plus récent d'abord), seulement ceux qui existent encore.
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

    /// Applique l'apparence à toute l'application (libadwaita).
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
