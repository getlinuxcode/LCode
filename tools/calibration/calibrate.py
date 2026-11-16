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


NETMUXD = os.path.expanduser("~/.local/share/lcode/bin/netmuxd")
MUX = ("127.0.0.1", 27015)


def device_environment():
    """Accès à l'iPhone en USB ou en Wi-Fi via netmuxd (démarré au besoin), sinon USB seul."""
    import socket

    def listening():
        try:
            with socket.create_connection(MUX, timeout=0.3):
                return True
        except OSError:
            return False

    if not os.access(NETMUXD, os.X_OK):
        return {}
    if not listening():
        log = os.path.expanduser("~/.local/share/lcode/netmuxd.log")
        subprocess.Popen([NETMUXD, "--disable-unix", "--host", MUX[0], "--port", str(MUX[1]),
                          "--plist-storage", "/var/lib/lockdown", "--upstream-usbmuxd", "/var/run/usbmuxd"],
                         stdout=open(log, "a"), stderr=subprocess.STDOUT, start_new_session=True)
        for _ in range(30):
            if listening():
                break
            time.sleep(0.1)
    return {"USBMUXD_SOCKET_ADDRESS": f"{MUX[0]}:{MUX[1]}"} if listening() else {}


def usb_connected():
    """Un iPhone est-il branché en USB (vu par le usbmuxd du système) ?"""
    try:
        out = subprocess.run(["idevice_id", "-l"], capture_output=True, text=True, timeout=10).stdout
        return bool(out.strip())
    except (OSError, subprocess.TimeoutExpired):
        return False


def sh(command, cwd=ROOT, env=None):
    """Commande shell avec la chaîne Swift de swiftly dans le PATH."""
    full = f". {SWIFT_ENV} && {command}" if os.path.exists(SWIFT_ENV) else command
    result = subprocess.run(["bash", "-c", full], cwd=cwd, env={**os.environ, **(env or {})})
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
                try:
                    with open(files[0]) as f:
                        expected = 2 * json.load(f).get("pageCount", 0)
                except (json.JSONDecodeError, OSError):
                    continue  # fichier en cours d'écriture : on réessaie à la seconde suivante
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
    parser.add_argument("--pages", help="passe partielle : préfixes de pages séparés par des virgules (ex. : nav.), "
                                        "mesures directes seulement, sans ajustement ni références")
    parser.add_argument("--timeout", type=int, default=900)
    parser.add_argument("--symboles", action="store_true",
                        help="refaire l'export des SF Symbols (automatique si la table locale manque)")
    args = parser.parse_args()
    os.chdir(ROOT)
    t0 = time.time()

    step("Compilation du catalogue pour LSim")
    sh("swift build --product CatalogExample")

    run = args.run
    if not run:
        if not args.skip_install:
            connection = device_environment()
            step(f"Compilation et installation du catalogue sur l'iPhone (xtool, {'USB ou Wi-Fi' if connection else 'USB'})")
            # L'USB s'il est branché (plus rapide), sinon le Wi-Fi : évite la question de xtool.
            transport = "--usb" if usb_connected() or not connection else "--network"
            sh(f"xtool dev run {transport}", cwd=IOS_PROJECT, env=connection)
        table = os.path.expanduser("~/.local/share/lcode/symbols/iOS-27.2.json")
        receiver.Handler.want_symbols = args.symboles or not os.path.exists(table)
        if args.pages:
            receiver.Handler.want_symbols = False
            receiver.Handler.only = [p.strip() for p in args.pages.split(",") if p.strip()]
        step("Réception des mesures" + (" (avec export des SF Symbols)" if receiver.Handler.want_symbols else ""))
        run = receive(args.port, os.path.join(ROOT, "Calibration"), args.timeout)
        print(f"Série reçue : {run}")

    if os.path.isdir(os.path.join(run, "symbols")):
        step("Table des SF Symbols (appariement des dessins de l'iPhone aux glyphes de la police)")
        venv = os.path.expanduser("~/.local/share/lcode/venv/bin/python")
        sh(f"'{venv}' -I tools/calibration/symbols.py '{run}'")

    if args.pages:
        venv = os.path.expanduser("~/.local/share/lcode/venv/bin/python")
        if glob.glob(os.path.join(run, "ios", "glass.field.low.*.json")):
            step("Verre Liquid Glass mesuré (fonds codés)")
            sh(f"'{venv}' -I tools/calibration/glassfield.py '{run}'")
        if glob.glob(os.path.join(run, "ios", "nav.edge.low.*.json")):
            step("Barre de navigation mesurée (effet de bord de défilement)")
            sh(f"'{venv}' -I tools/calibration/navfield.py '{run}'")
        step(f"Passe partielle terminée en {time.time() - t0:.0f} s : {run}")
        return

    step("Comparaison avant ajustement")
    sh(f"python3 -I tools/calibration/compare.py '{run}'")

    step("Ajustement automatique du profil")
    sh(f"python3 -I tools/calibration/fit.py '{run}'")

    # Mesures directes (fonds codés) : verre et effet de bord de la barre de navigation.
    venv = os.path.expanduser("~/.local/share/lcode/venv/bin/python")
    if glob.glob(os.path.join(run, "ios", "glass.field.low.*.json")):
        step("Verre Liquid Glass mesuré (fonds codés)")
        sh(f"'{venv}' -I tools/calibration/glassfield.py '{run}' --write")
    if glob.glob(os.path.join(run, "ios", "nav.edge.low.*.json")):
        step("Barre de navigation mesurée (effet de bord de défilement)")
        sh(f"'{venv}' -I tools/calibration/navfield.py '{run}' --write")

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
