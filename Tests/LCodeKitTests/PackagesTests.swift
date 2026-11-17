import Foundation
import Testing
@testable import LCodeKit

@Test func packageIdentityFollowsSwiftPM() {
    #expect(PackageManager.identity(of: "https://github.com/apple/swift-algorithms") == "swift-algorithms")
    #expect(PackageManager.identity(of: "https://github.com/Exyte/Popup.git") == "popup")
}

@Test func detectsSwiftUIImports() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("lcode-test-\(UUID().uuidString)")
    let sources = root.appendingPathComponent("Sources/A")
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "import Foundation\n// import SwiftUI dans un commentaire\n".write(to: sources.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
    #expect(!PackageOverlay.importsSwiftUI(root))
    try "@preconcurrency import SwiftUI\n".write(to: sources.appendingPathComponent("B.swift"), atomically: true, encoding: .utf8)
    #expect(PackageOverlay.importsSwiftUI(root))
}

@Test func removesDependencyAndProducts() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("lcode-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try """
    let package = Package(
        dependencies: [
            .package(url: "https://github.com/apple/swift-algorithms", from: "1.2.0"),
            .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2"),
        ],
        targets: [
            .target(name: "App", dependencies: [
                .product(name: "Algorithms", package: "swift-algorithms"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]),
        ]
    )
    """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    try PackageManager.removeDependency(identity: "swift-argument-parser", root: root)
    let manifest = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
    #expect(!manifest.contains("argument-parser"))
    #expect(manifest.contains("swift-algorithms"))
}
