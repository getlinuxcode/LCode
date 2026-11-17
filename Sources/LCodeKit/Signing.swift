import Foundation

// Signature et capabilities (« Signing & Capabilities » d'Xcode) pour un projet xtool.
//
// Ce que fait xtool (sources v1.24, PackLib/PackSchema.swift et XKit/DeveloperServices) :
// - `xtool.yml` porte `bundleID` (ou `orgID`), `infoPath` (Info.plist fusionné dans celui qu'xtool génère)
//   et `entitlementsPath` (plist d'entitlements, chemin relatif au projet) ;
// - à la signature, xtool active sur l'App ID les capabilities qu'il sait relier à un entitlement
//   (App Groups, Push, HealthKit…), retire celles des comptes gratuits qui exigent le programme payant,
//   et remplace lui-même `application-identifier`, `team-identifier` et `keychain-access-groups`.

// MARK: - xtool.yml

/// Lecture et modification des clés simples de `xtool.yml`, sans toucher au reste du fichier.
public enum XtoolConfig {
    public static func url(in root: URL) -> URL { root.appendingPathComponent("xtool.yml") }

    /// Valeur d'une clé de premier niveau (`bundleID: com.exemple.App` → `com.exemple.App`).
    public static func value(_ key: String, in text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) where line.hasPrefix(key + ":") {
            var v = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
            if let hash = v.range(of: " #") { v = String(v[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces) }
            if v.count >= 2, let q = v.first, q == "\"" || q == "'", v.last == q { v = String(v.dropFirst().dropLast()) }
            return v.isEmpty ? nil : v
        }
        return nil
    }

