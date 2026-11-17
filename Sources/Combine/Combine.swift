import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Combine for LSim (Linux has no Apple framework): the API surface apps and packages actually use.
// Subscriptions are simplified: no demand (backpressure), every value is delivered as soon as it is sent.

// MARK: - Subscriptions

public protocol Cancellable {
    func cancel()
}

public final class AnyCancellable: Cancellable, Hashable {
    private var action: (() -> Void)?
    private let lock = NSLock()

    public init(_ cancel: @escaping () -> Void) { action = cancel }
    public init<C: Cancellable>(_ canceller: C) { action = { canceller.cancel() } }

    public func cancel() {
        lock.lock()
        let a = action
        action = nil
        lock.unlock()
        a?()
    }

    deinit { cancel() }

    public func store(in set: inout Set<AnyCancellable>) { set.insert(self) }
    public func store<C: RangeReplaceableCollection>(in collection: inout C) where C.Element == AnyCancellable {
        collection.append(self)
    }

    public static func == (a: AnyCancellable, b: AnyCancellable) -> Bool { a === b }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

public enum Subscribers {
    public enum Completion<Failure: Error> {
        case finished
        case failure(Failure)
    }

    public struct Demand: Equatable, Hashable, Sendable {
        let max: Int?
        public static let unlimited = Demand(max: nil)
        public static let none = Demand(max: 0)
        public static func max(_ value: Int) -> Demand { Demand(max: value) }
    }
}

extension Subscribers.Completion: Equatable where Failure: Equatable {}

// MARK: - Publisher

/// In LSim, subscribing goes through `_subscribe` (values, then an optional completion).
public protocol Publisher<Output, Failure> {
    associatedtype Output
    associatedtype Failure: Error

    func _subscribe(_ receiveValue: @escaping (Output) -> Void,
                    _ receiveCompletion: @escaping (Subscribers.Completion<Failure>) -> Void) -> AnyCancellable
}

/// Publisher defined by its subscribe function (backs the operators).
public struct _ClosurePublisher<Output, Failure: Error>: Publisher {
    let body: (@escaping (Output) -> Void, @escaping (Subscribers.Completion<Failure>) -> Void) -> AnyCancellable
    public func _subscribe(_ v: @escaping (Output) -> Void, _ c: @escaping (Subscribers.Completion<Failure>) -> Void) -> AnyCancellable {
        body(v, c)
    }
}

public struct AnyPublisher<Output, Failure: Error>: Publisher {
    let body: (@escaping (Output) -> Void, @escaping (Subscribers.Completion<Failure>) -> Void) -> AnyCancellable

    public init<P: Publisher>(_ publisher: P) where P.Output == Output, P.Failure == Failure {
        body = { publisher._subscribe($0, $1) }
    }

    public func _subscribe(_ v: @escaping (Output) -> Void, _ c: @escaping (Subscribers.Completion<Failure>) -> Void) -> AnyCancellable {
        body(v, c)
    }
}

extension Publisher {
    public func eraseToAnyPublisher() -> AnyPublisher<Output, Failure> { AnyPublisher(self) }

    func make<O, F: Error>(_ body: @escaping (@escaping (O) -> Void, @escaping (Subscribers.Completion<F>) -> Void) -> AnyCancellable)
        -> AnyPublisher<O, F> {
        AnyPublisher(_ClosurePublisher(body: body))
    }

    // MARK: Subscribers

    public func sink(receiveCompletion: @escaping (Subscribers.Completion<Failure>) -> Void,
                     receiveValue: @escaping (Output) -> Void) -> AnyCancellable {
        _subscribe(receiveValue, receiveCompletion)
    }

    public func assign<Root: AnyObject>(to keyPath: ReferenceWritableKeyPath<Root, Output>, on object: Root) -> AnyCancellable
        where Failure == Never {
        _subscribe({ object[keyPath: keyPath] = $0 }, { _ in })
    }
}

extension Publisher where Failure == Never {
    public func sink(receiveValue: @escaping (Output) -> Void) -> AnyCancellable {
        _subscribe(receiveValue, { _ in })
    }

