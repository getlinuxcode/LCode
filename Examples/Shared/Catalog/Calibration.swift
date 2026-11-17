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
        // D'abord les SF Symbols, si le PC les demande : noms fournis par iOS + rendu de chacun
        // (appariés aux glyphes de la police sur le PC).
        let config = await fetchConfig(server)
        // Entraîneur de gestes : l'app affiche sa page et envoie elle-même le lot au PC.
        if config["mode"] as? String == "gestures", let index = pageIDs.firstIndex(of: "gesture.trainer") {
            show(index)
            return
        }
        if config["symbols"] as? Bool ?? true {
            await exportSymbols(server: server, runID: runID, status: status)
        }
        // Passe partielle : seules les pages dont l'identifiant commence par l'un des préfixes demandés.
        let prefixes = config["only"] as? [String] ?? []
        let selected = (0..<pageCount).filter { i in
            // L'entraîneur de gestes n'est jamais capturé comme une page.
            !pageIDs[i].hasPrefix("gesture.") && (prefixes.isEmpty || prefixes.contains { pageIDs[i].hasPrefix($0) })
        }
        for scheme in [UIUserInterfaceStyle.light, .dark] {
            window.overrideUserInterfaceStyle = scheme
            for index in selected {
                // Écran vide d'abord : la page est recréée et ses cadres relevés à neuf (sinon une page
                // déjà affichée pendant l'export des symboles ne renverrait aucun cadre).
                show(-1)
                try? await Task.sleep(for: .milliseconds(150))
                CalibrationRecorder.shared.frames = [:]
                let isAnimation = pageIDs[index].hasPrefix("anim.")
                let sampler = isAnimation ? AnimationSampler(window: window) : nil
                AnimationProbe.triggerTime = nil
                show(index)
                status("")
                sampler?.start()
                try? await Task.sleep(for: .milliseconds(isAnimation ? 2600 : 900))
                sampler?.stop()
                var payload = measure(window: window, pageID: pageIDs[index], scheme: scheme, runID: runID)
                if let sampler, let trigger = AnimationProbe.triggerTime {
                    // Position du carré rouge à chaque image, en secondes depuis le déclenchement.
                    // Carré rouge puis carré vert (−9999 : absent de cette image).
                    payload["samples"] = sampler.samples.map { s -> [Double] in
                        let r = s.frame ?? CGRect(x: -9999, y: -9999, width: 0, height: 0)
                        let g = s.green ?? CGRect(x: -9999, y: -9999, width: 0, height: 0)
                        return [s.time - trigger, r.minX, r.minY, r.width, r.height, g.minX, g.minY, g.width, g.height]
                    }
                }
                // Permet au récepteur de savoir quand la série est complète (pages × 2 thèmes).
                payload["pageCount"] = selected.count
                status("Envoi \(pageIDs[index]) (\(scheme == .light ? "clair" : "sombre"))…")
                try? await Task.sleep(for: .milliseconds(50))
                do {
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONSerialization.data(withJSONObject: Self.finite(payload))
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

    // MARK: - SF Symbols

    static func post(_ server: String, _ path: String, _ payload: [String: Any]) async throws {
        var request = URLRequest(url: URL(string: server + path)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        _ = try await URLSession.shared.data(for: request)
    }

    /// Liste des symboles fournie par iOS (bundle système CoreGlyphs), avec un diagnostic de ce qui a été trouvé.
    static func symbolNames() -> (names: [String], aliases: [String: String], info: [String: Any]) {
        let fm = FileManager.default
        var info: [String: Any] = [:]
        var names: [String] = []
        var aliases: [String: String] = [:]
        for base in ["/System/Library/CoreServices/CoreGlyphs.bundle",
                     "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources"] {
            info[base] = (try? fm.contentsOfDirectory(atPath: base))?.sorted().prefix(80).map { $0 } ?? "illisible"
            if names.isEmpty, let order = NSArray(contentsOfFile: base + "/symbol_order.plist") as? [String] {
                names = order
                info["source"] = base + "/symbol_order.plist"
            }
            if names.isEmpty, let availability = NSDictionary(contentsOfFile: base + "/name_availability.plist"),
               let symbols = availability["symbols"] as? [String: Any] {
                names = symbols.keys.sorted()
                info["source"] = base + "/name_availability.plist"
            }
            if aliases.isEmpty, let a = NSDictionary(contentsOfFile: base + "/name_aliases.strings") as? [String: String] {
                aliases = a
            }
        }
        return (names, aliases, info)
    }

    /// Rendu d'un symbole en niveaux de gris (64 × 64, noir sur blanc, ajusté sans déformation) et ses mesures.
    static func renderSymbol(_ name: String) -> (pixels: Data, metrics: [Double])? {
        let config = UIImage.SymbolConfiguration(pointSize: 48, weight: .regular, scale: .medium)
        guard let image = UIImage(systemName: name, withConfiguration: config)?.withTintColor(.black, renderingMode: .alwaysOriginal) else { return nil }
        let side = 64
        var pixels = [UInt8](repeating: 255, count: side * side)
        let ok = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.translateBy(x: 0, y: CGFloat(side))
            ctx.scaleBy(x: 1, y: -1)
            let size = image.size
            let k = min(CGFloat(side) / max(size.width, 1), CGFloat(side) / max(size.height, 1))
            let rect = CGRect(x: (CGFloat(side) - size.width * k) / 2, y: (CGFloat(side) - size.height * k) / 2,
                              width: size.width * k, height: size.height * k)
            UIGraphicsPushContext(ctx)
            image.draw(in: rect)
            UIGraphicsPopContext()
            return true
        }
        guard ok else { return nil }
        let insets = image.alignmentRectInsets
        let metrics = [Double(image.size.width), Double(image.size.height), Double(insets.top), Double(insets.left),
                       Double(insets.bottom), Double(insets.right), Double(image.baselineOffsetFromBottom ?? 0)]
        return (Data(pixels), metrics)
    }

    /// Configuration demandée par le PC : export des symboles, pages à capturer.
    static func fetchConfig(_ server: String) async -> [String: Any] {
        guard let url = URL(string: server + "/config"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return json
    }

    static func exportSymbols(server: String, runID: String, status: @escaping (String) -> Void) async {
        let (names, aliases, info) = symbolNames()
        try? await post(server, "/symbols", ["run": runID, "kind": "info", "count": names.count,
                                             "aliases": aliases, "info": info])
        guard !names.isEmpty else {
            status("Liste des symboles introuvable (voir le diagnostic sur le PC).")
            try? await Task.sleep(for: .seconds(2))
            return
        }
        let batchSize = 300
        for start in stride(from: 0, to: names.count, by: batchSize) {
            status("Symboles \(start)/\(names.count)…")
            var entries: [[String: Any]] = []
            for name in names[start..<min(start + batchSize, names.count)] {
                guard let r = renderSymbol(name) else { continue }
                entries.append(["name": name, "pixels": r.pixels.base64EncodedString(), "metrics": r.metrics])
            }
            try? await post(server, "/symbols", ["run": runID, "kind": "batch", "start": start, "total": names.count, "symbols": entries])
            await Task.yield()
        }
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
            let finite = frame.minX.isFinite && frame.minY.isFinite && frame.width.isFinite && frame.height.isFinite
            if !layer.isHidden, finite, frames.values.contains(where: { $0.insetBy(dx: -4, dy: -4).intersects(frame) }) {
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

    /// Remplace les nombres non finis (infini, NaN) : JSONSerialization lèverait une exception (plantage).
    static func finite(_ value: Any) -> Any {
        switch value {
        case let d as Double: return d.isFinite ? d : 0
        case let f as CGFloat: return f.isFinite ? Double(f) : 0
        case let f as Float: return f.isFinite ? Double(f) : 0
        case let a as [Any]: return a.map(finite)
        case let m as [String: Any]: return m.mapValues(finite)
        default: return value
        }
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
            // Tracé vide : encombrement infini (CGRect.null), illisible en JSON.
            if let path = shape.path, !path.isEmpty, !path.boundingBox.isNull, !path.boundingBox.isInfinite {
                d["pathBounds"] = [path.boundingBox.minX, path.boundingBox.minY, path.boundingBox.width, path.boundingBox.height]
            }
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

#if canImport(UIKit)
/// Relève, à chaque image de l'écran, le cadre présenté de la couche rouge (carré des pages anim.*).
@MainActor
final class AnimationSampler: NSObject {
    let window: UIWindow
    var samples: [(time: Double, frame: CGRect?, green: CGRect?)] = []
    private var link: CADisplayLink?

    init(window: UIWindow) { self.window = window }

    func start() {
        link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link?.preferredFrameRateRange = CAFrameRateRange(minimum: 120, maximum: 120, preferred: 120)
        link?.add(to: .main, forMode: .common)
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let red = Self.find(in: window.layer, root: window.layer, red: true)
        let green = Self.find(in: window.layer, root: window.layer, red: false)
        guard red != nil || green != nil else { return }
        samples.append((CACurrentMediaTime(), red, green))
    }

    /// Couche pure rouge (ou verte) de 50 à 70 pt de large, en coordonnées de la fenêtre présentée.
    static func find(in layer: CALayer, root: CALayer, red: Bool) -> CGRect? {
        let presented = layer.presentation() ?? layer
        if let c = presented.backgroundColor?.components, c.count >= 3,
           red ? (c[0] > 0.95 && c[1] < 0.05) : (c[1] > 0.95 && c[0] < 0.05), c[2] < 0.05,
           presented.bounds.width > 50, presented.bounds.width < 70 {
            return presented.convert(presented.bounds, to: root.presentation() ?? root)
        }
        for sub in layer.sublayers ?? [] {
            if let f = find(in: sub, root: root, red: red) { return f }
        }
        return nil
    }
}
#endif
