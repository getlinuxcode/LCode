import Foundation

// Animation engine. Each layout node has a stable identity (its path in the view tree). When something
// can move, a frame renders in two passes: the first records each node's target frame, the second draws
// the presented frame interpolated along the curve. Frames are absolute so parents and children move
// together. Nodes inserted during an animated transaction fade in (default .opacity transition).

// MARK: - Animation

public struct Animation: Equatable, Sendable {
    enum Curve: Equatable, Sendable {
        /// Cubic Bezier (x1, y1, x2, y2) over a fixed duration.
        case bezier(Double, Double, Double, Double, duration: Double)
        /// Spring: response (undamped period, s) and damping fraction (1 = critical).
        case spring(response: Double, damping: Double)
    }

    var curve: Curve
    var delay: Double = 0
    var speed: Double = 1

    // Base curves (CSS / Core Animation).
    public static func linear(duration: Double) -> Animation { Animation(curve: .bezier(0, 0, 1, 1, duration: duration)) }
    public static func easeIn(duration: Double) -> Animation { Animation(curve: .bezier(0.42, 0, 1, 1, duration: duration)) }
    public static func easeOut(duration: Double) -> Animation { Animation(curve: .bezier(0, 0, 0.58, 1, duration: duration)) }
    public static func easeInOut(duration: Double) -> Animation { Animation(curve: .bezier(0.42, 0, 0.58, 1, duration: duration)) }
    public static func timingCurve(_ c0x: Double, _ c0y: Double, _ c1x: Double, _ c1y: Double, duration: Double = 0.35) -> Animation {
        Animation(curve: .bezier(c0x, c0y, c1x, c1y, duration: duration))
    }
    public static var linear: Animation { preset("linear", linear(duration: 0.35)) }
    public static var easeIn: Animation { preset("easeIn", easeIn(duration: 0.35)) }
    public static var easeOut: Animation { preset("easeOut", easeOut(duration: 0.35)) }
    public static var easeInOut: Animation { preset("easeInOut", easeInOut(duration: 0.35)) }

    // Springs (iOS 17+).
    public static func spring(response: Double = 0.5, dampingFraction: Double = 0.825, blendDuration: Double = 0) -> Animation {
        Animation(curve: .spring(response: response, damping: dampingFraction))
    }
    /// Perceived duration and bounce (−1…1); Apple's convention: damping = 1 − bounce (bounce ≥ 0).
    public static func spring(duration: Double = 0.5, bounce: Double = 0, blendDuration: Double = 0) -> Animation {
        let damping = bounce >= 0 ? 1 - bounce : 1 / (1 + bounce)
        return Animation(curve: .spring(response: duration, damping: damping))
    }
    public static func interpolatingSpring(stiffness: Double, damping: Double, mass: Double = 1, initialVelocity: Double = 0) -> Animation {
        let omega = (stiffness / mass).squareRoot()
        return Animation(curve: .spring(response: 2 * .pi / omega, damping: damping / (2 * (stiffness * mass).squareRoot())))
    }
    public static func interactiveSpring(response: Double = 0.15, dampingFraction: Double = 0.86, blendDuration: Double = 0.25) -> Animation {
        spring(response: response, dampingFraction: dampingFraction)
    }
    public static func smooth(duration: Double = 0.5, extraBounce: Double = 0) -> Animation { spring(duration: duration, bounce: extraBounce) }
    public static func snappy(duration: Double = 0.5, extraBounce: Double = 0) -> Animation { spring(duration: duration, bounce: 0.15 + extraBounce) }
    public static func bouncy(duration: Double = 0.5, extraBounce: Double = 0) -> Animation { spring(duration: duration, bounce: 0.3 + extraBounce) }

    /// Presets: values measured on iPhone (design profile), otherwise Apple's documented values.
    static func preset(_ name: String, _ fallback: Animation) -> Animation {
        guard let setting = DesignProfile.current.animations?[name] else { return fallback }
        if let s = setting.spring { return Animation(curve: .spring(response: s.response, damping: s.damping)) }
        if let duration = setting.duration {
            switch setting.bezier {
            case "linear": return .linear(duration: duration)
            case "easeIn": return .easeIn(duration: duration)
            case "easeOut": return .easeOut(duration: duration)
            default: return .easeInOut(duration: duration)
            }
        }
        return fallback
    }

