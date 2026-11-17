#!/usr/bin/env python3
"""Direct measurement of Liquid Glass from the coded-background pages.

Usage: ~/.local/share/lcode/venv/bin/python -I tools/calibration/glassfield.py <run> [--source ios|lsim] [--write]

For each pixel of each glass shape:
  - low and high grey backgrounds → transmission α and added light β (r, g, b), since output = α·bg + β;
  - grey gradients in x/y (coarse ramp + 16 pt sine/cosine waves, position from the phase) → the exact
    background point shown by that pixel, hence the refraction shift, projected on the edge normal.
Measurements are binned by distance to the edge (medians) and written to the profile (`--write`) as
`tableLight` / `tableDark` for the regular and clear variants, plus `tintStrength`.
"""
import argparse
import json
import os
import sys

import numpy as np
from PIL import Image

PAGES = ["low", "high", "xcoarse", "xsin", "xcos", "ycoarse", "ysin", "ycos"]
MID_PAGES = ["xsin64", "xcos64", "ysin64", "ycos64"]  # 64 pt wave: resolves the 16 pt ambiguity
PERIOD = 16.0
MID_PERIOD = 64.0
PAD = 3.0  # pt measured around each shape
LOW, HIGH = 0.15, 0.70  # background levels (must match Catalog.swift)
SHAPES = {  # marker → (variant, "circle" | corner radius in pt | None = half the shorter side)
    "glass.capsule": ("regular", None),
    "glass.circle": ("regular", "circle"),
    "glass.rounded": ("regular", 26.0),
    "glass.clear": ("clear", None),
    "glass.tinted": ("tinted", None),
    "glass.small": ("regular", "circle"),   # bar button size
    "glass.pill": ("regular", None),
}
LIGHT = np.array([-0.55, -0.835])
TINT = {"light": np.array([0, 136, 255]) / 255, "dark": np.array([0, 145, 255]) / 255}  # the page's .blue
PROFILE = "Sources/LSimUI/Profiles/iOS-27.2.json"


def load(run, source, scheme):
    pages = {}
    for name in PAGES + MID_PAGES:
        base = os.path.join(run, source, f"glass.field.{name}.{scheme}")
        if not os.path.exists(base + ".json"):
            if name in MID_PAGES:
                continue
            return None
        with open(base + ".json") as f:
            meta = json.load(f)
        img = np.asarray(Image.open(base + ".png").convert("RGB"), dtype=np.float64)
        pages[name] = (meta, img)
    return pages


def sdf(ux, uy, bw, bh, r):
    qx, qy = np.abs(ux) - (bw - r), np.abs(uy) - (bh - r)
    ox, oy = np.maximum(qx, 0), np.maximum(qy, 0)
    return np.sqrt(ox * ox + oy * oy) + np.minimum(np.maximum(qx, qy), 0) - r


