#!/usr/bin/env python3
"""Full calibration in one command.

Usage: python3 -I tools/calibration/calibrate.py [--skip-install] [--run Calibration/<run>]

1. Builds the catalog for LSim, then for iOS, and installs it on the iPhone (xtool).
2. Receives the measurements: just tap the "LCode Catalog" icon on the iPhone.
3. Compares (report + contact sheets) and fits the design profile automatically.
4. Rebuilds LSim with the new profile, saves the references and checks for regressions.

`--run` skips steps 1 and 2 and reuses a run already received.
"""
import argparse
import glob
import json
import os
import shutil
import socket
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
    """iPhone access over USB or Wi-Fi through netmuxd (started if needed), otherwise USB only."""
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


def ensure_server_address(port):
    """Write the catalog's per-machine receiver address (CalibrationServer.swift, not in git) if missing."""
    path = os.path.join(IOS_PROJECT, "Sources", "Catalog", "CalibrationServer.swift")
    if os.path.exists(path):
        return
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.connect(("192.0.2.1", 9))  # no packet sent: only picks the LAN interface
        ip = s.getsockname()[0]
    with open(path, "w") as f:
        f.write("// Per-machine (not in git): address of the calibration receiver on the local network.\n"
                f'let defaultCalibrationServer = "http://{ip}:{port}"\n')
    print(f"Calibration receiver address: http://{ip}:{port} ({path})")


def usb_connected():
    """Is an iPhone plugged in over USB (as seen by the system usbmuxd)?"""
    try:
        out = subprocess.run(["idevice_id", "-l"], capture_output=True, text=True, timeout=10).stdout
        return bool(out.strip())
    except (OSError, subprocess.TimeoutExpired):
        return False


def sh(command, cwd=ROOT, env=None):
    """Shell command with the swiftly Swift toolchain on PATH."""
    full = f". {SWIFT_ENV} && {command}" if os.path.exists(SWIFT_ENV) else command
    result = subprocess.run(["bash", "-c", full], cwd=cwd, env={**os.environ, **(env or {})})
    if result.returncode != 0:
        sys.exit(f"Failed: {command}")


