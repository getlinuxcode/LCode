#!/usr/bin/env python3
"""System gesture decision rule, fitted on finger-made trials (gesture trainer).

Usage: ~/.local/share/lcode/venv/bin/python -I tools/calibration/gesturefit.py <batch.json> [--write]

Each trial: translation and velocity at release (pt, pt/s) and outcome (1: screen popped or sheet
dismissed). The rule is UIKit's: projected position = translation + k × velocity, compared with a
fraction s of the width (swipe) or of the sheet travel. Keeps the (k, s) that classifies the trials
best, at the centre of the optimal region.
"""
import argparse
import json
import sys

import numpy as np

PROFILE = "Sources/LSimUI/Profiles/iOS-27.2.json"
# Large sheet travel on iPhone 17 Pro Max: from its top (62 pt) to the bottom of the screen.
SHEET_TOP = 62.0


def fit(trials, axis, extent):
    # Trials where the recognizer missed the drag are ignored.
    trials = [t for t in trials if t.get("measured", 1) == 1]
    done = sum(1 for t in trials if t["done"] > 0.5)
    if done < 2 or len(trials) - done < 2:
        # The threshold is undetermined without trials of both outcomes.
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
    # Centre of the optimal region (more robust than an arbitrary corner).
    ii, jj = np.nonzero(acc >= best - 1e-9)
    k, s = float(np.median(ks[ii])), float(np.median(ss[jj]))
    return {"projection": round(k, 3), "threshold": round(s, 3)}, best, len(trials), int(y.sum())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("batch")
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()
    with open(args.batch) as f:
        data = json.load(f)
    result = {}
    if data.get("back"):
        r, acc, n, done = fit(data["back"], "x", lambda t: t["width"])
        if r is None:
            print(f"back swipe: {n} trials, {done} popped — at least 2 trials of each outcome "
                  "(popped and cancelled) are needed: threshold not written")
        else:
            result["backSwipe"] = r
            print(f"back swipe: {n} trials ({done} popped) → position + {r['projection']} s × velocity "
                  f"> {r['threshold']:.2f} × width (correctly classified: {acc:.0%})")
    if data.get("sheet"):
        r, acc, n, done = fit(data["sheet"], "y", lambda t: t["height"] - SHEET_TOP)
        if r is None:
            print(f"sheet drag: {n} trials, {done} dismissed — at least 2 trials of each outcome "
                  "(dismissed and restored) are needed: threshold not written")
        else:
            result["sheetDismiss"] = r
            print(f"sheet drag: {n} trials ({done} dismissed) → position + {r['projection']} s × velocity "
                  f"> {r['threshold']:.2f} × travel (correctly classified: {acc:.0%})")
    if args.write and result:
        with open(PROFILE) as f:
            profile = json.load(f)
        profile["gestures"] = result
        with open(PROFILE, "w") as f:
            json.dump(profile, f, indent=2, sort_keys=True, ensure_ascii=False)
            f.write("\n")
        print(f"Thresholds written to {PROFILE}")


if __name__ == "__main__":
    sys.exit(main())
