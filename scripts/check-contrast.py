#!/usr/bin/env python3
"""WCAG AA contrast over the client palette.

The palette was inverted from dark-on-light to light-on-dark in one pass, and
three colours came through that inversion looking right and measuring wrong --
gold at 2.67:1 on parchment, energy at 3.17:1, and the faint text that every
caption and every rail label in the game is set in at 3.71:1 on the rail.

None of that is visible in a screenshot to someone who already knows what the
label says. So it is measured here instead, from palette.gd itself, and it runs
in the client lint.

  python3 scripts/check-contrast.py
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PALETTE = ROOT / "client/scripts/ui/palette.gd"

AA_BODY = 4.5      # text below ~24 units
AA_LARGE = 3.0     # display sizes, and graphics


def parse() -> dict[str, str]:
    """Every `const NAME := Color("#RRGGBB")` and every entry of TIERS."""
    src = PALETTE.read_text()
    out = {m.group(1): m.group(2) for m in
           re.finditer(r'const (\w+)\s*:=\s*Color\("(#[0-9A-Fa-f]{6})"\)', src)}
    block = re.search(r"const TIERS\s*:=\s*\{(.*?)\}", src, re.S)
    if block:
        for m in re.finditer(r'"(\w+)":\s*Color\("(#[0-9A-Fa-f]{6})"\)', block.group(1)):
            out["tier:" + m.group(1)] = m.group(2)
    return out


def luminance(hex_colour: str) -> float:
    h = hex_colour.lstrip("#")
    channels = []
    for i in (0, 2, 4):
        c = int(h[i:i + 2], 16) / 255
        channels.append(c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4)
    r, g, b = channels
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def ratio(a: str, b: str) -> float:
    la, lb = luminance(a), luminance(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


# Each role is checked only against the grounds it is ACTUALLY drawn on, found
# by grepping the client. Checking everything against everything sounds safer and
# is worse: SUCCESS never appears on the rail, so a failure there is noise, and
# noise is what gets a check switched off.
#
#   PANEL  cards and rows        BG  the content ground        RAIL  the rail
TEXT_ROLES = {
    "TEXT":       ["PANEL", "BG", "RAIL"],
    "TEXT_DIM":   ["PANEL", "BG", "RAIL"],
    "TEXT_FAINT": ["PANEL", "BG", "RAIL"],   # captions AND every rail label
    "GOLD_INK":   ["PANEL", "BG"],
    "GOLD_DEEP":  ["PANEL", "BG"],
    "ENERGY":     ["PANEL", "BG"],
    "DIAMOND":    ["PANEL", "BG"],
    "DANGER":     ["PANEL", "BG"],
    "SUCCESS":    ["PANEL", "BG"],
}

# Graphics that carry meaning: an empty slot, a locked section. WCAG puts these
# at 3:1, not 4.5:1, because they are shapes rather than letterforms.
GRAPHIC_ROLES = {
    "EMPTY_SLOT": ["PANEL", "BG", "RAIL"],
}

# Purely decorative: a rule, a frame, a laurel. Reported so a change is visible,
# never enforced -- WCAG 1.4.11 covers graphics needed to UNDERSTAND content, and
# a gold hairline on parchment is deliberately quiet. Forcing these to 3:1 would
# mean darkening every ornament in the game to a brown that is not gold at all,
# which is the specific mistake this file exists to prevent in the other
# direction.
DECORATIVE = {
    "GOLD": ["PANEL", "BG", "RAIL"],
    "LINE": ["PANEL", "BG", "RAIL"],
}


def main() -> int:
    p = parse()
    failures = []

    def measure(name: str, ground: str, floor: float, enforce: bool) -> None:
        if name not in p or ground not in p:
            return
        r = ratio(p[name], p[ground])
        if enforce and r < floor:
            failures.append(f"{name} on {ground}: {r:.2f}, needs {floor}")
            mark = "FAIL"
        else:
            mark = "PASS" if r >= floor else "----"
        print(f"  {mark}  {name:<12} on {ground:<6} {r:5.2f}")

    print("\n== text ==")
    for role, grounds in TEXT_ROLES.items():
        for g in grounds:
            measure(role, g, AA_BODY, True)

    print("\n== meaningful graphics ==")
    for role, grounds in GRAPHIC_ROLES.items():
        for g in grounds:
            measure(role, g, AA_LARGE, True)

    print("\n== the imperial band ==")
    measure("BANNER_INK", "BANNER", AA_BODY, True)

    print("\n== tier names, printed on cards ==")
    for key in sorted(k for k in p if k.startswith("tier:")):
        measure(key, "PANEL", AA_BODY, True)

    print("\n== decorative, not enforced ==")
    for role, grounds in DECORATIVE.items():
        for g in grounds:
            measure(role, g, AA_LARGE, False)

    print()
    if failures:
        for f in failures:
            print("FAIL  " + f)
        print(f"\n{len(failures)} FAILED")
        return 1
    print("contrast clean")
    return 0


if __name__ == "__main__":
    sys.exit(main())
