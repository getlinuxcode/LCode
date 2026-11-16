import CGtk
import Foundation
import LSimUI
import Observation

/// Fenêtre du simulateur : habillage de l'appareil, rendu, événements.
///
/// Variables d'environnement :
/// - `LSIM_DEVICE`     : `iphone16pro` (défaut) ou `iphonese`
/// - `LSIM_DARK=1`     : démarre en mode sombre
/// - `LSIM_DESIGN=compat` : style iOS 18 (apps liées avec un SDK antérieur à iOS 26)
/// - `LSIM_ZOOM`       : facteur d'échelle de la fenêtre (défaut 1)
/// - `LSIM_SCREENSHOT` : rend une image PNG dans ce fichier puis quitte (sans fenêtre)
/// - `LSIM_SCROLL`     : défilement (en points) de la première zone défilante avant la capture
/// - `LSIM_SCREEN_ONLY=1` : capture du seul contenu de l'écran, @3x (calibration)
/// - `LSIM_DUMP`       : écrit les repères `accessibilityIdentifier` en JSON (calibration)
/// - `LSIM_TAPS`       : touchers à simuler avant la capture, en points écran : `x,y;x,y`
public final class SimulatorHost {
    let device: DeviceProfile
    let graph = ViewGraph()
    let text = PangoText()
    let buildRoot: (ViewGraph, EnvironmentValues) -> [LayoutNode]
    var colorScheme: ColorScheme
    var zoom: CGFloat
    var displayList = DisplayList()
    var area: UnsafeMutablePointer<GtkWidget>?
    var running = true
    var redrawScheduled = false

    static let margin: CGFloat = 24

    init(device: DeviceProfile, colorScheme: ColorScheme, zoom: CGFloat, buildRoot: @escaping (ViewGraph, EnvironmentValues) -> [LayoutNode]) {
        self.device = device
        self.colorScheme = colorScheme
        self.zoom = zoom
        self.buildRoot = buildRoot
        graph.onInvalidate = { [unowned self] in self.scheduleRedraw() }
    }

    public static func run<A: App>(_ app: A) {
        let env = ProcessInfo.processInfo.environment
        let device = env["LSIM_DEVICE"].flatMap { DeviceProfile.all[$0.lowercased()] } ?? .iPhone16Pro
        let scheme: ColorScheme = env["LSIM_DARK"] == "1" ? .dark : .light
        if env["LSIM_DESIGN"] == "compat" { DesignStyle.current = .compatibility }
        let zoom = env["LSIM_ZOOM"].flatMap(Double.init).map { CGFloat($0) } ?? 1
        let host = SimulatorHost(device: device, colorScheme: scheme, zoom: zoom) { graph, environment in
            graph.build(environment: environment, app: app) { _rootView(of: app.body) }
        }
        if let path = env["LSIM_SCREENSHOT"] {
            host.screenshot(to: path, taps: env["LSIM_TAPS"] ?? "")
        } else {
            host.runWindow()
        }
    }

    // MARK: - Géométrie

    var outerSize: CGSize {
        CGSize(
            width: device.screenSize.width + 2 * (device.bezel + Self.margin),
            height: device.screenSize.height + 2 * (device.bezel + Self.margin)
        )
    }

    var screenOrigin: CGPoint {
        CGPoint(x: Self.margin + device.bezel, y: Self.margin + device.bezel)
    }

    // MARK: - Rendu

    /// Reconstruit l'arbre de vues et recalcule le layout (avec suivi des objets @Observable).
    func updateLayout() {
        var environment = EnvironmentValues()
        environment.colorScheme = colorScheme
        let nodes = withObservationTracking {
            buildRoot(graph, environment)
        } onChange: { [unowned self] in
            self.scheduleRedraw()
        }
        let lc = LayoutContext(measurer: text, colorScheme: colorScheme, screen: device.screenRect, safeArea: device.safeArea)
        displayList = layoutRoot(nodes, in: device.contentRect, lc, presentations: graph.presentations)
    }