    /// `publisher.assign(to: &$property)`: the subscription lives as long as the object.
    public func assign(to published: inout Published<Output>.Publisher) {
        let subject = published.subject
        let token = _subscribe({ subject.send($0) }, { _ in })
        published.subject.retain(token)
    }
}

// MARK: - Simple publishers

public struct Just<Output>: Publisher {
    public typealias Failure = Never
    public let output: Output
    public init(_ output: Output) { self.output = output }
    public func _subscribe(_ v: @escaping (Output) -> Void, _ c: @escaping (Subscribers.Completion<Never>) -> Void) -> AnyCancellable {
        v(output)
        c(.finished)
        return AnyCancellable {}
    }
}

public struct Empty<Output, Failure: Error>: Publisher {
    public let completeImmediately: Bool
    public init(completeImmediately: Bool = true) { self.completeImmediately = completeImmediately }
    public init(completeImmediately: Bool = true, outputType: Output.Type, failureType: Failure.Type) {
        self.completeImmediately = completeImmediately
    }
    public func _subscribe(_ v: @escaping (Output) -> Void, _ c: @escaping (Subscribers.Completion<Failure>) -> Void) -> AnyCancellable {
        if completeImmediately { c(.finished) }
        return AnyCancellable {}
    }
}

public struct Fail<Output, Failure: Error>: Publisher {
    public let error: Failure
    public init(error: Failure) { self.error = error }
    public init(outputType: Output.Type, failure: Failure) { error = failure }
    public func _subscribe(_ v: @escaping (Output) -> Void, _ c: @escaping (Subscribers.Completion<Failure>) -> Void) -> AnyCancellable {
        c(.failure(error))
        return AnyCancellable {}
    }
}

/// The promise runs once; its result is replayed to later subscribers.
public final class Future<Output, Failure: Error>: Publisher {
    public typealias Promise = (Result<Output, Failure>) -> Void
    private var result: Result<Output, Failure>?
    private var waiting: [UUID: ((Output) -> Void, (Subscribers.Completion<Failure>) -> Void)] = [:]
    private let lock = NSLock()

    public init(_ attemptToFulfill: @escaping (@escaping Promise) -> Void) {
        attemptToFulfill { [weak self] result in self?.fulfill(result) }
    }

    private func fulfill(_ r: Result<Output, Failure>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = r
        let w = waiting
        waiting = [:]
        lock.unlock()
        for (v, c) in w.values { Self.deliver(r, v, c) }
    }

    private static func deliver(_ r: Result<Output, Failure>, _ v: (Output) -> Void, _ c: (Subscribers.Completion<Failure>) -> Void) {
        switch r {
        case let .success(value): v(value); c(.finished)
        case let .failure(error): c(.failure(error))
        }
    }

    public func _subscribe(_ v: @escaping (Output) -> Void, _ c: @escaping (Subscribers.Completion<Failure>) -> Void) -> AnyCancellable {
        lock.lock()
        if let result {
            lock.unlock()
            Self.deliver(result, v, c)
            return AnyCancellable {}
        }
        let id = UUID()
        waiting[id] = (v, c)
        lock.unlock()
        return AnyCancellable { [weak self] in
            self?.lock.lock()
            self?.waiting[id] = nil
            self?.lock.unlock()
        }
    }
}

public struct Deferred<DeferredPublisher: Publisher>: Publisher {
    public typealias Output = DeferredPublisher.Output
    public typealias Failure = DeferredPublisher.Failure
    public let createPublisher: () -> DeferredPublisher
    public init(createPublisher: @escaping () -> DeferredPublisher) { self.createPublisher = createPublisher }
    public func _subscribe(_ v: @escaping (Output) -> Void, _ c: @escaping (Subscribers.Completion<Failure>) -> Void) -> AnyCancellable {
        createPublisher()._subscribe(v, c)
    }
}

// MARK: - Subjects

public protocol Subject<Output, Failure>: AnyObject, Publisher {
    func send(_ value: Output)
    func send(completion: Subscribers.Completion<Failure>)
}

extension Subject where Output == Void {
    public func send() { send(()) }
}

/// Common subject base: lock-protected subscriber list.
public class _SubjectBase<Output, Failure: Error> {
    typealias Entry = (value: (Output) -> Void, completion: (Subscribers.Completion<Failure>) -> Void)
    var subscribers: [UUID: Entry] = [:]
    var completion: Subscribers.Completion<Failure>?
    let lock = NSRecursiveLock()
    private var retained: [AnyCancellable] = []

