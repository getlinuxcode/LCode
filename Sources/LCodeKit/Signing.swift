import Foundation

// Signing & Capabilities for an xtool project.
//
// What xtool does (v1.24 sources, PackLib/PackSchema.swift and XKit/DeveloperServices):
// - `xtool.yml` holds `bundleID` (or `orgID`), `infoPath` (merged into the Info.plist xtool generates)
//   and `entitlementsPath` (relative to the project);
// - when signing, it enables on the App ID the capabilities it can map to an entitlement (App Groups,
//   Push, HealthKit…), drops paid-only ones for free teams, and overwrites `application-identifier`,
//   `team-identifier` and `keychain-access-groups` itself.

// MARK: - xtool.yml

/// Reads and edits simple top-level keys of `xtool.yml`, leaving the rest of the file untouched.
public enum XtoolConfig {
    public static func url(in root: URL) -> URL { root.appendingPathComponent("xtool.yml") }

    public static func value(_ key: String, in text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) where line.hasPrefix(key + ":") {
            var v = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
            if let hash = v.range(of: " #") { v = String(v[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces) }
            if v.count >= 2, let q = v.first, q == "\"" || q == "'", v.last == q { v = String(v.dropFirst().dropLast()) }
            return v.isEmpty ? nil : v
        }
        return nil
    }

    /// The text with the key replaced, appended, or removed (`value` nil).
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

    /// Letters, digits, hyphens and dots, at least two components.
    public static func isValidBundleID(_ id: String) -> Bool {
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.allSatisfy { p in
            !p.isEmpty && p.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }
}

// MARK: - Capabilities

/// An Apple capability: its entitlement(s) and related Info.plist keys.
/// Titles are Apple's names; summaries, hints and labels are English and translated by the IDE.
public struct Capability: Sendable {
    /// What xtool does with it when signing.
    public enum Support: Sendable, Equatable {
        /// xtool enables it on the App ID and keeps it in the profile.
        case xtool
        /// Plain Info.plist key: nothing to enable on Apple's side.
        case infoPlist
        /// Partial support (explanation).
        case partial(String)
        /// xtool cannot enable it: iOS will likely refuse to install (explanation).
        case unsupported(String)
    }

    /// Where the main value lives (its presence means the capability is on).
    public enum Storage: Sendable, Equatable { case entitlement(String), infoPlist(String) }

    public enum Value: Sendable, Equatable {
        case bool(Bool)
        case string(String)
        /// List editable in the IDE (groups, domains, modes…). `$(BundleID)` is expanded.
        case list([String])
    }

    public let id: String
    public let title: String
    public let summary: String
    public let storage: Storage
    public let value: Value
    /// Entitlements added alongside (iCloud…).
    public let companions: [(key: String, value: Value)]
    /// Usage descriptions (Info.plist) iOS requires: key, label.
    public let usageKeys: [(key: String, label: String)]
    /// Paid program only (xtool drops it for a free team).
    public let requiresPaidAccount: Bool
    public let support: Support
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

