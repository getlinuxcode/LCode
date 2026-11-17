import Foundation
import LSimUI

/// Physical characteristics of a simulated device, in points.
public struct DeviceProfile: Sendable {
    public var name: String
    public var screenSize: CGSize
    public var safeArea: EdgeInsets
    public var cornerRadius: CGFloat
    public var hasDynamicIsland: Bool
    public var bezel: CGFloat

    public static let iPhone16Pro = DeviceProfile(
        name: "iPhone 16 Pro",
        screenSize: CGSize(width: 402, height: 874),
        safeArea: EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0),
        cornerRadius: 55,
        hasDynamicIsland: true,
        bezel: 14
    )

    public static let iPhone17ProMax = DeviceProfile(
        name: "iPhone 17 Pro Max",
        screenSize: CGSize(width: 440, height: 956),
        safeArea: EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0),
        cornerRadius: 62,
        hasDynamicIsland: true,
        bezel: 14
    )

    public static let iPhoneSE = DeviceProfile(
        name: "iPhone SE",
        screenSize: CGSize(width: 375, height: 667),
        safeArea: EdgeInsets(top: 20, leading: 0, bottom: 0, trailing: 0),
        cornerRadius: 0,
        hasDynamicIsland: false,
        bezel: 14
    )

    public static let all: [String: DeviceProfile] = [
        "iphone16pro": .iPhone16Pro,
        "iphone17promax": .iPhone17ProMax,
        "iphonese": .iPhoneSE,
    ]

    var screenRect: CGRect { CGRect(origin: .zero, size: screenSize) }

    var contentRect: CGRect {
        CGRect(
            x: safeArea.leading,
            y: safeArea.top,
            width: screenSize.width - safeArea.leading - safeArea.trailing,
            height: screenSize.height - safeArea.top - safeArea.bottom
        )
    }
}
