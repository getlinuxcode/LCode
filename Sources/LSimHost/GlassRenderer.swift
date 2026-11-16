import CGtk
import Foundation
import LSimUI

/// Rendu Liquid Glass : réfraction de ce qui est déjà dessiné derrière la forme.
extension CairoRenderer {
    func drawGlass(_ shape: ShapeKind, _ rect: CGRect, _ g: GlassRender) {
        guard rect.width > 1, rect.height > 1 else { return }
        // Ombre portée douce (sous le verre, visible autour).
        if g.shadowAlpha > 0, g.table?.edge == nil {
            fill(shape, rect.offsetBy(dx: 0, dy: g.shadowOffset), RGBA(0, 0, 0, g.shadowAlpha))
        }

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

        // Rectangle du verre et zone source élargie (la réfraction lit au-delà du bord).
        let gx0 = x0 - offX, gy0 = y0 - offY
        // La réfraction peut lire loin (jusqu'à `maxShift` × la bande de bord, au-delà du centre).
        let halfMin = Double(min(rect.width, rect.height)) / 2
        var reach = g.curvature == nil ? abs(g.refraction) : min(abs(g.refraction) * 40, g.maxShift * g.bezel)
        if let table = g.table {
            reach = (table.shift.map(abs).max() ?? 0) * (table.relative ? halfMin : 1)
        }
        // Contour mesuré : il déborde à l'extérieur de la forme (liseré sombre).
        let edgePad = max(0, -(g.table?.edge?.d.first ?? 0)) * scale
        let maxBlur = max(g.blur, g.table?.blur?.max() ?? 0)
        let margin = Int(((reach + 3 * maxBlur + 2) * scale + edgePad).rounded(.up))
        let outL = max(0, Int((gx0 - edgePad).rounded(.down))), outT = max(0, Int((gy0 - edgePad).rounded(.down)))
        let outR = min(surfW, Int((x1 - offX + edgePad).rounded(.up)))
        let outB = min(surfH, Int((y1 - offY + edgePad).rounded(.up)))
        guard outR > outL, outB > outT else { return }
        let srcL = max(0, outL - margin), srcT = max(0, outT - margin)
        let srcR = min(surfW, outR + margin), srcB = min(surfH, outB + margin)
        let sw = srcR - srcL, sh = srcB - srcT

        var original = [UInt32](repeating: 0, count: sw * sh)
        for y in 0..<sh { for x in 0..<sw { original[y * sw + x] = pixels[(srcT + y) * stride + srcL + x] } }
        // Fond flouté à plusieurs niveaux (écart-type en points) ; le verre mesuré choisit son flou selon
        // la distance au bord en interpolant entre deux niveaux.
        let levels: [Double] = g.table?.blur != nil ? [0, 0.6, 1.2, 2, 3, 4.5, 6.5, 9] : [g.blur]
        // Niveaux calculés à la demande : seuls ceux que la forme utilise réellement.
        let layers = BlurPyramid(original, sw, sh, levels: levels, scale: scale)
        let blurred = layers[0]

        // Géométrie de la forme (champ de distance d'un rectangle arrondi, centré).
        let hw = Double(rect.width) / 2, hh = Double(rect.height) / 2
        var radius: Double
        switch shape {
        case .rectangle: radius = 0
        case let .roundedRectangle(cr): radius = min(Double(cr), min(hw, hh))
        case .capsule, .circle, .ellipse: radius = min(hw, hh)
        }
        var bw = hw, bh = hh
        if shape == .circle { bw = min(hw, hh); bh = bw }
        @inline(__always) func sdf(_ x: Double, _ y: Double) -> Double {
            let qx = abs(x) - (bw - radius), qy = abs(y) - (bh - radius)
            let ox = max(qx, 0), oy = max(qy, 0)
            return (ox * ox + oy * oy).squareRoot() + min(max(qx, qy), 0) - radius
        }
        @inline(__always) func channel(_ p: UInt32, _ shift: UInt32) -> Double { Double((p >> shift) & 0xFF) }
        func sample(_ fx: Double, _ fy: Double, sigma: Double) -> (Double, Double, Double) {
            guard levels.count > 1 else { return sample(fx, fy, in: layers[0]) }
            var i = 0
            while i < levels.count - 2, levels[i + 1] < sigma { i += 1 }
            let t = min(max((sigma - levels[i]) / (levels[i + 1] - levels[i]), 0), 1)
            let a = sample(fx, fy, in: layers[i])
            if t <= 0.001 { return a }
            let b = sample(fx, fy, in: layers[i + 1])
            return (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
        }
        func sample(_ fx: Double, _ fy: Double) -> (Double, Double, Double) { sample(fx, fy, in: blurred) }
        func sample(_ fx: Double, _ fy: Double, in blurred: [UInt32]) -> (Double, Double, Double) {
            let x = min(max(fx, 0), Double(sw - 1)), y = min(max(fy, 0), Double(sh - 1))
            let xi = min(Int(x), sw - 2 >= 0 ? sw - 2 : 0), yi = min(Int(y), sh - 2 >= 0 ? sh - 2 : 0)
            let tx = x - Double(xi), ty = y - Double(yi)
            let x1i = min(xi + 1, sw - 1), y1i = min(yi + 1, sh - 1)
            let p00 = blurred[yi * sw + xi], p10 = blurred[yi * sw + x1i]
            let p01 = blurred[y1i * sw + xi], p11 = blurred[y1i * sw + x1i]
            func mix(_ s: UInt32) -> Double {
                let a = channel(p00, s) * (1 - tx) + channel(p10, s) * tx
                let b = channel(p01, s) * (1 - tx) + channel(p11, s) * tx
                return a * (1 - ty) + b * ty
            }
            return (mix(16), mix(8), mix(0))
        }

        // Colonnes des tables extraites une fois (pas d'allocation par pixel).
        func columns(_ rows: [[Double]]) -> ([Double], [Double], [Double]) {
            (rows.map { $0[0] }, rows.map { $0[1] }, rows.map { $0[2] })
        }
        let tTop = g.table.map { columns($0.betaTop) }, tBottom = g.table.map { columns($0.betaBottom) }
        let tBlur = g.table?.blur
        let edgeT = g.table.flatMap { t in (g.tintOverride != nil ? t.tintedEdge : nil) ?? t.edge }
        let eTop = edgeT.map { columns($0.betaTop) }, eBottom = edgeT.map { columns($0.betaBottom) }
        let edgeTableD = edgeT.map { GlassTable(relative: false, d: $0.d, shift: [], alpha: [], betaTop: [], betaBottom: []) }

        // Lumière venant du haut à gauche (liseré spéculaire).
        let lx = -0.55, ly = -0.835
        let tint = g.tint
        let ow = outR - outL, oh = outB - outT
        var out = [UInt32](repeating: 0, count: ow * oh)
        let e = 0.5 / scale
        for py in 0..<oh {
            for px in 0..<ow {
                let devX = Double(outL + px) + 0.5, devY = Double(outT + py) + 0.5
                let ux = (devX - gx0) / scale - hw, uy = (devY - gy0) / scale - hh
                let d = sdf(ux, uy)
                let orig = original[(outT + py - srcT) * sw + (outL + px - srcL)]
                let coverage = min(max(0.5 - d * scale, 0), 1)
                let edgeTable = edgeT
                if coverage <= 0, edgeTable == nil || -d < edgeTable!.d[0] { out[py * ow + px] = orig; continue }
                let inside = -d
                // Normale sortante au bord.
                var nx = sdf(ux + e, uy) - sdf(ux - e, uy), ny = sdf(ux, uy + e) - sdf(ux, uy - e)
                let nl = (nx * nx + ny * ny).squareRoot()
                if nl > 0 { nx /= nl; ny /= nl }
                // Réfraction : décalage le long de la normale, maximal au bord.
                if let table = g.table {
                    // Comportement mesuré sur iPhone : décalage, flou, transmission et lumière selon le bord.
                    let o = (channel(orig, 16), channel(orig, 8), channel(orig, 0), channel(orig, 24))
                    let w = (1 + (nx * lx + ny * ly)) / 2   // 1 face à la lumière, 0 à l'opposé
                    var cr = o.0, cg = o.1, cb = o.2
                    var ap = 1.0, bp = (0.0, 0.0, 0.0)      // transmission et lumière du rendu intérieur
                    if inside > 0 {
                        let x = table.relative ? inside / max(halfMin, 0.01) : inside
                        let unit = table.relative ? halfMin : 1
                        let toAxis = min(max((halfMin - inside) / max(halfMin * 0.2, 0.01), 0), 1)
                        let shift = table.value(table.shift, at: x) * unit * toAxis * toAxis * (3 - 2 * toAxis)
                        // Flou mesuré, plus anticrénelage là où la réfraction comprime le fond (pente forte du
                        // décalage) : le fond y est sous-échantillonné, l'iPhone le lisse.
                        let dx = 0.5 / scale / (table.relative ? max(halfMin, 0.01) : 1)
                        let slope = abs(table.value(table.shift, at: x + dx) - table.value(table.shift, at: max(x - dx, 0))) * unit
                            / (2 * 0.5 / scale)
                        var sigma = tBlur.map { table.value($0, at: x) } ?? g.blur
                        if g.tintOverride != nil, let tb = table.tintedBlur { sigma = tb }
                        sigma = (sigma * sigma + pow(0.4 * slope / scale, 2)).squareRoot()
                        let sx = (ux - nx * shift + hw) * scale + gx0 - Double(srcL) - 0.5
                        let sy = (uy - ny * shift + hh) * scale + gy0 - Double(srcT) - 0.5
                        (cr, cg, cb) = sample(sx, sy, sigma: sigma)
                        // Verre teinté : seule la luminance du fond traverse (mesuré sur iPhone).
                        let sat = g.tintOverride == nil ? table.saturation ?? 1 : 0
                        let lum = 0.2126 * cr + 0.7152 * cg + 0.0722 * cb
                        cr = lum + (cr - lum) * sat; cg = lum + (cg - lum) * sat; cb = lum + (cb - lum) * sat
                        let a = table.value(table.alpha, at: x)
                        let tt = tTop!, tb = tBottom!
                        let top = (table.value(tt.0, at: x), table.value(tt.1, at: x), table.value(tt.2, at: x))
                        let bottom = (table.value(tb.0, at: x), table.value(tb.1, at: x), table.value(tb.2, at: x))
                        let beta = (bottom.0 + (top.0 - bottom.0) * w, bottom.1 + (top.1 - bottom.1) * w,
                                    bottom.2 + (top.2 - bottom.2) * w)
                        cr = cr * a + 255 * beta.0; cg = cg * a + 255 * beta.1; cb = cb * a + 255 * beta.2
                        ap = a; bp = beta
                        if let tint = g.tintOverride {
                            let k = tint.a
                            cr = cr * (1 - k) + tint.r * 255 * k
                            cg = cg * (1 - k) + tint.g * 255 * k
                            cb = cb * (1 - k) + tint.b * 255 * k
                            ap *= 1 - k
                            bp = (bp.0 * (1 - k) + tint.r * k, bp.1 * (1 - k) + tint.g * k, bp.2 * (1 - k) + tint.b * k)
                        }
                    }
                    var cov = coverage
                    if let edge = edgeTable, inside < edge.d[edge.d.count - 1] {
                        // Contour : écart entre le contour mesuré (α·fond + β) et le rendu intérieur.
                        let ed = edgeTableD!, et = eTop!, eb = eBottom!
                        let ae = ed.value(edge.alpha, at: inside)
                        let te = (ed.value(et.0, at: inside), ed.value(et.1, at: inside), ed.value(et.2, at: inside))
                        let be = (ed.value(eb.0, at: inside), ed.value(eb.1, at: inside), ed.value(eb.2, at: inside))
                        let bx = (be.0 + (te.0 - be.0) * w, be.1 + (te.1 - be.1) * w, be.2 + (te.2 - be.2) * w)
                        cr += (ae - ap) * o.0 + 255 * (bx.0 - bp.0)
                        cg += (ae - ap) * o.1 + 255 * (bx.1 - bp.1)
                        cb += (ae - ap) * o.2 + 255 * (bx.2 - bp.2)
                        cov = 1   // l'anticrénelage est déjà dans la mesure
                    }
                    let fr = o.0 + (min(max(cr, 0), 255) - o.0) * cov
                    let fg = o.1 + (min(max(cg, 0), 255) - o.1) * cov
                    let fb = o.2 + (min(max(cb, 0), 255) - o.2) * cov
                    let fa = o.3 + (255 - o.3) * cov
                    out[py * ow + px] = UInt32(fa) << 24 | UInt32(fr) << 16 | UInt32(fg) << 8 | UInt32(fb)
                    continue
                }
                let t = min(max(inside / max(g.bezel, 0.01), 0), 1)
                var shift: Double
                if let c = g.curvature {
                    // Bord en arc : décalage proportionnel à la pente de la surface, x / √(1 − c·x²),
                    // faible à l'intérieur et très fort au bord (frontières courbes, effet miroir).
                    let x = 1 - t
                    shift = g.refraction * x / max(1 - c * x * x, 0.0004).squareRoot()
                    let limit = g.maxShift * g.bezel
                    shift = max(-limit, min(limit, shift))
                } else {
                    shift = g.refraction * pow(1 - t, g.exponent)
                }
                let sx = (ux - nx * shift + hw) * scale + gx0 - Double(srcL) - 0.5
                let sy = (uy - ny * shift + hh) * scale + gy0 - Double(srcT) - 0.5
                var (cr, cg, cb) = sample(sx, sy)
                // Saturation et luminosité, puis voile.
                let lum = 0.2126 * cr + 0.7152 * cg + 0.0722 * cb
                cr = (lum + (cr - lum) * g.saturation) * g.brightness
                cg = (lum + (cg - lum) * g.saturation) * g.brightness
                cb = (lum + (cb - lum) * g.saturation) * g.brightness
                cr = cr * (1 - tint.a) + tint.r * 255 * tint.a
                cg = cg * (1 - tint.a) + tint.g * 255 * tint.a
                cb = cb * (1 - tint.a) + tint.b * 255 * tint.a
                // Liseré : clair face à la lumière, légèrement sombre à l'opposé.
                if inside < g.rimWidth {
                    let edge = 1 - inside / max(g.rimWidth, 0.01)
                    let facing = nx * lx + ny * ly
                    let light = g.rimAlpha * (0.35 + 0.65 * max(0, facing)) * edge
                    let shade = g.shadowSide * max(0, -facing) * edge
                    cr = (cr + (255 - cr) * light) * (1 - shade)
                    cg = (cg + (255 - cg) * light) * (1 - shade)
                    cb = (cb + (255 - cb) * light) * (1 - shade)
                }
                // Filet lumineux net au bord extérieur.
                if g.edgeLine > 0, inside < 1.0 {
                    let k = g.edgeLine * (1 - inside)
                    cr += (255 - cr) * k
                    cg += (255 - cg) * k
                    cb += (255 - cb) * k
                }
                // Mélange anticrénelé avec l'original au bord.
                let o = (channel(orig, 16), channel(orig, 8), channel(orig, 0), channel(orig, 24))
                let fr = o.0 + (min(max(cr, 0), 255) - o.0) * coverage
                let fg = o.1 + (min(max(cg, 0), 255) - o.1) * coverage
                let fb = o.2 + (min(max(cb, 0), 255) - o.2) * coverage
                let fa = o.3 + (255 - o.3) * coverage
                out[py * ow + px] = UInt32(fa) << 24 | UInt32(fr) << 16 | UInt32(fg) << 8 | UInt32(fb)
            }
        }

        // Recomposition via Cairo (respecte les découpages en cours).
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
