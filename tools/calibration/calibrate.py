#!/usr/bin/env python3
"""Calibration complète en une commande.

Usage : python3 -I tools/calibration/calibrate.py [--skip-install] [--run Calibration/<série>]

1. Compile le catalogue pour LSim, puis pour iOS, et l'installe sur l'iPhone (xtool).
2. Reçoit les mesures : il suffit de toucher l'icône « LCode Catalogue » sur l'iPhone.
3. Compare (rapport + planches), ajuste le profil de design automatiquement.
4. Recompile LSim avec le nouveau profil, enregistre les références et vérifie la non-régression.

`--run` saute les étapes 1 et 2 et réutilise une série déjà reçue.
"""
import argparse
import glob
import json
import os
import shutil
import subprocess
import sys
import threading
import time
from http.server import ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import receiver  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
IOS_PROJECT = os.path.join(ROOT, "Examples", "iOS", "Catalog")
REFERENCE = os.path.join(ROOT, "Tests", "Calibration", "iOS-27.2")
SWIFT_ENV = os.path.expanduser("~/.local/share/swiftly/env.sh")


def step(title):
    print(f"\n━━ {title}", flush=True)


def sh(command, cwd=ROOT):
    """Commande shell avec la chaîne Swift de swiftly dans le PATH."""
    full = f". {SWIFT_ENV} && {command}" if os.path.exists(SWIFT_ENV) else command
    result = subprocess.run(["bash", "-c", full], cwd=cwd)
    if result.returncode != 0:
        sys.exit(f"Échec : {command}")


def receive(port, out_dir, timeout):
    """Attend une série complète (pages × 2 thèmes) envoyée par l'iPhone ; renvoie son dossier."""
    receiver.Handler.out_dir = out_dir
    server = ThreadingHTTPServer(("0.0.0.0", port), receiver.Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    print(f"En attente sur le port {port}. Touchez l'icône « LCode Catalogue » sur l'iPhone.", flush=True)
    start = time.time()
    known = set(glob.glob(os.path.join(out_dir, "*")))
    try:
        while time.time() - start < timeout:
            time.sleep(1)
            for run in set(glob.glob(os.path.join(out_dir, "*"))) - known:
                files = glob.glob(os.path.join(run, "ios", "*.json"))
                if not files:
                    continue
                with open(files[0]) as f:
                    expected = 2 * json.load(f).get("pageCount", 0)
                if expected and len(files) >= expected:
                    return run
        sys.exit("Délai dépassé : aucune série complète reçue.")
    finally:
        server.shutdown()


def save_reference(run):
    """Copie légère des mesures (cadres, sans images ni couches) pour la vérification."""
    os.makedirs(REFERENCE, exist_ok=True)
    for path in glob.glob(os.path.join(REFERENCE, "*.json")):
        if not path.endswith("residus.json"):
            os.remove(path)
    for path in glob.glob(os.path.join(run, "ios", "*.json")):
        with open(path) as f:
            meta = json.load(f)
        light = {k: meta[k] for k in ("page", "colorScheme", "device", "system", "screen", "markers")}
        light["markers"] = sorted(light["markers"], key=lambda m: m["id"])
        with open(os.path.join(REFERENCE, os.path.basename(path)), "w") as f:
            json.dump(light, f, indent=1, sort_keys=True)
            f.write("\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--skip-install", action="store_true", help="ne pas recompiler / réinstaller l'app iOS")
    parser.add_argument("--run", help="réutiliser une série déjà reçue")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--timeout", type=int, default=900)
    args = parser.parse_args()
    os.chdir(ROOT)
    t0 = time.time()

    step("Compilation du catalogue pour LSim")
    sh("swift build --product CatalogExample")

    run = args.run
    if not run:
        if not args.skip_install:
            step("Compilation et installation du catalogue sur l'iPhone (xtool)")
            sh("xtool dev", cwd=IOS_PROJECT)
        step("Réception des mesures")
        run = receive(args.port, os.path.join(ROOT, "Calibration"), args.timeout)
        print(f"Série reçue : {run}")

    step("Comparaison avant ajustement")
    sh(f"python3 -I tools/calibration/compare.py '{run}'")

    step("Ajustement automatique du profil")
    sh(f"python3 -I tools/calibration/fit.py '{run}'")

    step("Recompilation de LSim avec le nouveau profil")
    sh("swift build --product CatalogExample")

    step("Références et vérification de non-régression")
    save_reference(run)
    sh("python3 -I tools/calibration/check.py --update")
    sh("python3 -I tools/calibration/check.py")
    sh("swift test 2>&1 | grep -E 'Test run|✘'")

    step(f"Terminé en {time.time() - t0:.0f} s")
    print(f"Rapport d'ajustement : {os.path.join(run, 'ajustement.md')}")
    print(f"Planches : {os.path.join(run, 'planches')}")


if __name__ == "__main__":
    main()