def receive(port, out_dir, timeout):
    """Waits for a complete run (pages × 2 schemes) sent by the iPhone; returns its folder."""
    receiver.Handler.out_dir = out_dir
    server = ThreadingHTTPServer(("0.0.0.0", port), receiver.Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    print(f"Waiting on port {port}. Tap the \"LCode Catalog\" icon on the iPhone.", flush=True)
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
                    continue  # still being written: retry next second
                if expected and len(files) >= expected:
                    return run
        sys.exit("Timed out: no complete run received.")
    finally:
        server.shutdown()


def receive_gestures(port, out_dir, timeout):
    """Trainer mode: waits for the batch of finger-made gestures from the iPhone."""
    receiver.Handler.out_dir = out_dir
    receiver.Handler.mode = "gestures"
    receiver.Handler.want_symbols = False
    receiver.Handler.gestures_file = None
    server = ThreadingHTTPServer(("0.0.0.0", port), receiver.Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    print(f"Waiting on port {port}. Tap the \"LCode Catalog\" icon on the iPhone, "
          "then follow the on-screen instructions.", flush=True)
    start = time.time()
    try:
        while time.time() - start < timeout:
            time.sleep(1)
            if receiver.Handler.gestures_file:
                return receiver.Handler.gestures_file
        sys.exit("Timed out: no gesture batch received.")
    finally:
        server.shutdown()


def save_reference(run):
    """Lightweight copy of the measurements (frames, no images or layers) used by check.py."""
    os.makedirs(REFERENCE, exist_ok=True)
    for path in glob.glob(os.path.join(REFERENCE, "*.json")):
        if not path.endswith("residuals.json"):
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
    parser.add_argument("--skip-install", action="store_true", help="do not rebuild / reinstall the iOS app")
    parser.add_argument("--run", help="reuse a run already received")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--pages", help="partial pass: comma-separated page prefixes (e.g. nav.), "
                                        "direct measurements only, no fitting or references")
    parser.add_argument("--timeout", type=int, default=900)
    parser.add_argument("--symbols", "--symboles", dest="symbols", action="store_true",
                        help="redo the SF Symbols export (automatic if the local table is missing)")
    parser.add_argument("--gestures", "--gestes", dest="gestures", action="store_true",
                        help="gesture trainer: back swipes and sheet drags, done by finger")
    args = parser.parse_args()
    os.chdir(ROOT)
    t0 = time.time()

    if args.gestures:
        if not args.skip_install:
            connection = device_environment()
            step(f"Building and installing the catalog on the iPhone (xtool, {'USB or Wi-Fi' if connection else 'USB'})")
            transport = "--usb" if usb_connected() or not connection else "--network"
            ensure_server_address(args.port)
            sh(f"xtool dev run {transport}", cwd=IOS_PROJECT, env=connection)
        step("Finger-made gestures on the iPhone")
        path = receive_gestures(args.port, os.path.join(ROOT, "Calibration"), args.timeout * 2)
        venv = os.path.expanduser("~/.local/share/lcode/venv/bin/python")
        step("Gesture decision thresholds")
        sh(f"'{venv}' -I tools/calibration/gesturefit.py '{path}' --write")
        step("Rebuilding LSim with the new profile")
        sh("swift build --product CatalogExample")
        step(f"Done in {time.time() - t0:.0f} s")
        return

    step("Building the catalog for LSim")
    sh("swift build --product CatalogExample")

    run = args.run
    if not run:
        if not args.skip_install:
            connection = device_environment()
            step(f"Building and installing the catalog on the iPhone (xtool, {'USB or Wi-Fi' if connection else 'USB'})")
            # USB if plugged in (faster), else Wi-Fi: avoids xtool's interactive prompt.
            transport = "--usb" if usb_connected() or not connection else "--network"
            ensure_server_address(args.port)
            sh(f"xtool dev run {transport}", cwd=IOS_PROJECT, env=connection)
        table = os.path.expanduser("~/.local/share/lcode/symbols/iOS-27.2.json")
        receiver.Handler.want_symbols = args.symbols or not os.path.exists(table)
        if args.pages:
            receiver.Handler.want_symbols = False
            receiver.Handler.only = [p.strip() for p in args.pages.split(",") if p.strip()]
        step("Receiving measurements" + (" (with SF Symbols export)" if receiver.Handler.want_symbols else ""))
        run = receive(args.port, os.path.join(ROOT, "Calibration"), args.timeout)
        print(f"Run received: {run}")

    if os.path.isdir(os.path.join(run, "symbols")):
        step("SF Symbols table (matching iPhone drawings to font glyphs)")
        venv = os.path.expanduser("~/.local/share/lcode/venv/bin/python")
        sh(f"'{venv}' -I tools/calibration/symbols.py '{run}'")

    if args.pages:
        venv = os.path.expanduser("~/.local/share/lcode/venv/bin/python")
        if glob.glob(os.path.join(run, "ios", "glass.field.low.*.json")):
            step("Measured Liquid Glass (coded backgrounds)")
            sh(f"'{venv}' -I tools/calibration/glassfield.py '{run}'")
        if glob.glob(os.path.join(run, "ios", "nav.edge.low.*.json")):
            step("Measured navigation bar (scroll edge effect)")
            sh(f"'{venv}' -I tools/calibration/navfield.py '{run}'")
        step(f"Partial pass done in {time.time() - t0:.0f} s: {run}")
        return

    step("Comparison before fitting")
    sh(f"python3 -I tools/calibration/compare.py '{run}'")

    step("Automatic profile fitting")
    sh(f"python3 -I tools/calibration/fit.py '{run}'")

    # Direct measurements (coded backgrounds): glass and navigation bar edge effect.
    venv = os.path.expanduser("~/.local/share/lcode/venv/bin/python")
    if glob.glob(os.path.join(run, "ios", "glass.field.low.*.json")):
        step("Measured Liquid Glass (coded backgrounds)")
        sh(f"'{venv}' -I tools/calibration/glassfield.py '{run}' --write")
    if glob.glob(os.path.join(run, "ios", "nav.edge.low.*.json")):
        step("Measured navigation bar (scroll edge effect)")
        sh(f"'{venv}' -I tools/calibration/navfield.py '{run}' --write")
    if glob.glob(os.path.join(run, "ios", "anim.default.*.json")):
        step("Measured animation curves (frame by frame)")
        sh(f"'{venv}' -I tools/calibration/animfield.py '{run}' --write")

    step("Rebuilding LSim with the new profile")
    sh("swift build --product CatalogExample")

    step("References and regression check")
    save_reference(run)
    sh("python3 -I tools/calibration/check.py --update")
    sh("python3 -I tools/calibration/check.py")
    sh("swift test 2>&1 | grep -E 'Test run|✘'")

    step(f"Done in {time.time() - t0:.0f} s")
    print(f"Fit report: {os.path.join(run, 'fit-report.md')}")
    print(f"Contact sheets: {os.path.join(run, 'sheets')}")


if __name__ == "__main__":
    main()