def measure(pages, ident):
    meta = pages["low"][0]
    scale = meta["screen"]["scale"]
    markers = {m["id"]: m for m in meta["markers"]}
    m, board = markers[ident], markers["board." + ident]
    variant, kind = SHAPES[ident]
    hw, hh = m["width"] / 2, m["height"] / 2
    if kind == "circle":
        bw = bh = r = min(hw, hh)
    else:
        bw, bh = hw, hh
        r = min(hw, hh) if kind is None else min(kind, hw, hh)
    half_min = min(hw, hh)

    # Frame grown by PAD pt so the outer rim (dark edge line, shadow) is measured too.
    x0, y0 = int((m["x"] - PAD) * scale), int((m["y"] - PAD) * scale)
    x1, y1 = int((m["x"] + m["width"] + PAD) * scale), int((m["y"] + m["height"] + PAD) * scale)
    ys, xs = np.mgrid[y0:y1, x0:x1]
    px, py = (xs + 0.5) / scale, (ys + 0.5) / scale
    ux, uy = px - (m["x"] + hw), py - (m["y"] + hh)
    d = -sdf(ux, uy, bw, bh, r)
    e = 0.05
    nx = sdf(ux + e, uy, bw, bh, r) - sdf(ux - e, uy, bw, bh, r)
    ny = sdf(ux, uy + e, bw, bh, r) - sdf(ux, uy - e, bw, bh, r)
    nl = np.hypot(nx, ny) + 1e-12
    nx, ny = nx / nl, ny / nl

    crop = {k: v[1][y0:y1, x0:x1] for k, v in pages.items()}
    K, W = crop["low"], crop["high"]
    k, w = K.mean(axis=2), W.mean(axis=2)
    # output = α·bg + β, with bg = LOW or HIGH on these two pages.
    alpha = (w - k) / 255 / (HIGH - LOW)
    beta_rgb = (K / 255 - alpha[..., None] * LOW)
    span = np.maximum(w - k, 1e-6)

    # Normalised grey → position mapping, learnt on the background outside the glass (known positions).
    bx0, by0 = int(board["x"] * scale), int(board["y"] * scale)
    bx1, by1 = int((board["x"] + board["width"]) * scale), int((board["y"] + board["height"]) * scale)
    full = {kk: v[1][by0:by1, bx0:bx1].mean(axis=2) for kk, v in pages.items()}
    fys, fxs = np.mgrid[by0:by1, bx0:bx1]
    fpx, fpy = (fxs + 0.5) / scale - board["x"], (fys + 0.5) / scale - board["y"]
    outside = ~((fxs >= x0 - 6) & (fxs < x1 + 6) & (fys >= y0 - 6) & (fys < y1 + 6))
    fspan = np.maximum(full["high"] - full["low"], 1e-6)

    def mapping(page, positions):
        g = ((full[page] - full["low"]) / fspan)[outside]
        p = positions[outside]
        order = np.argsort(g)
        g, p = g[order], p[order]
        # Median per grey level (smooths rounding), then interpolation.
        levels = np.linspace(g.min(), g.max(), 400)
        idx = np.clip(np.searchsorted(g, levels), 0, len(g) - 1)
        centers = np.array([np.median(p[max(0, i - 20):i + 20]) for i in idx])
        return lambda v: np.interp(v, levels, centers)

    def phase_of(sin_v, cos_v):
        return np.arctan2(2 * sin_v - 1, 2 * cos_v - 1)

    def phase_mapping(sin_page, cos_page, positions, period):
        """Observed phase → position within the period, learnt outside the glass (corrects gamma and
        gradient interpolation errors)."""
        ph = phase_of(((full[sin_page] - full["low"]) / fspan)[outside],
                      ((full[cos_page] - full["low"]) / fspan)[outside])
        true = (positions[outside] % period) / period * 2 * np.pi
        err = np.angle(np.exp(1j * (true - ph)))
        bins = np.linspace(-np.pi, np.pi, 129)
        which = np.clip(np.digitize(ph, bins) - 1, 0, 127)
        corr = np.array([np.median(err[which == b]) if (which == b).sum() > 5 else 0.0 for b in range(128)])
        centers = (bins[:-1] + bins[1:]) / 2
        return lambda p: p + np.interp(p, centers, corr, period=2 * np.pi)

    def wave(sin_page, cos_page, positions, period):
        ph = phase_of((crop[sin_page].mean(axis=2) - k) / span, (crop[cos_page].mean(axis=2) - k) / span)
        ph = phase_mapping(sin_page, cos_page, positions, period)(ph)
        return (ph % (2 * np.pi)) / (2 * np.pi) * period

    def coord(axis, positions):
        # Coarse (needs ±8 pt without the 64 pt wave, ±32 pt with it), then 64 pt, then 16 pt.
        estimate = mapping(axis + "coarse", positions)((crop[axis + "coarse"].mean(axis=2) - k) / span)
        if axis + "sin64" in crop:
            g64 = wave(axis + "sin64", axis + "cos64", positions, MID_PERIOD)
            estimate = g64 + MID_PERIOD * np.round((estimate - g64) / MID_PERIOD)
        gf = wave(axis + "sin", axis + "cos", positions, PERIOD)
        return gf + PERIOD * np.round((estimate - gf) / PERIOD)

    sx = board["x"] + coord("x", fpx)
    sy = board["y"] + coord("y", fpy)
    dx, dy = sx - px, sy - py
    shift = -(dx * nx + dy * ny)
    facing = (1 + (nx * LIGHT[0] + ny * LIGHT[1])) / 2
    # Blur: sine/cosine wave contrast relative to the bare background. A Gaussian blur σ keeps
    # exp(−2π²σ²/P²) of the contrast of a wave of period P.
    def modulation(sin_page, cos_page, region, base):
        sv = (region[sin_page].mean(axis=2) - base[0]) / base[1]
        cv = (region[cos_page].mean(axis=2) - base[0]) / base[1]
        return np.hypot(2 * sv - 1, 2 * cv - 1)
    full_rgb = {kk: v[1][by0:by1, bx0:bx1] for kk, v in pages.items()}
    ref = np.median(np.concatenate([modulation(a, b, full_rgb, (full["low"], fspan))[outside]
                                    for a, b in (("xsin", "xcos"), ("ysin", "ycos"))]))
    ratio = (modulation("xsin", "xcos", crop, (k, span)) + modulation("ysin", "ycos", crop, (k, span))) / 2 / ref
    blur = PERIOD / (np.pi * np.sqrt(2)) * np.sqrt(-np.log(np.clip(ratio, 1e-3, 1.0)))
    valid = (d > 0.35) & (alpha > 0.12)
    return {"variant": variant, "d": d, "half": half_min, "shift": shift, "alpha": alpha, "blur": blur, "dx": dx, "dy": dy, "nx": nx, "ny": ny, "ux": ux, "uy": uy,
            "beta": beta_rgb, "facing": facing, "valid": valid, "inside": d > 0.35}