    public static var spring: Animation { preset("spring", spring(response: 0.5, dampingFraction: 0.825)) }
    public static var interactiveSpring: Animation { preset("interactiveSpring", interactiveSpring()) }
    public static var smooth: Animation { preset("smooth", smooth()) }
    public static var snappy: Animation { preset("snappy", snappy()) }
    public static var bouncy: Animation { preset("bouncy", bouncy()) }
    /// iOS 17+: spring without bounce (measured on iPhone: identical to .spring and .smooth).
    public static var `default`: Animation { preset("default", spring(duration: 0.55, bounce: 0)) }

    public func speed(_ speed: Double) -> Animation { var a = self; a.speed = speed; return a }
    public func delay(_ delay: Double) -> Animation { var a = self; a.delay = delay; return a }
    public func repeatCount(_ count: Int, autoreverses: Bool = true) -> Animation { self }
    public func repeatForever(autoreverses: Bool = true) -> Animation { self }
}

// MARK: - Curves

extension Animation {
    /// Remaining displacement (1 → 0) and velocity (per second) at time `t`, for initial offset d0 and
    /// initial velocity v0 (in offset units). Nil: finished.
    func displacement(at t: Double, d0: Double, v0: Double) -> (d: Double, v: Double)? {
        let time = max(0, (t - delay) * speed)
        switch curve {
        case let .bezier(x1, y1, x2, y2, duration):
            guard time < duration else { return nil }
            let p = Self.cubicBezier(time / max(duration, 1e-6), x1, y1, x2, y2)
            return (d0 * (1 - p), 0)
        case let .spring(response, damping):
            let omega = 2 * Double.pi / max(response, 1e-3)
            let zeta = damping
            var d: Double, v: Double
            if zeta < 1 {
                let wd = omega * (1 - zeta * zeta).squareRoot()
                let a = d0, b = (v0 + zeta * omega * d0) / wd
                let e = exp(-zeta * omega * time)
                let c = cos(wd * time), s = sin(wd * time)
                d = e * (a * c + b * s)
                v = e * ((-zeta * omega) * (a * c + b * s) + (-a * wd * s + b * wd * c))
            } else if zeta == 1 {
                let b = v0 + omega * d0
                let e = exp(-omega * time)
                d = e * (d0 + b * time)
                v = e * (b - omega * (d0 + b * time))
            } else {
                let r = omega * (zeta * zeta - 1).squareRoot()
                let r1 = -zeta * omega + r, r2 = -zeta * omega - r
                let c2 = (v0 - r1 * d0) / (r2 - r1), c1 = d0 - c2
                d = c1 * exp(r1 * time) + c2 * exp(r2 * time)
                v = c1 * r1 * exp(r1 * time) + c2 * r2 * exp(r2 * time)
            }
            // Stop below 0.01 pt and nearly still (or after 10 s).
            if (abs(d) < 0.01 && abs(v) < 0.1) || time > 10 { return nil }
            return (d, v)
        }
    }

    static func cubicBezier(_ x: Double, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Double {
        func bx(_ t: Double) -> Double { 3 * (1 - t) * (1 - t) * t * x1 + 3 * (1 - t) * t * t * x2 + t * t * t }
        func by(_ t: Double) -> Double { 3 * (1 - t) * (1 - t) * t * y1 + 3 * (1 - t) * t * t * y2 + t * t * t }
        var lo = 0.0, hi = 1.0, t = x
        for _ in 0..<40 {
            t = (lo + hi) / 2
            if bx(t) < x { lo = t } else { hi = t }
        }
        return by(t)
    }
}

// MARK: - Transactions

/// Animation being declared (`withAnimation`): state changes made in the block carry it to the next frame.
public enum Transaction {
    nonisolated(unsafe) static var current: Animation?
}

@discardableResult
public func withAnimation<Result>(_ animation: Animation? = .default, _ body: () throws -> Result) rethrows -> Result {
    let previous = Transaction.current
    Transaction.current = animation
    defer { Transaction.current = previous }
    return try body()
}

// MARK: - Animator

/// Presented values of each node, frame to frame.
public final class Animator {
    enum Mode { case direct, record, present }

    struct Track {
        var from: [Double]
        var velocity: [Double]
        var to: [Double]
        var start: Double
        var animation: Animation?
        var presented: [Double]
    }