    /// Le texte avec la clé remplacée, ajoutée à la fin, ou retirée (`value` nil).
    public static func setting(_ key: String, to value: String?, in text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        let index = lines.firstIndex { $0.hasPrefix(key + ":") }
        switch (index, value) {
        case let (i?, v?): lines[i] = "\(key): \(quoted(v))"
        case let (i?, nil): lines.remove(at: i)
        case let (nil, v?): lines.append("\(key): \(quoted(v))")
        case (nil, nil): break
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func quoted(_ v: String) -> String {
        v.contains(": ") || v.contains(" #") || v.hasPrefix("'") || v.hasPrefix("\"") ? "\"\(v)\"" : v
    }

    /// Un bundle ID valide : lettres, chiffres, tirets et points, au moins deux composants.
    public static func isValidBundleID(_ id: String) -> Bool {
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.allSatisfy { p in
            !p.isEmpty && p.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }
}

// MARK: - Capabilities

/// Une capability Apple : entitlement(s) et clés Info.plist qui l'accompagnent.
public struct Capability: Sendable {
    /// Ce qu'xtool en fait à la signature.
    public enum Support: Sendable, Equatable {
        /// xtool active la capability sur l'App ID et la garde dans le profil.
        case xtool
        /// Simple clé d'Info.plist : rien à activer côté Apple.
        case infoPlist
        /// Prise en charge partielle (explication).
        case partial(String)
        /// xtool ne sait pas l'activer : iOS refusera probablement l'installation (explication).
        case unsupported(String)
    }

    /// Où est rangée la valeur principale (qui dit si la capability est active).
    public enum Storage: Sendable, Equatable { case entitlement(String), infoPlist(String) }

    public enum Value: Sendable, Equatable {
        case bool(Bool)
        case string(String)
        /// Liste modifiable dans l'IDE (groupes, domaines, modes…). `$(BundleID)` est remplacé.
        case list([String])
    }

    public let id: String
    public let title: String
    public let summary: String
    public let storage: Storage
    public let value: Value
    /// Entitlements ajoutés en même temps (iCloud…).
    public let companions: [(key: String, value: Value)]
    /// Descriptions d'usage (Info.plist) demandées par iOS : clé, libellé.
    public let usageKeys: [(key: String, label: String)]
    /// Réservée aux membres du programme payant (xtool la retire pour une équipe gratuite).
    public let requiresPaidAccount: Bool
    public let support: Support
    /// Aide pour la liste (« groupes, séparés par des virgules »…).
    public let listHint: String?

    public var key: String {
        switch storage { case let .entitlement(k), let .infoPlist(k): return k }
    }

    init(_ id: String, _ title: String, _ summary: String, _ storage: Storage, _ value: Value,
         companions: [(key: String, value: Value)] = [], usage: [(key: String, label: String)] = [],
         paid: Bool, support: Support = .xtool, listHint: String? = nil) {
        self.id = id; self.title = title; self.summary = summary; self.storage = storage; self.value = value
        self.companions = companions; usageKeys = usage; requiresPaidAccount = paid; self.support = support
        self.listHint = listHint
    }

    /// Capabilities courantes, dans l'ordre de la page.
    public static let all: [Capability] = [
        Capability("app-groups", "App Groups", "Partage de données entre l'app et ses extensions.",
                   .entitlement("com.apple.security.application-groups"), .list(["group.$(BundleID)"]),
                   paid: false, listHint: "Groupes (group.…), séparés par des virgules — un seul avec un compte gratuit"),
        Capability("push", "Push Notifications", "Notifications à distance (APNs).",
                   .entitlement("aps-environment"), .string("development"), paid: true),
        Capability("background-modes", "Background Modes", "Exécution en arrière-plan (audio, position, téléchargements…).",
                   .infoPlist("UIBackgroundModes"), .list(["audio"]), paid: false, support: .infoPlist,
                   listHint: "Modes : audio, location, fetch, remote-notification, processing, voip, bluetooth-central…"),
        Capability("icloud", "iCloud", "CloudKit et stockage clé-valeur iCloud.",
                   .entitlement("com.apple.developer.icloud-services"), .list(["CloudKit"]),
                   companions: [("com.apple.developer.icloud-container-identifiers", .list(["iCloud.$(BundleID)"])),
                                ("com.apple.developer.ubiquity-kvstore-identifier", .string("$(TeamIdentifierPrefix)$(BundleID)"))],
                   paid: true, support: .unsupported("xtool n'active pas iCloud sur l'App ID : le profil ne contiendra pas "
                       + "l'entitlement et iOS refusera l'installation."),
                   listHint: "Services : CloudKit, CloudDocuments"),
        Capability("keychain-sharing", "Keychain Sharing", "Partage du trousseau entre vos apps.",
                   .entitlement("keychain-access-groups"), .list(["$(AppIdentifierPrefix)$(BundleID)"]), paid: false,
                   support: .partial("xtool remplace la liste par le seul groupe de l'app (ÉQUIPE.bundleID).")),
        Capability("healthkit", "HealthKit", "Lecture et écriture des données Santé.",
                   .entitlement("com.apple.developer.healthkit"), .bool(true),
                   usage: [("NSHealthShareUsageDescription", "Lecture des données Santé"),
                           ("NSHealthUpdateUsageDescription", "Écriture des données Santé")], paid: false),
        Capability("homekit", "HomeKit", "Contrôle des accessoires de la maison.",
                   .entitlement("com.apple.developer.homekit"), .bool(true),
                   usage: [("NSHomeKitUsageDescription", "Accès à la maison")], paid: false),
        Capability("sign-in-with-apple", "Sign in with Apple", "Connexion avec un identifiant Apple.",
                   .entitlement("com.apple.developer.applesignin"), .list(["Default"]), paid: true),
        Capability("associated-domains", "Associated Domains", "Liens universels, identifiants web partagés.",
                   .entitlement("com.apple.developer.associated-domains"), .list(["applinks:exemple.com"]), paid: true,
                   listHint: "Domaines (applinks:…, webcredentials:…), séparés par des virgules"),
        Capability("siri", "Siri", "Intents et raccourcis Siri.",
                   .entitlement("com.apple.developer.siri"), .bool(true),
                   usage: [("NSSiriUsageDescription", "Utilisation de Siri")], paid: true),
        Capability("network-extensions", "Network Extensions", "Tunnels VPN, filtres de contenu, proxys DNS.",
                   .entitlement("com.apple.developer.networking.networkextension"), .list(["packet-tunnel-provider"]),
                   paid: true, listHint: "Types : packet-tunnel-provider, content-filter-provider, dns-proxy…"),
        Capability("multipath", "Multipath", "Connexions TCP multichemins (Wi-Fi et cellulaire).",
                   .entitlement("com.apple.developer.networking.multipath"), .bool(true), paid: true),
        Capability("wireless-accessory", "Wireless Accessory Configuration", "Configuration Wi-Fi d'accessoires MFi.",
                   .entitlement("com.apple.external-accessory.wireless-configuration"), .bool(true), paid: false),
        Capability("data-protection", "Data Protection", "Chiffrement des fichiers de l'app tant que l'appareil est verrouillé.",
                   .entitlement("com.apple.developer.default-data-protection"), .string("NSFileProtectionComplete"), paid: false),
    ]

    /// Descriptions d'usage courantes (onglet « Info » d'Xcode), utiles avec ou sans capability.
    public static let privacyKeys: [(key: String, label: String)] = [
        ("NSCameraUsageDescription", "Appareil photo"),
        ("NSMicrophoneUsageDescription", "Micro"),
        ("NSPhotoLibraryUsageDescription", "Photothèque (lecture)"),
        ("NSPhotoLibraryAddUsageDescription", "Photothèque (ajout)"),
        ("NSLocationWhenInUseUsageDescription", "Position (app ouverte)"),
        ("NSLocationAlwaysAndWhenInUseUsageDescription", "Position (toujours)"),
        ("NSContactsUsageDescription", "Contacts"),
        ("NSCalendarsFullAccessUsageDescription", "Calendriers"),
        ("NSRemindersFullAccessUsageDescription", "Rappels"),
        ("NSBluetoothAlwaysUsageDescription", "Bluetooth"),
        ("NSFaceIDUsageDescription", "Face ID"),
        ("NSLocalNetworkUsageDescription", "Réseau local"),
        ("NSMotionUsageDescription", "Mouvements et forme"),
        ("NSSpeechRecognitionUsageDescription", "Reconnaissance vocale"),
        ("NSUserTrackingUsageDescription", "Suivi publicitaire (ATT)"),
    ]
}

// MARK: - Projet

/// Réglages de signature d'un projet : bundle ID et références dans `xtool.yml`, entitlements, Info.plist.
public final class ProjectSigning {
    public let root: URL
    /// Nom du fichier d'entitlements créé au besoin (`<nom>.entitlements`, comme Xcode).
    public let name: String

    public init(root: URL, name: String) {
        self.root = root
        self.name = name
    }

    private var configText: String { (try? String(contentsOf: XtoolConfig.url(in: root), encoding: .utf8)) ?? "version: 1\n" }

    private func setConfig(_ key: String, _ value: String?) throws {
        try XtoolConfig.setting(key, to: value, in: configText).write(to: XtoolConfig.url(in: root), atomically: true, encoding: .utf8)
    }

    public var bundleID: String? { XtoolConfig.value("bundleID", in: configText) }
    /// Préfixe d'organisation (si `bundleID` est absent, xtool forme `orgID.produit`).
    public var orgID: String? { XtoolConfig.value("orgID", in: configText) }

    public func setBundleID(_ id: String) throws {
        guard XtoolConfig.isValidBundleID(id) else {
            throw LCodeError("« \(id) » n'est pas un bundle ID valide (ex. : com.exemple.MonApp).")
        }
        try setConfig("bundleID", id)
    }

    public var entitlementsPath: String? { XtoolConfig.value("entitlementsPath", in: configText) }
    public var infoPath: String? { XtoolConfig.value("infoPath", in: configText) }

    private func resolve(_ path: String) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
    }

    // MARK: Fichiers plist

    static func readPlist(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [:] }
        return dict
    }

    static func writePlist(_ dict: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: url, options: .atomic)
    }