    func retain(_ token: AnyCancellable) {
        lock.lock(); retained.append(token); lock.unlock()
    }

    func add(_ v: @escaping (Output) -> Void, _ c: @escaping (Subscribers.Completion<Failure>) -> Void) -> AnyCancellable {
        lock.lock()
        if let completion {
            lock.unlock()
            c(completion)
            return AnyCancellable {}
        }
        let id = UUID()
        subscribers[id] = (v, c)
        lock.unlock()
        return AnyCancellable { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.subscribers[id] = nil
            self.lock.unlock()
        }
    }

    func broadcast(_ value: Output) {
        lock.lock()
        let targets = completion == nil ? Array(subscribers.values) : []
        lock.unlock()
        for t in targets { t.value(value) }
    }

    func finish(_ c: Subscribers.Completion<Failure>) {
        lock.lock()
        guard completion == nil else { lock.unlock(); return }
        completion = c
        let targets = Array(subscribers.values)
        subscribers = [:]
        lock.unlock()
        for t in targets { t.completion(c) }
    }
}

public final class PassthroughSubject<Output, Failure: Error>: _SubjectBase<Output, Failure>, Subject {
    public override init() {}
    public func send(_ value: Output) { broadcast(value) }
    public func send(completion: Subscribers.Completion<Failure>) { finish(completion) }
    public func _subscribe(_ v: @escaping (Output) -> Void, _ c: @escaping (Subscribers.Completion<Failure>) -> Void) -> AnyCancellable {
        add(v, c)
    }
}

public final class CurrentValueSubject<Output, Failure: Error>: _SubjectBase<Output, Failure>, Subject {
    private var current: Output
    public var value: Output {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { send(newValue) }
    }

    public init(_ value: Output) { current = value }

    public func send(_ value: Output) {
        lock.lock(); current = value; lock.unlock()
        broadcast(value)
    }

    public func send(completion: Subscribers.Completion<Failure>) { finish(completion) }

    public func _subscribe(_ v: @escaping (Output) -> Void, _ c: @escaping (Subscribers.Completion<Failure>) -> Void) -> AnyCancellable {
        let token = add(v, c)
        if completion == nil { v(value) }
        return token
    }
}

// MARK: - @Published and ObservableObject

/// Sent just before each @Published property change.
public final class ObservableObjectPublisher: Publisher {
    public typealias Output = Void
    public typealias Failure = Never
    private let subject = PassthroughSubject<Void, Never>()
    public init() {}
    public func send() { subject.send(()) }
    public func _subscribe(_ v: @escaping (Void) -> Void, _ c: @escaping (Subscribers.Completion<Never>) -> Void) -> AnyCancellable {
        subject._subscribe(v, c)
    }
}

public protocol ObservableObject: AnyObject {
    associatedtype ObjectWillChangePublisher: Publisher = ObservableObjectPublisher where ObjectWillChangePublisher.Failure == Never
    var objectWillChange: ObjectWillChangePublisher { get }
}

/// Default `objectWillChange`: one publisher per object, created on first access.
private final class WillChangeRegistry: @unchecked Sendable {
    static let shared = WillChangeRegistry()
    private struct Entry { weak var object: AnyObject?; let publisher: ObservableObjectPublisher }
    private var entries: [ObjectIdentifier: Entry] = [:]
    private let lock = NSLock()