    var mode: Mode = .direct
    private var tracks: [String: Track] = [:]
    private var targets: [String: [Double]] = [:]
    private var seen: Set<String> = []
    private var previousSeen: Set<String> = []
    private var counts: [String: Int] = [:]
    /// Current transaction's animation (set by `withAnimation` when state changes).
    public var pending: Animation?
    /// Clock (seconds); replaceable for deterministic frame-by-frame captures.
    public var clock: () -> Double = { Date().timeIntervalSinceReferenceDate }
    public private(set) var isAnimating = false
    /// An `.animation(_:value:)` value changed during this build.
    var implicitChange = false

    public init() {}

    var needsTwoPasses: Bool { pending != nil || isAnimating || implicitChange }

    func beginFrame() {
        counts = [:]
        seen = []
    }

    /// Unique key within the frame (nodes with the same identity are numbered in traversal order).
    func key(_ identity: String) -> String {
        let n = counts[identity, default: 0]
        counts[identity] = n + 1
        return n == 0 ? identity : "\(identity)~\(n)"
    }

    /// Presented value of an animatable quantity (rect, opacity…) for this frame.
    func present(_ key: String, _ target: [Double], animation: Animation?, now: Double) -> [Double] {
        seen.insert(key)
        switch mode {
        case .record:
            targets[key] = target
            return target
        case .direct:
            tracks[key] = Track(from: target, velocity: target.map { _ in 0 }, to: target, start: now, animation: nil, presented: target)
            return target
        case .present:
            let goal = targets[key] ?? target
            guard var track = tracks[key] else {
                tracks[key] = Track(from: goal, velocity: goal.map { _ in 0 }, to: goal, start: now, animation: nil, presented: goal)
                return goal
            }
            if !Self.same(track.to, goal) {
                if let spec = animation ?? pending {
                    // New target: start from the presented value, keeping its velocity (springs).
                    let v = currentVelocity(track, now: now)
                    track = Track(from: track.presented, velocity: v, to: goal, start: now, animation: spec, presented: track.presented)
                } else {
                    track = Track(from: goal, velocity: goal.map { _ in 0 }, to: goal, start: now, animation: nil, presented: goal)
                }
            }
            if let spec = track.animation {
                var done = true
                var value = track.to
                for i in value.indices {
                    let d0 = track.from[i] - track.to[i]
                    if let r = spec.displacement(at: now - track.start, d0: d0, v0: track.velocity[i]) {
                        value[i] = track.to[i] + r.d
                        if abs(d0) > 1e-9 || abs(track.velocity[i]) > 1e-9 { done = false }
                    }
                }
                track.presented = value
                if done { track.animation = nil; track.presented = track.to } else { stillAnimating = true }
            } else {
                track.presented = track.to
            }
            tracks[key] = track
            return track.presented
        }
    }

    private func currentVelocity(_ track: Track, now: Double) -> [Double] {
        guard let spec = track.animation else { return track.to.map { _ in 0 } }
        return track.to.indices.map { i in
            let d0 = track.from[i] - track.to[i]
            return -(spec.displacement(at: now - track.start, d0: d0, v0: track.velocity[i])?.v ?? 0)
        }
    }

    func isNew(_ key: String) -> Bool { !previousSeen.contains(key) && !previousSeen.isEmpty }

    private var insertedDepth = 0
    func enterInserted() { insertedDepth += 1 }
    func leaveInserted() { insertedDepth -= 1 }

    /// Progress (0 → 1) of a node's insertion transition, or nil. Only the root of a subtree inserted
    /// during an animated transaction gets one.
    func insertionProgress(_ key: String, animation: Animation?) -> Double? {
        let tkey = key + "#insert"
        switch mode {
        case .record, .direct:
            if mode == .record, tracks[tkey] != nil { targets[tkey] = [1] }
            return nil
        case .present:
            if tracks[tkey] == nil {
                guard insertedDepth == 0, isNew(key), let spec = animation ?? pending else { return nil }
                tracks[tkey] = Track(from: [0], velocity: [0], to: [1], start: frameTime, animation: spec, presented: [0])
                seen.insert(tkey)
                stillAnimating = true
                return 0
            }
            let p = present(tkey, [1], animation: nil, now: frameTime)[0]
            return min(max(p, 0), 1)
        }
    }

    private var stillAnimating = false

    /// Requests the next frame (transitions drawn outside tracks: navigation stack, sheets).
    func requestFrame() {
        if mode != .record { stillAnimating = true }
        externalFrame = true
    }
    /// Frame requested outside rendering (while building the tree).
    private var externalFrame = false

