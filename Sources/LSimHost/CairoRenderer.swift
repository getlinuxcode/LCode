import CGtk
import Foundation
import LSimUI

/// Mesure et dessin du texte avec Pango (même contexte pour les deux, pour des métriques identiques).
final class PangoText: TextMeasurer {
    let context: OpaquePointer

    init() {
        let fontMap = pango_cairo_font_map_get_default()
        context = pango_font_map_create_context(fontMap)
        // Métriques non arrondies : le layout reste stable quelle que soit l'échelle.
        let options = cairo_font_options_create()
        cairo_font_options_set_hint_metrics(options, CAIRO_HINT_METRICS_OFF)
        cairo_font_options_set_hint_style(options, CAIRO_HINT_STYLE_NONE)
        cairo_font_options_set_antialias(options, CAIRO_ANTIALIAS_GRAY)
        pango_cairo_context_set_font_options(context, options)
        cairo_font_options_destroy(options)
    }

    static func family(for font: Font) -> String {
        // Les polices Apple sont utilisées si elles sont installées localement, sinon des équivalents libres.
        switch font.design {
        case .default:
            // Taille optique, comme iOS : SF Pro Text sous 20 pt, SF Pro Display au-delà.
            font.size < 20
                ? "SF Pro Text, SF Pro, Inter, Noto Sans, sans-serif"
                : "SF Pro Display, SF Pro, Inter Display, Inter, Noto Sans, sans-serif"
        case .rounded: "SF Pro Rounded, Nunito, Noto Sans, sans-serif"
        case .monospaced: "SF Mono, JetBrains Mono, Noto Sans Mono, monospace"
        case .serif: "New York, Noto Serif, serif"
        }
    }

    /// Approche (tracking) appliquée par iOS à la police système, en points (table des Human Interface Guidelines).
    /// Approche appliquée par iOS à la police système, lue dans le profil de design (ajustée par le banc).
    static func tracking(for font: Font) -> CGFloat {
        guard font.design != .monospaced else { return 0 }
        return CGFloat(DesignProfile.current.text.tracking(forSize: Double(font.size), weight: font.weight.rawValue))
    }

    /// Interlignes « Dynamic Type » des HIG. Non utilisés : le banc de calibration a montré que SwiftUI
    /// utilise la hauteur naturelle de la police (17 pt → 20,3 pt). Conservés pour référence.
    static func lineHeight(for font: Font) -> CGFloat? {
        let table: [CGFloat: CGFloat] = [34: 41, 28: 34, 22: 28, 20: 25, 17: 22, 16: 21, 15: 20, 13: 18, 12: 16, 11: 13]
        return table[font.size]
    }

    func makeLayout(_ text: String, font: Font, width: CGFloat?, alignment: TextAlignment) -> OpaquePointer {
        let layout = pango_layout_new(context)!
        let attrs = pango_attr_list_new()
        let tracking = Self.tracking(for: font)
        if tracking != 0 {
            pango_attr_list_insert(attrs, pango_attr_letter_spacing_new(Int32(tracking * CGFloat(PANGO_SCALE))))
        }
        if font.isStrikethrough { pango_attr_list_insert(attrs, pango_attr_strikethrough_new(1)) }
        if font.isUnderline { pango_attr_list_insert(attrs, pango_attr_underline_new(PANGO_UNDERLINE_SINGLE)) }
        pango_layout_set_attributes(layout, attrs)
        pango_attr_list_unref(attrs)
        let desc = pango_font_description_new()
        pango_font_description_set_family(desc, Self.family(for: font))
        pango_font_description_set_absolute_size(desc, Double(font.size) * Double(PANGO_SCALE))
        pango_font_description_set_weight(desc, PangoWeight(rawValue: UInt32(font.weight.rawValue)))
        if font.isItalic { pango_font_description_set_style(desc, PANGO_STYLE_ITALIC) }
        pango_layout_set_font_description(layout, desc)
        pango_font_description_free(desc)
        pango_layout_set_text(layout, text, -1)
        pango_layout_set_wrap(layout, PANGO_WRAP_WORD_CHAR)
        if let width, width.isFinite {
            pango_layout_set_width(layout, Int32(width * CGFloat(PANGO_SCALE)))
        }
        switch alignment {
        case .leading: pango_layout_set_alignment(layout, PANGO_ALIGN_LEFT)
        case .center: pango_layout_set_alignment(layout, PANGO_ALIGN_CENTER)
        case .trailing: pango_layout_set_alignment(layout, PANGO_ALIGN_RIGHT)
        }
        return layout
    }

