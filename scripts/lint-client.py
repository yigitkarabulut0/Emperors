#!/usr/bin/env python3
"""Static checks on the Godot client that the engine will not make for you.

These are all mistakes already made once in this project. None of them raise an
error at runtime -- they just quietly produce a wrong-looking screen -- so they
are worth catching in text.
"""
import json
import pathlib
import re
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CLIENT = ROOT / "client"
FAILURES: list[str] = []


def fail(msg: str) -> None:
    FAILURES.append(msg)
    print(f"  FAIL  {msg}")


def ok(msg: str) -> None:
    print(f"  PASS  {msg}")


gd = sorted(p for p in CLIENT.rglob("*.gd"))
print(f"\n== {len(gd)} scripts ==")

# 1. A TextureRect without expand_mode reports the SOURCE TEXTURE's size as its
#    minimum size. A 96 px icon then forces its row to 96 px tall and the layout
#    silently blows out. This has bitten twice.
bad = []
for p in gd:
    src = p.read_text()
    for m in re.finditer(r"(\w+)\s*(?::=|=)\s*TextureRect\.new\(\)", src):
        var = m.group(1)
        if not re.search(rf"\b{re.escape(var)}\.expand_mode\s*=", src):
            bad.append(f"{p.relative_to(ROOT)}: {var} never sets expand_mode")
if bad:
    for b in bad:
        fail(b)
else:
    ok("every TextureRect sets expand_mode")

# 2. Art is addressed by logical key through ArtRegistry, so assets can be
#    renamed, atlased or moved into a downloadable pack without touching scenes.
leaks = []
for p in gd:
    if p.name == "art_registry.gd":
        continue
    for line in p.read_text().splitlines():
        if "res://assets/" in line and not line.lstrip().startswith("#"):
            leaks.append(f"{p.relative_to(ROOT)}: {line.strip()[:70]}")
if leaks:
    for l in leaks:
        fail(l)
else:
    ok("no scene hardcodes an res://assets path")

# 3. Autoloads may only reference autoloads registered before them AT LOAD TIME,
#    because Godot instantiates them in declaration order and a forward reference
#    is null while _init/_ready runs. Calling one from an ordinary method later is
#    fine and is how Api and Session legitimately depend on each other.
def init_scope(src: str) -> str:
    """Class-level variable initialisers plus the bodies of _init and _ready."""
    out, grabbing = [], False
    for line in src.splitlines():
        stripped = line.strip()
        if line.startswith("func "):
            grabbing = stripped.startswith(("func _init(", "func _ready("))
            continue
        if grabbing:
            out.append(line)
        elif not line.startswith((" ", "\t")) and re.match(r"(var|const|@onready)\b.*=", stripped):
            out.append(line)
    return "\n".join(out)


project = (CLIENT / "project.godot").read_text()
block = re.search(r"\[autoload\](.*?)(\n\[|\Z)", project, re.S)
order = [m.group(1) for m in re.finditer(r"^(\w+)\s*=", block.group(1), re.M)] if block else []
seen: list[str] = []
bad_order = []
for name in order:
    path = re.search(rf'^{name}\s*=\s*"\*?(res://[^"]+)"', block.group(1), re.M)
    seen.append(name)
    if not path:
        continue
    f = CLIENT / path.group(1).removeprefix("res://")
    if not f.exists():
        continue
    scope = init_scope(f.read_text())
    for other in order:
        if other in seen:
            continue
        if re.search(rf"\b{other}\.", scope):
            bad_order.append(f"{name} touches {other} while loading, but {other} loads after it")
if bad_order:
    for b in bad_order:
        fail(b)
else:
    ok(f"no autoload touches a later one while loading ({' -> '.join(order)})")

# 4. Every navigation icon the shell asks for must actually ship. The rail falls
#    back to a letter, so a missing file is invisible in a smoke test.
shell = (CLIENT / "scenes/shell/shell.gd").read_text()
wanted = re.findall(r'"icon":\s*"(\w+)"', shell)
missing = [n for n in wanted if not (CLIENT / f"assets/ui/{n}.png").exists()]
if missing:
    fail(f"navigation icons not on disk: {missing}")
elif not wanted:
    fail("the shell declares no navigation icons")
else:
    ok(f"all {len(wanted)} navigation icons ship")

