#!/usr/bin/env python3
"""Receives the measurements sent by the "LCode Catalog" app on the iPhone.

Usage: python3 tools/calibration/receiver.py [--port 8765] [--out Calibration]
Each page is saved as <out>/<run>/ios/<page>.<light|dark>.{json,png}.
"""
import argparse
import base64
import json
import os
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MAX_BODY = 64 * 1024 * 1024
SAFE = re.compile(r"[^A-Za-z0-9._-]")


def safe(name: str) -> str:
    return SAFE.sub("_", name)[:120] or "x"


class Handler(BaseHTTPRequestHandler):
    out_dir = "Calibration"
    want_symbols = True
    only = []  # page prefixes to capture (empty: all)
    mode = "pages"  # "gestures": the app opens the gesture trainer (finger-made trials)
    gestures_file = None  # path of the last gesture batch received

    def do_GET(self):
        if self.path == "/config":
            # Whether the app should export SF Symbols (slow: ~8,600 drawings).
            body = json.dumps({"symbols": self.want_symbols, "only": self.only, "mode": self.mode}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"LCode calibration receiver\n")

    def do_POST(self):
        if self.path not in ("/upload", "/symbols", "/gestures"):
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length", "0"))
        if length <= 0 or length > MAX_BODY:
            self.send_error(413)
            return
        try:
            payload = json.loads(self.rfile.read(length))
        except json.JSONDecodeError:
            self.send_error(400)
            return
        run = safe(payload.get("run", "run"))
        if self.path == "/gestures":
            folder = os.path.join(self.out_dir, "gestures")
            os.makedirs(folder, exist_ok=True)
            path = os.path.join(folder, f"{run}.json")
            with open(path + ".tmp", "w") as f:
                json.dump(payload, f, indent=1)
            os.replace(path + ".tmp", path)
            Handler.gestures_file = path
            print(f"gestures received: {len(payload.get('back', []))} swipes, {len(payload.get('sheet', []))} sheets → {path}", flush=True)
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")
            return
        if self.path == "/symbols":
            folder = os.path.join(self.out_dir, run, "symbols")
            os.makedirs(folder, exist_ok=True)
            name = "info.json" if payload.get("kind") == "info" else f"batch-{int(payload.get('start', 0)):05d}.json"
            with open(os.path.join(folder, name), "w") as f:
                json.dump(payload, f)
            if payload.get("kind") == "info":
                print(f"symbols: {payload.get('count')} names provided by iOS ({payload.get('info', {}).get('source', 'source not found')})", flush=True)
            else:
                print(f"symbols: batch {payload.get('start')} / {payload.get('total')} ({len(payload.get('symbols', []))} rendered)", flush=True)
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")
            return
        page = safe(payload.get("page", "page"))
        scheme = safe(payload.get("colorScheme", "light"))
        folder = os.path.join(self.out_dir, run, "ios")
        os.makedirs(folder, exist_ok=True)
        png = payload.pop("png", "")
        base = os.path.join(folder, f"{page}.{scheme}")
        if png:
            with open(base + ".png", "wb") as f:
                f.write(base64.b64decode(png))
        # Atomic write: the PC polls these files and must never read a half-written one.
        with open(base + ".json.tmp", "w") as f:
            json.dump(payload, f, indent=1, sort_keys=True)
        os.replace(base + ".json.tmp", base + ".json")
        print(f"received {page} ({scheme}): {len(payload.get('markers', []))} markers, "
              f"{len(payload.get('layers', []))} layers — {payload.get('device')} iOS {payload.get('system')}", flush=True)
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, *args):
        pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--out", default="Calibration")
    args = parser.parse_args()
    Handler.out_dir = args.out
    server = ThreadingHTTPServer(("0.0.0.0", args.port), Handler)
    print(f"Waiting for measurements on port {args.port} → {args.out}/", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
