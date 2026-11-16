#!/usr/bin/env python3
"""Correcteur automatique : ajuste le profil de design de LSim sur les mesures d'un iPhone.

Usage : python3 -I tools/calibration/fit.py Calibration/<série> [--dry-run]

1. Lecture directe de ce qu'iOS expose dans ses couches (couleurs, opacités, rayons).
2. Choix des comportements de chaque style (couleur du libellé, taille de police, remplissage)
   par recherche : chaque option est rendue dans LSim et comparée à l'iPhone.
3. Ajustement des valeurs continues : marges par correction directe des écarts, police par
   recherche, matière du verre par recherche sur les pixels.

Écrit le profil (Sources/LSimUI/Profiles/iOS-27.2.json) et un rapport <série>/ajustement.md.
Les écarts qu'aucun réglage n'explique sont listés comme anomalies, avec leurs mesures.
"""
import argparse
import copy
import json
import os
import statistics
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import calib  # noqa: E402

STYLES = ["automatic", "plain", "bordered", "borderedProminent", "glass", "glassProminent"]
SIZES = ["mini", "small", "regular", "large", "extraLarge"]
FILLED = ["bordered", "borderedProminent", "glass", "glassProminent"]
W_GEO, W_PIX, W_EDGE = 3.0, 1.0, 2.0