def table(samples, relative, step):
    """Per edge-distance bin: median of each shape, then mean over shapes (equal weight per shape,
    otherwise a bin's composition and value jump from one step to the next)."""
    unit = [s["half"] if relative else 1.0 for s in samples]
    top = max((s["d"][s["inside"]] / u).max() for s, u in zip(samples, unit))
    edges = np.arange(0, top + step, step)
    rows = {"d": [], "shift": [], "alpha": [], "blur": [], "betaTop": [], "betaBottom": []}
    for lo, hi in zip(edges[:-1], edges[1:]):
        sh, al, bl, bt, bb = [], [], [], [], []
        for s, u in zip(samples, unit):
            d = s["d"] / u
            sel = s["inside"] & (d >= lo) & (d < hi)
            if sel.sum() < 20:
                continue
            sv = sel & s["valid"]
            if sv.sum() >= 20:
                sh.append(np.median(s["shift"][sv]) / u)
            al.append(np.median(s["alpha"][sel]))
            bl.append(np.median(s["blur"][sv]) if sv.sum() >= 20 else np.nan)
            t, b = sel & (s["facing"] > 0.6), sel & (s["facing"] < 0.4)
            bt.append(np.median(s["beta"][t if t.sum() >= 5 else sel], axis=0))
            bb.append(np.median(s["beta"][b if b.sum() >= 5 else sel], axis=0))
        if not al:
            continue
        rows["d"].append(round(float((lo + hi) / 2), 4))
        rows["shift"].append(round(float(np.mean(sh)), 4) if sh else None)
        rows["alpha"].append(round(float(np.mean(al)), 4))
        rows["blur"].append(round(float(np.nanmean(bl)), 4) if np.isfinite(bl).any() else 0.0)
        rows["betaTop"].append([round(float(v), 4) for v in np.mean(bt, axis=0)])
        rows["betaBottom"].append([round(float(v), 4) for v in np.mean(bb, axis=0)])
    last = 0.0
    for i, v in enumerate(rows["shift"]):
        if v is None:
            rows["shift"][i] = last
        else:
            last = v
    # Smoothing: 5-bin running median (removes isolated outliers).
    for key in ("shift", "alpha", "blur"):
        v = np.array(rows[key], dtype=float)
        rows[key] = [round(float(np.median(v[max(0, i - 2):i + 3])), 4) for i in range(len(v))]
    rows["relative"] = relative
    return rows


