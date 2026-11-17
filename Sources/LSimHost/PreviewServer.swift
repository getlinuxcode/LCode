import CGtk
import Foundation
import LSimUI

/// Mode aperçu, piloté par l'IDE (sans fenêtre) : l'écran est rendu dans un fichier d'image brute à
/// chaque changement (animations comprises), annoncé sur la sortie standard par
/// « frame <largeur> <hauteur> <pas> » ; les gestes arrivent sur l'entrée standard :
///   press x y | move dx dy | release x y | tap x y | scroll x y dy | scheme light|dark | quit
/// (coordonnées en points de l'écran simulé).
extension SimulatorHost {
    /// Pixels par point des images envoyées à l'IDE.
    static let previewScale: CGFloat = 2

    func serve(framePath: String) {
        final class State { var dirty = true }
        let state = State()
        graph.onInvalidate = { state.dirty = true }
        setvbuf(stdout, nil, _IOLBF, 0)

        // Commandes de l'IDE, lues sur un fil à part puis traitées sur la boucle principale.
        Thread.detachNewThread { [unowned self] in
            while let line = readLine() {
                let parts = line.split(separator: " ").map(String.init)
                DispatchQueue.main.async { self.handle(parts, state: { state.dirty = true }) }
            }
            DispatchQueue.main.async { exit(0) }
        }

        // Boucle : ~60 images/s au plus, seulement si quelque chose a changé ou s'anime.
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
        case "quit":
            exit(0)
        default:
            break
        }
        markDirty()
    }

    /// Écran seul (coins arrondis, barre d'état, indicateur d'accueil), en ARGB32 prémultiplié.
    func writeFrame(to path: String) {
        let scale = Self.previewScale
        let width = Int32(device.screenSize.width * scale), height = Int32(device.screenSize.height * scale)
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
                print("frame \(width) \(height) \(stride)")
            }
        }
        cairo_destroy(cr)
        cairo_surface_destroy(surface)
    }

    /// Point d'entrée d'un aperçu (`#Preview`) : servi à l'IDE, ou dans une fenêtre à défaut.
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