class Fitter:
    def __init__(self, run, binary, profile_path):
        self.run = run
        self.binary = binary
        self.ios = calib.load_ios(run)
        self.device = calib.DEVICES.get(next(iter(self.ios.values()))["meta"]["device"], "iphone17promax")
        with open(profile_path) as f:
            self.profile = json.load(f)
        self.work = os.path.join(run, "fit")
        os.makedirs(self.work, exist_ok=True)
        self.evals = 0
        self.changes = {}

    # --- Évaluation ---------------------------------------------------------------------------

    def keys(self, pages):
        return [k for k in self.ios if k[0] in pages]

    def evaluate(self, profile, pages):
        """Rend les pages avec ce profil et renvoie (score, écarts par repère)."""
        self.evals += 1
        path = os.path.join(self.work, "candidat.json")
        with open(path, "w") as f:
            json.dump(profile, f)
        rendered = calib.render_many(self.binary, self.keys(pages), self.device,
                                     os.path.join(self.work, "rendus"), profile=path)
        rows = []
        for key, (meta, png) in rendered.items():
            ios = self.ios[key]
            for r in calib.compare_page(ios["meta"], ios["png"], meta, png):
                r["page"], r["scheme"] = key
                rows.append(r)
        score = sum(W_GEO * r["geoSum"] + W_PIX * r["pix"] + W_EDGE * r.get("edge", 0) for r in rows)
        return score, rows

    def search(self, label, pages, path, candidates):
        """Essaie chaque valeur d'un réglage (chemin dans le profil) et garde la meilleure."""
        best_value = get(self.profile, path)
        best_score, _ = self.evaluate(self.profile, pages)
        for value in candidates:
            if value == best_value:
                continue
            trial = copy.deepcopy(self.profile)
            put(trial, path, value)
            score, _ = self.evaluate(trial, pages)
            if score < best_score - 1e-6:
                best_value, best_score = value, score
        self.set(label, path, best_value)
        return best_value

    def set(self, label, path, value):
        """Applique une valeur et la consigne (une ligne par réglage : valeur initiale → finale)."""
        old = get(self.profile, path)
        if old == value:
            return
        key = ".".join(path)
        if key not in self.changes:
            self.changes[key] = [label, copy.deepcopy(old), None]
        self.changes[key][2] = copy.deepcopy(value)
        put(self.profile, path, value)

    # --- 1. Lecture directe -----------------------------------------------------------------------

    def read_layers(self):
        def marker(page, scheme, ident):
            meta = self.ios[(page, scheme)]["meta"]
            return next(m for m in meta["markers"] if m["id"] == ident), meta["layers"]

        b = self.profile["button"]
        # Remplissage neutre de .bordered (sans teinte).
        fill = {}
        for scheme in ("light", "dark"):
            m, layers = marker("button.bordered", scheme, "button.bordered.regular.normal")
            layer = calib.best_layer(m, layers)
            fill[scheme] = [round(v, 4) for v in layer["backgroundColor"]]
            if scheme == "light":
                capsule = abs(layer["cornerRadius"] - m["height"] / 2) < 0.5
        self.set("couches", ["button", "neutralFill"], fill)
        self.set("couches", ["button", "defaultShape"], "capsule" if capsule else "roundedRectangle")

        # Opacité d'une teinte en fond de .bordered (médiane sur les teintes du catalogue).
        for scheme, key in (("light", "tintFillAlphaLight"), ("dark", "tintFillAlphaDark")):
            meta = self.ios[("button.tints", scheme)]["meta"]
            alphas = [calib.best_layer(m, meta["layers"])["backgroundColor"][3]
                      for m in meta["markers"] if m["id"].endswith(".bordered")]
            self.set("couches", ["button", key], round(statistics.median(alphas), 3))

        # Rayon par défaut de .roundedRectangle.
        m, layers = marker("button.shapes", "light", "shape.roundedRectangle.bordered")
        self.set("couches", ["button", "roundedRectangleRadius"], round(calib.best_layer(m, layers)["cornerRadius"], 2))

        # Gris du verre teinté désactivé (échantillon à gauche du libellé).
        fill = {}
        for scheme in ("light", "dark"):
            m, _ = marker("button.glassProminent", scheme, "button.glassProminent.large.disabled")
            img = calib.image(self.ios[("button.glassProminent", scheme)]["png"], cache=True)
            s = self.ios[("button.glassProminent", scheme)]["meta"]["screen"]["scale"]
            px = img.getpixel((int((m["x"] + 12) * s), int((m["y"] + m["height"] / 2) * s)))
            fill[scheme] = [round(c / 255, 4) for c in px] + [1]
        self.set("pixels", ["button", "disabledGlassTintedFill"], fill)

    # --- 2. Comportements -------------------------------------------------------------------------

    def fit_behaviours(self):
        labels = ["tint", "primary", "white", "inherit"]
        fills = ["none", "neutralOrTinted", "solid", "glass", "glassTinted"]
        for style in STYLES:
            pages = [f"button.{style}"]
            base = ["button", "styles", style]
            self.search(f"comportement {style}", pages, base + ["fill"], fills)
            self.search(f"comportement {style}", pages, base + ["label"], labels)
            self.search(f"comportement {style}", pages, base + ["destructiveLabel"], labels)
            self.search(f"comportement {style}", pages, base + ["followsControlSize"], [True, False])

    # --- 3. Valeurs continues -------------------------------------------------------------------

    @staticmethod
    def sample(size):
        """Phrase témoin de la page Texte (doit rester identique à Catalog.swift)."""
        if size >= 28:
            return "Portez ce whisky"
        if size >= 20:
            return "Portez ce vieux whisky"
        return "Portez ce vieux whisky au juge blond"

    def fit_tracking(self):
        """Approche du texte par corps, ajustée sur les pages Texte (phrase témoin, sans marges en jeu).

        Correction directe : écart de largeur ÷ nombre d'intervalles entre lettres, en 3 itérations.
        """
        pages = [p for p in ("text.regular", "text.semibold") if any(k[0] == p for k in self.ios)]
        if not pages:
            print("  (pas de page Texte dans cette série : approche inchangée)")
            return
        text = self.profile["text"]
        text.setdefault("trackingSemibold", {})
        for _ in range(3):
            _, rows = self.evaluate(self.profile, pages)
            groups = {}
            for r in rows:
                if "d" not in r or not r["id"].startswith("text."):
                    continue
                _, size, _, weight = r["id"].split(".")
                table = "trackingSemibold" if weight == "semibold" else "tracking"
                gaps = len(self.sample(int(size))) - 1
                groups.setdefault((table, size), []).append(r["d"]["width"] / gaps)
            for (table, size), deltas in groups.items():
                path = ["text", table, size]
                current = text[table].get(size, text["tracking"].get(size, 0))
                self.set(f"approche {size} pt ({'semi-gras' if table != 'tracking' else 'normal'})", path,
                         round(current - statistics.median(deltas), 3))

    def fit_sizes(self):
        sizes = self.profile["button"]["sizes"]
        # Police : recherche sur un style sans fond qui suit controlSize (pas de marges en jeu).
        follower = next((s for s in STYLES if self.profile["button"]["styles"][s]["fill"] == "none"
                         and self.profile["button"]["styles"][s]["followsControlSize"]), None)
        if follower:
            for size in SIZES:
                current = sizes[size]["fontSize"]
                candidates = sorted({current + d for d in (-3, -2, -1, 0, 1, 2, 3)} & set(range(9, 25)))
                best, best_err = current, None
                for fs in candidates:
                    trial = copy.deepcopy(self.profile)
                    trial["button"]["sizes"][size]["fontSize"] = fs
                    _, rows = self.evaluate(trial, [f"button.{follower}"])
                    err = sum(r["geoSum"] for r in rows if f".{size}." in r["id"])
                    if best_err is None or err < best_err - 1e-6:
                        best, best_err = fs, err
                self.set(f"police {size}", ["button", "sizes", size, "fontSize"], best)

        # Marges : correction directe des écarts de largeur / hauteur (3 itérations).
        pages = [f"button.{s}" for s in FILLED] + ["button.shapes"]
        for _ in range(3):
            _, rows = self.evaluate(self.profile, pages)
            for size in SIZES:
                sel = [r for r in rows if "d" in r and r["page"] != "button.shapes" and f".{size}." in r["id"]]
                if not sel:
                    continue
                dw = statistics.mean(r["d"]["width"] for r in sel)
                dh = statistics.mean(r["d"]["height"] for r in sel)
                s = sizes[size]
                self.set(f"marges {size}", ["button", "sizes", size, "padH"], round(s["padH"] - dw / 2, 2))
                self.set(f"marges {size}", ["button", "sizes", size, "padV"], round(s["padV"] - dh / 2, 2))
            circle = [r for r in rows if "d" in r and r["id"].startswith("shape.circle.")]
            if circle:
                dw = statistics.mean(r["d"]["width"] for r in circle)
                for size in SIZES:
                    old = sizes[size]["circlePadH"]
                    self.set("marges cercle", ["button", "sizes", size, "circlePadH"], round(old - dw / 2, 2))

    IMAGE_STYLE_SIZES = {"largeTitle": 34, "title2": 22, "body": 17, "footnote": 13, "caption": 12}

    def fit_image(self):
        """Symboles : marges du cadre autour de l'encre (correction directe), puis facteurs d'échelle (recherche)."""
        if not any(k[0] == "image.styles" for k in self.ios):
            print("  (pas de page Image dans cette série : réglages d'image inchangés)")
            return
        img = self.profile.setdefault("imageSettings", {"scaleSmall": 0.78, "scaleMedium": 1, "scaleLarge": 1.29,
                                                        "paddingH": 0, "paddingV": 0})
        for _ in range(3):
            _, rows = self.evaluate(self.profile, ["image.styles"])
            dh, dv = [], []
            for r in rows:
                if "d" not in r or not r["id"].startswith("image."):
                    continue
                size = self.IMAGE_STYLE_SIZES.get(r["id"].split(".")[1])
                if size:
                    dh.append(r["d"]["width"] / (2 * size))
                    dv.append(r["d"]["height"] / (2 * size))
            if dh:
                self.set("images", ["imageSettings", "paddingH"], round(img["paddingH"] - statistics.median(dh), 4))
                self.set("images", ["imageSettings", "paddingV"], round(img["paddingV"] - statistics.median(dv), 4))
        # Espacement par défaut image ↔ voisine : correction directe sur la pile du modèle xtool.
        if any(k[0] == "image.resizable" for k in self.ios):
            img.setdefault("stackSpacing", 8)
            for _ in range(2):
                _, rows = self.evaluate(self.profile, ["image.resizable"])
                stack = [r for r in rows if r["id"] == "template.stack" and "d" in r]
                if stack:
                    dh = statistics.mean(r["d"]["height"] for r in stack)
                    self.set("images", ["imageSettings", "stackSpacing"], round(max(0, img["stackSpacing"] - dh), 2))
        if any(k[0] == "image.scales" for k in self.ios):
            for key in ("scaleSmall", "scaleLarge", "scaleMedium"):
                v = img[key]
                self.search("images", ["image.scales"], ["imageSettings", key],
                            [round(v + d, 3) for d in (-0.12, -0.06, -0.03, -0.01, 0.01, 0.03, 0.06, 0.12)])

    GLASS_FALLBACK = {
        "regular": {"blur": 2.5, "refraction": 6, "bezel": 10, "exponent": 2, "saturation": 1.25, "brightness": 1.03,
                    "tintLight": [1, 1, 1, 0.55], "tintDark": [0.11, 0.11, 0.12, 0.55], "rimLight": 0.55, "rimDark": 0.3,
                    "rimWidth": 1.2, "shadowSide": 0.06, "shadowLight": 0.06, "shadowDark": 0.3, "shadowOffset": 2},
        "clear": {"blur": 0.5, "refraction": 7, "bezel": 10, "exponent": 2, "saturation": 1.1, "brightness": 1.0,
                  "tintLight": [1, 1, 1, 0.12], "tintDark": [0, 0, 0, 0.15], "rimLight": 0.6, "rimDark": 0.35,
                  "rimWidth": 1.2, "shadowSide": 0.05, "shadowLight": 0.05, "shadowDark": 0.25, "shadowOffset": 2},
    }

    def fit_glass(self):
        """Liquid Glass : recherche par motifs (grands pas d'abord, puis divisés par deux) sur les pixels.

        Le vrai verre peut être loin des valeurs de départ (lentille couvrant toute la forme, aucun flou),
        d'où des pas initiaux larges.
        """
        if not any(k[0] == "glass.refraction" for k in self.ios):
            print("  (pas de page de réfraction dans cette série : verre inchangé)")
            return
        settings = self.profile.setdefault("glassSettings", copy.deepcopy(self.GLASS_FALLBACK))
        if all(settings.get(v, {}).get("tableLight") for v in ("regular", "clear")):
            print("  (verre mesuré par glassfield.py : tables prioritaires, réglage paramétrique sauté)")
            return
        start_steps = {"refraction": 8, "bezel": 10, "curvature": 0.25, "maxShift": 1.5, "blur": 1.0,
                       "saturation": 0.3, "brightness": 0.1, "rimLight": 0.25, "rimDark": 0.25, "rimWidth": 1.5,
                       "shadowSide": 0.08, "edgeLineLight": 0.3, "edgeLineDark": 0.3, "shadowLight": 0.04,
                       "shadowDark": 0.1, "tintA": 0.2, "tintV": 0.15}
        bounds = {"refraction": (-40, 60), "bezel": (1, 60), "curvature": (0, 0.999), "maxShift": (0.2, 8),
                  "blur": (0, 8), "saturation": (0.3, 2.5), "brightness": (0.5, 1.6), "rimLight": (0, 1),
                  "rimDark": (0, 1), "rimWidth": (0.2, 8), "shadowSide": (0, 0.6), "edgeLineLight": (0, 1),
                  "edgeLineDark": (0, 1), "shadowLight": (0, 0.4), "shadowDark": (0, 0.6)}
        for variant in ("regular", "clear"):
            for key, default in (("curvature", 0.9), ("maxShift", 3), ("edgeLineLight", 0.5), ("edgeLineDark", 0.35)):
                settings[variant].setdefault(key, default)
        for variant, pages in (("clear", ["glass.refraction"]), ("regular", ["glass.refraction", "button.glass"])):
            params = settings[variant]
            steps = dict(start_steps)
            for _ in range(5):
                for key in [k for k in start_steps if k not in ("tintA", "tintV")]:
                    lo, hi = bounds[key]
                    v, st = params[key], steps[key]
                    self.search(f"verre {variant}", pages, ["glassSettings", variant, key],
                                [round(min(hi, max(lo, v + d)), 3) for d in (-st, st)])
                if variant == "regular":
                    v = params.get("tintStrength", 0.75)
                    self.search(f"verre {variant}", ["glass.refraction"], ["glassSettings", variant, "tintStrength"],
                                [round(min(1, max(0, v + d)), 3) for d in (-steps["tintA"], steps["tintA"])])
                for key in ("tintLight", "tintDark"):
                    t = params[key]
                    a, g = steps["tintA"], steps["tintV"]
                    cands = [t[:3] + [round(min(1, max(0, t[3] + d)), 3)] for d in (-a, a)]
                    cands += [[round(min(1, max(0, c + d)), 3) for c in t[:3]] + [t[3]] for d in (-g, g)]
                    self.search(f"verre {variant}", pages, ["glassSettings", variant, key], cands)
                steps = {k: v / 2 for k, v in steps.items()}

    # --- Rapport ------------------------------------------------------------------------------------

    def summary(self, rows):
        geo = [r["geo"] for r in rows]
        return {
            "repères": len(rows),
            "≤0,5 pt": sum(g <= 0.5 for g in geo),
            "≤1 pt": sum(g <= 1 for g in geo),
            ">1 pt": sum(g > 1 for g in geo),
            "Δpix moyen": round(statistics.mean(r["pix"] for r in rows), 1),
        }