def edge_table(samples, scale=3.0):
    """Rim: transmission and added light at absolute edge distance (−PAD to +1.5 pt, half-pixel bins),
    measured on straight sides only (corner diagonals smear the anti-aliasing)."""
    step = 0.5 / scale
    edges = np.arange(-PAD + 0.5, 1.5 + step, step)
    rows = {"d": [], "alpha": [], "betaTop": [], "betaBottom": []}
    for lo, hi in zip(edges[:-1], edges[1:]):
        al, bt, bb = [], [], []
        for s in samples:
            straight = (np.abs(s["nx"]) > 0.99) | (np.abs(s["ny"]) > 0.99)
            sel = straight & (s["d"] >= lo) & (s["d"] < hi)
            if sel.sum() < 10:
                continue
            al.append(np.median(s["alpha"][sel]))
            t, b = sel & (s["facing"] > 0.6), sel & (s["facing"] < 0.4)
            bt.append(np.median(s["beta"][t if t.sum() >= 5 else sel], axis=0))
            bb.append(np.median(s["beta"][b if b.sum() >= 5 else sel], axis=0))
        if not al:
            continue
        rows["d"].append(round(float((lo + hi) / 2), 4))
        rows["alpha"].append(round(float(np.mean(al)), 4))
        rows["betaTop"].append([round(float(v), 4) for v in np.mean(bt, axis=0)])
        rows["betaBottom"].append([round(float(v), 4) for v in np.mean(bb, axis=0)])
    return rows


