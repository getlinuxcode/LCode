import Foundation

// CoreVideo pour le simulateur LSim : l'image d'une vidéo (CVPixelBuffer), en BGRA 8 bits prémultiplié,
// que le rendu de LSim sait dessiner.

public typealias OSType = UInt32
public typealias CVReturn = Int32
public let kCVReturnSuccess: CVReturn = 0
public let kCVPixelFormatType_32BGRA: OSType = 0x4247_5241 // 'BGRA'
public let kCVPixelFormatType_32ARGB: OSType = 0x0000_0020

/// Image en mémoire (BGRA). Classe : passée sans copie de l'API vidéo au rendu.
public final class CVPixelBuffer: @unchecked Sendable {
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public private(set) var data: Data
    /// Numéro croissant : le rendu sait qu'une nouvelle image est arrivée.
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
