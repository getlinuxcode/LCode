import Foundation

// CoreVideo for LSim: video frames as premultiplied 8-bit BGRA, which the LSim renderer draws directly.

public typealias OSType = UInt32
public typealias CVReturn = Int32
public let kCVReturnSuccess: CVReturn = 0
public let kCVPixelFormatType_32BGRA: OSType = 0x4247_5241 // 'BGRA'
public let kCVPixelFormatType_32ARGB: OSType = 0x0000_0020

/// A class so frames go from the video API to the renderer without copying.
public final class CVPixelBuffer: @unchecked Sendable {
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public private(set) var data: Data
    /// Increasing counter that lets the renderer detect a new frame.
    public let generation: Int

    private static var counter = 0
    private static let lock = NSLock()

    public init(width: Int, height: Int, bytesPerRow: Int, data: Data) {
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.data = data
        Self.lock.lock()
        Self.counter += 1
        generation = Self.counter
        Self.lock.unlock()
    }
}

public typealias CVImageBuffer = CVPixelBuffer

public func CVPixelBufferGetWidth(_ buffer: CVPixelBuffer) -> Int { buffer.width }
public func CVPixelBufferGetHeight(_ buffer: CVPixelBuffer) -> Int { buffer.height }
public func CVPixelBufferGetBytesPerRow(_ buffer: CVPixelBuffer) -> Int { buffer.bytesPerRow }
public func CVPixelBufferGetPixelFormatType(_ buffer: CVPixelBuffer) -> OSType { kCVPixelFormatType_32BGRA }