    func draw(_ cr: OpaquePointer) {
        updateLayout()
        let r = CairoRenderer(cr: cr, text: text)
        cairo_save(cr)
        cairo_scale(cr, zoom, zoom)

        // Fond de la fenêtre.
        r.fill(.rectangle, CGRect(origin: .zero, size: outerSize), RGBA(0.16, 0.16, 0.17))

        // Châssis de l'appareil.
        let screen = CGRect(origin: screenOrigin, size: device.screenSize)
        let body = screen.insetBy(dx: -device.bezel, dy: -device.bezel)
        let bodyRadius = device.cornerRadius > 0 ? device.cornerRadius + device.bezel : 28
        r.fill(.roundedRectangle(cornerRadius: bodyRadius), body.insetBy(dx: -1.5, dy: -1.5), RGBA(0.42, 0.42, 0.44))
        r.fill(.roundedRectangle(cornerRadius: bodyRadius), body, RGBA(0.04, 0.04, 0.05))

        // Écran.
        cairo_save(cr)
        r.path(.roundedRectangle(cornerRadius: device.cornerRadius), screen)
        cairo_clip(cr)
        r.fill(.rectangle, screen, colorScheme == .light ? RGBA(1, 1, 1) : RGBA(0, 0, 0))
        cairo_translate(cr, screen.minX, screen.minY)
        r.draw(displayList)
        drawSystemChrome(r)
        cairo_restore(cr)

        cairo_restore(cr)
    }

    /// Barre d'état, Dynamic Island et indicateur d'accueil.
    func drawSystemChrome(_ r: CairoRenderer) {
        let w = device.screenSize.width
        let fg: RGBA = colorScheme == .light ? RGBA(0, 0, 0) : RGBA(1, 1, 1)
        let statusCenterY: CGFloat = device.hasDynamicIsland ? 29.5 : 10
        let timeFont = Font.system(size: device.hasDynamicIsland ? 17 : 12, weight: .semibold)

        let time = "9:41"
        let timeSize = text.measure(time, font: timeFont, maxWidth: nil)
        let timeCenterX: CGFloat = device.hasDynamicIsland ? 72 : w / 2
        r.drawText(time, font: timeFont, at: CGPoint(x: timeCenterX - timeSize.width / 2, y: statusCenterY - timeSize.height / 2),
                   width: nil, color: fg, alignment: .leading)

        // Batterie.
        let scale: CGFloat = device.hasDynamicIsland ? 1 : 0.8
        let batteryW = 25 * scale, batteryH = 12 * scale
        let batteryX = w - (device.hasDynamicIsland ? 44 : 12) - batteryW
        let battery = CGRect(x: batteryX, y: statusCenterY - batteryH / 2, width: batteryW, height: batteryH)
        r.setColor(RGBA(fg.r, fg.g, fg.b, 0.4))
        r.path(.roundedRectangle(cornerRadius: 3.5 * scale), battery)
        cairo_set_line_width(r.cr, 1)
        cairo_stroke(r.cr)
        r.fill(.roundedRectangle(cornerRadius: 2 * scale), battery.insetBy(dx: 2 * scale, dy: 2 * scale), fg)
        r.fill(.roundedRectangle(cornerRadius: 1), CGRect(x: battery.maxX + 1.5, y: statusCenterY - 2, width: 1.5, height: 4), RGBA(fg.r, fg.g, fg.b, 0.4))

        // Wi-Fi : trois arcs concentriques.
        let wifiCenter = CGPoint(x: battery.minX - 17 * scale, y: statusCenterY + 5 * scale)
        cairo_set_line_cap(r.cr, CAIRO_LINE_CAP_ROUND)
        r.setColor(fg)
        for (i, radius) in [3.0, 7.0, 11.0].enumerated() {
            cairo_new_path(r.cr)
            if i == 0 {
                cairo_arc(r.cr, wifiCenter.x, wifiCenter.y - 1, 2 * scale, 0, 2 * .pi)
                cairo_fill(r.cr)
            } else {
                cairo_set_line_width(r.cr, 2.2 * scale)
                cairo_arc(r.cr, wifiCenter.x, wifiCenter.y, radius * scale, -.pi * 3 / 4, -.pi / 4)
                cairo_stroke(r.cr)
            }
        }

        // Réseau cellulaire : quatre barres.
        let barsRight = wifiCenter.x - 16 * scale
        for i in 0..<4 {
            let h = (4 + CGFloat(i) * 2.6) * scale
            let x = barsRight - CGFloat(4 - i) * 5 * scale
            r.fill(.roundedRectangle(cornerRadius: 1), CGRect(x: x, y: statusCenterY + 6 * scale - h, width: 3 * scale, height: h), fg)
        }

        if device.hasDynamicIsland {
            r.fill(.capsule, CGRect(x: (w - 126) / 2, y: 11, width: 126, height: 37), RGBA(0, 0, 0))
            let indicator = CGRect(x: (w - 144) / 2, y: device.screenSize.height - 13, width: 144, height: 5)
            r.fill(.capsule, indicator, fg)
        }
    }

