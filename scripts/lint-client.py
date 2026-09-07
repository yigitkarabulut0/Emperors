#!/usr/bin/env python3
"""Lint the Godot client: every script parses, every asset a layout names exists
and is imported, every asset the slicing manifests promise exists.

    python3 scripts/lint-client.py
"""
import json, os, subprocess, sys, glob

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLIENT = os.path.join(ROOT, "client")
fails = 0

def ok(msg): print(f"  PASS  {msg}")
def fail(msg):
    global fails; fails += 1; print(f"  FAIL  {msg}")

# 1. scripts compile (with the project's autoloads available)
r = subprocess.run(["godot", "--headless", "--path", CLIENT, "--script", "res://tests/lint_scripts.gd"],
                   capture_output=True, text=True)
out = r.stdout + r.stderr
errs = [l for l in out.splitlines() if "LINT FAIL" in l or "SCRIPT ERROR" in l]
for e in errs[:12]: fail(e.strip())
if not errs and "failed=0" in out: ok("all scripts compile")
elif not errs: fail("script lint did not report: " + out[-300:])

# 2. assets named by layouts exist and are imported
def walk_parts(parts, found):
    for p in parts:
        if not isinstance(p, dict): continue
        a = p.get("asset", "")
        if a and "<" not in a and "{" not in a: found.add(a)
        for k in ("parts", "content"):
            if k in p: walk_parts(p[k], found)
named = set()
for lay in sorted(glob.glob(os.path.join(CLIENT, "layout", "*.json"))):
    d = json.load(open(lay)); walk_parts(d.get("elements", []), named)
missing = [a for a in sorted(named) if not os.path.exists(os.path.join(CLIENT, "assets", a + ".png"))]
for a in missing: fail(f"layout names a missing asset: {a}")
if not missing: ok(f"all {len(named)} layout assets exist")

# 3. every shipped png is imported
pngs = sorted(glob.glob(os.path.join(CLIENT, "assets", "**", "*.png"), recursive=True))
unimported = [p for p in pngs if not os.path.exists(p + ".import")]
for p in unimported: fail(f"not imported (run godot --headless --path client --import): {os.path.relpath(p, CLIENT)}")
if not unimported: ok(f"all {len(pngs)} shipped assets are imported")

# 4. manifests promise -> disk
promised = set()
for m in sorted(glob.glob(os.path.join(ROOT, "art", "slices", "*.json"))):
    if m.endswith(".layout.json"): continue
    for c in json.load(open(m)).get("crops", []): promised.add(c["name"])
lost = [a for a in sorted(promised) if not os.path.exists(os.path.join(CLIENT, "assets", a + ".png"))]
for a in lost: fail(f"manifest promises an asset that is not on disk: {a}")
if not lost: ok(f"all {len(promised)} manifest crops are on disk")

print(f"\n{fails} FAILED" if fails else "\nclient lint clean")
sys.exit(1 if fails else 0)