    public func entitlements() -> [String: Any] { entitlementsPath.map { Self.readPlist(resolve($0)) } ?? [:] }
    public func info() -> [String: Any] { infoPath.map { Self.readPlist(resolve($0)) } ?? [:] }

    /// Écrit les entitlements ; crée le fichier et sa référence au besoin, les retire quand il n'en reste aucun
    /// (seulement si c'est le fichier créé par LCode).
    func writeEntitlements(_ dict: [String: Any]) throws {
        let ownName = "\(name).entitlements"
        if dict.isEmpty {
            guard let path = entitlementsPath else { return }
            if path == ownName {
                try? FileManager.default.removeItem(at: resolve(path))
                try setConfig("entitlementsPath", nil)
            } else {
                try Self.writePlist(dict, to: resolve(path))
            }
            return
        }
        let path = entitlementsPath ?? ownName
        try Self.writePlist(dict, to: resolve(path))
        if entitlementsPath == nil { try setConfig("entitlementsPath", path) }
    }

    func writeInfo(_ dict: [String: Any]) throws {
        let path = infoPath ?? "Info.plist"
        try Self.writePlist(dict, to: resolve(path))
        if infoPath == nil { try setConfig("infoPath", path) }
    }

    // MARK: Capabilities

    public func isEnabled(_ capability: Capability) -> Bool {
        switch capability.storage {
        case let .entitlement(k): return entitlements()[k] != nil
        case let .infoPlist(k): return info()[k] != nil
        }
    }

