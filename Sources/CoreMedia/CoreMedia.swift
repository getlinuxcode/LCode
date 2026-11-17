import Foundation

// CoreMedia pour le simulateur LSim : le temps des médias (CMTime, CMTimeRange) et ses opérations.

public typealias CMTimeValue = Int64
public typealias CMTimeScale = Int32

public struct CMTimeFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let valid = CMTimeFlags(rawValue: 1)
    public static let hasBeenRounded = CMTimeFlags(rawValue: 2)
    public static let positiveInfinity = CMTimeFlags(rawValue: 4)
    public static let negativeInfinity = CMTimeFlags(rawValue: 8)
    public static let indefinite = CMTimeFlags(rawValue: 16)
}

public struct CMTime: Hashable, Comparable, Sendable, CustomStringConvertible {
    public var value: CMTimeValue
    public var timescale: CMTimeScale
    public var flags: CMTimeFlags
    public var epoch: Int64 = 0

    public init(value: CMTimeValue, timescale: CMTimeScale) {
        self.value = value
        self.timescale = timescale
        flags = timescale > 0 ? .valid : []
    }

    public init(value: CMTimeValue, timescale: CMTimeScale, flags: CMTimeFlags, epoch: Int64) {
        self.value = value
        self.timescale = timescale
        self.flags = flags
        self.epoch = epoch
    }

    public init(seconds: Double, preferredTimescale: CMTimeScale) {
        if seconds.isNaN {
            self = .invalid
        } else if seconds.isInfinite {
            self = seconds > 0 ? .positiveInfinity : .negativeInfinity
        } else {
            self.init(value: CMTimeValue((seconds * Double(preferredTimescale)).rounded()), timescale: preferredTimescale)
        }
    }

    public static let zero = CMTime(value: 0, timescale: 1)
    public static let invalid = CMTime(value: 0, timescale: 0, flags: [], epoch: 0)
    public static let indefinite = CMTime(value: 0, timescale: 0, flags: [.valid, .indefinite], epoch: 0)
    public static let positiveInfinity = CMTime(value: 0, timescale: 0, flags: [.valid, .positiveInfinity], epoch: 0)
    public static let negativeInfinity = CMTime(value: 0, timescale: 0, flags: [.valid, .negativeInfinity], epoch: 0)

    public var isValid: Bool { flags.contains(.valid) }
    public var isIndefinite: Bool { flags.contains(.indefinite) }
    public var isNumeric: Bool { isValid && !isIndefinite && !flags.contains(.positiveInfinity) && !flags.contains(.negativeInfinity) }
    public var isPositiveInfinity: Bool { flags.contains(.positiveInfinity) }
    public var isNegativeInfinity: Bool { flags.contains(.negativeInfinity) }

    public var seconds: Double {
        if isPositiveInfinity { return .infinity }
        if isNegativeInfinity { return -.infinity }
        guard isNumeric, timescale != 0 else { return .nan }
        return Double(value) / Double(timescale)
    }

    public func convertScale(_ newTimescale: Int32, method: CMTimeRoundingMethod) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: newTimescale)
    }

    public var description: String { isNumeric ? "CMTime(\(seconds) s)" : "CMTime(invalide)" }

    public static func < (a: CMTime, b: CMTime) -> Bool { a.seconds < b.seconds }
    public static func == (a: CMTime, b: CMTime) -> Bool {
        if a.isNumeric && b.isNumeric { return a.seconds == b.seconds }
        return a.flags == b.flags
    }
    public func hash(into hasher: inout Hasher) { hasher.combine(isNumeric ? seconds : -1) }

    static func scale(_ a: CMTime, _ b: CMTime) -> CMTimeScale { max(a.timescale, b.timescale, 600) }

    public static func + (a: CMTime, b: CMTime) -> CMTime {
        CMTime(seconds: a.seconds + b.seconds, preferredTimescale: scale(a, b))
    }
    public static func - (a: CMTime, b: CMTime) -> CMTime {
        CMTime(seconds: a.seconds - b.seconds, preferredTimescale: scale(a, b))
    }
    public static func += (a: inout CMTime, b: CMTime) { a = a + b }
    public static func -= (a: inout CMTime, b: CMTime) { a = a - b }
}

public enum CMTimeRoundingMethod: Sendable {
    case `default`, roundHalfAwayFromZero, roundTowardZero, roundAwayFromZero, quickTime, roundTowardPositiveInfinity,
         roundTowardNegativeInfinity
}

public func CMTimeMake(value: Int64, timescale: Int32) -> CMTime { CMTime(value: value, timescale: timescale) }
public func CMTimeMakeWithSeconds(_ seconds: Double, preferredTimescale: Int32) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: preferredTimescale)
}
public func CMTimeGetSeconds(_ time: CMTime) -> Double { time.seconds }
public func CMTimeAdd(_ a: CMTime, _ b: CMTime) -> CMTime { a + b }
public func CMTimeSubtract(_ a: CMTime, _ b: CMTime) -> CMTime { a - b }
public func CMTimeCompare(_ a: CMTime, _ b: CMTime) -> Int32 { a < b ? -1 : (a == b ? 0 : 1) }
public func CMTimeMultiply(_ time: CMTime, multiplier: Int32) -> CMTime {
    CMTime(seconds: time.seconds * Double(multiplier), preferredTimescale: max(time.timescale, 600))
}
public func CMTimeMultiplyByFloat64(_ time: CMTime, multiplier: Double) -> CMTime {
    CMTime(seconds: time.seconds * multiplier, preferredTimescale: max(time.timescale, 600))
}

public struct CMTimeRange: Hashable, Sendable {
    public var start: CMTime
    public var duration: CMTime
    public init(start: CMTime, duration: CMTime) {
        self.start = start
        self.duration = duration
    }
    public init(start: CMTime, end: CMTime) { self.init(start: start, duration: end - start) }
    public var end: CMTime { start + duration }
    public var isEmpty: Bool { duration.seconds <= 0 }
    public func containsTime(_ time: CMTime) -> Bool { time >= start && time < end }
    public static let zero = CMTimeRange(start: .zero, duration: .zero)
    public static let invalid = CMTimeRange(start: .invalid, duration: .invalid)
}

public func CMTimeRangeMake(start: CMTime, duration: CMTime) -> CMTimeRange { CMTimeRange(start: start, duration: duration) }