    /// Police du symbole : le corps de la police SwiftUI multiplié par le facteur d'échelle d'image.
    static func symbolFont(_ font: Font, _ scale: Image.Scale) -> Font {
        var f = font
        f.size = font.size * CGFloat(DesignProfile.current.image.factor(scale))
        return f
    }

    /// Encre et boîte typographique d'un symbole (en points, relatives à l'origine du texte) ; nil si inconnu.
    func symbolBoxes(_ name: String, font: Font, scale: Image.Scale) -> (ink: CGRect, logical: CGRect)? {
        guard let character = SymbolTable.shared.character(for: name) else { return nil }
        let layout = makeLayout(character, font: Self.symbolFont(font, scale), width: nil, alignment: .leading)
        defer { g_object_unref(UnsafeMutableRawPointer(layout)) }
        var ink = PangoRectangle(), logical = PangoRectangle()
        pango_layout_get_extents(layout, &ink, &logical)
        let k = CGFloat(PANGO_SCALE)
        func rect(_ r: PangoRectangle) -> CGRect {
            CGRect(x: CGFloat(r.x) / k, y: CGFloat(r.y) / k, width: CGFloat(r.width) / k, height: CGFloat(r.height) / k)
        }
        return (rect(ink), rect(logical))
    }

    /// Cadre d'un symbole, d'après les mesures sur iPhone : largeur = chasse du glyphe (+ marge éventuelle),
    /// hauteur = hauteur de l'encre + une marge proportionnelle au corps (≈ 0,09 × corps de chaque côté).
    func measureSymbol(_ name: String, font: Font, scale: Image.Scale) -> SymbolMetrics? {
        guard let box = symbolBoxes(name, font: font, scale: scale) else { return nil }
        let p = DesignProfile.current.image
        let size = Self.symbolFont(font, scale).size
        return SymbolMetrics(size: CGSize(width: box.logical.width + 2 * CGFloat(p.paddingH) * size,
                                          height: box.ink.height + 2 * CGFloat(p.paddingV) * size))
    }

    func measureImage(_ path: String) -> CGSize? {
        var w: Int32 = 0, h: Int32 = 0
        guard gdk_pixbuf_get_file_info(path, &w, &h) != nil, w > 0, h > 0 else { return nil }
        return CGSize(width: CGFloat(w), height: CGFloat(h))
    }

    func measure(_ text: String, font: Font, maxWidth: CGFloat?) -> CGSize {
        let layout = makeLayout(text, font: font, width: maxWidth, alignment: .leading)
        defer { g_object_unref(UnsafeMutableRawPointer(layout)) }
        var w: Int32 = 0, h: Int32 = 0
        pango_layout_get_size(layout, &w, &h)
        return CGSize(width: CGFloat(w) / CGFloat(PANGO_SCALE), height: CGFloat(h) / CGFloat(PANGO_SCALE))
    }
}

/// Images décodées, à la taille en pixels où elles sont dessinées (net, y compris pour le SVG).
private final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()
    private var pixbufs: [String: OpaquePointer] = [:]

    func pixbuf(_ path: String, width: Int32, height: Int32) -> OpaquePointer? {
        let key = "\(path)@\(width)x\(height)"
        if let p = pixbufs[key] { return p }
        guard let p = gdk_pixbuf_new_from_file_at_scale(path, width, height, 0, nil) else { return nil }
        if pixbufs.count > 64 { pixbufs.values.forEach { g_object_unref(UnsafeMutableRawPointer($0)) }; pixbufs = [:] }
        pixbufs[key] = p
        return p
    }
}

/// Traduit une DisplayList en appels Cairo.
struct CairoRenderer {
    let cr: OpaquePointer
    let text: PangoText

    /// Image étirée au rectangle, décodée à la résolution de l'écran.
    func drawImage(_ path: String, in rect: CGRect) {
        guard rect.width > 0, rect.height > 0 else { return }
        var sx = Double(rect.width), sy = Double(rect.height)
        cairo_user_to_device_distance(cr, &sx, &sy)
        let pw = Int32(max(1, abs(sx).rounded())), ph = Int32(max(1, abs(sy).rounded()))
        guard let pixbuf = ImageCache.shared.pixbuf(path, width: pw, height: ph) else { return }
        cairo_save(cr)
        cairo_translate(cr, rect.minX, rect.minY)
        cairo_scale(cr, Double(rect.width) / Double(pw), Double(rect.height) / Double(ph))
        gdk_cairo_set_source_pixbuf(cr, pixbuf, 0, 0)
        cairo_rectangle(cr, 0, 0, Double(pw), Double(ph))
        cairo_fill(cr)
        cairo_restore(cr)
    }