    private func plistValue(_ value: Capability.Value) -> Any {
        let bundle = bundleID ?? orgID.map { "\($0).\(name)" } ?? "com.example.\(name)"
        func expand(_ s: String) -> String { s.replacingOccurrences(of: "$(BundleID)", with: bundle) }
        switch value {
        case let .bool(b): return b
        case let .string(s): return expand(s)
        case let .list(l): return l.map(expand)
        }
    }

    public func setEnabled(_ capability: Capability, _ on: Bool) throws {
        switch capability.storage {
        case let .entitlement(k):
            var ents = entitlements()
            ents[k] = on ? (ents[k] ?? plistValue(capability.value)) : nil
            for c in capability.companions { ents[c.key] = on ? (ents[c.key] ?? plistValue(c.value)) : nil }
            try writeEntitlements(ents)
        case let .infoPlist(k):
            var dict = info()
            dict[k] = on ? (dict[k] ?? plistValue(capability.value)) : nil
            try writeInfo(dict)
        }
    }

    /// Valeurs de la liste d'une capability active (groupes, domaines, modes…).
    public func values(_ capability: Capability) -> [String] {
        let dict: [String: Any]
        switch capability.storage {
        case .entitlement: dict = entitlements()
        case .infoPlist: dict = info()
        }
        return dict[capability.key] as? [String] ?? []
    }

    public func setValues(_ capability: Capability, _ values: [String]) throws {
        let clean = values.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        switch capability.storage {
        case let .entitlement(k):
            var ents = entitlements()
            ents[k] = clean
            try writeEntitlements(ents)
        case let .infoPlist(k):
            var dict = info()
            dict[k] = clean
            try writeInfo(dict)
        }
    }

    /// Description d'usage (Info.plist) ; nil si absente.
    public func usage(_ key: String) -> String? { info()[key] as? String }

    /// Définit ou retire (texte vide) une description d'usage.
    public func setUsage(_ key: String, _ text: String) throws {
        var dict = info()
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if (dict[key] as? String) == (t.isEmpty ? nil : t) { return }
        dict[key] = t.isEmpty ? nil : t
        if dict.isEmpty && infoPath == nil { return }
        try writeInfo(dict)
    }
}

