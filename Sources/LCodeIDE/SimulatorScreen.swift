import CAdw
import Foundation

/// Screen of a windowless LSim app (preview or running app): shows the frames the process writes to a file
/// and sends gestures (press, drag, scroll) back in screen points.
final class SimulatorScreen {
    let picture: UnsafeMutablePointer<GtkWidget>
    /// Raw frame file shared with the process (LSIM_PREVIEW_FRAME / LSIM_SERVE_FRAME).
    let framePath: String
    /// Sends a command to the process (press, move, release, scroll, scheme…).
    var send: (String) -> Void = { _ in }
    private(set) var frameSize = CGSize(width: 440, height: 956)
    private var dragStart: (Double, Double)?

    init(name: String) {
        framePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("lcode-\(name)-\(getpid())-\(UUID().uuidString.prefix(6)).raw").path
        picture = gtk_picture_new()!
        gtk_picture_set_content_fit(cast(raw(picture)), GTK_CONTENT_FIT_CONTAIN)
        gtk_picture_set_can_shrink(cast(raw(picture)), 1)
        gtk_widget_set_vexpand(picture, 1)
        gtk_widget_set_hexpand(picture, 1)
        gtk_widget_set_margin_start(picture, 16); gtk_widget_set_margin_end(picture, 16)
        gtk_widget_set_margin_bottom(picture, 16)
        installGestures()
        watchSize()
    }

    /// Resizes have no signal on GtkPicture: check the displayed size a few times per second.
    private func watchSize() {
        final class Box { weak var screen: SimulatorScreen?; init(_ s: SimulatorScreen) { screen = s } }
        let box = Unmanaged.passRetained(Box(self)).toOpaque()
        let tick: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { data in
            let box = Unmanaged<Box>.fromOpaque(data!)
            guard let screen = box.takeUnretainedValue().screen else { box.release(); return 0 }
            if gtk_widget_get_mapped(screen.picture) != 0 { screen.syncRenderScale() }
            return 1
        }
        g_timeout_add(250, tick, box)
    }

    deinit { try? FileManager.default.removeItem(atPath: framePath) }

    struct Frame { var width, height, stride: Int; var scale: Double }

    /// Parses a `frame <width> <height> <stride> [<scale>]` line (prefixed with 0x01 to tell it apart from the
    /// app's print()s); nil for any other line.
    static func parseFrame(_ line: String) -> Frame? {
        let trimmed = line.hasPrefix("\u{1}") ? String(line.dropFirst()) : line
        guard trimmed.hasPrefix("frame ") else { return nil }
        let n = trimmed.split(separator: " ").dropFirst().compactMap { Double($0) }
        guard n.count == 3 || n.count == 4 else { return nil }
        return Frame(width: Int(n[0]), height: Int(n[1]), stride: Int(n[2]), scale: n.count == 4 ? n[3] : 2)
    }

    /// Render scale last requested from the process.
    private var requestedScale = 2.0

    /// Pixels per point at which the frame is actually displayed (widget size × monitor scale).
    private var displayScale: Double? {
        let w = Double(gtk_widget_get_width(picture)), h = Double(gtk_widget_get_height(picture))
        guard w > 1, h > 1 else { return nil }
        var monitor = Double(gtk_widget_get_scale_factor(picture))
        if let native = gtk_widget_get_native(picture), let surface = gtk_native_get_surface(native) {
            monitor = gdk_surface_get_scale(surface)
        }
        return min(w / Double(frameSize.width), h / Double(frameSize.height)) * monitor
    }

    /// Render scale for a process about to start (passed as LSIM_FRAME_SCALE): its first frame is already sharp.
    func scaleForNewProcess() -> Double {
        requestedScale = displayScale ?? 2
        return requestedScale
    }

    /// Asks the process to render at the displayed size when it changed (window or pane resized).
    func syncRenderScale() {
        guard let wanted = displayScale, abs(wanted - requestedScale) / requestedScale > 0.02 else { return }
        requestedScale = wanted
        send("scale \(wanted)")
    }

    func load(_ frame: Frame) {
        loadFrame(width: frame.width, height: frame.height, stride: frame.stride, scale: frame.scale)
    }