    func setColor(_ c: RGBA) {
        cairo_set_source_rgba(cr, c.r, c.g, c.b, c.a)
    }

    func path(_ kind: ShapeKind, _ r: CGRect) {
        cairo_new_path(cr)
        switch kind {
        case .rectangle:
            cairo_rectangle(cr, r.minX, r.minY, r.width, r.height)
        case let .roundedRectangle(radius):
            roundedRect(r, radius)
        case .capsule:
            roundedRect(r, min(r.width, r.height) / 2)
        case .ellipse, .circle:
            guard r.width > 0, r.height > 0 else { return }
            cairo_save(cr)
            cairo_translate(cr, r.midX, r.midY)
            cairo_scale(cr, r.width / 2, r.height / 2)
            cairo_arc(cr, 0, 0, 1, 0, 2 * .pi)
            cairo_restore(cr)
        }
    }

    func roundedRect(_ r: CGRect, _ radius: CGFloat) {
        let rad = max(0, min(radius, min(r.width, r.height) / 2))
        cairo_new_sub_path(cr)
        cairo_arc(cr, r.maxX - rad, r.minY + rad, rad, -.pi / 2, 0)
        cairo_arc(cr, r.maxX - rad, r.maxY - rad, rad, 0, .pi / 2)
        cairo_arc(cr, r.minX + rad, r.maxY - rad, rad, .pi / 2, .pi)
        cairo_arc(cr, r.minX + rad, r.minY + rad, rad, .pi, 3 * .pi / 2)
        cairo_close_path(cr)
    }

    func fill(_ kind: ShapeKind, _ r: CGRect, _ color: RGBA) {
        setColor(color)
        // Comme Core Animation, les rectangles pleins sont alignés sur les pixels de l'écran :
        // deux aplats juxtaposés ne laissent pas transparaître le fond entre eux.
        path(kind, kind == .rectangle ? snapped(r) : r)
        cairo_fill(cr)
    }