// MARK: - Compte Apple (xtool auth)

/// État de connexion d'xtool aux services Apple (`xtool auth status`). LCode ne voit jamais le mot de passe :
/// la connexion par Apple ID se fait dans un terminal, la clé API est lue par xtool depuis le fichier .p8.
public struct AppleAccount: Equatable, Sendable {
    public enum Mode: Equatable, Sendable { case apiKey, appleID }
    public var mode: Mode
    public var keyID: String?
    public var issuerID: String?
    public var appleID: String?
    public var teamID: String?
    public var expiry: String?

    /// Analyse la sortie de `xtool auth status` ; nil si déconnecté.
    public static func parse(status: String) -> AppleAccount? {
        guard status.contains("Logged in") else { return nil }
        func field(_ name: String) -> String? {
            status.split(separator: "\n").first { $0.contains("- \(name):") }
                .map { String($0[$0.range(of: "\(name):")!.upperBound...]).trimmingCharacters(in: .whitespaces) }
        }
        let keyID = field("ASC key ID")
        return AppleAccount(mode: keyID != nil ? .apiKey : .appleID, keyID: keyID, issuerID: field("Issuer ID"),
                            appleID: field("Apple ID"), teamID: field("Team ID"), expiry: field("Token expiry"))
    }

    /// Une équipe de développement (`xtool ds teams list`).
    public struct Team: Equatable, Sendable {
        public var name: String
        public var id: String
        public var status: String
        public var memberships: [String]
        /// Équipe gratuite (« Personal Team ») : apps valables 7 jours, capabilities limitées.
        public var isFree: Bool {
            memberships.isEmpty || memberships.contains { $0.localizedCaseInsensitiveContains("free") }
        }
    }

    /// Analyse `Nom [statut]: ID` suivi de lignes `- adhésion (plateforme)`.
    public static func parse(teams: String) -> [Team] {
        var result: [Team] = []
        for line in teams.split(separator: "\n").map(String.init) {
            if line.hasPrefix("- "), !result.isEmpty {
                result[result.count - 1].memberships.append(String(line.dropFirst(2)))
            } else if let open = line.range(of: " ["), let close = line.range(of: "]: ", range: open.upperBound..<line.endIndex) {
                result.append(Team(name: String(line[..<open.lowerBound]), id: String(line[close.upperBound...]).trimmingCharacters(in: .whitespaces),
                                   status: String(line[open.upperBound..<close.lowerBound]), memberships: []))
            }
        }
        return result
    }

    /// Exécute xtool (sans terminal) ; renvoie le code de retour et la sortie (standard et erreur).
    @discardableResult
    public static func xtool(_ arguments: [String], input: String? = nil, environment: [String: String] = [:]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["xtool"] + arguments
        var env = ProcessInfo.processInfo.environment
        let local = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path
        env["PATH"] = local + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        process.environment = env.merging(environment) { _, n in n }
        let out = Pipe(), inPipe = Pipe()
        process.standardOutput = out
        process.standardError = out
        process.standardInput = inPipe
        do { try process.run() } catch { return (-1, "xtool introuvable : \(error)") }
        if let input { try? inPipe.fileHandleForWriting.write(contentsOf: Data(input.utf8)) }
        try? inPipe.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        return (process.terminationStatus, text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression))
    }

    /// État courant (lecture locale, sans réseau).
    public static func current() -> AppleAccount? { parse(status: xtool(["auth", "status"]).output) }

    /// Équipes du compte (connexion par Apple ID seulement ; interroge Apple).
    public static func teams() -> [Team] {
        let r = xtool(["ds", "teams", "list"])
        return r.status == 0 ? parse(teams: r.output) : []
    }

    /// Connexion par clé API App Store Connect : xtool lit lui-même le fichier .p8 (rien n'est copié ni affiché).
    public static func logIn(keyID: String, issuerID: String, keyFile: URL) throws {
        let r = xtool(["auth", "login", "--mode", "key"], input: "\(keyID)\n\(issuerID)\n\(keyFile.path)\n")
        guard r.status == 0, r.output.contains("Logged in") else {
            throw LCodeError(r.output.split(separator: "\n").filter { !$0.hasSuffix(": ") }.suffix(3).joined(separator: "\n"))
        }
    }

    public static func logOut() throws {
        let r = xtool(["auth", "logout"])
        guard r.status == 0 else { throw LCodeError(r.output) }
    }

    /// Identifiant de clé déduit du nom donné par App Store Connect (`AuthKey_ABC123.p8`).
    public static func keyID(fromFileName name: String) -> String? {
        guard name.hasPrefix("AuthKey_"), name.hasSuffix(".p8") else { return nil }
        let id = String(name.dropFirst("AuthKey_".count).dropLast(3))
        return id.isEmpty ? nil : id
    }

    /// Commande de connexion par Apple ID, à lancer dans un terminal (mot de passe et code saisis par l'utilisateur).
    public static let passwordLoginCommand = ["xtool", "auth", "login", "--mode", "password"]
}

