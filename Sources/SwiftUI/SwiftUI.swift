// Imported by user code as `SwiftUI` in simulator builds: re-exports LSimUI and routes `@main` to the simulator.
@_exported import Combine
@_exported import Foundation
@_exported import LSimUI
@_exported import Observation
import LSimHost

extension App {
    public static func main() {
        SimulatorHost.run(Self.init())
    }
}

/// Entry point for `#Preview`: the IDE turns each preview block into a function launched through here.
public enum _LSimPreview {
    public static func run<V: View>(@ViewBuilder _ content: @escaping () -> V) {
        SimulatorHost.runPreview(content)
    }
}

