"""Fonctions communes du banc de calibration : rendu LSim sans fenêtre et comparaison avec l'iPhone."""
import glob
import json
import os
import subprocess
from concurrent.futures import ThreadPoolExecutor

from PIL import Image, ImageChops, ImageStat

DEVICES = {"iPhone18,2": "iphone17promax"}


def load_ios(run):
    """Mesures iPhone d'une série : {(page, thème): {"meta": …, "png": chemin}}."""
    out = {}
    for path in sorted(glob.glob(os.path.join(run, "ios", "*.json"))):
        with open(path) as f:
            meta = json.load(f)
        out[(meta["page"], meta["colorScheme"])] = {"meta": meta, "png": path[:-5] + ".png"}
    return out


def render_lsim(binary, page, scheme, device, out_dir, profile=None):
    """Rend une page du catalogue dans LSim (écran seul, @3x) ; renvoie (mesures, chemin PNG)."""
    base = os.path.join(out_dir, f"{page}.{scheme}")
    env = dict(os.environ, CATALOG_PAGE_ID=page, LSIM_SCREEN_ONLY="1", LSIM_DEVICE=device,
               LSIM_DUMP=base + ".json", LSIM_SCREENSHOT=base + ".png")
    if scheme == "dark":
        env["LSIM_DARK"] = "1"
    if profile:
        env["LSIM_PROFILE"] = profile
    subprocess.run([binary], env=env, check=True, stdout=subprocess.DEVNULL)
    with open(base + ".json") as f:
        return json.load(f), base + ".png"


def render_many(binary, keys, device, out_dir, profile=None, workers=None):
    """Rend plusieurs (page, thème) en parallèle."""
    os.makedirs(out_dir, exist_ok=True)
    with ThreadPoolExecutor(max_workers=workers or os.cpu_count()) as pool:
        futures = {k: pool.submit(render_lsim, binary, k[0], k[1], device, out_dir, profile) for k in keys}
        return {k: f.result() for k, f in futures.items()}


def crop(img, rect, scale, pad=6):
    x, y, w, h = rect
    return img.crop((int((x - pad) * scale), int((y - pad) * scale),
                     int((x + w + pad) * scale), int((y + h + pad) * scale)))


_image_cache = {}


def image(path, cache=False):
    if cache and path in _image_cache:
        return _image_cache[path]
    img = Image.open(path).convert("RGB")
    if cache:
        _image_cache[path] = img
    return img


def compare_page(ios_meta, ios_png, lsim_meta, lsim_png):
    """Écarts par repère : géométrie (LSim − iPhone, en points) et pixels (écart moyen 0–255).

    Sans capture iPhone (`ios_png` vide ou absent), seule la géométrie est comparée (pix = 0).
    """
    scale = ios_meta["screen"]["scale"]
    has_pixels = bool(ios_png) and os.path.exists(ios_png)
    a_img = image(ios_png, cache=True) if has_pixels else None
    b_img = image(lsim_png) if has_pixels else None
    lsim = {m["id"]: m for m in lsim_meta["markers"]}
    rows = []
    for m in ios_meta["markers"]:
        o = lsim.get(m["id"])
        if o is None:
            rows.append({"id": m["id"], "missing": True, "geo": 99.0, "geoSum": 99.0, "pix": 99.0})
            continue
        d = {k: o[k] - m[k] for k in ("x", "y", "width", "height")}
        rect = (m["x"], m["y"], m["width"], m["height"])
        pix = 0.0
        if has_pixels:
            diff = ImageChops.difference(crop(a_img, rect, scale), crop(b_img, rect, scale))
            pix = sum(ImageStat.Stat(diff).mean) / 3
        rows.append({"id": m["id"], "d": d, "geo": max(abs(v) for v in d.values()),
                     "geoSum": sum(abs(v) for v in d.values()), "pix": pix,
                     "ios": m, "lsim": o})
    return rows


def best_layer(marker, layers, need=("backgroundColor", "cornerRadius")):
    """Couche iOS dont le cadre colle au repère et qui porte un fond ou un rayon."""
    best = None
    for layer in layers:
        x, y, w, h = layer["frame"]
        if (abs(x - marker["x"]) < 1.5 and abs(y - marker["y"]) < 1.5
                and abs(w - marker["width"]) < 3 and abs(h - marker["height"]) < 3
                and ("backgroundColor" in layer or layer.get("cornerRadius", 0) > 0)):
            best = layer
    return best
