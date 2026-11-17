#!/usr/bin/env python3
"""Builds the SF Symbols name → glyph table for this machine.

Usage: ~/.local/share/lcode/venv/bin/python -I tools/calibration/symbols.py Calibration/<run>

The iPhone sent the symbol names and a drawing of each (black on white, 64 × 64). This script draws
every glyph of the private use area (U+100000…) of the installed SF Pro font and matches the shapes
(normalised silhouettes, nearest neighbour). The result only holds name → code point mappings derived
from the user's own data; it is written outside the repository: ~/.local/share/lcode/symbols/iOS-27.2.json
"""
import argparse
import base64
import glob
import json
import os
import sys

import numpy as np
from fontTools.ttLib import TTFont
from PIL import Image, ImageDraw, ImageFont

FONT = os.path.expanduser("~/.local/share/fonts/apple/SF-Pro-Text-Regular.otf")
OUT = os.path.expanduser("~/.local/share/lcode/symbols/iOS-27.2.json")
N = 48  # normalised silhouette side


def normalize(gray):
    """Silhouette: ink cropped, scaled uniformly into N × N, centred. Returns (vector, aspect ratio)."""
    a = 255 - np.asarray(gray, dtype=np.float32)
    ys, xs = np.nonzero(a > 40)
    if len(xs) == 0:
        return None, 0
    crop = a[ys.min():ys.max() + 1, xs.min():xs.max() + 1]
    h, w = crop.shape
    k = (N - 2) / max(h, w)
    img = Image.fromarray(crop.astype(np.uint8)).resize((max(1, round(w * k)), max(1, round(h * k))), Image.LANCZOS)
    canvas = np.zeros((N, N), dtype=np.float32)
    oy, ox = (N - img.height) // 2, (N - img.width) // 2
    canvas[oy:oy + img.height, ox:ox + img.width] = np.asarray(img, dtype=np.float32)
    v = canvas.flatten()
    norm = np.linalg.norm(v)
    return (v / norm if norm else v), w / h


def font_glyphs():
    """Silhouettes of all glyphs in the font's private use area."""
    cmap = TTFont(FONT, lazy=True).getBestCmap()
    cps = sorted(cp for cp in cmap if cp >= 0x100000)
    font = ImageFont.truetype(FONT, 48)
    vectors, ratios, kept = [], [], []
    for cp in cps:
        img = Image.new("L", (96, 96), 255)
        ImageDraw.Draw(img).text((16, 8), chr(cp), font=font, fill=0)
        v, r = normalize(img)
        if v is not None:
            vectors.append(v)
            ratios.append(r)
            kept.append(cp)
    return np.array(vectors), np.array(ratios), kept


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("run")
    parser.add_argument("--out", default=OUT)
    args = parser.parse_args()

    folder = os.path.join(args.run, "symbols")
    with open(os.path.join(folder, "info.json")) as f:
        info = json.load(f)
    entries = []
    for path in sorted(glob.glob(os.path.join(folder, "batch-*.json"))):
        with open(path) as f:
            entries += json.load(f)["symbols"]
    if not entries:
        sys.exit(f"No symbol drawings in {folder} (iOS provided {info.get('count')} names).")
    print(f"{len(entries)} symbols drawn by the iPhone; font: {os.path.basename(FONT)}")

    fv, fr, cps = font_glyphs()
    print(f"{len(cps)} glyphs in the font's private use area")

    table, distances, weak = {}, [], []
    for e in entries:
        pixels = np.frombuffer(base64.b64decode(e["pixels"]), dtype=np.uint8).reshape(64, 64)
        v, ratio = normalize(Image.fromarray(pixels))
        if v is None:
            continue
        sims = fv @ v                                   # cosine similarity (unit vectors)
        sims = sims - 0.5 * np.abs(np.log(np.maximum(fr, 1e-3) / max(ratio, 1e-3)))  # penalise a different aspect ratio
        order = np.argsort(sims)[::-1]
        best = int(order[0])
        score = float(sims[best])
        margin = score - float(sims[order[1]])
        distances.append(score)
        # Accept if very similar, or fairly similar AND clearly ahead of the runner-up
        # (thin shapes like "minus" score lower because of anti-aliasing).
        if score < 0.9 and not (score >= 0.84 and margin >= 0.03):
            weak.append((e["name"], score))
            continue
        table[e["name"]] = cps[best]

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w") as f:
        json.dump({"source": os.path.basename(args.run.rstrip("/")), "font": os.path.basename(FONT),
                   "symbols": table, "aliases": info.get("aliases", {})}, f, sort_keys=True)
    print(f"{len(table)} symbols matched, {len(weak)} uncertain ones dropped (similarity < 0.9).")
    for name in ("globe", "checkmark.circle.fill", "star.fill", "plus", "gear", "heart", "chevron.right"):
        print(f"  {name:24s} → U+{table[name]:X}" if name in table else f"  {name:24s} → (unmatched)")
    print(f"Table written: {args.out}")


if __name__ == "__main__":
    main()