    /// Common capabilities, in page order.
    public static let all: [Capability] = [
        Capability("app-groups", "App Groups", "Share data between the app and its extensions.",
                   .entitlement("com.apple.security.application-groups"), .list(["group.$(BundleID)"]),
                   paid: false, listHint: "Groups (group.…), comma-separated — only one with a free account"),
        Capability("push", "Push Notifications", "Remote notifications (APNs).",
                   .entitlement("aps-environment"), .string("development"), paid: true),
        Capability("background-modes", "Background Modes", "Run in the background (audio, location, downloads…).",
                   .infoPlist("UIBackgroundModes"), .list(["audio"]), paid: false, support: .infoPlist,
                   listHint: "Modes: audio, location, fetch, remote-notification, processing, voip, bluetooth-central…"),
        Capability("icloud", "iCloud", "CloudKit and iCloud key-value storage.",
                   .entitlement("com.apple.developer.icloud-services"), .list(["CloudKit"]),
                   companions: [("com.apple.developer.icloud-container-identifiers", .list(["iCloud.$(BundleID)"])),
                                ("com.apple.developer.ubiquity-kvstore-identifier", .string("$(TeamIdentifierPrefix)$(BundleID)"))],
                   paid: true, support: .unsupported("xtool does not enable iCloud on the App ID: the profile will lack "
                       + "the entitlement and iOS will refuse to install the app."),
                   listHint: "Services: CloudKit, CloudDocuments"),
        Capability("keychain-sharing", "Keychain Sharing", "Share the keychain between your apps.",
                   .entitlement("keychain-access-groups"), .list(["$(AppIdentifierPrefix)$(BundleID)"]), paid: false,
                   support: .partial("xtool replaces the list with the app's own group (TEAM.bundleID).")),
        Capability("healthkit", "HealthKit", "Read and write Health data.",
                   .entitlement("com.apple.developer.healthkit"), .bool(true),
                   usage: [("NSHealthShareUsageDescription", "Read Health data"),
                           ("NSHealthUpdateUsageDescription", "Write Health data")], paid: false),
        Capability("homekit", "HomeKit", "Control home accessories.",
                   .entitlement("com.apple.developer.homekit"), .bool(true),
                   usage: [("NSHomeKitUsageDescription", "Home access")], paid: false),
        Capability("sign-in-with-apple", "Sign in with Apple", "Sign in with an Apple Account.",
                   .entitlement("com.apple.developer.applesignin"), .list(["Default"]), paid: true),
        Capability("associated-domains", "Associated Domains", "Universal links, shared web credentials.",
                   .entitlement("com.apple.developer.associated-domains"), .list(["applinks:example.com"]), paid: true,
                   listHint: "Domains (applinks:…, webcredentials:…), comma-separated"),
        Capability("siri", "Siri", "Siri intents and shortcuts.",
                   .entitlement("com.apple.developer.siri"), .bool(true),
                   usage: [("NSSiriUsageDescription", "Siri usage")], paid: true),
        Capability("network-extensions", "Network Extensions", "VPN tunnels, content filters, DNS proxies.",
                   .entitlement("com.apple.developer.networking.networkextension"), .list(["packet-tunnel-provider"]),
                   paid: true, listHint: "Types: packet-tunnel-provider, content-filter-provider, dns-proxy…"),
        Capability("multipath", "Multipath", "Multipath TCP connections (Wi-Fi and cellular).",
                   .entitlement("com.apple.developer.networking.multipath"), .bool(true), paid: true),
        Capability("wireless-accessory", "Wireless Accessory Configuration", "Wi-Fi configuration of MFi accessories.",
                   .entitlement("com.apple.external-accessory.wireless-configuration"), .bool(true), paid: false),
        Capability("data-protection", "Data Protection", "Encrypt the app's files while the device is locked.",
                   .entitlement("com.apple.developer.default-data-protection"), .string("NSFileProtectionComplete"), paid: false),
    ]

    /// Common usage descriptions (Xcode's Info tab), useful with or without a capability.
    public static let privacyKeys: [(key: String, label: String)] = [
        ("NSCameraUsageDescription", "Camera"),
        ("NSMicrophoneUsageDescription", "Microphone"),
        ("NSPhotoLibraryUsageDescription", "Photo Library"),
        ("NSPhotoLibraryAddUsageDescription", "Photo Library (add only)"),
        ("NSLocationWhenInUseUsageDescription", "Location (when in use)"),
        ("NSLocationAlwaysAndWhenInUseUsageDescription", "Location (always)"),
        ("NSContactsUsageDescription", "Contacts"),
        ("NSCalendarsFullAccessUsageDescription", "Calendars"),
        ("NSRemindersFullAccessUsageDescription", "Reminders"),
        ("NSBluetoothAlwaysUsageDescription", "Bluetooth"),
        ("NSFaceIDUsageDescription", "Face ID"),
        ("NSLocalNetworkUsageDescription", "Local Network"),
        ("NSMotionUsageDescription", "Motion & Fitness"),
        ("NSSpeechRecognitionUsageDescription", "Speech Recognition"),
        ("NSUserTrackingUsageDescription", "Tracking (ATT)"),
    ]
}

// MARK: - Project

/// A project's signing settings: bundle ID and references in `xtool.yml`, entitlements, Info.plist.
public final class ProjectSigning {
    public let root: URL
    /// Base name of the entitlements file created on demand (`<name>.entitlements`, like Xcode).
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
    /// Organization prefix (without `bundleID`, xtool uses `orgID.product`).
    public var orgID: String? { XtoolConfig.value("orgID", in: configText) }

    public func setBundleID(_ id: String) throws {
        guard XtoolConfig.isValidBundleID(id) else {
            throw LCodeError("\"\(id)\" is not a valid bundle ID (e.g. com.example.MyApp).")
        }
        try setConfig("bundleID", id)
    }

    public var entitlementsPath: String? { XtoolConfig.value("entitlementsPath", in: configText) }
    public var infoPath: String? { XtoolConfig.value("infoPath", in: configText) }

    private func resolve(_ path: String) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
    }

    // MARK: Plist files

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

    /// Writes the entitlements, creating the file and its reference on demand; removes them when empty
    /// (only if LCode created the file).
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

    public func usage(_ key: String) -> String? { info()[key] as? String }

    /// Sets or removes (empty text) a usage description.
    public func setUsage(_ key: String, _ text: String) throws {
        var dict = info()
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if (dict[key] as? String) == (t.isEmpty ? nil : t) { return }
        dict[key] = t.isEmpty ? nil : t
        if dict.isEmpty && infoPath == nil { return }
        try writeInfo(dict)
    }
}

