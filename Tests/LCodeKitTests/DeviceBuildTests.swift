import Foundation
@testable import LCodeKit
import Testing

@Test func deploymentTargetFromManifest() {
    #expect(DeviceBuild.deploymentTarget("platforms: [.iOS(.v17), .macOS(.v14)]") == "17.0")
    #expect(DeviceBuild.deploymentTarget("platforms: [.iOS(.v16_4)]") == "16.4")
    #expect(DeviceBuild.deploymentTarget("no platforms") == "17.0")
}