    func publisher(for object: AnyObject) -> ObservableObjectPublisher {
        lock.lock(); defer { lock.unlock() }
        let id = ObjectIdentifier(object)
        if let e = entries[id], e.object === object { return e.publisher }
        if entries.count > 512 { entries = entries.filter { $0.value.object != nil } }
        let p = ObservableObjectPublisher()
        entries[id] = Entry(object: object, publisher: p)
        return p
    }
}

extension ObservableObject where ObjectWillChangePublisher == ObservableObjectPublisher {
    public var objectWillChange: ObservableObjectPublisher { WillChangeRegistry.shared.publisher(for: self) }
}

private func _sendWillChange<T: ObservableObject>(_ object: T) {
    (object.objectWillChange as? ObservableObjectPublisher)?.send()
}

@propertyWrapper
public struct Published<Value> {
    /// `$property`: the current value on subscription, then each new value before it is stored (as on iOS).
    public struct Publisher: Combine.Publisher {
        public typealias Output = Value
        public typealias Failure = Never
        let subject: CurrentValueSubject<Value, Never>
        public func _subscribe(_ v: @escaping (Value) -> Void, _ c: @escaping (Subscribers.Completion<Never>) -> Void) -> AnyCancellable {
            subject._subscribe(v, c)
        }
    }

    private let subject: CurrentValueSubject<Value, Never>

    public init(wrappedValue: Value) { subject = CurrentValueSubject(wrappedValue) }
    public init(initialValue: Value) { self.init(wrappedValue: initialValue) }

    @available(*, unavailable, message: "@Published is only available on properties of classes")
    public var wrappedValue: Value {
        get { fatalError() }
        set { fatalError() }
    }

    public var projectedValue: Publisher {
        get { Publisher(subject: subject) }
        set {}
    }

    public static subscript<EnclosingSelf: AnyObject>(
        _enclosingInstance object: EnclosingSelf,
        wrapped wrappedKeyPath: ReferenceWritableKeyPath<EnclosingSelf, Value>,
        storage storageKeyPath: ReferenceWritableKeyPath<EnclosingSelf, Published<Value>>
    ) -> Value {
        get { object[keyPath: storageKeyPath].subject.value }
        set {
            if let observable = object as? any ObservableObject { _sendWillChange(observable) }
            object[keyPath: storageKeyPath].subject.send(newValue)
        }
    }
}

// MARK: - Schedulers

/// Interval for `debounce`, `throttle`, `delay`: `.milliseconds(300)`, `.seconds(1)`, or a number of seconds.
public struct SchedulerTimeIntervalConvertible: ExpressibleByFloatLiteral, ExpressibleByIntegerLiteral, Sendable {
    public let seconds: Double
    public init(seconds: Double) { self.seconds = seconds }
    public init(floatLiteral value: Double) { seconds = value }
    public init(integerLiteral value: Int) { seconds = Double(value) }
    public static func seconds(_ s: Double) -> Self { Self(seconds: s) }
    public static func seconds(_ s: Int) -> Self { Self(seconds: Double(s)) }
    public static func milliseconds(_ ms: Int) -> Self { Self(seconds: Double(ms) / 1000) }
    public static func microseconds(_ us: Int) -> Self { Self(seconds: Double(us) / 1_000_000) }
    public static func nanoseconds(_ ns: Int) -> Self { Self(seconds: Double(ns) / 1_000_000_000) }
}

public protocol Scheduler {
    func _schedule(_ action: @escaping () -> Void)
    func _schedule(after seconds: Double, _ action: @escaping () -> Void)
}

extension DispatchQueue: Scheduler {
    public func _schedule(_ action: @escaping () -> Void) { async(execute: action) }
    public func _schedule(after seconds: Double, _ action: @escaping () -> Void) {
        asyncAfter(deadline: .now() + seconds, execute: action)
    }
}

extension RunLoop: Scheduler {
    public func _schedule(_ action: @escaping () -> Void) {
        // RunLoop.main is the main thread (serviced by the simulator); anything else runs inline.
        if self === RunLoop.main { DispatchQueue.main.async(execute: action) } else { perform(action) }
    }
    public func _schedule(after seconds: Double, _ action: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: action)
    }
}

