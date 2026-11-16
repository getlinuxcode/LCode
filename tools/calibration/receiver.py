#!/usr/bin/env python3
"""Récepteur des mesures envoyées par l'app « LCode Catalogue » sur iPhone.

Usage : python3 tools/calibration/receiver.py [--port 8765] [--out Calibration]
Chaque page reçue est enregistrée dans <out>/<run>/ios/<page>.<clair|sombre>.{json,png}.
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
    only = []  # préfixes de pages à capturer (vide : toutes)

    def do_GET(self):
        if self.path == "/config":
            # L'app demande si elle doit exporter les SF Symbols (long : 8 600 dessins).
            body = json.dumps({"symbols": self.want_symbols, "only": self.only}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"LCode calibration receiver\n")

    def do_POST(self):
        if self.path not in ("/upload", "/symbols"):
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
        if self.path == "/symbols":
            folder = os.path.join(self.out_dir, run, "symbols")
            os.makedirs(folder, exist_ok=True)
            name = "info.json" if payload.get("kind") == "info" else f"batch-{int(payload.get('start', 0)):05d}.json"
            with open(os.path.join(folder, name), "w") as f:
                json.dump(payload, f)
            if payload.get("kind") == "info":
                print(f"symboles : {payload.get('count')} noms fournis par iOS ({payload.get('info', {}).get('source', 'source introuvable')})", flush=True)
            else:
                print(f"symboles : lot {payload.get('start')} / {payload.get('total')} ({len(payload.get('symbols', []))} rendus)", flush=True)
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
        # Écriture atomique : le PC surveille ces fichiers et ne doit jamais en lire un à moitié écrit.
        with open(base + ".json.tmp", "w") as f:
            json.dump(payload, f, indent=1, sort_keys=True)
        os.replace(base + ".json.tmp", base + ".json")
        print(f"reçu {page} ({scheme}) : {len(payload.get('markers', []))} repères, "
              f"{len(payload.get('layers', []))} couches — {payload.get('device')} iOS {payload.get('system')}", flush=True)
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
    print(f"En attente des mesures sur le port {args.port} → {args.out}/", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