def spread(samples, relative, step):
    """Disagreement between shapes of one variant (to choose absolute or relative units)."""
    curves = []
    for s in samples:
        unit = s["half"] if relative else 1.0
        sel = s["valid"]
        d, sh = s["d"][sel] / unit, s["shift"][sel] / unit
        bins = np.arange(0, 1 if relative else 20, step)
        curves.append([np.median(sh[(d >= b) & (d < b + step)]) * unit if ((d >= b) & (d < b + step)).sum() > 5 else np.nan
                       for b in bins])
    c = np.array(curves)
    return float(np.nanmean(np.nanstd(c, axis=0))) if len(curves) > 1 else 0.0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("run")
    parser.add_argument("--source", default="ios")
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()

    result = {}
    for scheme in ("light", "dark"):
        pages = load(args.run, args.source, scheme)
        if pages is None:
            print(f"{scheme}: coded-background pages missing")
            continue
        present = {m["id"] for m in pages["low"][0]["markers"]}
        samples = {ident: measure(pages, ident) for ident in SHAPES if ident in present}
        regular = [samples[i] for i in ("glass.capsule", "glass.circle", "glass.rounded", "glass.small", "glass.pill")
                   if i in samples]
        abs_spread, rel_spread = spread(regular, False, 1.0), spread(regular, True, 0.05)
        # Relative by default (shift scales with the shape) unless absolute is clearly better.
        relative = rel_spread < abs_spread * 1.25
        print(f"{scheme}: disagreement between shapes — absolute {abs_spread:.2f}, relative {rel_spread:.2f} "
              f"→ {'relative' if relative else 'absolute'}")
        step = 0.01 if relative else 0.25
        reg = table(regular, relative, step)
        clr = table([samples["glass.clear"]], relative, step)
        reg["edge"] = edge_table(regular)
        clr["edge"] = edge_table([samples["glass.clear"]])
        reg["tintedEdge"] = edge_table([samples["glass.tinted"]])
        # Blur under the tint: transmission is low (≈ 0.1), so take the interior without a transmission threshold.
        tin = samples["glass.tinted"]
        core = (tin["d"] > tin["half"] * 0.4) & (tin["alpha"] > 0.03)
        reg["tintedBlur"] = round(float(np.median(tin["blur"][core])), 3) if core.sum() > 50 else None
        # Tinted glass: tint opacity from the interior transmission, relative to regular glass.
        tinted = samples["glass.tinted"]
        a_t = float(np.median(tinted["alpha"][tinted["d"] > tinted["half"] * 0.5]))
        cap = samples["glass.capsule"]
        a_r = float(np.median(cap["alpha"][cap["d"] > cap["half"] * 0.5]))
        strength = round(max(0.0, min(1.0, 1 - a_t / max(a_r, 1e-6))), 3)
        # Effective tint colour (output = (α_r·bg + β_r)(1−k) + T·k), then the saturation and brightness
        # that turn the requested colour into T (least squares over r, g, b).
        sel_t, sel_r = tinted["d"] > tinted["half"] * 0.5, cap["d"] > cap["half"] * 0.5
        b_t = np.median(tinted["beta"][sel_t], axis=0)
        b_r = np.median(cap["beta"][sel_r], axis=0)
        k = max(strength, 1e-3)
        target = (b_t - (1 - k) * b_r) / k
        color = TINT[scheme]
        lum = float(np.dot(color, [0.2126, 0.7152, 0.0722]))
        # T = b·lum + (b·s)·(c − lum): linear in (b, b·s).
        A = np.stack([np.full(3, lum), color - lum], axis=1)
        (bb, bs), *_ = np.linalg.lstsq(A, target, rcond=None)
        transform = [round(float(bs / bb), 4), round(float(bb), 4), strength]
        result[scheme] = {"regular": reg, "clear": clr, "tintStrength": strength, "tintTransform": transform}
        for name, t in (("regular", reg), ("clear", clr)):
            n = len(t["d"])
            picks = sorted({0, 1, 2, 4, 8, n // 4, n // 2, n - 1})
            print(f"  {name:8s} blur " + " ".join(f"{v:.2f}" for v in t["blur"][::max(1, len(t["blur"]) // 8)]))
            print(f"  {name:8s} " + "  ".join(f"d={t['d'][i]:.2f}: shift {t['shift'][i]:+.2f} α {t['alpha'][i]:.2f}"
                                              for i in picks if i < n))
        print(f"  tint: blur {reg['tintedBlur']}")
        print(f"  tint: transmission {a_t:.2f} (regular {a_r:.2f}) → opacity {strength}, "
              f"colour {np.round(target, 3)} → saturation {transform[0]}, brightness {transform[1]}")

    # Geometry (shift) does not depend on the scheme: reuse the light measurement, which has better contrast.
    if "light" in result and "dark" in result:
        for variant in ("regular", "clear"):
            lt, dk = result["light"][variant], result["dark"][variant]
            if lt["relative"] == dk["relative"]:
                dk["shift"] = [round(float(v), 4) for v in np.interp(dk["d"], lt["d"], lt["shift"])]
                dk["blur"] = [round(float(v), 4) for v in np.interp(dk["d"], lt["d"], lt["blur"])]

    if args.write and result:
        with open(PROFILE) as f:
            profile = json.load(f)
        glass = profile["glassSettings"]
        for scheme, data in result.items():
            key = "tableLight" if scheme == "light" else "tableDark"
            for variant in ("regular", "clear"):
                t = dict(data[variant])
                # Saturation cannot be measured on grey backgrounds: carried over from the previous profile.
                t["saturation"] = (glass[variant].get(key) or {}).get("saturation", glass[variant].get("saturation", 1.0))
                glass[variant][key] = t
            glass["regular"]["tintTransform" + ("Light" if scheme == "light" else "Dark")] = data["tintTransform"]
        glass["regular"]["tintStrength"] = result.get("light", result.get("dark"))["tintStrength"]
        with open(PROFILE, "w") as f:
            json.dump(profile, f, indent=2, sort_keys=True, ensure_ascii=False)
            f.write("\n")
        print(f"Tables written to {PROFILE}")


if __name__ == "__main__":
    sys.exit(main())