// MARK: - Apple account (xtool auth)

/// xtool's Apple sign-in state (`xtool auth status`). LCode never sees the password: Apple ID sign-in
/// happens in a terminal, and xtool reads the API key from the .p8 file itself.
public struct AppleAccount: Equatable, Sendable {
    public enum Mode: Equatable, Sendable { case apiKey, appleID }
    public var mode: Mode
    public var keyID: String?
    public var issuerID: String?
    public var appleID: String?
    public var teamID: String?
    public var expiry: String?

    /// Parses `xtool auth status`; nil when signed out.
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

    /// A development team (`xtool ds teams list`).
    public struct Team: Equatable, Sendable {
        public var name: String
        public var id: String
        public var status: String
        public var memberships: [String]
        /// Free "Personal Team": apps last 7 days, limited capabilities.
        public var isFree: Bool {
            memberships.isEmpty || memberships.contains { $0.localizedCaseInsensitiveContains("free") }
        }
    }

    /// Parses `Name [status]: ID` followed by `- membership (platform)` lines.
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

    /// Runs xtool without a terminal; returns the exit status and combined output.
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
        do { try process.run() } catch { return (-1, "xtool not found: \(error)") }
        if let input { try? inPipe.fileHandleForWriting.write(contentsOf: Data(input.utf8)) }
        try? inPipe.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        return (process.terminationStatus, text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression))
    }

    /// Current state (local, no network).
    public static func current() -> AppleAccount? { parse(status: xtool(["auth", "status"]).output) }

    /// The account's teams (Apple ID sign-in only; queries Apple).
    public static func teams() -> [Team] {
        let r = xtool(["ds", "teams", "list"])
        return r.status == 0 ? parse(teams: r.output) : []
    }

    /// App Store Connect API key sign-in: xtool reads the .p8 itself (nothing is copied or shown).
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

    /// Key ID from App Store Connect's file name (`AuthKey_ABC123.p8`).
    public static func keyID(fromFileName name: String) -> String? {
        guard name.hasPrefix("AuthKey_"), name.hasSuffix(".p8") else { return nil }
        let id = String(name.dropFirst("AuthKey_".count).dropLast(3))
        return id.isEmpty ? nil : id
    }

    /// Apple ID sign-in command, run in a terminal (the user types the password and code).
    public static let passwordLoginCommand = ["xtool", "auth", "login", "--mode", "password"]
}

// MARK: - Signing errors

/// Account, signing or provisioning problem found in `xtool dev run` output.
public struct SigningIssue: Equatable, Sendable {
    /// Explanation in English; the IDE displays it through `tr`.
    public let message: String
    /// Original xtool line.
    public let detail: String

    public static let noAccount = "No Apple account signed in: sign in (menu › Apple Account…)."
    public static let fallback = "xtool failed while preparing or signing the app."
    /// Every message `extract` can produce.
    public static var allMessages: [String] { rules.map(\.message) + [fallback] }

    public var needsAccount: Bool { message == Self.noAccount }

    private static let rules: [(patterns: [String], message: String)] = [
        (["Input ended before a response", "Select login mode", "Mode selection is required", "AuthToken"],
         noAccount),
        (["multiple app groups"], "A free team allows only one App Group: remove the others."),
        (["maximum number of", "maxAppIds", "10 App IDs", "too many app ids"],
         "App ID limit reached (10 per week with a free account): reuse an existing bundle ID or wait."),
        (["is not available", "already exists", "cannot be registered"],
         "This bundle ID is already taken by another team: choose another one."),
        (["expired", "NOT_AUTHORIZED", "401", "Unauthorized", "unauthorized", "authentication"],
         "Apple session expired or rejected: sign in again (menu › Apple Account…)."),
        (["certificate", "Certificate"],
         "Development certificate problem: check the team's certificate count (xtool ds certificates)."),
        (["entitlement", "Entitlement", "capabilit"],
         "A capability is not allowed for this team or profile: check Signing & Capabilities."),
        (["provision", "Provision", "profile"], "Could not get a provisioning profile for this device or bundle ID."),
        (["device", "Device"], "Device not registered or unreachable for signing."),
    ]

    /// Signing problems in `xtool dev run` output (compiler errors are ignored).
    public static func extract(from output: String) -> [SigningIssue] {
        var issues: [SigningIssue] = []
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.range(of: #"^\S+:\d+:\d+: "#, options: .regularExpression) != nil { continue }
            let isError = line.hasPrefix("Error:") || line.hasPrefix("error:") || line.contains("Console.Error")
                || line.contains("Input ended before a response")
            guard isError else { continue }
            let message = rules.first { rule in rule.patterns.contains { line.contains($0) } }?.message
                ?? fallback
            let issue = SigningIssue(message: message, detail: line)
            if !issues.contains(issue) { issues.append(issue) }
        }
        return issues
    }
}
