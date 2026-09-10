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

# 5. a layout's text is the server's, or it is fixed copy that says so
#
# Layout.gd never draws a text part's "sample" unless the part is "static": the
# sample is the painting's own copy, and drawn as live text it showed the
# painting's names and numbers as the player's while the server was slow. So a
# text part nothing in the code ever sets would be blank forever -- either it is
# fixed copy and wants "static": true, or it is dead.
code = ""
for f in glob.glob(os.path.join(CLIENT, "scenes", "**", "*.gd"), recursive=True) + \
        glob.glob(os.path.join(CLIENT, "scripts", "**", "*.gd"), recursive=True):
    code += open(f).read()
def text_parts(parts, out):
    for p in parts:
        if not isinstance(p, dict): continue
        if p.get("kind") == "text": out.append(p)
        for k in ("parts", "content"):
            if k in p: text_parts(p[k], out)
unset = []
for lay in sorted(glob.glob(os.path.join(CLIENT, "layout", "*.json"))):
    parts = []
    text_parts(json.load(open(lay)).get("elements", []), parts)
    for p in parts:
        pid = str(p.get("id", ""))
        if p.get("static") or pid.endswith("_style"):
            continue
        if f'"{pid}"' not in code:
            unset.append(f"{os.path.basename(lay)}: {pid}")
for u in unset: fail(f"a layout text nothing sets (mark it \"static\" if it is fixed copy): {u}")
if not unset: ok("every live layout text is set by code")

# 6. a tap is not answered twice
#
# A screen's `_busy` guards its buttons while an action is in flight. Clearing it
# between the action and the reload that follows let a second tap land on a
# card the first had already changed: a second raid at a stale target, a
# second purchase of a sold offer. Within one function, `_busy = false` may not
# sit between the action and an `await _load`.
early = []
for f in sorted(glob.glob(os.path.join(CLIENT, "scenes", "**", "*.gd"), recursive=True)):
    lines = open(f).read().splitlines()
    funcs, cur = [], None
    for i, l in enumerate(lines):
        if l.startswith("func "):
            cur = [l, []]; funcs.append(cur)
        elif cur is not None:
            cur[1].append((i + 1, l))
    for head, body in funcs:
        acts = [n for n, l in body if "await GameState.act(" in l or "await Api.post_json(" in l]
        loads = [n for n, l in body if "await _load" in l]
        clears = [n for n, l in body if l.strip() == "_busy = false"]
        for c in clears:
            if any(a < c for a in acts) and any(ld > c for ld in loads):
                early.append(f"{os.path.relpath(f, CLIENT)}:{c} ({head.split('(')[0][5:]})")
for e in early: fail(f"_busy is cleared before the reload: {e}")
if not early: ok("every action holds its screen until the reload")

# 7. one button system
#
# A button is a painted plate with its word in type (UI.plate_button /
# plate_face), a painted crop (UI.tex_button), or an invisible hotspot over
# paint (UI.hotspot) -- all made in scripts/ui/. A bare Button.new() elsewhere
# is a fourth kind, drawn in Godot's default theme or a flat stylebox, and the
# auth screen shipped two of them.
bare = []
for f in sorted(glob.glob(os.path.join(CLIENT, "scenes", "**", "*.gd"), recursive=True)):
    for n, l in enumerate(open(f).read().splitlines(), 1):
        if "Button.new()" in l and not any(k in l for k in ("TextureButton", "CheckButton", "OptionButton", "LinkButton")):
            bare.append(f"{os.path.relpath(f, CLIENT)}:{n}")
        if "StyleBoxFlat.new()" in l:
            bare.append(f"{os.path.relpath(f, CLIENT)}:{n} (StyleBoxFlat)")
for b in bare: fail(f"a control drawn outside the painted kit: {b}")
if not bare: ok("every button and field is one of the painted kit's")

print(f"\n{fails} FAILED" if fails else "\nclient lint clean")
sys.exit(1 if fails else 0)
