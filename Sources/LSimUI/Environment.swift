import Foundation

public protocol EnvironmentKey {
    associatedtype Value
    static var defaultValue: Value { get }
}

public struct EnvironmentValues {
    public var font: Font?
    public var fontWeight: Font.Weight?
    public var isItalic = false
    public var foregroundColor: Color?
    public var tint: Color?
    public var colorScheme: ColorScheme = .light
    public var multilineTextAlignment: TextAlignment = .leading
    public var isEnabled = true
    public var textCase: Text.Case?
    var buttonStyle: _ButtonStyleKind = .automatic
    public var controlSize: ControlSize = .regular
    public var buttonBorderShape: ButtonBorderShape = .automatic

    private var custom: [ObjectIdentifier: Any] = [:]

    public init() {}

    public subscript<K: EnvironmentKey>(key: K.Type) -> K.Value {
        get { custom[ObjectIdentifier(key)] as? K.Value ?? K.defaultValue }
        set { custom[ObjectIdentifier(key)] = newValue }
    }
}

/// Lecture d'une valeur d'environnement dans une vue : `@Environment(\.colorScheme) var scheme`.
@propertyWrapper
public struct Environment<Value>: _DynamicProperty {
    final class Box { var values: EnvironmentValues? }

    let keyPath: KeyPath<EnvironmentValues, Value>
    let box = Box()

    public init(_ keyPath: KeyPath<EnvironmentValues, Value>) {
        self.keyPath = keyPath
    }

    public var wrappedValue: Value {
        (box.values ?? EnvironmentValues())[keyPath: keyPath]
    }

    func _install(_ context: _InstallContext) {
        box.values = context.environment
    }
}
