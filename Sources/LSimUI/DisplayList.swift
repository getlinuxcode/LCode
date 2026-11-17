import CoreVideo
import Foundation

public enum ShapeKind: Hashable, Sendable {
    case rectangle
    case roundedRectangle(cornerRadius: CGFloat)
    case capsule
    case ellipse
    case circle
}

/// Backend-independent list of drawing commands.
public enum DisplayItem {
    case fill(ShapeKind, CGRect, RGBA)
    case stroke(ShapeKind, CGRect, RGBA, lineWidth: CGFloat)
    case text(String, Font, CGRect, RGBA, TextAlignment)
    /// SF Symbol fitted to the rect.
    case symbol(String, Font, Image.Scale, CGRect, RGBA)
    /// Asset catalog image (PNG, JPEG, SVG…) stretched to the rect.
    case image(String, CGRect)
    /// In-memory video frame (premultiplied BGRA) stretched to the rect.
    case pixels(CVPixelBuffer, CGRect)
    /// Chevron (›) or back arrow (‹) drawn as strokes.
    case chevron(CGRect, RGBA, lineWidth: CGFloat, pointingLeft: Bool)
    case pushOpacity(Double)
    case popOpacity
    /// Translation and scale around a point (transitions).
    case pushTransform(dx: CGFloat, dy: CGFloat, scale: CGFloat, anchor: CGPoint)
    case popTransform
    case pushClip(ShapeKind, CGRect)
    case popClip
    /// Vertical fade from an opaque color (top) to transparent (bottom).
    case fade(CGRect, RGBA)
    /// Material: blurs what is already drawn in the area, then applies a tinted veil.
    case backdrop(CGRect, blur: CGFloat, tint: RGBA, shape: ShapeKind = .rectangle)
    /// Measured scroll edge effect: progressive blur, transmission and veil per row.
    /// The second rect positions the table (its y = 0 is at the rect's top, offset by `shift`).
    case scrollEdge(CGRect, ScrollEdgeTable, shift: CGFloat)
    /// Linear gradient in a shape: colors, locations (0…1), start and end points.
    case linearGradient(ShapeKind, CGRect, [RGBA], [CGFloat], CGPoint, CGPoint)
    /// Liquid Glass: refraction, blur, saturation, veil and rim over what is already drawn.
    case glass(ShapeKind, CGRect, GlassRender)
    /// Hit area (button, onTapGesture). Areas drawn last are on top.
    case hitRegion(id: String, CGRect)
    /// Measurement marker (`accessibilityIdentifier`): frame of the identified view.
    case marker(id: String, CGRect)
    /// Drag gesture area (swipe back, sheet pull-down); `vertical`: gesture direction.
    case panRegion(id: String, CGRect, vertical: Bool)
    /// Scrollable area: state id, visible rect.
    case scrollRegion(id: String, CGRect)
}

public struct DisplayList {
    public var items: [DisplayItem] = []
    private var clips: [CGRect] = []

    public init() {}

    mutating func append(_ item: DisplayItem) {
        switch item {
        case let .pushClip(_, rect):
            clips.append(clips.last.map { $0.intersection(rect) } ?? rect)
        case .popClip:
            _ = clips.popLast()
        case let .hitRegion(id, rect):
            // A hit area hidden by a clip (scrolled list) is not tappable.
            let visible = clips.last.map { $0.intersection(rect) } ?? rect
            guard !visible.isNull, !visible.isEmpty else { return }
            items.append(.hitRegion(id: id, visible))
            return
        case let .scrollRegion(id, rect):
            let visible = clips.last.map { $0.intersection(rect) } ?? rect
            items.append(.scrollRegion(id: id, visible))
            return
        default:
            break
        }
        items.append(item)
    }

    /// Appends another list's items, honoring the current clips.
    mutating func append(contentsOf other: DisplayList) {
        for item in other.items { append(item) }
    }

    /// Topmost hit area under the point.
    public func hitTest(_ point: CGPoint) -> String? {
        for item in items.reversed() {
            if case let .hitRegion(id, rect) = item, rect.contains(point) { return id }
        }
        return nil
    }

    /// Measurement markers (id → frame).
    public var markers: [(id: String, rect: CGRect)] {
        // Active transforms (transitions) apply to markers as they do to drawing.
        var stack: [(dx: CGFloat, dy: CGFloat, scale: CGFloat, anchor: CGPoint)] = []
        var out: [(id: String, rect: CGRect)] = []
        for item in items {
            switch item {
            case let .pushTransform(dx, dy, scale, anchor): stack.append((dx, dy, scale, anchor))
            case .popTransform: _ = stack.popLast()
            case let .marker(id, r):
                var rect = r
                for t in stack.reversed() {
                    rect = CGRect(x: t.anchor.x + (rect.minX - t.anchor.x) * t.scale + t.dx,
                                  y: t.anchor.y + (rect.minY - t.anchor.y) * t.scale + t.dy,
                                  width: rect.width * t.scale, height: rect.height * t.scale)
                }
                out.append((id, rect))
            default: break
            }
        }
        return out
    }

    /// Topmost scrollable area under the point.
    /// Topmost gesture area under the point, for the given direction.
    public func panTarget(_ point: CGPoint, vertical: Bool) -> String? {
        for item in items.reversed() {
            if case let .panRegion(id, rect, v) = item, v == vertical, rect.contains(point) { return id }
        }
        return nil
    }

    public func scrollTarget(_ point: CGPoint) -> String? {
        for item in items.reversed() {
            if case let .scrollRegion(id, rect) = item, rect.contains(point) { return id }
        }
        return nil
    }
}

/// Text measurement: provided by the backend (Pango) or a fake measurer in tests.
public protocol TextMeasurer {
    func measure(_ text: String, font: Font, maxWidth: CGFloat?) -> CGSize
    /// SF Symbol measurement (nil if unknown).
    func measureSymbol(_ name: String, font: Font, scale: Image.Scale) -> SymbolMetrics?
    /// Pixel size of an image file (nil if unreadable).
    func measureImage(_ path: String) -> CGSize?
}

extension TextMeasurer {
    public func measureSymbol(_ name: String, font: Font, scale: Image.Scale) -> SymbolMetrics? { nil }
    public func measureImage(_ path: String) -> CGSize? { nil }
}

public final class LayoutContext {
    public let measurer: TextMeasurer
    public let colorScheme: ColorScheme
    /// Full screen and safe areas, so backgrounds (List, bars) can extend under the status bar.
    public let screen: CGRect
    public let safeArea: EdgeInsets
    /// Pixels per point of the simulated device (3 on recent iPhones).
    public var displayScale: CGFloat = 3
    /// Graph animator (nil: no animation).
    public var animator: Animator?

    public init(measurer: TextMeasurer, colorScheme: ColorScheme, screen: CGRect = .zero, safeArea: EdgeInsets = EdgeInsets()) {
        self.measurer = measurer
        self.colorScheme = colorScheme
        self.screen = screen
        self.safeArea = safeArea
    }

    /// Extends a rect to the screen edges if it touches the safe area edges.
    func extendingIntoSafeArea(_ rect: CGRect) -> CGRect {
        guard screen != .zero else { return rect }
        var r = rect
        if abs(rect.minY - (screen.minY + safeArea.top)) < 0.5 {
            r.origin.y = screen.minY
            r.size.height += safeArea.top
        }
        if abs(rect.maxY - (screen.maxY - safeArea.bottom)) < 0.5 {
            r.size.height += safeArea.bottom
        }
        return r
    }
}