    // MARK: - Événements

    func toScreen(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: CGFloat(x) / zoom - screenOrigin.x, y: CGFloat(y) / zoom - screenOrigin.y)
    }

    var dragStart: CGPoint?
    var dragLast: CGFloat = 0
    var dragScrollID: String?
    var isScrolling = false
    var pointer = CGPoint.zero

    /// Contrôle qui suit le doigt (Slider) pendant le geste en cours.
    var dragControlID: String?

    func press(at point: CGPoint) {
        dragStart = point
        dragLast = 0
        dragLastX = 0
        isScrolling = false
        dragScrollID = displayList.scrollTarget(point)
        let hit = displayList.hitTest(point)
        // Toucher hors du champ actif : le clavier se ferme.
        if hit != graph.focusedID { graph.resignFocus() }
        if let hit, let handler = graph.dragHandlers[hit] {
            dragControlID = hit
            handler(point)
        } else {
            graph.pressedID = hit
        }
        queueDraw()
    }

    /// Déplacement du doigt (souris enfoncée) : un contrôle glissable le suit ; sinon, au-delà de 8 pt,
    /// le geste devient un défilement (horizontal pour les ScrollView horizontales).
    func drag(dx: CGFloat, dy: CGFloat) {
        guard let start = dragStart else { return }
        if let control = dragControlID {
            graph.dragHandlers[control]?(CGPoint(x: start.x + dx, y: start.y + dy))
            return
        }
        if !isScrolling, hypot(dx, dy) > 8, dragScrollID != nil {
            isScrolling = true
            graph.pressedID = nil
        }
        if isScrolling, let id = dragScrollID {
            if graph.horizontalScrolls.contains(id) {
                graph.scroll(id, by: -(dx - dragLastX))
            } else {
                graph.scroll(id, by: -(dy - dragLast))
            }
        }
        dragLast = dy
        dragLastX = dx
    }

    var dragLastX: CGFloat = 0

    func release(at point: CGPoint) {
        let pressed = graph.pressedID
        graph.pressedID = nil
        if dragControlID == nil, !isScrolling, let pressed, displayList.hitTest(point) == pressed {
            graph.performAction(pressed)
        }
        dragControlID = nil
        dragStart = nil
        isScrolling = false
        queueDraw()
    }

    /// Clavier : la frappe va au champ de texte actif ; sinon raccourcis du simulateur (D, Q).
    func key(_ keyval: UInt32) -> Bool {
        if graph.hasFocusedTextField {
            switch keyval {
            case 0xff08: graph.deleteBackward()                 // Retour arrière
            case 0xff0d, 0xff8d: graph.submitText()             // Entrée
            case 0xff1b: graph.resignFocus()                    // Échap
            default:
                let code = gdk_keyval_to_unicode(keyval)
                guard code >= 0x20, let scalar = Unicode.Scalar(code) else { return false }
                graph.insertText(String(Character(scalar)))
            }
            return true
        }
        switch keyval {
        case 0x64, 0x44: toggleColorScheme(); return true
        case 0x71, 0x51: running = false; return true
        default: return false
        }
    }

    /// Molette : défile la zone sous le pointeur.
    func wheel(dy: Double) {
        guard let id = displayList.scrollTarget(pointer) else { return }
        graph.scroll(id, by: CGFloat(dy) * 40)
    }

    func toggleColorScheme() {
        colorScheme = colorScheme == .light ? .dark : .light
        queueDraw()
    }

    func queueDraw() {
        redrawScheduled = false
        if let area { gtk_widget_queue_draw(area) }
    }

    /// Peut être appelé depuis n'importe quel fil : le rendu est replanifié sur la boucle GTK.
    func scheduleRedraw() {
        guard area != nil, !redrawScheduled else { return }
        redrawScheduled = true
        let cb: @convention(c) (gpointer?) -> gboolean = { data in
            Unmanaged<SimulatorHost>.fromOpaque(data!).takeUnretainedValue().queueDraw()
            return 0
        }
        g_idle_add(cb, Unmanaged.passUnretained(self).toOpaque())
    }

    // MARK: - Fenêtre GTK

    func runWindow() {
        gtk_init()
        let me = Unmanaged.passRetained(self).toOpaque()

        let window = gtk_window_new()!
        let gtkWindow = OpaquePointer(window)
        gtk_window_set_title(UnsafeMutablePointer(gtkWindow), "LCode Simulator — \(device.name)")
        gtk_window_set_default_size(UnsafeMutablePointer(gtkWindow), Int32(outerSize.width * zoom), Int32(outerSize.height * zoom))
        gtk_window_set_resizable(UnsafeMutablePointer(gtkWindow), 0)

        let area = gtk_drawing_area_new()!
        self.area = area
        let drawFunc: @convention(c) (UnsafeMutablePointer<GtkDrawingArea>?, OpaquePointer?, Int32, Int32, gpointer?) -> Void = { _, cr, _, _, data in
            Unmanaged<SimulatorHost>.fromOpaque(data!).takeUnretainedValue().draw(cr!)
        }
        gtk_drawing_area_set_draw_func(UnsafeMutablePointer(OpaquePointer(area)), drawFunc, me, nil)

        // Souris enfoncée = doigt : un glisser fait défiler, un clic sans mouvement est un toucher.
        let dragGesture = gtk_gesture_drag_new()!
        let dragBegin: @convention(c) (OpaquePointer?, Double, Double, gpointer?) -> Void = { _, x, y, data in
            let host = Unmanaged<SimulatorHost>.fromOpaque(data!).takeUnretainedValue()
            host.press(at: host.toScreen(x, y))
        }
        let dragUpdate: @convention(c) (OpaquePointer?, Double, Double, gpointer?) -> Void = { _, dx, dy, data in
            let host = Unmanaged<SimulatorHost>.fromOpaque(data!).takeUnretainedValue()
            host.drag(dx: CGFloat(dx) / host.zoom, dy: CGFloat(dy) / host.zoom)
        }
        let dragEnd: @convention(c) (OpaquePointer?, Double, Double, gpointer?) -> Void = { gesture, dx, dy, data in
            let host = Unmanaged<SimulatorHost>.fromOpaque(data!).takeUnretainedValue()
            var x = 0.0, y = 0.0
            gtk_gesture_drag_get_start_point(gesture, &x, &y)
            host.release(at: host.toScreen(x + dx, y + dy))
        }
        lsim_signal_connect(UnsafeMutableRawPointer(dragGesture), "drag-begin", unsafeBitCast(dragBegin, to: GCallback.self), me)
        lsim_signal_connect(UnsafeMutableRawPointer(dragGesture), "drag-update", unsafeBitCast(dragUpdate, to: GCallback.self), me)
        lsim_signal_connect(UnsafeMutableRawPointer(dragGesture), "drag-end", unsafeBitCast(dragEnd, to: GCallback.self), me)
        gtk_widget_add_controller(area, dragGesture)

        // Molette et pavé tactile.
        let scroller = gtk_event_controller_scroll_new(GTK_EVENT_CONTROLLER_SCROLL_VERTICAL)!
        let onScroll: @convention(c) (OpaquePointer?, Double, Double, gpointer?) -> gboolean = { _, _, dy, data in
            Unmanaged<SimulatorHost>.fromOpaque(data!).takeUnretainedValue().wheel(dy: dy)
            return 1
        }
        lsim_signal_connect(UnsafeMutableRawPointer(scroller), "scroll", unsafeBitCast(onScroll, to: GCallback.self), me)
        gtk_widget_add_controller(area, scroller)

        let motion = gtk_event_controller_motion_new()!
        let onMotion: @convention(c) (OpaquePointer?, Double, Double, gpointer?) -> Void = { _, x, y, data in
            let host = Unmanaged<SimulatorHost>.fromOpaque(data!).takeUnretainedValue()
            host.pointer = host.toScreen(x, y)
        }
        lsim_signal_connect(UnsafeMutableRawPointer(motion), "motion", unsafeBitCast(onMotion, to: GCallback.self), me)
        gtk_widget_add_controller(area, motion)

        // Clavier : D = mode sombre, Q = quitter.
        let keys = gtk_event_controller_key_new()!
        let keyPressed: @convention(c) (OpaquePointer?, guint, guint, GdkModifierType, gpointer?) -> gboolean = { _, keyval, _, _, data in
            let host = Unmanaged<SimulatorHost>.fromOpaque(data!).takeUnretainedValue()
            return host.key(keyval) ? 1 : 0
        }
        lsim_signal_connect(UnsafeMutableRawPointer(keys), "key-pressed", unsafeBitCast(keyPressed, to: GCallback.self), me)
        gtk_widget_add_controller(window, keys)

        let closeRequest: @convention(c) (OpaquePointer?, gpointer?) -> gboolean = { _, data in
            Unmanaged<SimulatorHost>.fromOpaque(data!).takeUnretainedValue().running = false
            return 0
        }
        lsim_signal_connect(UnsafeMutableRawPointer(window), "close-request", unsafeBitCast(closeRequest, to: GCallback.self), me)

        gtk_window_set_child(UnsafeMutablePointer(gtkWindow), area)
        gtk_window_present(UnsafeMutablePointer(gtkWindow))

        // Tâches asynchrones (.task, @MainActor) : la boucle d'exécution de Swift est servie
        // toutes les 16 ms au sein de la boucle GTK.
        let pump: @convention(c) (gpointer?) -> gboolean = { _ in
            _ = RunLoop.main.run(mode: .default, before: Date())
            return 1
        }
        g_timeout_add(16, pump, nil)

        while running {
            g_main_context_iteration(nil, 1)
        }
    }

    // MARK: - Capture sans fenêtre

    func screenshot(to path: String, taps: String) {
        // Touchers simulés : chaque toucher reconstruit le layout puis déclenche l'action visée.
        if let scroll = ProcessInfo.processInfo.environment["LSIM_SCROLL"].flatMap(Double.init) {
            updateLayout()
            let first = displayList.items.compactMap { item -> String? in
                if case let .scrollRegion(id, _) = item { return id } else { return nil }
            }.first
            if let first { graph.scroll(first, by: CGFloat(scroll)) }
        }
        for tap in taps.split(separator: ";") {
            let parts = tap.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 2 else { continue }
            updateLayout()
            let point = CGPoint(x: parts[0], y: parts[1])
            if let id = displayList.hitTest(point) { graph.performAction(id) }
        }
        let env = ProcessInfo.processInfo.environment
        let screenOnly = env["LSIM_SCREEN_ONLY"] == "1"
        // Écran seul : contenu de l'app à l'échelle de l'appareil (@3x), sans cadre ni barre d'état,
        // comme une capture faite par l'app elle-même sur l'iPhone.
        let pixelScale: CGFloat = screenOnly ? 3 : 2
        let size = screenOnly ? device.screenSize : CGSize(width: outerSize.width * zoom, height: outerSize.height * zoom)
        let surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, Int32(size.width * pixelScale), Int32(size.height * pixelScale))
        let cr = cairo_create(surface)!
        cairo_scale(cr, pixelScale, pixelScale)
        // Deux passes : la première fixe les tailles (GeometryReader) et lance les onAppear.
        updateLayout()
        if screenOnly {
            updateLayout()
            let r = CairoRenderer(cr: cr, text: text)
            r.fill(.rectangle, device.screenRect, colorScheme == .light ? RGBA(1, 1, 1) : RGBA(0, 0, 0))
            r.draw(displayList)
        } else {
            draw(cr)
        }
        cairo_surface_write_to_png(surface, path)
        cairo_destroy(cr)
        cairo_surface_destroy(surface)
        if let dump = env["LSIM_DUMP"] {
            writeDump(to: dump)
        }
        print("[LSim] capture écrite : \(path)")
    }

    /// Repères de mesure au format commun avec l'app Catalogue sur iPhone (points écran).
    func writeDump(to path: String) {
        let markers = displayList.markers.map { m -> [String: Any] in
            ["id": m.id, "x": Double(m.rect.minX), "y": Double(m.rect.minY), "width": Double(m.rect.width), "height": Double(m.rect.height)]
        }
        let json: [String: Any] = [
            "source": "lsim",
            "device": device.name,
            "screen": ["width": Double(device.screenSize.width), "height": Double(device.screenSize.height), "scale": 3.0],
            "colorScheme": colorScheme == .light ? "light" : "dark",
            "markers": markers,
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: path))
            print("[LSim] mesures écrites : \(path) (\(markers.count) repères)")
        } catch {
            print("[LSim] échec d'écriture des mesures : \(error)")
        }
    }
}