extension OperationQueue: Scheduler {
    public func _schedule(_ action: @escaping () -> Void) { addOperation(action) }
    public func _schedule(after seconds: Double, _ action: @escaping () -> Void) {
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { self.addOperation(action) }
    }
}

public struct ImmediateScheduler: Scheduler {
    public static let shared = ImmediateScheduler()
    public func _schedule(_ action: @escaping () -> Void) { action() }
    public func _schedule(after seconds: Double, _ action: @escaping () -> Void) {
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: action)
    }
}

// MARK: - Operators

extension Publisher {
    public func map<T>(_ transform: @escaping (Output) -> T) -> AnyPublisher<T, Failure> {
        make { v, c in self._subscribe({ v(transform($0)) }, c) }
    }

    public func map<T>(_ keyPath: KeyPath<Output, T>) -> AnyPublisher<T, Failure> {
        map { $0[keyPath: keyPath] }
    }

    public func tryMap<T>(_ transform: @escaping (Output) throws -> T) -> AnyPublisher<T, Error> {
        make { v, c in
            var token: AnyCancellable?
            var done = false
            token = self._subscribe({ value in
                guard !done else { return }
                do { v(try transform(value)) } catch { done = true; c(.failure(error)); token?.cancel() }
            }, { completion in
                guard !done else { return }
                switch completion {
                case .finished: c(.finished)
                case let .failure(e): c(.failure(e))
                }
            })
            return AnyCancellable { token?.cancel() }
        }
    }

    public func compactMap<T>(_ transform: @escaping (Output) -> T?) -> AnyPublisher<T, Failure> {
        make { v, c in self._subscribe({ if let t = transform($0) { v(t) } }, c) }
    }

    public func filter(_ isIncluded: @escaping (Output) -> Bool) -> AnyPublisher<Output, Failure> {
        make { v, c in self._subscribe({ if isIncluded($0) { v($0) } }, c) }
    }

    public func removeDuplicates(by predicate: @escaping (Output, Output) -> Bool) -> AnyPublisher<Output, Failure> {
        make { v, c in
            var last: Output?
            let lock = NSLock()
            return self._subscribe({ value in
                lock.lock()
                let same = last.map { predicate($0, value) } ?? false
                last = value
                lock.unlock()
                if !same { v(value) }
            }, c)
        }
    }

    public func dropFirst(_ count: Int = 1) -> AnyPublisher<Output, Failure> {
        make { v, c in
            var seen = 0
            return self._subscribe({ value in
                if seen < count { seen += 1 } else { v(value) }
            }, c)
        }
    }

    public func prefix(_ maxLength: Int) -> AnyPublisher<Output, Failure> {
        make { v, c in
            var count = 0
            var token: AnyCancellable?
            token = self._subscribe({ value in
                guard count < maxLength else { return }
                count += 1
                v(value)
                if count == maxLength { c(.finished); token?.cancel() }
            }, { completion in if count < maxLength { c(completion) } })
            if maxLength == 0 { c(.finished) }
            return AnyCancellable { token?.cancel() }
        }
    }

    public func first() -> AnyPublisher<Output, Failure> { prefix(1) }

    public func first(where predicate: @escaping (Output) -> Bool) -> AnyPublisher<Output, Failure> {
        filter(predicate).prefix(1)
    }

    public func scan<T>(_ initial: T, _ next: @escaping (T, Output) -> T) -> AnyPublisher<T, Failure> {
        make { v, c in
            var acc = initial
            return self._subscribe({ acc = next(acc, $0); v(acc) }, c)
        }
    }

