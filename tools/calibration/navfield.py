#!/usr/bin/env python3
"""Mesure de la barre de navigation Liquid Glass à partir des pages `nav.edge.*` et `nav.bar.*`.

Usage : ~/.local/share/lcode/venv/bin/python -I tools/calibration/navfield.py <série> [--source ios|lsim] [--write]

Effet de bord de défilement (pages nav.edge.low/high/xsin/xcos, contenu défilé sous la barre) :
pour chaque ligne de l'écran, sortie = α·fond + β (fonds gris bas/haut) et flou d'après le contraste des
ondes verticales de 16 pt. Médianes par ligne, hors boutons et titre (colonnes du milieu exclues si
le titre y est). Écrit `navigationEdgeLight` / `navigationEdgeDark` dans le profil (`--write`).
"""
import argparse
import json
import os
import sys

import numpy as np
from PIL import Image

LOW, HIGH = 0.15, 0.70
PERIOD = 16.0
PROFILE = "Sources/LSimUI/Profiles/iOS-27.2.json"


def load(run, source, scheme, names):
    out = {}
    for name in names:
        base = os.path.join(run, source, f"{name}.{scheme}")
        if not os.path.exists(base + ".png"):
            return None
        with open(base + ".json") as f:
            meta = json.load(f)
        out[name] = (meta, np.asarray(Image.open(base + ".png").convert("RGB"), dtype=np.float64) / 255)
    return out


def edge_profile(pages):
    meta = pages["nav.edge.low"][0]
    scale = meta["screen"]["scale"]
    K, W = pages["nav.edge.low"][1], pages["nav.edge.high"][1]
    k, w = K.mean(axis=2), W.mean(axis=2)
    alpha = (w - k) / (HIGH - LOW)
    beta = K - alpha[..., None] * LOW
    span = np.maximum(w - k, 1e-6)
    s = (pages["nav.edge.xsin"][1].mean(axis=2) - k) / span
    c = (pages["nav.edge.xcos"][1].mean(axis=2) - k) / span
    mod = np.hypot(2 * s - 1, 2 * c - 1)

    h, wpx = k.shape
    # Colonnes utiles : bandes entre les boutons et le titre (marges de 80 pt de chaque côté du centre exclues
    # là où passe le titre, et 70 pt aux bords pour les boutons).
    xs = (np.arange(wpx) + 0.5) / scale
    width = wpx / scale
    cols = ((xs > 76) & (xs < width / 2 - 70)) | ((xs > width / 2 + 70) & (xs < width - 76))
    # Contraste de référence : bas de l'écran (contenu nu).
    ref = np.median(mod[int(h * 0.7):, cols])
    rows = {"y": [], "alpha": [], "beta": [], "blur": []}
    step = 1  # points
    content = meta["markers"][0] if meta["markers"] else None
    bottom = int(min(h / scale, 200))
    for y in range(0, bottom, step):
        r0, r1 = int(y * scale), int((y + step) * scale)
        a = float(np.median(alpha[r0:r1, cols]))
        b = np.median(beta[r0:r1][:, cols].reshape(-1, 3), axis=0)
        ratio = float(np.median(mod[r0:r1, cols])) / ref
        sigma = PERIOD / (np.pi * np.sqrt(2)) * np.sqrt(-np.log(min(max(ratio, 1e-3), 1.0)))
        rows["y"].append(y + step / 2)
        rows["alpha"].append(round(a, 4))
        rows["beta"].append([round(float(v), 4) for v in b])
        rows["blur"].append(round(sigma, 3))
    # Base de la barre sur l'appareil de mesure (iPhone 17 Pro Max : zone sûre 62 pt + barre 54 pt), pour
    # recaler la table sur d'autres appareils.
    rows["referenceBarBottom"] = 116.0
    return rows


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("run")
    parser.add_argument("--source", default="ios")
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()
    names = ["nav.edge.low", "nav.edge.high", "nav.edge.xsin", "nav.edge.xcos"]
    result = {}
    for scheme in ("light", "dark"):
        pages = load(args.run, args.source, scheme, names)
        if pages is None:
            print(f"{scheme} : pages nav.edge absentes")
            continue
        prof = edge_profile(pages)
        result[scheme] = prof
        print(f"{scheme} : effet de bord, ligne par ligne (y en pt depuis le haut de l'écran)")
        for i in range(0, len(prof["y"]), 8):
            print(f"  y={prof['y'][i]:5.1f}  α {prof['alpha'][i]:.2f}  β {prof['beta'][i]}  flou {prof['blur'][i]:.2f}")
    if args.write and result:
        with open(PROFILE) as f:
            profile = json.load(f)
        nav = profile.setdefault("navigation", {})
        for scheme, prof in result.items():
            nav["edgeLight" if scheme == "light" else "edgeDark"] = prof
        with open(PROFILE, "w") as f:
            json.dump(profile, f, indent=2, sort_keys=True, ensure_ascii=False)
            f.write("\n")
        print(f"Effet de bord écrit dans {PROFILE}")


if __name__ == "__main__":
    sys.exit(main())
