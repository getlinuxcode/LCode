import CoreVideo
import Foundation

/// Video frame (CVPixelBuffer) aspect-fitted into the proposed size; backs AVKit's `VideoPlayer`.
public struct _PixelBufferView: View, _PrimitiveView {
    public typealias Body = Never
    let buffer: CVPixelBuffer
    let fill: Bool

    public init(_ buffer: CVPixelBuffer, fill: Bool = false) {
        self.buffer = buffer
        self.fill = fill
    }

    public func _makeNodes(_ context: BuildContext) -> [LayoutNode] {
        [PixelBufferNode(buffer: buffer, fill: fill)]
    }
}

final class PixelBufferNode: LayoutNode {
    let buffer: CVPixelBuffer
    let fill: Bool

    init(buffer: CVPixelBuffer, fill: Bool) {
        self.buffer = buffer
        self.fill = fill
    }

    override func computeSize(_ p: ProposedViewSize, _ lc: LayoutContext) -> CGSize {
        // Like a resizable image: takes all the proposed space.
        p.replacingUnspecifiedDimensions(by: CGSize(width: buffer.width / 2, height: buffer.height / 2))
    }

    override func draw(in rect: CGRect, _ lc: LayoutContext, _ list: inout DisplayList) {
        guard buffer.width > 0, buffer.height > 0, rect.width > 0, rect.height > 0 else { return }
        let kw = rect.width / CGFloat(buffer.width), kh = rect.height / CGFloat(buffer.height)
        let k = fill ? max(kw, kh) : min(kw, kh)
        let size = CGSize(width: CGFloat(buffer.width) * k, height: CGFloat(buffer.height) * k)
        let target = CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
        if fill { list.append(.pushClip(.rectangle, rect)) }
        list.append(.pixels(buffer, target))
        if fill { list.append(.popClip) }
    }
}
