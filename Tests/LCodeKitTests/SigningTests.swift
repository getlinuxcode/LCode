import Foundation
import Testing
@testable import LCodeKit

private func tempProject(_ yml: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("lcode-signing-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try yml.write(to: root.appendingPathComponent("xtool.yml"), atomically: true, encoding: .utf8)
    return root
}

@Test func xtoolConfigEditsKeysInPlace() {
    let text = "version: 1\nbundleID: com.example.A # commentaire\nproduct: A\n"
    #expect(XtoolConfig.value("bundleID", in: text) == "com.example.A")
    let changed = XtoolConfig.setting("bundleID", to: "fr.joris.B", in: text)
    #expect(changed == "version: 1\nbundleID: fr.joris.B\nproduct: A\n")
    let added = XtoolConfig.setting("entitlementsPath", to: "A.entitlements", in: changed)
    #expect(added.hasSuffix("product: A\nentitlementsPath: A.entitlements\n"))
    #expect(XtoolConfig.setting("entitlementsPath", to: nil, in: added) == changed)
    #expect(XtoolConfig.value("orgID", in: text) == nil)
}

@Test func bundleIDValidation() {
    #expect(XtoolConfig.isValidBundleID("com.exemple.Mon-App2"))
    #expect(!XtoolConfig.isValidBundleID("MonApp"))
    #expect(!XtoolConfig.isValidBundleID("com..app"))
    #expect(!XtoolConfig.isValidBundleID("com.exemple.mon app"))
}

@Test func capabilitiesWriteEntitlementsAndReference() throws {
    let root = try tempProject("version: 1\nbundleID: com.exemple.Sonde\n")
    defer { try? FileManager.default.removeItem(at: root) }
    let signing = ProjectSigning(root: root, name: "Sonde")
    let groups = Capability.all.first { $0.id == "app-groups" }!
    let health = Capability.all.first { $0.id == "healthkit" }!

    try signing.setEnabled(groups, true)
    #expect(signing.entitlementsPath == "Sonde.entitlements")
    #expect(signing.isEnabled(groups))
    #expect(signing.values(groups) == ["group.com.exemple.Sonde"])
    try signing.setEnabled(health, true)
    #expect(signing.entitlements()["com.apple.developer.healthkit"] as? Bool == true)

    // Le fichier est un plist XML qu'xtool sait lire.
    let xml = try String(contentsOf: root.appendingPathComponent("Sonde.entitlements"), encoding: .utf8)
    #expect(xml.contains("<key>com.apple.security.application-groups</key>"))
    #expect(xml.contains("<true/>"))

    try signing.setValues(groups, ["group.a", " ", "group.b "])
    #expect(signing.values(groups) == ["group.a", "group.b"])

    // Plus aucun entitlement : le fichier et sa référence disparaissent.
    try signing.setEnabled(groups, false)
    try signing.setEnabled(health, false)
    #expect(signing.entitlementsPath == nil)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Sonde.entitlements").path))
}

@Test func infoPlistCapabilitiesAndUsageDescriptions() throws {
    let root = try tempProject("version: 1\nbundleID: com.exemple.Sonde\n")
    defer { try? FileManager.default.removeItem(at: root) }
    let signing = ProjectSigning(root: root, name: "Sonde")
    let background = Capability.all.first { $0.id == "background-modes" }!
    try signing.setEnabled(background, true)
    #expect(signing.infoPath == "Info.plist")
    #expect(signing.values(background) == ["audio"])
    try signing.setUsage("NSCameraUsageDescription", "Pour scanner les codes.")
    #expect(signing.usage("NSCameraUsageDescription") == "Pour scanner les codes.")
    try signing.setUsage("NSCameraUsageDescription", "")
    #expect(signing.usage("NSCameraUsageDescription") == nil)
    #expect(signing.entitlementsPath == nil)
}

@Test func parsesAuthStatusAndTeams() {
    let key = AppleAccount.parse(status: "Logged in.\n- ASC key ID: ABC123\n- Issuer ID: 1111-2222\n")
    #expect(key?.mode == .apiKey)
    #expect(key?.keyID == "ABC123")
    #expect(key?.issuerID == "1111-2222")
    let password = AppleAccount.parse(status: "Logged in.\n- Apple ID: a@b.c\n- Team ID: TEAM42\n- Token expiry: 1/1/2027\n")
    #expect(password?.mode == .appleID)
    #expect(password?.teamID == "TEAM42")
    #expect(AppleAccount.parse(status: "Logged out\n") == nil)

    let teams = AppleAccount.parse(teams: "Jean Dupont [active]: TEAM42\n- Xcode Free Provisioning Program (ios)\nSociété [active]: XYZ9\n- Apple Developer Program (ios)\n")
    #expect(teams.count == 2)
    #expect(teams[0].isFree)
    #expect(!teams[1].isFree)
    #expect(teams[1].id == "XYZ9")
    #expect(AppleAccount.keyID(fromFileName: "AuthKey_46ABC.p8") == "46ABC")
}

@Test func extractsSigningIssuesButNotCompilerErrors() {
    let output = """
    /x/Sources/A/A.swift:3:5: error: cannot find 'x' in scope
    Planning...
    Error: App 'com.a.b' requests multiple app groups: group.a, group.b, which is not permitted when using a free team.
    Error: Input ended before a response was received.
    """
    let issues = SigningIssue.extract(from: output)
    #expect(issues.count == 2)
    #expect(issues[0].message.contains("seul App Group"))
    #expect(issues[1].message.contains("Aucun compte Apple"))
}