    func loadFrame(width: Int, height: Int, stride: Int, scale: Double) {
        guard let data = FileManager.default.contents(atPath: framePath), data.count >= stride * height else { return }
        let bytes = data.withUnsafeBytes { g_bytes_new($0.baseAddress, gsize(data.count)) }
        let texture = gdk_memory_texture_new(Int32(width), Int32(height), GDK_MEMORY_B8G8R8A8_PREMULTIPLIED, bytes, gsize(stride))
        gtk_picture_set_paintable(cast(raw(picture)), texture)
        g_object_unref(UnsafeMutableRawPointer(texture))
        g_bytes_unref(bytes)
        gtk_widget_set_opacity(picture, 1)
        frameSize = CGSize(width: CGFloat(Double(width) / scale), height: CGFloat(Double(height) / scale))
        syncRenderScale()
    }

    func clear() {
        gtk_picture_set_paintable(cast(raw(picture)), nil)
    }

    // MARK: - Gestures → app

    /// Simulated screen point (in points) under a widget point.
    private func screenPoint(_ x: Double, _ y: Double) -> (Double, Double)? {
        let w = Double(gtk_widget_get_width(picture)), h = Double(gtk_widget_get_height(picture))
        let fw = Double(frameSize.width), fh = Double(frameSize.height)
        guard w > 0, h > 0 else { return nil }
        let s = min(w / fw, h / fh)
        let ox = (w - fw * s) / 2, oy = (h - fh * s) / 2
        let px = (x - ox) / s, py = (y - oy) / s
        guard px >= 0, py >= 0, px <= fw, py <= fh else { return nil }
        return (px, py)
    }

    private var scale: Double {
        let w = Double(gtk_widget_get_width(picture)), h = Double(gtk_widget_get_height(picture))
        return max(0.01, min(w / Double(frameSize.width), h / Double(frameSize.height)))
    }

    private func installGestures() {
        let drag = gtk_gesture_drag_new()!
        final class Box { weak var screen: SimulatorScreen?; init(_ s: SimulatorScreen) { screen = s } }
        let box = Unmanaged.passRetained(Box(self)).toOpaque()
        let begin: @convention(c) (OpaquePointer?, Double, Double, UnsafeMutableRawPointer?) -> Void = { _, x, y, data in
            guard let s = Unmanaged<Box>.fromOpaque(data!).takeUnretainedValue().screen, let p = s.screenPoint(x, y) else { return }
            s.dragStart = p
            s.send("press \(p.0) \(p.1)")
        }
        let update: @convention(c) (OpaquePointer?, Double, Double, UnsafeMutableRawPointer?) -> Void = { _, dx, dy, data in
            guard let s = Unmanaged<Box>.fromOpaque(data!).takeUnretainedValue().screen, s.dragStart != nil else { return }
            s.send("move \(dx / s.scale) \(dy / s.scale)")
        }
        let end: @convention(c) (OpaquePointer?, Double, Double, UnsafeMutableRawPointer?) -> Void = { _, dx, dy, data in
            guard let s = Unmanaged<Box>.fromOpaque(data!).takeUnretainedValue().screen, let start = s.dragStart else { return }
            s.send("release \(start.0 + dx / s.scale) \(start.1 + dy / s.scale)")
            s.dragStart = nil
        }
        _ = lcode_connect(raw(drag), "drag-begin", unsafeBitCast(begin, to: GCallback.self), box)
        _ = lcode_connect(raw(drag), "drag-update", unsafeBitCast(update, to: GCallback.self), box)
        _ = lcode_connect(raw(drag), "drag-end", unsafeBitCast(end, to: GCallback.self), box)
        gtk_widget_add_controller(picture, drag)

        let scroll = gtk_event_controller_scroll_new(GTK_EVENT_CONTROLLER_SCROLL_VERTICAL)!
        let onScroll: @convention(c) (OpaquePointer?, Double, Double, UnsafeMutableRawPointer?) -> gboolean = { _, _, dy, data in
            guard let s = Unmanaged<Box>.fromOpaque(data!).takeUnretainedValue().screen else { return 0 }
            s.send("scroll \(s.frameSize.width / 2) \(s.frameSize.height / 2) \(dy * 40)")
            return 1
        }
        _ = lcode_connect(raw(scroll), "scroll", unsafeBitCast(onScroll, to: GCallback.self), box)
        gtk_widget_add_controller(picture, scroll)
    }
}
