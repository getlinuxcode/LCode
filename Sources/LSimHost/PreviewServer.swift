import CGtk
import Foundation
import LSimUI

/// Headless mode driven by the IDE: the screen is rendered to a raw image file on every change
/// (animations included) and announced on stdout as `frame <width> <height> <stride> <scale>`. Commands on stdin:
///   press x y | move dx dy | release x y | tap x y | scroll x y dy | scheme light|dark | scale s | quit
/// (coordinates in simulated screen points).
extension SimulatorHost {
    func serve(framePath: String) {
        final class State { var dirty = true }
        let state = State()
        graph.onInvalidate = { state.dirty = true }
        setvbuf(stdout, nil, _IOLBF, 0)

        // IDE commands are read on a separate thread and handled on the main loop.
        Thread.detachNewThread { [unowned self] in
            while let line = readLine() {
                let parts = line.split(separator: " ").map(String.init)
                DispatchQueue.main.async { self.handle(parts, state: { state.dirty = true }) }
            }
            DispatchQueue.main.async { exit(0) }
        }

        // At most ~60 fps, and only when something changed or is animating.
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [unowned self] _ in
            guard state.dirty || graph.animator.isAnimating else { return }
            state.dirty = false
            writeFrame(to: framePath)
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.run()
    }

    private func handle(_ parts: [String], state markDirty: () -> Void) {
        guard let command = parts.first else { return }
        let n = parts.dropFirst().compactMap { Double($0) }.map { CGFloat($0) }
        switch command {
        case "press" where n.count == 2:
            updateLayout()
            press(at: CGPoint(x: n[0], y: n[1]))
        case "move" where n.count == 2:
            drag(dx: n[0], dy: n[1])
        case "release" where n.count == 2:
            release(at: CGPoint(x: n[0], y: n[1]))
        case "tap" where n.count == 2:
            updateLayout()
            press(at: CGPoint(x: n[0], y: n[1]))
            release(at: CGPoint(x: n[0], y: n[1]))
        case "scroll" where n.count == 3:
            pointer = CGPoint(x: n[0], y: n[1])
            wheel(dy: Double(n[2]) / 40)
        case "scheme" where parts.count == 2:
            colorScheme = parts[1] == "dark" ? .dark : .light
        case "scale" where n.count == 1:
            // Frames rendered at the displayed pixel size stay sharp (no downscaling in the IDE).
            frameScale = min(max(n[0], 0.25), 6)
        case "quit":
            exit(0)
        default:
            break
        }
        markDirty()
    }

    /// Screen only (rounded corners, status bar, home indicator), premultiplied ARGB32.
    func writeFrame(to path: String) {
        let scale = frameScale
        let width = Int32((device.screenSize.width * scale).rounded()), height = Int32((device.screenSize.height * scale).rounded())
        let surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width, height)!
        let cr = cairo_create(surface)!
        cairo_scale(cr, scale, scale)
        updateLayout()
        let r = CairoRenderer(cr: cr, text: text)
        let screen = CGRect(origin: .zero, size: device.screenSize)
        cairo_save(cr)
        r.path(.roundedRectangle(cornerRadius: device.cornerRadius), screen)
        cairo_clip(cr)
        r.fill(.rectangle, screen, colorScheme == .light ? RGBA(1, 1, 1) : RGBA(0, 0, 0))
        r.draw(displayList)
        drawSystemChrome(r)
        cairo_restore(cr)
        cairo_surface_flush(surface)
        let stride = Int(cairo_image_surface_get_stride(surface))
        if let data = cairo_image_surface_get_data(surface) {
            let bytes = Data(bytes: data, count: stride * Int(height))
            let tmp = path + ".tmp"
            if FileManager.default.createFile(atPath: tmp, contents: bytes) {
                rename(tmp, path)
                // Leading 0x01 byte tells this announcement apart from the app's own print() on the same stdout.
                print("\u{1}frame \(width) \(height) \(stride) \(scale)")
            }
        }
        cairo_destroy(cr)
        cairo_surface_destroy(surface)
    }

    /// `#Preview` entry point: served to the IDE, or shown in a window otherwise.
    public static func runPreview<V: View>(_ content: @escaping () -> V) {
        let env = ProcessInfo.processInfo.environment
        let device = env["LSIM_DEVICE"].flatMap { DeviceProfile.all[$0.lowercased()] } ?? .iPhone16Pro
        let scheme: ColorScheme = env["LSIM_DARK"] == "1" ? .dark : .light
        let host = SimulatorHost(device: device, colorScheme: scheme, zoom: 1) { graph, environment in
            graph.build(environment: environment) { content() }
        }
        if let frame = env["LSIM_PREVIEW_FRAME"] {
            host.serve(framePath: frame)
        } else if let path = env["LSIM_SCREENSHOT"] {
            host.screenshot(to: path, taps: env["LSIM_TAPS"] ?? "")
        } else {
            host.runWindow()
        }
    }
}