    public func handleEvents(receiveSubscription: ((Any) -> Void)? = nil, receiveOutput: ((Output) -> Void)? = nil,
                             receiveCompletion: ((Subscribers.Completion<Failure>) -> Void)? = nil,
                             receiveCancel: (() -> Void)? = nil, receiveRequest: ((Subscribers.Demand) -> Void)? = nil)
        -> AnyPublisher<Output, Failure> {
        make { v, c in
            receiveSubscription?(())
            let token = self._subscribe({ receiveOutput?($0); v($0) }, { receiveCompletion?($0); c($0) })
            return AnyCancellable { receiveCancel?(); token.cancel() }
        }
    }

    public func receive<S: Scheduler>(on scheduler: S, options: Any? = nil) -> AnyPublisher<Output, Failure> {
        make { v, c in
            self._subscribe({ value in scheduler._schedule { v(value) } }, { completion in scheduler._schedule { c(completion) } })
        }
    }

    public func subscribe<S: Scheduler>(on scheduler: S, options: Any? = nil) -> AnyPublisher<Output, Failure> {
        make { v, c in
            var token: AnyCancellable?
            scheduler._schedule { token = self._subscribe(v, c) }
            return AnyCancellable { token?.cancel() }
        }
    }

    public func delay<S: Scheduler>(for interval: SchedulerTimeIntervalConvertible, scheduler: S, options: Any? = nil)
        -> AnyPublisher<Output, Failure> {
        make { v, c in
            self._subscribe({ value in scheduler._schedule(after: interval.seconds) { v(value) } },
                            { completion in scheduler._schedule(after: interval.seconds) { c(completion) } })
        }
    }

    public func debounce<S: Scheduler>(for interval: SchedulerTimeIntervalConvertible, scheduler: S, options: Any? = nil)
        -> AnyPublisher<Output, Failure> {
        make { v, c in
            var generation = 0
            let lock = NSLock()
            return self._subscribe({ value in
                lock.lock(); generation += 1; let g = generation; lock.unlock()
                scheduler._schedule(after: interval.seconds) {
                    lock.lock(); let current = generation == g; lock.unlock()
                    if current { v(value) }
                }
            }, c)
        }
    }

    public func throttle<S: Scheduler>(for interval: SchedulerTimeIntervalConvertible, scheduler: S, latest: Bool)
        -> AnyPublisher<Output, Failure> {
        make { v, c in
            var pending: Output?
            var windowOpen = false
            let lock = NSLock()
            return self._subscribe({ value in
                lock.lock()
                if windowOpen {
                    if latest { pending = value }
                    lock.unlock()
                    return
                }
                windowOpen = true
                pending = nil
                lock.unlock()
                scheduler._schedule { v(value) }
                scheduler._schedule(after: interval.seconds) {
                    lock.lock(); let p = pending; pending = nil; windowOpen = false; lock.unlock()
                    if let p { v(p) }
                }
            }, c)
        }
    }

    public func combineLatest<P: Publisher>(_ other: P) -> AnyPublisher<(Output, P.Output), Failure> where P.Failure == Failure {
        make { v, c in
            var a: Output?, b: P.Output?
            let lock = NSLock()
            func emit() {
                lock.lock(); let pair = a.flatMap { x in b.map { (x, $0) } }; lock.unlock()
                if let pair { v(pair) }
            }
            let t1 = self._subscribe({ x in lock.lock(); a = x; lock.unlock(); emit() }, c)
            let t2 = other._subscribe({ y in lock.lock(); b = y; lock.unlock(); emit() }, c)
            return AnyCancellable { t1.cancel(); t2.cancel() }
        }
    }

    public func combineLatest<P: Publisher, T>(_ other: P, _ transform: @escaping (Output, P.Output) -> T)
        -> AnyPublisher<T, Failure> where P.Failure == Failure {
        combineLatest(other).map { transform($0.0, $0.1) }
    }

