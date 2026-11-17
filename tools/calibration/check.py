#!/usr/bin/env python3
"""Regression check: does LSim still match the iPhone reference measurements?

Usage: python3 -I tools/calibration/check.py [--update]

References live in Tests/Calibration/<profile>/: frames measured on the iPhone (no images) and
`residuals.json`, the accepted residual of each marker after the last fit. The check fails when a marker
drifts more than TOLERANCE pt from its accepted residual (or exceeds 1 pt if it was exact).
`--update` stores the current deltas as the new accepted residuals (done by calibrate.py).
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
        if path.endswith("residuals.json"):
            continue
        with open(path) as f:
            meta = json.load(f)
        refs[(meta["page"], meta["colorScheme"])] = meta
    if not refs:
        print(f"No references in {args.reference}.")
        return 1
    device = calib.DEVICES.get(next(iter(refs.values()))["device"], "iphone17promax")

    with tempfile.TemporaryDirectory() as tmp:
        rendered = calib.render_many(args.lsim, list(refs), device, tmp)
        rows = []
        for key, (meta, png) in rendered.items():
            for r in calib.compare_page(refs[key], None, meta, png):
                rows.append((f"{key[0]}|{key[1]}|{r['id']}", r["geo"]))

    residuals_path = os.path.join(args.reference, "residuals.json")
    if args.update:
        with open(residuals_path, "w") as f:
            json.dump({k: round(g, 2) for k, g in sorted(rows)}, f, indent=1, sort_keys=True)
            f.write("\n")
        print(f"{len(rows)} residuals written to {residuals_path}.")
        return 0

    accepted = {}
    if os.path.exists(residuals_path):
        with open(residuals_path) as f:
            accepted = json.load(f)
    failures = []
    for key, geo in rows:
        limit = max(accepted.get(key, 0) + TOLERANCE, 1.0)
        if geo > limit + 1e-6:
            failures.append((key, geo, limit))
    within = sum(g <= 1 for _, g in rows)
    print(f"{len(rows)} markers: {within} within 1 pt of the iPhone, {len(failures)} regression(s).")
    for key, geo, limit in sorted(failures, key=lambda f: -f[1])[:30]:
        print(f"  REGRESSION {key}: {geo:.2f} pt (limit {limit:.2f})")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
