import Foundation

/// Génération de design iOS reproduite par le simulateur.
///
/// iOS n'active Liquid Glass que pour les apps liées avec le SDK d'iOS 26 ou plus ;
/// les autres s'affichent en mode compatibilité (style iOS 18).
public enum DesignStyle: Sendable {
    case liquidGlass
    case compatibility

    nonisolated(unsafe) public static var current: DesignStyle = .liquidGlass
}
