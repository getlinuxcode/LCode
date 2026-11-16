#!/usr/bin/env python3
"""Vérification de non-régression : LSim reste-t-il fidèle aux mesures de référence de l'iPhone ?

Usage : python3 -I tools/calibration/check.py [--update]

Les références sont dans Tests/Calibration/<profil>/ : les cadres mesurés sur l'iPhone (sans images)
et `residus.json`, l'écart accepté de chaque repère lors du dernier ajustement. Le contrôle échoue si
un repère s'écarte de plus de TOLERANCE pt de son résidu accepté (ou dépasse 1 pt s'il était juste).
`--update` enregistre les écarts actuels comme nouveaux résidus acceptés (fait par calibrate.py).
"""
import argparse
import glob
import json
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import calib  # noqa: E402

TOLERANCE = 0.5
REFERENCE = "Tests/Calibration/iOS-27.2"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--lsim", default=".build/debug/CatalogExample")
    parser.add_argument("--reference", default=REFERENCE)
    parser.add_argument("--update", action="store_true")
    args = parser.parse_args()

    refs = {}
    for path in sorted(glob.glob(os.path.join(args.reference, "*.json"))):
        if path.endswith("residus.json"):
            continue
        with open(path) as f:
            meta = json.load(f)
        refs[(meta["page"], meta["colorScheme"])] = meta
    if not refs:
        print(f"Aucune référence dans {args.reference}.")
        return 1
    device = calib.DEVICES.get(next(iter(refs.values()))["device"], "iphone17promax")

    with tempfile.TemporaryDirectory() as tmp:
        rendered = calib.render_many(args.lsim, list(refs), device, tmp)
        rows = []
        for key, (meta, png) in rendered.items():
            for r in calib.compare_page(refs[key], None, meta, png):
                rows.append((f"{key[0]}|{key[1]}|{r['id']}", r["geo"]))

    residus_path = os.path.join(args.reference, "residus.json")
    if args.update:
        with open(residus_path, "w") as f:
            json.dump({k: round(g, 2) for k, g in sorted(rows)}, f, indent=1, sort_keys=True)
            f.write("\n")
        print(f"{len(rows)} résidus enregistrés dans {residus_path}.")
        return 0

    accepted = {}
    if os.path.exists(residus_path):
        with open(residus_path) as f:
            accepted = json.load(f)
    failures = []
    for key, geo in rows:
        limit = max(accepted.get(key, 0) + TOLERANCE, 1.0)
        if geo > limit + 1e-6:
            failures.append((key, geo, limit))
    within = sum(g <= 1 for _, g in rows)
    print(f"{len(rows)} repères : {within} à ≤ 1 pt de l'iPhone, {len(failures)} régression(s).")
    for key, geo, limit in sorted(failures, key=lambda f: -f[1])[:30]:
        print(f"  RÉGRESSION {key} : {geo:.2f} pt (limite {limit:.2f})")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