// MARK: - Erreurs de signature

/// Problème de compte, de signature ou de provisionnement relevé dans la sortie de `xtool dev run`.
public struct SigningIssue: Equatable, Sendable {
    /// Explication en français.
    public let message: String
    /// Ligne d'origine d'xtool.
    public let detail: String

    private static let rules: [(patterns: [String], message: String)] = [
        (["Input ended before a response", "Select login mode", "Mode selection is required", "AuthToken"],
         "Aucun compte Apple connecté : connectez-vous (menu › Compte Apple…)."),
        (["multiple app groups"], "Une équipe gratuite n'accepte qu'un seul App Group : retirez les autres."),
        (["maximum number of", "maxAppIds", "10 App IDs", "too many app ids"],
         "Limite d'App IDs atteinte (10 par semaine avec un compte gratuit) : réutilisez un bundle ID existant ou attendez."),
        (["is not available", "already exists", "cannot be registered"],
         "Ce bundle ID est déjà pris par une autre équipe : choisissez-en un autre."),
        (["expired", "NOT_AUTHORIZED", "401", "Unauthorized", "unauthorized", "authentication"],
         "Session Apple expirée ou refusée : reconnectez-vous (menu › Compte Apple…)."),
        (["certificate", "Certificate"],
         "Problème de certificat de développement : vérifiez le nombre de certificats de l'équipe (xtool ds certificates)."),
        (["entitlement", "Entitlement", "capabilit"],
         "Une capability n'est pas autorisée pour cette équipe ou ce profil : vérifiez la page Signature et capabilities."),
        (["provision", "Provision", "profile"], "Profil de provisionnement impossible à obtenir pour cet appareil ou ce bundle ID."),
        (["device", "Device"], "Appareil non enregistré ou injoignable pour la signature."),
    ]

    /// Problèmes de signature d'une sortie de `xtool dev run` (les erreurs du compilateur sont ignorées).
    public static func extract(from output: String) -> [SigningIssue] {
        var issues: [SigningIssue] = []
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // Erreurs de compilation (fichier:ligne:colonne: error:) : ce n'est pas la signature.
            if line.range(of: #"^\S+:\d+:\d+: "#, options: .regularExpression) != nil { continue }
            let isError = line.hasPrefix("Error:") || line.hasPrefix("error:") || line.contains("Console.Error")
                || line.contains("Input ended before a response")
            guard isError else { continue }
            let message = rules.first { rule in rule.patterns.contains { line.contains($0) } }?.message
                ?? "xtool a échoué pendant la préparation ou la signature."
            let issue = SigningIssue(message: message, detail: line)
            if !issues.contains(issue) { issues.append(issue) }
        }
        return issues
    }
}