    /// Rectangle arrondi aux pixels de l'écran (dans l'espace de l'utilisateur).
    func snapped(_ r: CGRect) -> CGRect {
        var x0 = Double(r.minX), y0 = Double(r.minY), x1 = Double(r.maxX), y1 = Double(r.maxY)
        cairo_user_to_device(cr, &x0, &y0)
        cairo_user_to_device(cr, &x1, &y1)
        x0.round(); y0.round(); x1.round(); y1.round()
        cairo_device_to_user(cr, &x0, &y0)
        cairo_device_to_user(cr, &x1, &y1)
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    func drawText(_ string: String, font: Font, at origin: CGPoint, width: CGFloat?, color: RGBA, alignment: TextAlignment) {
        let layout = text.makeLayout(string, font: font, width: width, alignment: alignment)
        defer { g_object_unref(UnsafeMutableRawPointer(layout)) }
        setColor(color)
        cairo_move_to(cr, origin.x, origin.y)
        pango_cairo_show_layout(cr, layout)
    }

    func draw(_ list: DisplayList) {
        var opacities: [Double] = []
        for item in list.items {
            switch item {
            case let .fill(kind, rect, color):
                fill(kind, rect, color)
            case let .text(string, font, rect, color, alignment):
                // +1 pt de marge pour éviter un retour à la ligne dû aux arrondis.
                drawText(string, font: font, at: rect.origin, width: rect.width + 1, color: color, alignment: alignment)
            case let .pushTransform(dx, dy, scale, anchor):
                cairo_save(cr)
                cairo_translate(cr, Double(dx + anchor.x), Double(dy + anchor.y))
                cairo_scale(cr, Double(scale), Double(scale))
                cairo_translate(cr, Double(-anchor.x), Double(-anchor.y))
            case .popTransform:
                cairo_restore(cr)
            case let .pushOpacity(alpha):
                opacities.append(alpha)
                cairo_push_group(cr)
            case .popOpacity:
                let alpha = opacities.popLast() ?? 1
                cairo_pop_group_to_source(cr)
                cairo_paint_with_alpha(cr, alpha)
            case let .pushClip(kind, rect):
                cairo_save(cr)
                path(kind, rect)
                cairo_clip(cr)
            case .popClip:
                cairo_restore(cr)
            case let .stroke(kind, rect, color, lineWidth):
                setColor(color)
                path(kind, rect)
                cairo_set_line_width(cr, lineWidth)
                cairo_stroke(cr)
            case let .chevron(rect, color, lineWidth, pointingLeft):
                setColor(color)
                cairo_new_path(cr)
                cairo_set_line_width(cr, lineWidth)
                cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
                cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND)
                let (tipX, baseX) = pointingLeft ? (rect.minX, rect.maxX) : (rect.maxX, rect.minX)
                cairo_move_to(cr, baseX, rect.minY)
                cairo_line_to(cr, tipX, rect.midY)
                cairo_line_to(cr, baseX, rect.maxY)
                cairo_stroke(cr)
            case let .fade(rect, color):
                let gradient = cairo_pattern_create_linear(rect.minX, rect.minY, rect.minX, rect.maxY)
                cairo_pattern_add_color_stop_rgba(gradient, 0, color.r, color.g, color.b, color.a)
                cairo_pattern_add_color_stop_rgba(gradient, 0.7, color.r, color.g, color.b, color.a * 0.85)
                cairo_pattern_add_color_stop_rgba(gradient, 1, color.r, color.g, color.b, 0)
                cairo_set_source(cr, gradient)
                cairo_rectangle(cr, rect.minX, rect.minY, rect.width, rect.height)
                cairo_fill(cr)
                cairo_pattern_destroy(gradient)
            case let .symbol(name, font, scale, rect, color):
                drawSymbol(name, font: font, scale: scale, in: rect, color: color)
            case let .image(path, rect):
                drawImage(path, in: rect)
            case let .linearGradient(shape, rect, colors, locations, p0, p1):
                let pattern = cairo_pattern_create_linear(p0.x, p0.y, p1.x, p1.y)
                for (c, l) in zip(colors, locations) {
                    cairo_pattern_add_color_stop_rgba(pattern, Double(l), c.r, c.g, c.b, c.a)
                }
                cairo_set_source(cr, pattern)
                path(shape, shape == .rectangle ? snapped(rect) : rect)
                cairo_fill(cr)
                cairo_pattern_destroy(pattern)
            case let .glass(shape, rect, glass):
                drawGlass(shape, rect, glass)
            case let .scrollEdge(rect, table, shift):
                drawScrollEdge(rect, table, shift: shift)
            case let .backdrop(rect, blur, tint, shape):
                blurRegion(rect, sigma: blur, shape: shape)
                setColor(tint)
                path(shape, rect)
                cairo_fill(cr)
            case .hitRegion, .scrollRegion, .marker, .panRegion:
                break
            }
        }
    }

    /// Dessine un symbole : son encre est centrée et mise à l'échelle dans le rectangle (sans déformation).
    func drawSymbol(_ name: String, font: Font, scale: Image.Scale, in rect: CGRect, color: RGBA) {
        guard let character = SymbolTable.shared.character(for: name),
              let box = text.symbolBoxes(name, font: font, scale: scale), box.ink.width > 0, box.ink.height > 0 else {
            // Symbole inconnu : cadre de substitution.
            setColor(RGBA(color.r, color.g, color.b, color.a * 0.35))
            path(.roundedRectangle(cornerRadius: 3), rect.insetBy(dx: 1, dy: 1))
            cairo_set_line_width(cr, 1)
            cairo_stroke(cr)
            return
        }
        let natural = text.measureSymbol(name, font: font, scale: scale)?.size ?? box.ink.size
        let k = min(rect.width / natural.width, rect.height / natural.height)
        let layout = text.makeLayout(character, font: PangoText.symbolFont(font, scale), width: nil, alignment: .leading)
        defer { g_object_unref(UnsafeMutableRawPointer(layout)) }
        cairo_save(cr)
        cairo_translate(cr, rect.midX, rect.midY)
        cairo_scale(cr, k, k)
        // Horizontalement : la boîte typographique (chasse) est centrée ; verticalement : l'encre.
        cairo_translate(cr, -(box.logical.midX), -(box.ink.midY))
        setColor(color)
        cairo_move_to(cr, 0, 0)
        pango_cairo_show_layout(cr, layout)
        cairo_restore(cr)
    }

