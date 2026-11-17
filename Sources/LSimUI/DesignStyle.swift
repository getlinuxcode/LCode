import Foundation

/// iOS design generation the simulator reproduces. iOS only enables Liquid Glass for apps linked
/// against the iOS 26 SDK or later; others run in compatibility mode (iOS 18 look).
public enum DesignStyle: Sendable {
    case liquidGlass
    case compatibility

    nonisolated(unsafe) public static var current: DesignStyle = .liquidGlass
}
