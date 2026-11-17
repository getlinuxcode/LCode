#!/usr/bin/env python3
"""Banc d'essai : chaque paquet SwiftPM compile-t-il dans le simulateur LSim ?

Usage : Scripts/essai-paquets.py <dossier de travail> <url> [<url>…]

Pour chaque URL : le paquet est ajouté (dernière version publiée) à un projet de test créé par `lcode new`,
ses produits bibliothèque sont importés par l'app, puis l'app est compilée pour le simulateur
(`lcode run --capture`). Le résultat (réussite, erreurs regroupées) va dans <dossier>/resultats.json et à
l'écran. Le projet de test est réutilisé d'un paquet à l'autre : LCode n'est compilé qu'une fois.
"""
import json, os, re, shutil, subprocess, sys, time
from collections import Counter

LCODE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
BIN = os.path.join(LCODE, ".build/debug/lcode")


def run(args, cwd=None, timeout=1800):
    p = subprocess.run(args, cwd=cwd, capture_output=True, text=True, timeout=timeout)
    return p.returncode, p.stdout + p.stderr


def latest_version(url):
    code, out = run(["git", "ls-remote", "--tags", "--refs", url], timeout=120)
    versions = []
    for line in out.splitlines():
        tag = line.rsplit("/", 1)[-1].lstrip("v")
        if re.fullmatch(r"\d+\.\d+\.\d+", tag):
            versions.append(tuple(int(x) for x in tag.split(".")))
    return ".".join(map(str, max(versions))) if versions else None


def identity(url):
    last = url.rstrip("/").rsplit("/", 1)[-1]
    return (last[:-4] if last.endswith(".git") else last).lower()


def main():
    work, urls = sys.argv[1], sys.argv[2:]
    os.makedirs(work, exist_ok=True)
    project = os.path.join(work, "Essai")
    if not os.path.isdir(project):
        code, out = run([BIN, "new", "Essai", "--dans", work])
        if code != 0:
            sys.exit(out)
    manifest = os.path.join(project, "Package.swift")
    original = os.path.join(work, "Package.swift.origine")
    if not os.path.exists(original):
        shutil.copy(manifest, original)
    imports_file = os.path.join(project, "Sources/Essai/EssaiImports.swift")
    results_path = os.path.join(work, "resultats.json")
    results = json.load(open(results_path)) if os.path.exists(results_path) else {}

    for url in urls:
        name = identity(url)
        started = time.time()
        shutil.copy(original, manifest)
        for leftover in ["Package.resolved", imports_file]:
            if os.path.exists(os.path.join(project, leftover)):
                os.remove(os.path.join(project, leftover))
        version = latest_version(url)
        args = ["swift", "package", "add-dependency", url] + (["--from", version] if version else ["--branch", "main"])
        code, out = run(args, cwd=project)
        code, out = run(["swift", "package", "resolve"], cwd=project)
        if code != 0:
            results[name] = {"url": url, "etat": "résolution impossible", "erreurs": out[-1500:]}
            print(f"✗ {name} : résolution impossible")
            continue
        checkouts = os.path.join(project, ".build/checkouts")
        folder = next((os.path.join(checkouts, d) for d in os.listdir(checkouts) if d.lower() == name), None)
        code, dump = run(["swift", "package", "dump-package", "--package-path", folder])
        products = [p for p in json.loads(dump).get("products", []) if "library" in p.get("type", {})]
        if not products:
            results[name] = {"url": url, "etat": "aucune bibliothèque"}
            continue
        # Le premier produit (le principal en général) : ses modules sont importés par l'app.
        product = products[0]
        run(["swift", "package", "add-target-dependency", product["name"], "Essai", "--package", name], cwd=project)
        with open(imports_file, "w") as f:
            f.write("".join(f"import {m}\n" for m in product["targets"]))
        code, out = run([BIN, "run", project, "--capture", os.path.join(work, f"{name}.png")])
        errors = [l for l in out.splitlines() if re.search(r"error:", l) and "/" in l]
        messages = Counter(re.sub(r"^.*?error:\s*", "", re.sub(r"\x1b\[[0-9;]*m", "", l)) for l in errors)
        modules = Counter(re.sub(r"\x1b\[[0-9;]*m", "", m) for l in errors
                          for m in re.findall(r"no such module '([^']+)'", l))
        ok = code == 0
        results[name] = {
            "url": url, "version": version, "produit": product["name"],
            "etat": "ok" if ok else "échec", "duree": round(time.time() - started),
            "modules_manquants": dict(modules), "erreurs": dict(messages.most_common(25)),
            "nb_erreurs": len(errors), "fin": out[-1200:] if not ok and not errors else "",
        }
        print(f"{'✓' if ok else '✗'} {name} {version} ({product['name']}) — {len(errors)} erreur(s)"
              + (f", modules manquants : {', '.join(modules)}" if modules else ""))
        json.dump(results, open(results_path, "w"), ensure_ascii=False, indent=1)
    json.dump(results, open(results_path, "w"), ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()