    /// Flou approchant un flou gaussien (trois passes de flou boîte) sur une zone déjà dessinée.
    func blurRegion(_ rect: CGRect, sigma: CGFloat, shape: ShapeKind = .rectangle) {
        let target = cairo_get_group_target(cr)
        guard cairo_surface_get_type(target) == CAIRO_SURFACE_TYPE_IMAGE else { return }
        cairo_surface_flush(target)
        var x0 = Double(rect.minX), y0 = Double(rect.minY), x1 = Double(rect.maxX), y1 = Double(rect.maxY)
        cairo_user_to_device(cr, &x0, &y0)
        cairo_user_to_device(cr, &x1, &y1)
        var dx = 0.0, dy = 0.0
        cairo_surface_get_device_offset(target, &dx, &dy)
        var radius = Double(sigma), unused = 0.0
        cairo_user_to_device_distance(cr, &radius, &unused)

        let width = Int(cairo_image_surface_get_width(target))
        let height = Int(cairo_image_surface_get_height(target))
        let stride = Int(cairo_image_surface_get_stride(target)) / 4
        guard let raw = cairo_image_surface_get_data(target) else { return }
        let left = max(0, Int((min(x0, x1) - dx).rounded(.down)))
        let top = max(0, Int((min(y0, y1) - dy).rounded(.down)))
        let right = min(width, Int((max(x0, x1) - dx).rounded(.up)))
        let bottom = min(height, Int((max(y0, y1) - dy).rounded(.up)))
        guard right > left, bottom > top else { return }

        let pixels = UnsafeMutableRawPointer(raw).assumingMemoryBound(to: UInt32.self)
        let w = right - left, h = bottom - top
        // Trois passes de flou boîte de demi-largeur r ≈ σ·√3 / … (approximation classique).
        let r = max(1, Int((radius * 0.95).rounded()))
        var buffer = [UInt32](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { buffer[y * w + x] = pixels[(top + y) * stride + left + x] } }
        for _ in 0..<3 {
            Self.boxBlur(&buffer, w, h, r, horizontal: true)
            Self.boxBlur(&buffer, w, h, r, horizontal: false)
        }
        // Le résultat flouté est recomposé à travers la forme (capsule, coins arrondis…) et les
        // découpages en cours, au lieu d'être écrit directement dans les pixels.
        let blurred = buffer.withUnsafeMutableBytes { bytes -> OpaquePointer? in
            cairo_image_surface_create_for_data(bytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                                CAIRO_FORMAT_ARGB32, Int32(w), Int32(h), Int32(w * 4))
        }
        guard let blurred else { return }
        cairo_save(cr)
        path(shape, rect)
        cairo_clip(cr)
        cairo_identity_matrix(cr)
        cairo_set_source_surface(cr, blurred, Double(left) + dx, Double(top) + dy)
        cairo_paint(cr)
        cairo_restore(cr)
        cairo_surface_finish(blurred)
        cairo_surface_destroy(blurred)
    }

    static func boxBlur(_ data: inout [UInt32], _ w: Int, _ h: Int, _ r: Int, horizontal: Bool) {
        let lines = horizontal ? h : w
        let length = horizontal ? w : h
        var line = [UInt32](repeating: 0, count: length)
        for l in 0..<lines {
            let index: (Int) -> Int = horizontal ? { l * w + $0 } : { $0 * w + l }
            for i in 0..<length { line[i] = data[index(i)] }
            var sums = [Int](repeating: 0, count: 4)
            func channels(_ p: UInt32) -> (Int, Int, Int, Int) {
                (Int(p >> 24 & 0xFF), Int(p >> 16 & 0xFF), Int(p >> 8 & 0xFF), Int(p & 0xFF))
            }
            // Bords étendus (le pixel du bord est répété).
            for k in -r...r {
                let c = channels(line[min(max(k, 0), length - 1)])
                sums[0] += c.0; sums[1] += c.1; sums[2] += c.2; sums[3] += c.3
            }
            let n = 2 * r + 1
            for i in 0..<length {
                data[index(i)] = UInt32(sums[0] / n) << 24 | UInt32(sums[1] / n) << 16 | UInt32(sums[2] / n) << 8 | UInt32(sums[3] / n)
                let out = channels(line[min(max(i - r, 0), length - 1)])
                let inn = channels(line[min(max(i + r + 1, 0), length - 1)])
                sums[0] += inn.0 - out.0; sums[1] += inn.1 - out.1; sums[2] += inn.2 - out.2; sums[3] += inn.3 - out.3
            }
        }
    }
}
