// Module importé par le code utilisateur sous le nom `SwiftUI` lors d'un build simulateur.
// Il réexporte LSimUI (l'API) et branche le point d'entrée `@main` sur le simulateur.
@_exported import Foundation
@_exported import LSimUI
@_exported import Observation
import LSimHost

extension App {
    public static func main() {
        SimulatorHost.run(Self.init())
    }
}

/// Aperçus (`#Preview`) : l'IDE transforme chaque bloc en fonction et lance celle-ci par ce point d'entrée.
public enum _LSimPreview {
    public static func run<V: View>(@ViewBuilder _ content: @escaping () -> V) {
        SimulatorHost.runPreview(content)
    }
}

