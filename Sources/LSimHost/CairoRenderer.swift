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
    static func tracking(for font: Font) -> CGFloat {
        guard font.design != .monospaced else { return 0 }
        let table: [Int: CGFloat] = [
            6: 0.24, 7: 0.23, 8: 0.21, 9: 0.17, 10: 0.12, 11: 0.06, 12: 0, 13: -0.08, 14: -0.15,
            15: -0.23, 16: -0.31, 17: -0.30 /* calibré sur iPhone, iOS 27 (HIG : -0.43) */, 18: -0.44, 19: -0.45, 20: -0.45, 21: -0.36, 22: -0.26,
            23: -0.10, 24: 0.07, 25: 0.15, 26: 0.22, 27: 0.29, 28: 0.38, 29: 0.40, 30: 0.40,
            31: 0.39, 32: 0.41, 33: 0.40, 34: 0.40, 35: 0.38, 36: 0.37, 37: 0.36, 38: 0.37,
            39: 0.38, 40: 0.37,
        ]
        let size = Int(font.size.rounded())
        if let value = table[size] { return value }
        if size < 6 { return 0.24 }
        // Au-delà de 40 pt, l'approche diminue progressivement jusqu'à 0 vers 80 pt.
        return max(0, 0.37 * (1 - CGFloat(size - 40) / 40))
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

    func measure(_ text: String, font: Font, maxWidth: CGFloat?) -> CGSize {
        let layout = makeLayout(text, font: font, width: maxWidth, alignment: .leading)
        defer { g_object_unref(UnsafeMutableRawPointer(layout)) }
        var w: Int32 = 0, h: Int32 = 0
        pango_layout_get_size(layout, &w, &h)
        return CGSize(width: CGFloat(w) / CGFloat(PANGO_SCALE), height: CGFloat(h) / CGFloat(PANGO_SCALE))
    }
}

/// Traduit une DisplayList en appels Cairo.
struct CairoRenderer {
    let cr: OpaquePointer
    let text: PangoText

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
        path(kind, r)
        cairo_fill(cr)
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
            case let .backdrop(rect, blur, tint):
                blurRegion(rect, sigma: blur)
                setColor(tint)
                cairo_rectangle(cr, rect.minX, rect.minY, rect.width, rect.height)
                cairo_fill(cr)
            case .hitRegion, .scrollRegion, .marker:
                break
            }
        }
    }

    /// Flou approchant un flou gaussien (trois passes de flou boîte) sur une zone déjà dessinée.
    func blurRegion(_ rect: CGRect, sigma: CGFloat) {
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
        for y in 0..<h { for x in 0..<w { pixels[(top + y) * stride + left + x] = buffer[y * w + x] } }
        cairo_surface_mark_dirty(target)
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
