import CGtk
import Foundation
import LSimUI

/// Effet de bord de défilement Liquid Glass, d'après la table mesurée sur iPhone : chaque ligne du
/// contenu est floutée (écart-type variable, interpolé entre plusieurs niveaux), puis
/// sortie = α·contenu flouté + β.
extension CairoRenderer {
    func drawScrollEdge(_ rect: CGRect, _ table: ScrollEdgeTable, shift: CGFloat) {
        guard rect.width > 1, rect.height > 1 else { return }
        let target = cairo_get_group_target(cr)
        guard cairo_surface_get_type(target) == CAIRO_SURFACE_TYPE_IMAGE,
              let raw = cairo_image_surface_get_data(target) else { return }
        cairo_surface_flush(target)
        var x0 = Double(rect.minX), y0 = Double(rect.minY), x1 = Double(rect.maxX), y1 = Double(rect.maxY)
        cairo_user_to_device(cr, &x0, &y0)
        cairo_user_to_device(cr, &x1, &y1)
        var offX = 0.0, offY = 0.0
        cairo_surface_get_device_offset(target, &offX, &offY)
        let scale = (x1 - x0) / Double(rect.width)
        guard scale > 0 else { return }
        let surfW = Int(cairo_image_surface_get_width(target))
        let surfH = Int(cairo_image_surface_get_height(target))
        let stride = Int(cairo_image_surface_get_stride(target)) / 4
        let pixels = UnsafeMutableRawPointer(raw).assumingMemoryBound(to: UInt32.self)

        let maxBlur = table.blur.max() ?? 0
        let margin = Int((3 * maxBlur * scale).rounded(.up)) + 2
        let outL = max(0, Int((x0 - offX).rounded(.down))), outT = max(0, Int((y0 - offY).rounded(.down)))
        let outR = min(surfW, Int((x1 - offX).rounded(.up))), outB = min(surfH, Int((y1 - offY).rounded(.up)))
        guard outR > outL, outB > outT else { return }
        // Source élargie vers le bas (le flou lit sous la zone) ; bords latéraux et haut répliqués.
        let srcT = outT, srcB = min(surfH, outB + margin)
        let sw = outR - outL, sh = srcB - srcT
        var original = [UInt32](repeating: 0, count: sw * sh)
        for y in 0..<sh { for x in 0..<sw { original[y * sw + x] = pixels[(srcT + y) * stride + outL + x] } }

        let levels: [Double] = [0, 0.75, 1.5, 2.5, 4, 6, 9, 13]
        let layers = BlurPyramid(original, sw, sh, levels: levels, scale: scale)

        let ow = outR - outL, oh = outB - outT
        var out = [UInt32](repeating: 0, count: ow * oh)
        for py in 0..<oh {
            // Ligne en points depuis le haut de la zone, recalée sur la mesure.
            let yPt = (Double(outT + py) + 0.5 - (y0 - offY)) / scale - Double(shift)
            let a = table.value(table.alpha, at: yPt)
            let b = (table.value(table.beta.map { $0[0] }, at: yPt), table.value(table.beta.map { $0[1] }, at: yPt),
                     table.value(table.beta.map { $0[2] }, at: yPt))
            let sigma = table.value(table.blur, at: yPt)
            var i = 0
            while i < levels.count - 2, levels[i + 1] < sigma { i += 1 }
            let t = min(max((sigma - levels[i]) / (levels[i + 1] - levels[i]), 0), 1)
            let la = layers[i], lb = layers[i + 1]
            for px in 0..<ow {
                let idx = py * sw + px
                func ch(_ p: UInt32, _ s: UInt32) -> Double { Double((p >> s) & 0xFF) }
                let pa = la[idx], pb = lb[idx]
                let r = ch(pa, 16) + (ch(pb, 16) - ch(pa, 16)) * t
                let g = ch(pa, 8) + (ch(pb, 8) - ch(pa, 8)) * t
                let bl = ch(pa, 0) + (ch(pb, 0) - ch(pa, 0)) * t
                let fr = min(max(r * a + 255 * b.0, 0), 255)
                let fg = min(max(g * a + 255 * b.1, 0), 255)
                let fb = min(max(bl * a + 255 * b.2, 0), 255)
                out[py * ow + px] = 0xFF00_0000 | UInt32(fr) << 16 | UInt32(fg) << 8 | UInt32(fb)
            }
        }

        let surface = out.withUnsafeMutableBytes { bytes -> OpaquePointer? in
            cairo_image_surface_create_for_data(bytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                                CAIRO_FORMAT_ARGB32, Int32(ow), Int32(oh), Int32(ow * 4))
        }
        guard let surface else { return }
        cairo_save(cr)
        cairo_identity_matrix(cr)
        cairo_rectangle(cr, Double(outL) + offX, Double(outT) + offY, Double(ow), Double(oh))
        cairo_clip(cr)
        cairo_set_source_surface(cr, surface, Double(outL) + offX, Double(outT) + offY)
        cairo_paint(cr)
        cairo_restore(cr)
        cairo_surface_finish(surface)
        cairo_surface_destroy(surface)
    }
}

/// Fond flouté à plusieurs niveaux (écart-type en points), chaque niveau calculé au premier accès.
final class BlurPyramid {
    let original: [UInt32]
    let w: Int, h: Int
    let levels: [Double]
    let scale: Double
    private var cache: [[UInt32]?]

    init(_ original: [UInt32], _ w: Int, _ h: Int, levels: [Double], scale: Double) {
        self.original = original
        self.w = w
        self.h = h
        self.levels = levels
        self.scale = scale
        cache = Array(repeating: nil, count: levels.count)
    }

    subscript(_ i: Int) -> [UInt32] {
        if let layer = cache[i] { return layer }  // tableau partagé (copie à l'écriture) : pas de recopie
        var b = original
        // Trois passes de boîte de rayon r : σ ≈ √(r(r+1)) pixels.
        let r = Int((levels[i] * scale - 0.5).rounded())
        if r >= 1 {
            for _ in 0..<3 {
                CairoRenderer.boxBlur(&b, w, h, r, horizontal: true)
                CairoRenderer.boxBlur(&b, w, h, r, horizontal: false)
            }
        }
        cache[i] = b
        return b
    }
}
