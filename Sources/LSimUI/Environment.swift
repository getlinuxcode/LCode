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
    public var imageScale: Image.Scale = .medium
    /// Set by `aspectRatio`, `scaledToFit` or `scaledToFill` (nil: a resizable image stretches).
    public var imageContentMode: ContentMode?
    var buttonStyle: _ButtonStyleKind = .automatic
    public var controlSize: ControlSize = .regular
    public var buttonBorderShape: ButtonBorderShape = .automatic
    public var labelStyle: _LabelStyleKind = .automatic
    public var labelsHidden = false
    public var textFieldStyle: _TextFieldStyleKind = .automatic
    public var pickerStyle: _PickerStyleKind = .automatic
    var onSubmit: (() -> Void)?

    private var custom: [ObjectIdentifier: Any] = [:]
    /// Objects set with `.environment(object)`, keyed by type.
    var objects: [ObjectIdentifier: AnyObject] = [:]

    public init() {}

    public subscript<K: EnvironmentKey>(key: K.Type) -> K.Value {
        get { custom[ObjectIdentifier(key)] as? K.Value ?? K.defaultValue }
        set { custom[ObjectIdentifier(key)] = newValue }
    }
}

@propertyWrapper
public struct Environment<Value>: _DynamicProperty {
    final class Box { var values: EnvironmentValues? }

    let read: (EnvironmentValues) -> Value
    let box = Box()

    public init(_ keyPath: KeyPath<EnvironmentValues, Value>) {
        read = { $0[keyPath: keyPath] }
    }

    public init(_ objectType: Value.Type) where Value: AnyObject {
        read = { $0.object(objectType) }
    }

    public var wrappedValue: Value {
        read(box.values ?? EnvironmentValues())
    }

    func _install(_ context: _InstallContext) {
        box.values = context.environment
    }
}
