#!/usr/bin/env python3
"""Compare les mesures de l'iPhone à celles de LSim pour une calibration.

Usage : python3 -I tools/calibration/compare.py Calibration/<run> [--lsim .build/debug/CatalogExample]

Pour chaque page reçue de l'iPhone, LSim rend la même page (même thème) sans fenêtre,
puis on compare les cadres de chaque repère et les pixels autour. Produit :
  <run>/rapport.md         tableau des écarts, trié du pire au meilleur
  <run>/planches/*.png     iPhone | LSim | différence, pour chaque repère
"""
import argparse
import glob
import json
import os
import subprocess
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFont

DEVICES = {"iPhone18,2": "iphone17promax"}
FONT = "/home/joris/.local/share/fonts/apple/SF-Pro-Text-Regular.otf"


def run_lsim(binary, page, scheme, device, out_dir):
    base = os.path.join(out_dir, f"{page}.{scheme}")
    env = dict(os.environ, CATALOG_PAGE_ID=page, LSIM_SCREEN_ONLY="1", LSIM_DEVICE=device,
               LSIM_DUMP=base + ".json", LSIM_SCREENSHOT=base + ".png")
    if scheme == "dark":
        env["LSIM_DARK"] = "1"
    subprocess.run([binary], env=env, check=True, stdout=subprocess.DEVNULL)
    with open(base + ".json") as f:
        return json.load(f), base + ".png"


def layers_for(marker, layers):
    """Couches iOS dont le cadre correspond au repère (fond, forme du bouton…)."""
    mx, my, mw, mh = marker["x"], marker["y"], marker["width"], marker["height"]
    out = []
    for layer in layers:
        x, y, w, h = layer["frame"]
        if abs(x - mx) <= 1.5 and abs(y - my) <= 1.5 and abs(w - mw) <= 3 and abs(h - mh) <= 3:
            out.append(layer)
    return out


def describe_layers(layers):
    parts = []
    for layer in layers[:3]:
        bits = [layer["class"]]
        if layer.get("cornerRadius"):
            bits.append(f"rayon {layer['cornerRadius']:.1f} ({layer.get('cornerCurve', '')})")
        for key in ("backgroundColor", "fillColor"):
            if key in layer:
                c = layer[key]
                bits.append(f"{key[:2]} rgba({round(c[0]*255)},{round(c[1]*255)},{round(c[2]*255)},{c[3]:.2f})" if len(c) >= 4 else f"{key} {c}")
        if "filters" in layer:
            bits.append("filtres " + ",".join(f.split(" ")[0] for f in layer["filters"]))
        if "shadow" in layer:
            bits.append(f"ombre r{layer['shadow']['radius']:.1f}")
        parts.append(" ".join(bits))
    return " ; ".join(parts)


def crop(img, rect, scale, pad=6):
    x, y, w, h = rect
    box = (int((x - pad) * scale), int((y - pad) * scale), int((x + w + pad) * scale), int((y + h + pad) * scale))
    return img.crop(box)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("run")
    parser.add_argument("--lsim", default=".build/debug/CatalogExample")
    args = parser.parse_args()

    lsim_dir = os.path.join(args.run, "lsim")
    sheets_dir = os.path.join(args.run, "planches")
    os.makedirs(lsim_dir, exist_ok=True)
    os.makedirs(sheets_dir, exist_ok=True)
    font = ImageFont.truetype(FONT, 22) if os.path.exists(FONT) else None

    rows = []
    for path in sorted(glob.glob(os.path.join(args.run, "ios", "*.json"))):
        with open(path) as f:
            ios = json.load(f)
        page, scheme = ios["page"], ios["colorScheme"]
        device = DEVICES.get(ios["device"], "iphone17promax")
        lsim, lsim_png = run_lsim(args.lsim, page, scheme, device, lsim_dir)
        scale = ios["screen"]["scale"]
        ios_img = Image.open(path[:-5] + ".png").convert("RGB")
        lsim_img = Image.open(lsim_png).convert("RGB")
        lsim_markers = {m["id"]: m for m in lsim["markers"]}

        sheet_rows = []
        for m in sorted(ios["markers"], key=lambda m: (m["y"], m["x"])):
            other = lsim_markers.get(m["id"])
            if other is None:
                rows.append((99, page, scheme, m["id"], "absent de LSim", "", ""))
                continue
            d = {k: other[k] - m[k] for k in ("x", "y", "width", "height")}
            geo = max(abs(v) for v in d.values())
            # Comparaison visuelle sur la zone iPhone (même rectangle dans les deux images).
            a = crop(ios_img, (m["x"], m["y"], m["width"], m["height"]), scale)
            b = crop(lsim_img, (m["x"], m["y"], m["width"], m["height"]), scale)
            diff = ImageChops.difference(a, b).convert("L")
            mean = sum(diff.getdata()) / max(1, diff.width * diff.height)
            rows.append((geo, page, scheme, m["id"],
                         " ".join(f"{k[0]}{v:+.1f}" for k, v in d.items() if abs(v) >= 0.25) or "=",
                         f"{mean:.1f}", describe_layers(layers_for(m, ios.get("layers", [])))))
            sheet_rows.append((m["id"], geo, mean, a, crop(lsim_img, (other["x"], other["y"], other["width"], other["height"]), scale), diff))

        # Planche : iPhone | LSim (son propre cadre) | différence (même zone).
        if sheet_rows:
            col = max(max(r[3].width, r[4].width) for r in sheet_rows)
            height = sum(max(r[3].height, r[4].height) + 40 for r in sheet_rows) + 20
            sheet = Image.new("RGB", (col * 3 + 80, height), (40, 40, 42))
            draw = ImageDraw.Draw(sheet)
            y = 10
            for ident, geo, mean, a, b, diff in sheet_rows:
                draw.text((10, y), f"{ident}   géométrie Δ{geo:.1f} pt   pixels Δ{mean:.1f}", fill=(230, 230, 230), font=font)
                y += 30
                sheet.paste(a, (10, y))
                sheet.paste(b, (col + 40, y))
                sheet.paste(diff.point(lambda v: min(255, v * 3)).convert("RGB"), (col * 2 + 70, y))
                y += max(a.height, b.height) + 10
            sheet.save(os.path.join(sheets_dir, f"{page}.{scheme}.png"))

    rows.sort(key=lambda r: (-r[0], r[1], r[3]))
    with open(os.path.join(args.run, "rapport.md"), "w") as f:
        f.write("# Rapport de calibration\n\n")
        f.write(f"{len(rows)} repères comparés. Δ géométrie en points (x, y, w, h : LSim − iPhone) ; Δ pixels = écart moyen (0–255).\n\n")
        f.write("| Δgéo | page | thème | repère | écarts | Δpix | couches iOS |\n|---|---|---|---|---|---|---|\n")
        for geo, page, scheme, ident, d, mean, layers in rows:
            f.write(f"| {geo:.1f} | {page} | {scheme} | `{ident}` | {d} | {mean} | {layers} |\n")
    worst = [r for r in rows if r[0] > 1]
    print(f"{len(rows)} repères comparés, {len(worst)} avec un écart géométrique > 1 pt.")
    print(f"Rapport : {os.path.join(args.run, 'rapport.md')}")


if __name__ == "__main__":
    sys.exit(main())
