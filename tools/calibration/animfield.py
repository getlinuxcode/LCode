#!/usr/bin/env python3
"""Animation curves measured on the iPhone (anim.* pages): fits springs and durations.

Usage: ~/.local/share/lcode/venv/bin/python -I tools/calibration/animfield.py <run> [--write]

Each page moves a red square from x = 40 to x = 300; the iPhone samples its position every display
frame (seconds since the trigger). Progress p(t) = (x − 40) / 260 is then fitted with:
  - a spring: best response and damping (least squares);
  - a Bezier curve: duration and control points.
`--write` stores the parameters in the profile (`animations`), used by LSimUI for its presets.
"""
import argparse
import json
import math
import os
import sys

import numpy as np

PROFILE = "Sources/LSimUI/Profiles/iOS-27.2.json"
START, END = 40.0, 300.0
# Apple presets written to the profile; the other pages only validate the fit.
PRESETS = {"default", "spring", "smooth", "snappy", "bouncy", "easeInOut", "linear"}
PAGES = ["default", "spring", "easeInOut", "linear", "smooth", "snappy", "bouncy", "springCustom", "easeOut1"]


def spring_progress(t, response, damping):
    w = 2 * math.pi / response
    t = np.maximum(t, 0)
    if damping < 1:
        wd = w * math.sqrt(1 - damping * damping)
        d = np.exp(-damping * w * t) * (np.cos(wd * t) + damping * w / wd * np.sin(wd * t))
    elif damping == 1:
        d = np.exp(-w * t) * (1 + w * t)
    else:
        r = w * math.sqrt(damping * damping - 1)
        r1, r2 = -damping * w + r, -damping * w - r
        c2 = -r1 / (r2 - r1)
        d = (1 - c2) * np.exp(r1 * t) + c2 * np.exp(r2 * t)
    return 1 - d


def bezier_progress(t, duration, x1, y1, x2, y2):
    x = np.clip(t / duration, 0, 1)
    lo, hi = np.zeros_like(x), np.ones_like(x)
    for _ in range(40):
        mid = (lo + hi) / 2
        bx = 3 * (1 - mid) ** 2 * mid * x1 + 3 * (1 - mid) * mid ** 2 * x2 + mid ** 3
        lo = np.where(bx < x, mid, lo)
        hi = np.where(bx < x, hi, mid)
    s = (lo + hi) / 2
    return 3 * (1 - s) ** 2 * s * y1 + 3 * (1 - s) * s ** 2 * y2 + s ** 3


def fit_spring(t, p):
    best = None
    for response in np.arange(0.15, 1.3, 0.02):
        for damping in np.arange(0.3, 1.6, 0.02):
            err = float(np.sqrt(np.mean((spring_progress(t, response, damping) - p) ** 2)))
            if best is None or err < best[0]:
                best = (err, round(float(response), 3), round(float(damping), 3))
    return best


def fit_bezier(t, p):
    best = None
    curves = {"linear": (0, 0, 1, 1), "easeIn": (0.42, 0, 1, 1), "easeOut": (0, 0, 0.58, 1),
              "easeInOut": (0.42, 0, 0.58, 1)}
    for name, c in curves.items():
        for duration in np.arange(0.1, 1.6, 0.01):
            err = float(np.sqrt(np.mean((bezier_progress(t, duration, *c) - p) ** 2)))
            if best is None or err < best[0]:
                best = (err, name, round(float(duration), 3))
    return best


def load(run, page, scheme="light"):
    path = os.path.join(run, "ios", f"anim.{page}.{scheme}.json")
    if not os.path.exists(path):
        return None
    with open(path) as f:
        samples = json.load(f).get("samples") or []
    if not samples:
        return None
    a = np.array(samples, dtype=float)
    t, x = a[:, 0], a[:, 1]
    keep = t >= -0.05
    return t[keep], (x[keep] - START) / (END - START)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("run")
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()
    result = {}
    for page in PAGES:
        data = load(args.run, page)
        if data is None:
            print(f"{page:13s}: no samples")
            continue
        t, p = data
        # The trigger is stamped before the transaction reaches the screen: the lag is fitted with the curve (4 ms steps).
        lag0 = float(t[np.argmax(p > 0.005)]) if (p > 0.005).any() else 0.0
        s = b = None
        for offset in np.arange(max(0.0, lag0 - 0.06), lag0 + 0.004, 0.004):
            ts = t - offset
            cs, cb = fit_spring(ts, p), fit_bezier(ts, p)
            if s is None or cs[0] < s[0]:
                s = cs + (offset,)
            if b is None or cb[0] < b[0]:
                b = cb + (offset,)
        lag = s[3] if s[0] <= b[0] else b[3]
        kind = "spring" if s[0] <= b[0] else "bezier"
        print(f"{page:13s}: {len(t)} frames, lag {lag * 1000:.0f} ms, max {p.max():.3f} | "
              f"spring response {s[1]} damping {s[2]} (rms {s[0]:.4f}) | {b[1]} {b[2]} s (rms {b[0]:.4f}) → {kind}")
        result[page] = ({"spring": {"response": s[1], "damping": s[2]}} if kind == "spring"
                        else {"bezier": b[1], "duration": b[2]})
        result[page]["lag"] = round(lag, 4)
    if args.write and result:
        with open(PROFILE) as f:
            profile = json.load(f)
        profile["animations"] = {k: v for k, v in result.items() if k in PRESETS}
        with open(PROFILE, "w") as f:
            json.dump(profile, f, indent=2, sort_keys=True, ensure_ascii=False)
            f.write("\n")
        print(f"Animations written to {PROFILE}")


if __name__ == "__main__":
    sys.exit(main())
