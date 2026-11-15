import SwiftUI

#if canImport(UIKit)
import UIKit

// Côté iPhone : mesure les cadres exacts calculés par SwiftUI, inspecte les couches
// Core Animation, capture l'écran en sRVB et envoie le tout au PC.

@MainActor
final class CalibrationRecorder {
    static let shared = CalibrationRecorder()
    var frames: [String: CGRect] = [:]
}

extension View {
    func calibrate(_ id: String) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            CalibrationRecorder.shared.frames[id] = frame
        }
    }
}

@MainActor
enum CalibrationRunner {
    /// Adresse du récepteur : argument de lancement `-calibrationServer http://…`, sinon la valeur
    /// générée pour cette machine (CalibrationServer.swift, propre au projet iOS).
    static var server: String? {
        UserDefaults.standard.string(forKey: "calibrationServer") ?? defaultCalibrationServer
    }

    static func run(pageCount: Int, pageIDs: [String], show: @escaping (Int) -> Void, status: @escaping (String) -> Void) async {
        guard let server, let url = URL(string: server + "/upload") else {
            status("Aucun serveur de calibration (argument -calibrationServer).")
            return
        }
        guard let window = keyWindow() else { return }
        let runID = ISO8601DateFormatter().string(from: Date())
        for scheme in [UIUserInterfaceStyle.light, .dark] {
            window.overrideUserInterfaceStyle = scheme
            for index in 0..<pageCount {
                CalibrationRecorder.shared.frames = [:]
                show(index)
                status("")
                try? await Task.sleep(for: .milliseconds(900))
                let payload = measure(window: window, pageID: pageIDs[index], scheme: scheme, runID: runID)
                status("Envoi \(pageIDs[index]) (\(scheme == .light ? "clair" : "sombre"))…")
                try? await Task.sleep(for: .milliseconds(50))
                do {
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONSerialization.data(withJSONObject: payload)
                    _ = try await URLSession.shared.data(for: request)
                } catch {
                    status("Échec de l'envoi : \(error.localizedDescription)")
                    return
                }
            }
        }
        window.overrideUserInterfaceStyle = .unspecified
        status("Calibration terminée ✓")
    }

    static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.keyWindow
    }

    static func measure(window: UIWindow, pageID: String, scheme: UIUserInterfaceStyle, runID: String) -> [String: Any] {
        let frames = CalibrationRecorder.shared.frames
        // Capture sRVB (sans la barre d'état, qui est une autre fenêtre).
        let format = UIGraphicsImageRendererFormat(for: window.traitCollection)
        format.preferredRange = .standard
        format.scale = window.screen.scale
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }

        var layers: [[String: Any]] = []
        func visit(_ layer: CALayer, depth: Int) {
            let frame = layer.convert(layer.bounds, to: window.layer)
            if !layer.isHidden, frames.values.contains(where: { $0.insetBy(dx: -4, dy: -4).intersects(frame) }) {
                layers.append(describe(layer, frame: frame, depth: depth))
            }
            for sub in layer.sublayers ?? [] { visit(sub, depth: depth + 1) }
        }
        visit(window.layer, depth: 0)

        var machine = utsname()
        uname(&machine)
        let model = withUnsafeBytes(of: &machine.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }

        return [
            "source": "ios",
            "run": runID,
            "page": pageID,
            "device": model,
            "system": UIDevice.current.systemVersion,
            "colorScheme": scheme == .dark ? "dark" : "light",
            "screen": ["width": window.bounds.width, "height": window.bounds.height, "scale": window.screen.scale],
            "markers": frames.map { ["id": $0.key, "x": $0.value.minX, "y": $0.value.minY, "width": $0.value.width, "height": $0.value.height] },
            "layers": layers,
            "png": image.pngData()?.base64EncodedString() ?? "",
        ]
    }

    static func srgb(_ color: CGColor?) -> [Double]? {
        guard let color, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let c = color.converted(to: space, intent: .defaultIntent, options: nil)?.components else { return nil }
        return c.map { Double($0) }
    }

    static func describe(_ layer: CALayer, frame: CGRect, depth: Int) -> [String: Any] {
        var d: [String: Any] = [
            "class": String(describing: type(of: layer)),
            "depth": depth,
            "frame": [frame.minX, frame.minY, frame.width, frame.height],
            "cornerRadius": layer.cornerRadius,
            "cornerCurve": layer.cornerCurve.rawValue,
            "opacity": layer.opacity,
            "masksToBounds": layer.masksToBounds,
            "hasContents": layer.contents != nil,
            "hasMask": layer.mask != nil,
            "borderWidth": layer.borderWidth,
        ]
        if let delegate = layer.delegate { d["delegate"] = String(describing: type(of: delegate)) }
        if let bg = srgb(layer.backgroundColor) { d["backgroundColor"] = bg }
        if let border = srgb(layer.borderColor), layer.borderWidth > 0 { d["borderColor"] = border }
        if layer.shadowOpacity > 0 {
            d["shadow"] = ["opacity": layer.shadowOpacity, "radius": layer.shadowRadius,
                           "offset": [layer.shadowOffset.width, layer.shadowOffset.height], "color": srgb(layer.shadowColor) ?? []]
        }
        if let filters = layer.filters, !filters.isEmpty { d["filters"] = filters.map { "\($0)" } }
        if let compositing = layer.compositingFilter { d["compositingFilter"] = "\(compositing)" }
        if let shape = layer as? CAShapeLayer {
            if let fill = srgb(shape.fillColor) { d["fillColor"] = fill }
            if let path = shape.path { d["pathBounds"] = [path.boundingBox.minX, path.boundingBox.minY, path.boundingBox.width, path.boundingBox.height] }
        }
        return d
    }
}

#else

// Côté LSim : l'identifiant d'accessibilité sert de repère de mesure.
extension View {
    func calibrate(_ id: String) -> some View {
        accessibilityIdentifier(id)
    }
}

#endif
