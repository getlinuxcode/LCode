#!/usr/bin/env python3
"""Test bench: does each SwiftPM package build in the LSim simulator?

Usage: Scripts/package-compat.py <work directory> <url> [<url>…]

For each URL, the package (latest released version) is added to a test project created by `lcode new`,
its library products are imported by the app, then the app is built for the simulator
(`lcode run --capture`). The result (success, grouped errors) goes to <directory>/results.json and to
the screen. The test project is reused from one package to the next, so LCode is only built once.
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
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    work, urls = sys.argv[1], sys.argv[2:]
    os.makedirs(work, exist_ok=True)
    project = os.path.join(work, "CompatTest")
    if not os.path.isdir(project):
        code, out = run([BIN, "new", "CompatTest", "--in", work])
        if code != 0:
            sys.exit(out)
    manifest = os.path.join(project, "Package.swift")
    original = os.path.join(work, "Package.swift.orig")
    if not os.path.exists(original):
        shutil.copy(manifest, original)
    imports_file = os.path.join(project, "Sources/CompatTest/CompatImports.swift")
    results_path = os.path.join(work, "results.json")
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
            results[name] = {"url": url, "status": "resolution failed", "errors": out[-1500:]}
            print(f"✗ {name}: resolution failed")
            continue
        checkouts = os.path.join(project, ".build/checkouts")
        folder = next((os.path.join(checkouts, d) for d in os.listdir(checkouts) if d.lower() == name), None)
        code, dump = run(["swift", "package", "dump-package", "--package-path", folder])
        products = [p for p in json.loads(dump).get("products", []) if "library" in p.get("type", {})]
        if not products:
            results[name] = {"url": url, "status": "no library"}
            continue
        # First product (usually the main one): its modules are imported by the app.
        product = products[0]
        run(["swift", "package", "add-target-dependency", product["name"], "CompatTest", "--package", name], cwd=project)
        with open(imports_file, "w") as f:
            f.write("".join(f"import {m}\n" for m in product["targets"]))
        code, out = run([BIN, "run", project, "--capture", os.path.join(work, f"{name}.png")])
        errors = [l for l in out.splitlines() if re.search(r"error:", l) and "/" in l]
        messages = Counter(re.sub(r"^.*?error:\s*", "", re.sub(r"\x1b\[[0-9;]*m", "", l)) for l in errors)
        modules = Counter(re.sub(r"\x1b\[[0-9;]*m", "", m) for l in errors
                          for m in re.findall(r"no such module '([^']+)'", l))
        ok = code == 0
        results[name] = {
            "url": url, "version": version, "product": product["name"],
            "status": "ok" if ok else "failed", "duration": round(time.time() - started),
            "missing_modules": dict(modules), "errors": dict(messages.most_common(25)),
            "error_count": len(errors), "tail": out[-1200:] if not ok and not errors else "",
        }
        print(f"{'✓' if ok else '✗'} {name} {version} ({product['name']}) — {len(errors)} error(s)"
              + (f", missing modules: {', '.join(modules)}" if modules else ""))
        json.dump(results, open(results_path, "w"), ensure_ascii=False, indent=1)
    json.dump(results, open(results_path, "w"), ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()
