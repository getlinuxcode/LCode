import Foundation

@resultBuilder
public enum ViewBuilder {
    public static func buildBlock() -> EmptyView { EmptyView() }

    public static func buildBlock<Content: View>(_ content: Content) -> Content { content }

    public static func buildBlock<each Content: View>(_ content: repeat each Content) -> TupleView<repeat each Content> {
        TupleView(repeat each content)
    }

    public static func buildExpression<Content: View>(_ content: Content) -> Content { content }

    public static func buildIf<Content: View>(_ content: Content?) -> Content? { content }

    public static func buildOptional<Content: View>(_ content: Content?) -> Content? { content }

    public static func buildEither<T: View, F: View>(first: T) -> _ConditionalContent<T, F> {
        _ConditionalContent(storage: .trueContent(first))
    }

    public static func buildEither<T: View, F: View>(second: F) -> _ConditionalContent<T, F> {
        _ConditionalContent(storage: .falseContent(second))
    }

    public static func buildLimitedAvailability<Content: View>(_ content: Content) -> AnyView { AnyView(content) }
}

public struct TupleView<each Content: View>: View, _PrimitiveView {
    public typealias Body = Never
    public let value: (repeat each Content)

    public init(_ value: repeat each Content) {
        self.value = (repeat each value)
    }

    public func _makeNodes(_ context: BuildContext) -> [LayoutNode] {
        var nodes: [LayoutNode] = []
        var index = 0
        for child in repeat each value {
            nodes += LSimUI._makeNodes(child, context.child("\(index)"))
            index += 1
        }
        return nodes
    }
}

public struct _ConditionalContent<TrueContent: View, FalseContent: View>: View, _PrimitiveView {
    public typealias Body = Never
    enum Storage {
        case trueContent(TrueContent)
        case falseContent(FalseContent)
    }

    let storage: Storage

    public func _makeNodes(_ context: BuildContext) -> [LayoutNode] {
        switch storage {
        case let .trueContent(v): LSimUI._makeNodes(v, context.child("T"))
        case let .falseContent(v): LSimUI._makeNodes(v, context.child("F"))
        }
    }
}

extension Optional: View where Wrapped: View {
    public typealias Body = Never
}

extension Optional: _PrimitiveView where Wrapped: View {
    public func _makeNodes(_ context: BuildContext) -> [LayoutNode] {
        guard let wrapped = self else { return [] }
        return LSimUI._makeNodes(wrapped, context.child("some"))
    }
}

public struct EmptyView: View, _PrimitiveView {
    public typealias Body = Never
    public init() {}
    public func _makeNodes(_ context: BuildContext) -> [LayoutNode] { [] }
}

public struct Group<Content: View>: View, _PrimitiveView {
    public typealias Body = Never
    let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public func _makeNodes(_ context: BuildContext) -> [LayoutNode] {
        LSimUI._makeNodes(content, context)
    }
}

public struct AnyView: View, _PrimitiveView {
    public typealias Body = Never
    let make: (BuildContext) -> [LayoutNode]

    public init<V: View>(_ view: V) {
        make = { LSimUI._makeNodes(view, $0.child("Any<\(V.self)>")) }
    }

    public func _makeNodes(_ context: BuildContext) -> [LayoutNode] { make(context) }
}

public struct ForEach<Data: RandomAccessCollection, ID: Hashable, Content: View>: View, _PrimitiveView {
    public typealias Body = Never
    let data: Data
    let id: KeyPath<Data.Element, ID>
    let content: (Data.Element) -> Content

    public init(_ data: Data, id: KeyPath<Data.Element, ID>, @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.data = data
        self.id = id
        self.content = content
    }

    public func _makeNodes(_ context: BuildContext) -> [LayoutNode] {
        data.flatMap { element in
            LSimUI._makeNodes(content(element), context.child("id:\(element[keyPath: id])"))
        }
    }
}

extension ForEach where Data == Range<Int>, ID == Int {
    public init(_ data: Range<Int>, @ViewBuilder content: @escaping (Int) -> Content) {
        self.init(data, id: \.self, content: content)
    }
}

extension ForEach where Data.Element: Identifiable, ID == Data.Element.ID {
    public init(_ data: Data, @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.init(data, id: \.id, content: content)
    }
}