    public func merge<P: Publisher>(with other: P) -> AnyPublisher<Output, Failure> where P.Output == Output, P.Failure == Failure {
        make { v, c in
            var finished = 0
            let lock = NSLock()
            let complete: (Subscribers.Completion<Failure>) -> Void = { completion in
                if case .failure = completion { c(completion); return }
                lock.lock(); finished += 1; let all = finished == 2; lock.unlock()
                if all { c(.finished) }
            }
            let t1 = self._subscribe(v, complete)
            let t2 = other._subscribe(v, complete)
            return AnyCancellable { t1.cancel(); t2.cancel() }
        }
    }

    public func flatMap<P: Publisher>(_ transform: @escaping (Output) -> P) -> AnyPublisher<P.Output, Failure> where P.Failure == Failure {
        make { v, c in
            var inner: [AnyCancellable] = []
            let lock = NSLock()
            let outer = self._subscribe({ value in
                let t = transform(value)._subscribe(v, { if case .failure = $0 { c($0) } })
                lock.lock(); inner.append(t); lock.unlock()
            }, c)
            return AnyCancellable { outer.cancel(); lock.lock(); inner.forEach { $0.cancel() }; lock.unlock() }
        }
    }

    public func replaceError(with output: Output) -> AnyPublisher<Output, Never> {
        make { v, c in
            self._subscribe(v, { completion in
                if case .failure = completion { v(output) }
                c(.finished)
            })
        }
    }

    public func `catch`<P: Publisher>(_ handler: @escaping (Failure) -> P) -> AnyPublisher<Output, P.Failure> where P.Output == Output {
        make { v, c in
            var next: AnyCancellable?
            let token = self._subscribe(v, { completion in
                switch completion {
                case .finished: c(.finished)
                case let .failure(error): next = handler(error)._subscribe(v, c)
                }
            })
            return AnyCancellable { token.cancel(); next?.cancel() }
        }
    }

    public func mapError<E: Error>(_ transform: @escaping (Failure) -> E) -> AnyPublisher<Output, E> {
        make { v, c in
            self._subscribe(v, { completion in
                switch completion {
                case .finished: c(.finished)
                case let .failure(error): c(.failure(transform(error)))
                }
            })
        }
    }

    public func setFailureType<E: Error>(to failureType: E.Type) -> AnyPublisher<Output, E> where Failure == Never {
        make { v, c in self._subscribe(v, { _ in c(.finished) }) }
    }

    public func replaceNil<T>(with output: T) -> AnyPublisher<T, Failure> where Output == T? {
        map { $0 ?? output }
    }

    public func collect() -> AnyPublisher<[Output], Failure> {
        make { v, c in
            var all: [Output] = []
            return self._subscribe({ all.append($0) }, { completion in
                if case .finished = completion { v(all) }
                c(completion)
            })
        }
    }

    public func share() -> AnyPublisher<Output, Failure> { eraseToAnyPublisher() }
}

extension Publisher where Output: Equatable {
    public func removeDuplicates() -> AnyPublisher<Output, Failure> { removeDuplicates(by: ==) }
}

extension Publisher where Output == Never {}

extension Publisher where Failure == Never {
    public var values: AsyncStream<Output> {
        AsyncStream { continuation in
            let token = self._subscribe({ continuation.yield($0) }, { _ in continuation.finish() })
            continuation.onTermination = { _ in token.cancel() }
        }
    }
}

extension Publisher {
    public var values: AsyncThrowingStream<Output, Error> {
        AsyncThrowingStream { continuation in
            let token = self._subscribe({ continuation.yield($0) }, { completion in
                switch completion {
                case .finished: continuation.finish()
                case let .failure(error): continuation.finish(throwing: error)
                }
            })
            continuation.onTermination = { _ in token.cancel() }
        }
    }
}

// MARK: - Publishers.* (named types used in signatures)