def get(d, path):
    """Valeur au chemin donné, ou None si une clé manque (nouvelle entrée de table)."""
    for p in path:
        if not isinstance(d, dict) or p not in d:
            return None
        d = d[p]
    return d


def put(d, path, value):
    for p in path[:-1]:
        d = d[p]
    d[path[-1]] = value


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("run")
    parser.add_argument("--lsim", default=".build/debug/CatalogExample")
    parser.add_argument("--profile", default="Sources/LSimUI/Profiles/iOS-27.2.json")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--etapes", default="couches,comportements,approche,tailles,images,verre",
                        help="étapes à exécuter (ex. : --etapes verre)")
    args = parser.parse_args()

    t0 = time.time()
    fitter = Fitter(args.run, args.lsim, args.profile)
    all_pages = sorted({k[0] for k in fitter.ios})
    _, before = fitter.evaluate(fitter.profile, all_pages)
    print("avant :", fitter.summary(before), flush=True)

    wanted = set(args.etapes.split(","))
    for key, step, fn in (("couches", "lecture des couches", fitter.read_layers),
                          ("comportements", "comportements", fitter.fit_behaviours),
                          ("approche", "approche du texte", fitter.fit_tracking),
                          ("tailles", "tailles et marges", fitter.fit_sizes),
                          ("images", "images", fitter.fit_image),
                          ("verre", "matière du verre", fitter.fit_glass)):
        if key not in wanted:
            continue
        fn()
        print(f"  {step} : terminé ({fitter.evals} évaluations, {time.time() - t0:.0f} s)", flush=True)

    _, after = fitter.evaluate(fitter.profile, all_pages)
    print("après :", fitter.summary(after), flush=True)

    anomalies = sorted((r for r in after if r["geo"] > 1), key=lambda r: -r["geo"])
    with open(os.path.join(args.run, "ajustement.md"), "w") as f:
        f.write("# Ajustement automatique du profil\n\n")
        f.write(f"{fitter.evals} évaluations en {time.time() - t0:.0f} s.\n\n")
        f.write("| | " + " | ".join(fitter.summary(before)) + " |\n|---|" + "---|" * len(fitter.summary(before)) + "\n")
        for name, rows in (("avant", before), ("après", after)):
            f.write(f"| {name} | " + " | ".join(str(v) for v in fitter.summary(rows).values()) + " |\n")
        f.write("\n## Réglages modifiés\n\n| étape | réglage | avant | après |\n|---|---|---|---|\n")
        for path, (label, old, new) in fitter.changes.items():
            f.write(f"| {label} | `{path}` | `{json.dumps(old)}` | `{json.dumps(new)}` |\n")
        f.write(f"\n## Anomalies non expliquées ({len(anomalies)})\n\n")
        f.write("Écarts > 1 pt qu'aucun réglage du profil ne corrige : à traiter dans le code.\n\n")
        f.write("| Δgéo | page | thème | repère | x, y, w, h (LSim − iPhone) |\n|---|---|---|---|---|\n")
        for r in anomalies:
            d = r.get("d", {})
            f.write(f"| {r['geo']:.1f} | {r['page']} | {r['scheme']} | `{r['id']}` | "
                    + ", ".join(f"{d[k]:+.1f}" for k in ("x", "y", "width", "height")) + " |\n" if d else "absent |\n")

    if not args.dry_run:
        with open(args.profile, "w") as f:
            json.dump(fitter.profile, f, indent=2, sort_keys=True, ensure_ascii=False)
            f.write("\n")
        print(f"Profil écrit : {args.profile}")
    print(f"Rapport : {os.path.join(args.run, 'ajustement.md')}  —  {len(fitter.changes)} réglages modifiés, "
          f"{len(anomalies)} anomalies.")


if __name__ == "__main__":
    sys.exit(main())
