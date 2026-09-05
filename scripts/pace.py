#!/usr/bin/env python3
"""Time-to-level under a given balance, for real session patterns.

Answers the only question that matters about a progression curve: how long does
it actually take. It reads the generated balance rather than restating any
formula, so it cannot drift from what the server runs, and it models a player
who sleeps -- a "perfect play, 1440 energy a day" figure flatters every curve
and is what let the current one look reasonable.

  python3 scripts/pace.py                  the shipped balance
  python3 scripts/pace.py --xpe-step 1.14  a candidate, without writing anything
"""
import argparse, json, pathlib

BAL = pathlib.Path(__file__).resolve().parent.parent / "balance"

# Hours between check-ins. A pool that fills while you sleep stops earning, so
# the gaps are what decide how much energy a day is actually worth.
ARCHETYPES = {
    "casual 3/day":    [5, 8, 11],
    "regular 5/day":   [3, 3, 4, 6, 8],
    "committed 8/day": [1, 1, 2, 2, 2, 3, 5, 8],
    "hourly 17/day":   [1] * 16 + [8],
}
MARKS = [5, 10, 15, 20, 30, 40, 60]


def load(xpe_step=None):
    jobs = json.loads((BAL / "jobs.json").read_text())["jobs"]
    prog = json.loads((BAL / "progression.json").read_text())
    if xpe_step is not None:
        base = 2.00
        for i, j in enumerate(jobs, start=1):
            j["base_xp"] = max(2, round(j["energy_cost"] * base * xpe_step ** max(0, i - 2)))
    return jobs, prog


def max_energy(prog, level):
    e = prog["energy"]
    return e["base_max"] + e.get("per_level", 0) * (level - 1)


def days_to(jobs, prog, gaps, cap=60, limit_days=1200):
    """Simulates check-ins, spending the whole pool on the best affordable job."""
    need = {l["level"]: l["xp_to_next"] for l in prog["levels"]}
    period = prog["energy"]["regen_base_seconds"]
    refill = prog["energy"].get("levelup_refill", False)
    level, xp, hours, i = 1, 0, 0.0, 0
    reached = {}
    while level < cap and hours < limit_days * 24:
        gap = gaps[i % len(gaps)]
        i += 1
        hours += gap
        # Energy regenerates during the gap and stops at the pool's ceiling.
        pool = min(max_energy(prog, level), int(gap * 3600 / period))
        while pool > 0:
            job = None
            for j in jobs:
                if j["unlock_level"] <= level and j["energy_cost"] <= pool:
                    job = j
            if job is None:
                break
            pool -= job["energy_cost"]
            xp += job["base_xp"]
            while level < cap and xp >= need.get(level, 1 << 60):
                xp -= need[level]
                level += 1
                if level in MARKS:
                    reached[level] = hours / 24.0
                # A level-up refills the pool, so a session does not end when the
                # bar empties -- it ends when the bar empties WITHOUT a level. In
                # the early game that is most of the energy a player ever spends,
                # and leaving it out of the model understates the curve badly:
                # a first sitting reaches level 12, not level 5.
                if refill:
                    pool = max_energy(prog, level)
    return reached


def table(title, jobs, prog):
    print("\n%s" % title)
    print("  %-17s %s" % ("", "  ".join("%7s" % ("L%d" % m) for m in MARKS)))
    for name, gaps in ARCHETYPES.items():
        r = days_to(jobs, prog, gaps)
        cells = []
        for m in MARKS:
            cells.append("%7s" % ("%.1fd" % r[m] if m in r else "—"))
        print("  %-17s %s" % (name, "  ".join(cells)))


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--xpe-step", type=float, default=None)
    ap.add_argument("--base-max", type=int, default=None)
    ap.add_argument("--per-level", type=int, default=None)
    ap.add_argument("--regen-seconds", type=int, default=None)
    a = ap.parse_args()
    jobs, prog = load()
    table("shipped", jobs, prog)
    if a.xpe_step or a.base_max or a.per_level or a.regen_seconds:
        jobs2, prog2 = load(a.xpe_step)
        if a.base_max:
            prog2["energy"]["base_max"] = a.base_max
        if a.per_level:
            prog2["energy"]["per_level"] = a.per_level
        if a.regen_seconds:
            prog2["energy"]["regen_base_seconds"] = a.regen_seconds
        e = prog2["energy"]
        table("xpe step %s, pool %d+%d/level, regen %ds" % (
            a.xpe_step or "shipped", e["base_max"], e.get("per_level", 0),
            e["regen_base_seconds"]), jobs2, prog2)
        print("\n  energy captured per day (level 30):")
        for name, gaps in ARCHETYPES.items():
            cap_new = sum(min(max_energy(prog2, 30), int(g * 3600 / e["regen_base_seconds"]))
                          for g in gaps) * (24.0 / sum(gaps))
            cap_old = sum(min(max_energy(prog, 30),
                              int(g * 3600 / prog["energy"]["regen_base_seconds"]))
                          for g in gaps) * (24.0 / sum(gaps))
            print("    %-17s %5d -> %5d" % (name, cap_old, cap_new))
        print("\n  xp per energy, rung 1 -> 15: %.2f -> %.2f (%.1fx)" % (
            jobs2[0]["base_xp"] / jobs2[0]["energy_cost"],
            jobs2[-1]["base_xp"] / jobs2[-1]["energy_cost"],
            (jobs2[-1]["base_xp"] / jobs2[-1]["energy_cost"])
            / (jobs2[0]["base_xp"] / jobs2[0]["energy_cost"])))