public enum Publishers {
    public typealias Map<Upstream: Publisher, Output> = AnyPublisher<Output, Upstream.Failure>
    public typealias Filter<Upstream: Publisher> = AnyPublisher<Upstream.Output, Upstream.Failure>
    public typealias RemoveDuplicates<Upstream: Publisher> = AnyPublisher<Upstream.Output, Upstream.Failure>
    public typealias ReceiveOn<Upstream: Publisher, Context> = AnyPublisher<Upstream.Output, Upstream.Failure>

    public static func Merge<A: Publisher, B: Publisher>(_ a: A, _ b: B) -> AnyPublisher<A.Output, A.Failure>
        where A.Output == B.Output, A.Failure == B.Failure {
        a.merge(with: b)
    }

    public static func CombineLatest<A: Publisher, B: Publisher>(_ a: A, _ b: B) -> AnyPublisher<(A.Output, B.Output), A.Failure>
        where A.Failure == B.Failure {
        a.combineLatest(b)
    }
}

// MARK: - Timer and NotificationCenter

extension Timer {
    /// `Timer.publish(every: 1, on: .main, in: .common).autoconnect()`
    public static func publish(every interval: TimeInterval, tolerance: TimeInterval? = nil, on runLoop: RunLoop,
                               in mode: RunLoop.Mode, options: Any? = nil) -> TimerPublisher {
        TimerPublisher(interval: interval)
    }

    public final class TimerPublisher: Publisher {
        public typealias Output = Date
        public typealias Failure = Never
        let interval: TimeInterval
        private let subject = PassthroughSubject<Date, Never>()
        private var source: DispatchSourceTimer?
        private let lock = NSLock()

        init(interval: TimeInterval) { self.interval = interval }

        /// Starts the timer on the main thread.
        public func connect() -> Cancellable {
            lock.lock(); defer { lock.unlock() }
            if source == nil {
                let s = DispatchSource.makeTimerSource(queue: .main)
                s.schedule(deadline: .now() + interval, repeating: interval)
                s.setEventHandler { [weak self] in self?.subject.send(Date()) }
                s.resume()
                source = s
            }
            return AnyCancellable { [weak self] in
                self?.lock.lock(); self?.source?.cancel(); self?.source = nil; self?.lock.unlock()
            }
        }

        public func autoconnect() -> AnyPublisher<Date, Never> {
            _ClosurePublisher<Date, Never> { [self] v, c in
                let token = self.subject._subscribe(v, c)
                let connection = self.connect()
                return AnyCancellable { token.cancel(); connection.cancel() }
            }.eraseToAnyPublisher()
        }

        public func _subscribe(_ v: @escaping (Date) -> Void, _ c: @escaping (Subscribers.Completion<Never>) -> Void) -> AnyCancellable {
            subject._subscribe(v, c)
        }
    }
}

extension NotificationCenter {
    public func publisher(for name: Notification.Name, object: AnyObject? = nil) -> AnyPublisher<Notification, Never> {
        _ClosurePublisher<Notification, Never> { [self] v, _ in
            let observer = self.addObserver(forName: name, object: object, queue: nil) { v($0) }
            return AnyCancellable { self.removeObserver(observer) }
        }.eraseToAnyPublisher()
    }
}

extension URLSession {
    public func dataTaskPublisher(for url: URL) -> AnyPublisher<(data: Data, response: URLResponse), URLError> {
        dataTaskPublisher(for: URLRequest(url: url))
    }

    public func dataTaskPublisher(for request: URLRequest) -> AnyPublisher<(data: Data, response: URLResponse), URLError> {
        _ClosurePublisher<(data: Data, response: URLResponse), URLError> { [self] v, c in
            let task = self.dataTask(with: request) { data, response, error in
                if let data, let response {
                    v((data, response))
                    c(.finished)
                } else {
                    c(.failure((error as? URLError) ?? URLError(.unknown)))
                }
            }
            task.resume()
            return AnyCancellable { task.cancel() }
        }.eraseToAnyPublisher()
    }
}