    /// Renders a full frame (one or two passes); called by the root layout.
    func frame(_ render: () -> DisplayList) -> DisplayList {
        let now = clock()
        frameTime = now
        if needsTwoPasses {
            mode = .record
            beginFrame()
            targets = [:]
            _ = render()
            mode = .present
        } else {
            mode = .direct
        }
        beginFrame()
        stillAnimating = false
        let list = render()
        isAnimating = stillAnimating || externalFrame
        externalFrame = false
        // Forget tracks of removed nodes.
        tracks = tracks.filter { seen.contains($0.key) }
        previousSeen = seen
        pending = nil
        implicitChange = false
        mode = .direct
        return list
    }

    var frameTime: Double = 0

    static func same(_ a: [Double], _ b: [Double]) -> Bool {
        guard a.count == b.count else { return false }
        for i in a.indices where abs(a[i] - b[i]) > 0.01 { return false }
        return true
    }
}

// MARK: - Modifiers

private struct AnimationKey: EnvironmentKey { static let defaultValue: Animation? = nil }
private struct TransitionKey: EnvironmentKey { static let defaultValue: AnyTransition? = nil }

extension EnvironmentValues {
    /// Implicit animation for nodes built here (`.animation(_:value:)` whose value just changed).
    var animation: Animation? {
        get { self[AnimationKey.self] }
        set { self[AnimationKey.self] = newValue }
    }
    var transition: AnyTransition? {
        get { self[TransitionKey.self] }
        set { self[TransitionKey.self] = newValue }
    }
}

final class AnimationValueBox { var value: AnyHashable?; var initialized = false }

struct _AnimationValueModifier<V: Equatable>: _PrimitiveModifier {
    let animation: Animation?
    let value: V
    func _apply(_ context: BuildContext, _ content: (BuildContext) -> [LayoutNode]) -> [LayoutNode] {
        let box = context.graph.persistent(context.path + "#animationValue") { AnimationValueBox() }
        let current = AnyHashable(String(describing: value))
        var ctx = context
        if box.initialized, box.value != current {
            ctx.environment.animation = animation
            context.graph.animator.implicitChange = true
        }
        box.value = current
        box.initialized = true
        return content(ctx)
    }
}

struct _TransitionModifier: _PrimitiveModifier {
    let transition: AnyTransition
    func _apply(_ context: BuildContext, _ content: (BuildContext) -> [LayoutNode]) -> [LayoutNode] {
        var ctx = context
        ctx.environment.transition = transition
        return content(ctx)
    }
}

extension View {
    public func animation<V: Equatable>(_ animation: Animation?, value: V) -> some View {
        modifier(_AnimationValueModifier(animation: animation, value: value))
    }
    public func transition(_ t: AnyTransition) -> some View {
        modifier(_TransitionModifier(transition: t))
    }
}

// MARK: - Transitions

public struct AnyTransition: Sendable {
    enum Kind: Sendable { case identity, opacity, scale(Double), move(Edge), slide, offset(CGFloat, CGFloat) }
    var insertion: [Kind]
    var removal: [Kind]
    var animation: Animation?

    init(_ kinds: [Kind]) { insertion = kinds; removal = kinds }

    public static let identity = AnyTransition([.identity])
    public static let opacity = AnyTransition([.opacity])
    public static let slide = AnyTransition([.slide])
    public static let scale = AnyTransition([.scale(0)])
    public static func scale(scale: CGFloat, anchor: UnitPoint = .center) -> AnyTransition { AnyTransition([.scale(Double(scale))]) }
    public static func move(edge: Edge) -> AnyTransition { AnyTransition([.move(edge)]) }
    public static func push(from edge: Edge) -> AnyTransition { AnyTransition([.move(edge), .opacity]) }
    public static func offset(x: CGFloat = 0, y: CGFloat = 0) -> AnyTransition { AnyTransition([.offset(x, y)]) }
    public static func asymmetric(insertion: AnyTransition, removal: AnyTransition) -> AnyTransition {
        var t = insertion
        t.removal = removal.removal
        return t
    }
    public func combined(with other: AnyTransition) -> AnyTransition {
        var t = self
        t.insertion += other.insertion
        t.removal += other.removal
        return t
    }
    public func animation(_ animation: Animation?) -> AnyTransition { var t = self; t.animation = animation; return t }
}