# 5. Every thing the balance documents name needs its row icon. ArtRegistry
#    returns null for a missing UI glyph rather than a placeholder, so a job or
#    holding added to balance without art is a blank row -- visible only to
#    someone who happens to scroll to it.
def ids(path: str, key: str) -> list[str]:
    doc = json.loads((ROOT / path).read_text())
    return [e["id"] for e in (doc[key] if isinstance(doc, dict) else doc)]


families = [
    ("jobs", ids("balance/jobs.json", "jobs")),
    ("upgrades", ids("balance/estates.json", "upgrades")),
    ("holdings", ids("balance/estates.json", "holdings")),
    ("slots", ["weapon", "armor", "horse"]),
]
for family, wanted_ids in families:
    absent = [i for i in wanted_ids if not (CLIENT / f"assets/ui/{family}/{i}.png").exists()]
    if absent:
        fail(f"{family} with no icon: {absent}")
    else:
        ok(f"all {len(wanted_ids)} {family} have an icon")

# 6. Every (design, tier) pair the item table can hand a client must ship.
#    ArtRegistry falls back to design 01 of the same slot when one is missing, so
#    the game keeps working and a whole tier of swords quietly shows the wrong
#    blade. Nothing surfaces that but this check.
items_doc = json.loads((ROOT / "balance/items.json").read_text())
tiers = [t["id"] for t in json.loads((ROOT / "balance/tiers.json").read_text())["tiers"]]
# Painted icons are per DESIGN; the older line art was per design-and-tier. Both
# are accepted while the folder is half migrated -- what must never happen is a
# design with no art at all, because ArtRegistry then falls back to design 01 of
# the same slot and a whole tier of swords quietly shows the wrong blade.
designs = sorted({d["art"] for d in items_doc["definitions"]})
gone = []
for art in designs:
    painted = (CLIENT / f"assets/items/{art}.png").exists()
    tinted = all((CLIENT / f"assets/items/{art}_{t}.png").exists() for t in tiers)
    if not painted and not tinted:
        gone.append(art)
if gone:
    fail(f"{len(gone)} item designs have no art: {gone[:5]}")
else:
    painted_n = sum(1 for a in designs if (CLIENT / f"assets/items/{a}.png").exists())
    ok(f"all {len(designs)} item designs have art ({painted_n} painted)")

# 7. An unimported asset does not exist as far as an exported build is concerned.
unimported = [p.relative_to(ROOT) for p in (CLIENT / "assets").rglob("*.png")
              if not p.with_suffix(".png.import").exists()]
if unimported:
    fail(f"{len(unimported)} assets have no .import: {unimported[:3]}")
else:
    ok("every shipped asset is imported")

# 8. Everything above reads the scripts as text. Only Godot actually parses
#    GDScript, and a parse error takes a whole screen down at runtime while
#    looking perfectly fine to every rule above.
#
#    Every file individually, via --check-only. Booting the project only parses
#    what the boot scene reaches, so a broken tab that nobody opens at startup
#    passed this rule cleanly -- which is exactly how one shipped.
#
#    --check-only does not register autoloads, so every file that uses one
#    reports "Identifier not found: Api" and friends. That is the one false
#    positive and it is filtered by name; anything else is a real finding.
godot = shutil.which("godot")
if not godot:
    print("  SKIP  godot is not on PATH, so scripts were not parsed")
else:
    project = (CLIENT / "project.godot").read_text()
    block = re.search(r"\[autoload\](.*?)(\n\[|\Z)", project, re.S)
    autoloads = [m.group(1) for m in re.finditer(r"^(\w+)\s*=", block.group(1), re.M)] if block else []
    benign = {f"Identifier not found: {name}" for name in autoloads}

    problems = []
    for f in gd:
        rel = f.relative_to(CLIENT).as_posix()
        proc = subprocess.run(
            [godot, "--headless", "--path", str(CLIENT), "--check-only", "--script", "res://" + rel],
            capture_output=True, text=True, timeout=120)
        for ln in (proc.stdout + proc.stderr).splitlines():
            if "Parse Error" not in ln and "Compile Error" not in ln:
                continue
            if any(b in ln for b in benign):
                continue
            problems.append(f"{rel}: {ln.strip()[:110]}")
    if problems:
        for pr in problems[:6]:
            fail(pr)
    else:
        ok(f"all {len(gd)} scripts parse")

print()
if FAILURES:
    print(f"{len(FAILURES)} FAILED")
    sys.exit(1)
print("client lint clean")
