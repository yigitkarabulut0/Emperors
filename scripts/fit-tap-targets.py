#!/usr/bin/env python3
"""Grows every button's tap target to 44 pt without moving what it looks like.

    python3 scripts/fit-tap-targets.py --check     # report, change nothing
    python3 scripts/fit-tap-targets.py             # widen the layouts

The design grid is 941 units across and the phone draws it over 440 pt, so a
unit is 0.4676 pt and Apple's 44 pt minimum is 95 units. Almost every button in
the references is painted smaller than that -- they are pictures of buttons from
a mock-up, not tap targets -- and the smallest are 17 pt across.

A button's rect is its tap area AND its picture, so this grows the rect and sets
"keep_texture_size" on the painted ones, which makes the control draw its
texture at its own size centred inside: the button looks exactly as it did and
takes a thumb. Buttons that set their own label (kind button with "label") draw
a stretching plate instead, so those just grow.

Growing stops at whatever else can be pressed. Two tap areas that share pixels
means one of them cannot be reached, which is worse than a small button, so a
button that cannot reach 44 pt without touching a neighbour is grown as far as
it fits and reported.
"""
import argparse, json, pathlib, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
GRID_W, SCREEN_PT = 941.0, 440.0
PT = SCREEN_PT / GRID_W
MIN_UNITS = 44.0 / PT            # 94.1 -> 95
TARGET = 95.0
CONTROLS = ("button", "hotspot")


def rect(e):
    r = e.get("rect", [0, 0, 0, 0])
    return [float(r[0]), float(r[1]), float(r[2]), float(r[3])]


def overlaps(a, b):
    return (a[0] < b[0] + b[2] and b[0] < a[0] + a[2]
            and a[1] < b[1] + b[3] and b[1] < a[1] + a[3])


def containers(elements, bounds, out):
    """Every (list of siblings, bounding box) a control can live in."""
    out.append((elements, bounds))
    for e in elements:
        if not isinstance(e, dict):
            continue
        r = rect(e)
        if e.get("kind") == "template":
            containers(e.get("parts", []), [0.0, 0.0, r[2], r[3]], out)
        elif e.get("kind") in ("scroll", "group"):
            kids = e.get("content", e.get("parts", []))
            containers(kids, [0.0, 0.0, max(r[2], 1e9 if e.get("axis") == "horizontal" else r[2]), r[3]], out)
        elif "parts" in e:
            containers(e["parts"], [0.0, 0.0, r[2], r[3]], out)


def grow(r, others, bounds):
    """Widens r toward TARGET on each short axis, around its own centre.

    Strictly symmetric, and that is the point. A button is drawn centred in its
    rect, and almost every one of them has a twin painted into the panel behind
    it -- the references are whole screens, so a panel crop carries whatever was
    painted on it. Move a rect's centre and the drawn button slides off its
    painted twin, and the player sees two. That shipped on the army screen:
    AUTO EQUIP grew upward to reach 44 pt and appeared twice.

    So a control never moves. If it cannot reach 44 pt without covering
    something else that can be pressed, it stays as painted and is reported.
    """
    out = list(r)
    for axis in (0, 1):
        size = 2 if axis == 0 else 3
        if out[size] >= TARGET:
            continue
        centre = out[axis] + out[size] / 2.0
        for want in range(int(TARGET), int(out[size]), -1):
            lo = centre - want / 2.0
            hi = centre + want / 2.0
            if lo < bounds[axis] or hi > bounds[axis] + bounds[size]:
                continue
            cand = list(out)
            cand[axis] = lo
            cand[size] = want
            if all(not overlaps(cand, o) for o in others):
                out = cand
                break
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    grown = short = 0
    for path in sorted((ROOT / "client/layout").glob("*.json")):
        d = json.loads(path.read_text())
        boxes = []
        containers(d.get("elements", []), [0.0, 0.0, GRID_W, 1672.0], boxes)
        changed = False
        for siblings, bounds in boxes:
            controls = [e for e in siblings if isinstance(e, dict) and e.get("kind") in CONTROLS]
            # A scrolling region is an obstacle too, and a quieter one: a button
            # lying over a row does not look wrong, it just takes the drags that
            # start on it, and the row stops moving. AUTO EQUIP did that to the
            # army's slots.
            regions = [rect(e) for e in siblings
                       if isinstance(e, dict) and e.get("kind") == "scroll"]
            for e in controls:
                r = rect(e)
                if min(r[2], r[3]) >= MIN_UNITS:
                    continue
                others = [rect(o) for o in controls if o is not e] + regions
                new = grow(r, others, bounds)
                if new == r:
                    short += 1
                    print(f"  STUCK {path.stem}/{e.get('id')} {r[2]:.0f}x{r[3]:.0f} "
                          f"({r[2]*PT:.0f}x{r[3]*PT:.0f} pt) -- no room")
                    continue
                grown += 1
                fit = "ok " if min(new[2], new[3]) >= MIN_UNITS else "part"
                print(f"  {fit} {path.stem}/{e.get('id'):18} "
                      f"{r[2]:.0f}x{r[3]:.0f} -> {new[2]:.0f}x{new[3]:.0f} "
                      f"({new[2]*PT:.0f}x{new[3]*PT:.0f} pt)")
                if not args.check:
                    e.setdefault("paint_rect", [round(v) for v in r])
                    e["rect"] = [round(v) for v in new]
                    # A picture keeps its size inside the bigger control; a plate
                    # with its own label is meant to stretch.
                    if e.get("kind") == "button" and "label" not in e:
                        e["keep_texture_size"] = True
                    changed = True
        if changed and not args.check:
            path.write_text(json.dumps(d, indent=1) + "\n")
            mirror = ROOT / "art/slices" / (path.stem + ".layout.json")
            if mirror.exists():
                mirror.write_text(json.dumps(d, indent=1) + "\n")
    print(f"\n{grown} grown, {short} with no room")
    return 1 if short and args.check else 0


if __name__ == "__main__":
    sys.exit(main())
