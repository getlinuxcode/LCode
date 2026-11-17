#!/usr/bin/env python3
"""Règle de décision des gestes système, ajustée sur des essais faits au doigt (entraîneur de gestes).

Usage : ~/.local/share/lcode/venv/bin/python -I tools/calibration/gesturefit.py <lot.json> [--write]

Pour chaque essai : déplacement et vitesse au lâcher (points, points/s) et issue (1 : écran retiré ou
feuille fermée). La règle cherchée est celle d'UIKit : position projetée = déplacement + k × vitesse,
comparée à une fraction s de la largeur (balayage) ou de la course de la feuille. On retient (k, s) qui
classe le mieux les essais, au centre de la zone des solutions exactes.
"""
import argparse
import json
import sys

import numpy as np

PROFILE = "Sources/LSimUI/Profiles/iOS-27.2.json"
# Course d'une feuille en grand sur iPhone 17 Pro Max : du sommet (62 pt) au bas de l'écran.
SHEET_TOP = 62.0


def fit(trials, axis, extent):
    # Essais sans relevé du glisser (le reconnaisseur ne l'a pas vu) : ignorés.
    trials = [t for t in trials if t.get("measured", 1) == 1]
    done = sum(1 for t in trials if t["done"] > 0.5)
    if done < 2 or len(trials) - done < 2:
        # Sans essais des deux issues, le seuil n'est pas déterminé.
        return None, 0.0, len(trials), done
    d = np.array([t["d" + axis] for t in trials], dtype=float)
    v = np.array([t["v" + axis] for t in trials], dtype=float)
    y = np.array([t["done"] for t in trials], dtype=float)
    e = np.array([extent(t) for t in trials], dtype=float)
    ks = np.arange(0.0, 0.61, 0.01)
    ss = np.arange(0.05, 0.96, 0.01)
    acc = np.zeros((len(ks), len(ss)))
    for i, k in enumerate(ks):
        p = (d + k * v) / e
        for j, s in enumerate(ss):
            acc[i, j] = np.mean((p > s) == (y > 0.5))
    best = acc.max()
    # Centre de la zone optimale (plus robuste qu'un coin quelconque).
    ii, jj = np.nonzero(acc >= best - 1e-9)
    k, s = float(np.median(ks[ii])), float(np.median(ss[jj]))
    return {"projection": round(k, 3), "threshold": round(s, 3)}, best, len(trials), int(y.sum())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("lot")
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()
    with open(args.lot) as f:
        data = json.load(f)
    result = {}
    if data.get("back"):
        r, acc, n, done = fit(data["back"], "x", lambda t: t["width"])
        if r is None:
            print(f"retour par balayage : {n} essais dont {done} retirés — il faut au moins 2 essais de chaque "
                  "issue (retiré et revenu) : seuil non écrit")
        else:
          result["backSwipe"] = r
          print(f"retour par balayage : {n} essais ({done} retirés) → position + {r['projection']} s × vitesse "
              f"> {r['threshold']:.2f} × largeur (essais bien classés : {acc:.0%})")
    if data.get("sheet"):
        r, acc, n, done = fit(data["sheet"], "y", lambda t: t["height"] - SHEET_TOP)
        if r is None:
            print(f"feuille tirée       : {n} essais dont {done} fermées — il faut au moins 2 essais de chaque "
                  "issue (fermée et revenue) : seuil non écrit")
        else:
          result["sheetDismiss"] = r
          print(f"feuille tirée       : {n} essais ({done} fermées) → position + {r['projection']} s × vitesse "
              f"> {r['threshold']:.2f} × course (essais bien classés : {acc:.0%})")
    if args.write and result:
        with open(PROFILE) as f:
            profile = json.load(f)
        profile["gestures"] = result
        with open(PROFILE, "w") as f:
            json.dump(profile, f, indent=2, sort_keys=True, ensure_ascii=False)
            f.write("\n")
        print(f"Seuils écrits dans {PROFILE}")


if __name__ == "__main__":
    sys.exit(main())
