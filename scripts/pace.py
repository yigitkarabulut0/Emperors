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


def gift_energy(level, prog, commerce):
    """The daily deals' free gift, as the energy it is worth on average: a potion
    is a full pool, XP wages are that much energy spent on the best job. Gold
    wages and diamonds do not level anyone, so they count for nothing here."""
    pool = commerce["deals"]["gift"]
    total = sum(g["weight"] for g in pool)
    e = 0.0
    for g in pool:
        e += grant_energy(g["grant"], level, prog) * g["weight"] / total
    return e


def token_pct(token_id):
    """A token's energy as a share of the pool: a potion is all of it, a flask its
    energy_pct. Read from rewards.json, so it cannot drift from what is paid."""
    if token_id == "energy_potion":
        return 100
    for t in json.loads((BAL / "rewards.json").read_text())["tokens"]:
        if t["id"] == token_id:
            return t.get("energy_pct", 0)
    return 0


def grant_energy(grant, level, prog, cart=0.0):
    """What one reward is worth in energy: tokens that restore energy, experience
    wages (that much energy's work), and cart writs at a cart's expected worth.
    Gold, diamonds, gear and looks do not level anyone and count for nothing."""
    e = grant.get("xp_wages", 0)
    for tid, n in grant.get("tokens", {}).items():
        if tid == "cart":
            e += n * cart
        else:
            e += n * token_pct(tid) * max_energy(prog, level) / 100
    return e


def cart_energy(level, prog, retention):
    """One Tax Cart's expected worth in energy, over its published odds."""
    odds = retention["cart"]["odds"]
    return sum(grant_energy(o["grant"], level, prog) * o["bp"] for o in odds) / 10000


def carts_per_day(gaps, retention):
    """Carts a lord with these check-ins opens in a day: one arrives every
    interval, `cap` can wait, and a check-in opens them all."""
    c = retention["cart"]
    interval_h = c["interval_seconds"] / 3600
    waiting, clock, opened = 0, 0.0, 0
    for _ in range(30):                      # a month of days, then the average
        for g in gaps:
            clock += g
            arrived = int(clock // interval_h)
            clock -= arrived * interval_h
            waiting = min(c["cap"], waiting + arrived)
            if waiting == c["cap"]:
                clock = 0.0                  # a full yard stops the clock
            opened += waiting
            waiting = 0
    return opened / 30


def daily_extra(source, level, prog, gaps, commerce, retention):
    """A source's energy per day, claimed at the day's first check-in."""
    if source == "gift":
        return gift_energy(level, prog, commerce)
    cart = cart_energy(level, prog, retention)
    if source == "cart":
        return cart * carts_per_day(gaps, retention)
    if source == "calendar":
        sq = retention["calendar"]["squares"]
        return sum(grant_energy(s["grant"], level, prog, cart) for s in sq) / len(sq)
    if source == "weekly":
        w = retention["weekly"]
        drawn = [t for t in w["pool"] if t.get("min_level", 1) <= max(level, w["eligible_level_floor"])]
        avg = sum(grant_energy(t["grant"], level, prog, cart) for t in drawn) / max(1, len(drawn))
        week = (sum(grant_energy(t["grant"], level, prog, cart) for t in w["fixed"])
                + avg * w["draw"] + sum(grant_energy(c["grant"], level, prog, cart) for c in w["chests"]))
        return week / 7
    return 0.0


# How often the panel is expected to run a festival: one every fortnight. The
# festivals are scheduled by hand, so this is the plan the budget is held to,
# not a rule the server keeps.
FESTIVAL_EVERY_DAYS = 14


def liveops_extra(source, level, prog, gaps, retention, liveops):
    """A live-ops source's energy per day, at its expected worth.

    courier  the Royal Courier's cart writ: its hour's chance, taken when a
             check-in falls inside its minutes.
    charter  the Royal Charter's free lane, all fifty tiers over a season (a
             casual lord's day of points fills it in about three weeks).
    festival a festival's tasks and milestones, one festival a fortnight."""
    cart = cart_energy(level, prog, retention)
    if source == "courier":
        e = liveops["hourly"]
        row = next(r for r in e["table"] if r["id"] == "royal_courier")
        hit = row["bp"] / 10000 * min(1.0, row["minutes"] / 60)
        return hit * len(gaps) * grant_energy(row["effect"]["grant"], level, prog, cart)
    if source == "charter":
        s = liveops["season"]
        return sum(grant_energy(g, level, prog, cart) for g in s["free"]) / s["days"]
    if source == "festival":
        per = []
        for t in liveops["events"]["templates"]:
            per.append(sum(grant_energy(x["grant"], level, prog, cart) for x in t["tasks"] + t["milestones"]))
        return (sum(per) / max(1, len(per))) / FESTIVAL_EVERY_DAYS
    return 0.0


def social_extra(source, level, prog, social, rewards):
    """A social source's energy per day, at its upper bound.

    gifts  the day's draughts, each a share of the lord's OWN pool (a gift is a
           flask, rewards.tokens): the count the balance allows, times what one
           draught restores at this level. A lord with no friends gets none of
           it, which is why it is measured as a ceiling rather than a mean --
           the budget has to hold for the lord with fifty."""
    if source == "gifts":
        f = social["friends"]
        pct = next((t["energy_pct"] for t in rewards["tokens"] if t["id"] == f["gift_token"]), 0)
        return f["gifts_received_per_day"] * max(1, max_energy(prog, level) * pct // 100)
    return 0.0


def hunt_extra(level, prog, gaps, hunt, best_tier_bp=None):
    """The roads' experience per day, at their upper bound (Wave 7).

    Expeditions cost no energy at all, so what they pay is pure addition, and
    three soldiers out all day is the ceiling the budget has to hold for. The
    day is walked with the lord's own check-ins: a soldier is sent on the first,
    and a slot pays whenever the gap since it was sent has covered the field's
    hours. The best field per hour is taken, which is the one a lord would take.

    Only the EXPERIENCE is counted: that is what moves a climb. The road's gold
    is the point of it and is measured nowhere, as the cart's and the Charter's
    gold are not -- gold buys gear and feeds the anvil, and neither is a level.
    """
    slots = max((s["slots"] for s in hunt["slots"] if level >= s["level"]), default=0)
    if slots <= 0 or not hunt["fields"]:
        return 0.0
    rank = 1.0 + (best_tier_bp or 0) / 10000.0
    # The field a lord would pick: the most experience an hour.
    field = max(hunt["fields"], key=lambda f: f["xp_wages"] / f["hours"])
    day = sum(gaps)
    # How many hauls one slot can bring home in a day of THESE check-ins.
    hauls, waited = 0, 0.0
    for g in gaps * 2:                         # two days, so a road can span the wrap
        waited += g
        if waited >= field["hours"]:
            hauls += 1
            waited = 0.0
    return slots * (hauls / 2.0) * field["xp_wages"] * rank


def war_extra(level, prog, gaps, war):
    """The kingdom war's purse (Wave 8), as a ceiling: a lord who rides out
    every week AND whose kingdom wins it.

    The purse is paid by letter when the week is settled and a war attack costs
    no energy at all, so what it is worth to a climb is its experience spread
    over the week's days. Three attacks a day is what bounds the war, and none
    of them pays anything on its own -- only the week does.

    The BEAST is not here, for the reason the campaign is not: it spends energy
    to pay it back. Six blows at a raid's price is 198 energy at level sixty and
    the three chests are 85 wages of experience, so a kingdom's beast makes a
    climb slower, never faster. What it pays is gold, and gold is not a level.
    """
    if not war:
        return 0.0
    return war["won"]["grant"].get("xp_wages", 0) / 7.0


def aid_factor(social):
    """What the kingdom's aid adds to a day's experience, at its upper bound: a
    full stack held for its hours, every day. A lord whose kingdom never
    answers gets nothing of it.

    It is printed rather than assumed so that an aid grown to a whole day at
    ten times the stack shows up as a budget line instead of as a surprise."""
    a = social["aid"]
    share = a["max_stacks"] * a["stack_bp"] / 10000
    return 1 + share * min(24, a["hours"]) / 24


def decree_factor(pvp):
    """What the Throne's decree adds to a day's experience, on average.

    Realm-wide, sixty minutes, once a week, and only one of the three edicts
    is an experience one -- so a lord's expected share is that edict's figure
    over the hours of a week. The gold and luck edicts level nobody and are
    measured here at nothing, as gold is everywhere else in this file.

    It is printed rather than assumed so that a decree grown to four hours at
    +200% shows up as a budget line instead of as a surprise."""
    t = pvp["throne"]
    xp = [d for d in t["decrees"] if d["bucket"] == "xp_bp"]
    if not xp:
        return 1.0
    share = sum(d["bp"] for d in xp) / len(t["decrees"]) / 10000
    minutes = max(d["minutes"] for d in t["decrees"])
    return 1 + share * minutes / (7 * 24 * 60)


def scholar_factor(liveops, gaps):
    """What Scholar's Hour adds to a day's experience, on average: the chance a
    check-in falls inside its minutes, times its bonus (the timed lane's cap
    is far above it). A lord who waits for it does better; one who does not
    look gets this."""
    row = next(r for r in liveops["hourly"]["table"] if r["id"] == "scholars_hour")
    hit = row["bp"] / 10000 * min(1.0, row["minutes"] / 60)
    return 1 + hit * row["effect"]["bp"] / 10000


LIVEOPS = ("courier", "charter", "festival", "scholars", "decree")
# The hall (Wave 6): the friends' gift is energy, the kingdom's aid is a timed
# lane bonus. The spyglass and the hall itself pay nothing and level nobody.
SOCIAL = ("gifts", "aid")


def road_energy(level, prog, retention):
    """The Victory Road's milestone at this level, in energy, claimed on arrival."""
    cart = cart_energy(level, prog, retention)
    return sum(grant_energy(m["grant"], level, prog, cart)
               for m in retention["road"]["milestones"] if m["level"] == level)


def days_to(jobs, prog, gaps, cap=60, limit_days=1200, commerce=None, sources=(), retention=None, liveops=None, pvp=None, social=None, rewards=None, hunt=None, best_tier_bp=None, war=None):
    """Simulates check-ins, spending the whole pool on the best affordable job.
    `sources` are the free rewards claimed at the first check-in of each day,
    at their expected worth ("gift", "cart", "calendar", "weekly"), and "road"
    for the Victory Road's milestones as they are reached -- an upper bound: a
    lord who never opens the store or the Court, and has no Steward, claims none.
    The live-ops sources (LIVEOPS) are claimed the same way; "scholars" lifts
    every collect's experience by Scholar's Hour's expected share."""
    need = {l["level"]: l["xp_to_next"] for l in prog["levels"]}
    period = prog["energy"]["regen_base_seconds"]
    refill = prog["energy"].get("levelup_refill", False)
    level, xp, hours, i = 1, 0, 0.0, 0
    reached = {}
    bonus = 0.0   # energy owed by a milestone, spent at the next check-in
    xp_factor = scholar_factor(liveops, gaps) if "scholars" in sources else 1.0
    if "decree" in sources and pvp:
        xp_factor *= decree_factor(pvp)
    if "aid" in sources and social:
        xp_factor *= aid_factor(social)
    while level < cap and hours < limit_days * 24:
        gap = gaps[i % len(gaps)]
        i += 1
        hours += gap
        # Energy regenerates during the gap and stops at the pool's ceiling.
        pool = min(max_energy(prog, level), int(gap * 3600 / period))
        if (i - 1) % len(gaps) == 0:
            for src in sources:
                if src in ("courier", "charter", "festival"):
                    pool += int(liveops_extra(src, level, prog, gaps, retention, liveops))
                elif src == "gifts":
                    pool += int(social_extra(src, level, prog, social, rewards))
                elif src == "hunt":
                    pool += int(hunt_extra(level, prog, gaps, hunt, best_tier_bp))
                elif src == "war":
                    pool += int(war_extra(level, prog, gaps, war))
                elif src not in ("road", "scholars", "decree", "aid"):
                    pool += int(daily_extra(src, level, prog, gaps, commerce, retention))
        pool += int(bonus)
        bonus = 0.0
        while pool > 0:
            job = None
            for j in jobs:
                if j["unlock_level"] <= level and j["energy_cost"] <= pool:
                    job = j
            if job is None:
                break
            pool -= job["energy_cost"]
            xp += job["base_xp"] * xp_factor
            while level < cap and xp >= need.get(level, 1 << 60):
                xp -= need[level]
                level += 1
                if level in MARKS:
                    reached[level] = hours / 24.0
                if "road" in sources:
                    bonus += road_energy(level, prog, retention)
                # A level-up refills the pool, so a session does not end when the
                # bar empties -- it ends when the bar empties WITHOUT a level. In
                # the early game that is most of the energy a player ever spends,
                # and leaving it out of the model understates the curve badly:
                # a first sitting reaches level 12, not level 5.
                if refill:
                    pool = max_energy(prog, level)
    return reached


def table(title, jobs, prog, commerce=None, sources=(), retention=None):
    print("\n%s" % title)
    print("  %-17s %s" % ("", "  ".join("%7s" % ("L%d" % m) for m in MARKS)))
    for name, gaps in ARCHETYPES.items():
        r = days_to(jobs, prog, gaps, commerce=commerce, sources=sources, retention=retention)
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
    commerce = json.loads((BAL / "commerce.json").read_text())
    retention = json.loads((BAL / "retention.json").read_text())
    everything = ("gift", "cart", "calendar", "weekly", "road")
    table("with every free source claimed (expected worth)", jobs, prog, commerce, everything, retention)
    casual = ARCHETYPES["casual 3/day"]
    base = days_to(jobs, prog, casual).get(60)
    print("\n  casual level 60, one free source at a time:")
    print("    %-26s %6.1fd" % ("none", base))
    for src, label in (("gift", "the Royal Store's daily gift"), ("cart", "the Tax Cart"),
                       ("calendar", "the 28-day calendar"), ("weekly", "the week's quests"),
                       ("road", "the Victory Road")):
        d = days_to(jobs, prog, casual, commerce=commerce, sources=(src,), retention=retention).get(60)
        print("    %-26s %6.1fd  %+5.1f%%" % (label, d, (d - base) * 100 / base))
    gifted = days_to(jobs, prog, casual, commerce=commerce, sources=("gift",), retention=retention).get(60)
    allin = days_to(jobs, prog, casual, commerce=commerce, sources=everything, retention=retention).get(60)
    print("    %-26s %6.1fd  %+5.1f%%" % ("all of them together", allin, (allin - base) * 100 / base))
    loop = (allin - gifted) * 100 / gifted
    print("    the daily loop (cart, calendar, week, road) on top of the gift: %+.1f%%; its budget is 5%%" % loop)
    if abs(loop) > 5:
        print("\n  OVER BUDGET: the daily loop moves casual level 60 by %.1f%%, past the 5%% it may." % loop)
        raise SystemExit(1)
    print("    (the Golden Hour pays gold only, and the welcome back comes to lords who were away:")
    print("     neither moves a lord who plays every day)")

    # Live ops (Wave 4), on top of the gift and the daily loop, with its own 5%.
    liveops = json.loads((BAL / "liveops.json").read_text())
    pvp = json.loads((BAL / "pvp.json").read_text())
    print("\n  casual level 60, the live ops on top of the gift and the daily loop:")
    for src, label in (("scholars", "Scholar's Hour"), ("courier", "the Royal Courier"),
                       ("charter", "the Charter's free lane"), ("festival", "a festival a fortnight"),
                       ("decree", "the Throne's decree")):
        d = days_to(jobs, prog, casual, commerce=commerce, sources=everything + (src,), retention=retention,
                    liveops=liveops, pvp=pvp).get(60)
        print("    %-26s %6.1fd  %+5.1f%%" % (label, d, (d - allin) * 100 / allin))
    live = days_to(jobs, prog, casual, commerce=commerce, sources=everything + LIVEOPS, retention=retention,
                   liveops=liveops, pvp=pvp).get(60)
    lv = (live - allin) * 100 / allin
    print("    %-26s %6.1fd  %+5.1f%%" % ("all of them together", live, lv))
    print("    the live ops on top of the daily loop: %+.1f%%; their budget is 5%%" % lv)
    if abs(lv) > 5:
        print("\n  OVER BUDGET: the live ops move casual level 60 by %.1f%%, past the 5%% they may." % lv)
        raise SystemExit(1)
    print("    (Gold Rush, the Caravan and the Charter's gold wages pay gold; the royal lane and the")
    print("     deeds pay diamonds and looks; Busy Hands finishes quests sooner, never more of them)")
    # Rekabet (Wave 5). Only the Throne's decree is measured, and it is above.
    # The arena and the bounty board are outside this budget BY CONSTRUCTION,
    # not by omission: validate_pvp.go refuses an arena grant that carries
    # experience, energy or a boost, so nothing can quietly put them back in.
    print("    the arena and the bounty board: +0.0%, by construction -- neither pays experience")
    print("     or energy, and validate_pvp.go refuses a grant that would")

    # The hall (Wave 6), on top of everything above, with its own 3%. Two
    # sources, both measured at their CEILING: a lord with fifty friends who
    # all give, in a kingdom that answers every call. A lord with neither gets
    # none of this, so the budget is held for the one who has both.
    social = json.loads((BAL / "social.json").read_text())
    rewards = json.loads((BAL / "rewards.json").read_text())
    print("\n  casual level 60, the hall on top of the gift, the daily loop and the live ops:")
    for src, label in (("gifts", "friends' gifts"), ("aid", "the kingdom's aid")):
        d = days_to(jobs, prog, casual, commerce=commerce, sources=everything + LIVEOPS + (src,),
                    retention=retention, liveops=liveops, pvp=pvp, social=social,
                    rewards=rewards).get(60)
        print("    %-26s %6.1fd  %+5.1f%%" % (label, d, (d - live) * 100 / live))
    hall = days_to(jobs, prog, casual, commerce=commerce, sources=everything + LIVEOPS + SOCIAL,
                   retention=retention, liveops=liveops, pvp=pvp, social=social, rewards=rewards).get(60)
    hv = (hall - live) * 100 / live
    print("    %-26s %6.1fd  %+5.1f%%" % ("all of them together", hall, hv))
    print("    the hall on top of the live ops: %+.1f%%; its budget is 3%%" % hv)
    if abs(hv) > 3:
        print("\n  OVER BUDGET: the hall moves casual level 60 by %.1f%%, past the 3%% it may." % hv)
        raise SystemExit(1)
    print("    (the spyglass burns gold, the goal's chests pay gold, a cart and diamonds, and")
    print("     validate_social.go refuses a grant in this document that carries experience)")

    # The roads (Wave 7), on top of everything above, with their own 5%. Three
    # soldiers out all day, at the top of the ladder: the ceiling, as the hall's
    # is. What is measured is the EXPERIENCE only -- the road's gold is the
    # point of it, and gold is not a level.
    hunt = json.loads((BAL / "hunt.json").read_text())
    items = json.loads((BAL / "items.json").read_text())
    top = max(items["tier_mult_bp"].values())
    share = (top - 10000) * hunt["tier_share_bp"] // 10000
    print("\n  casual level 60, the roads on top of the gift, the daily loop, the live ops and the hall:")
    roads = days_to(jobs, prog, casual, commerce=commerce,
                    sources=everything + LIVEOPS + SOCIAL + ("hunt",),
                    retention=retention, liveops=liveops, pvp=pvp, social=social, rewards=rewards,
                    hunt=hunt, best_tier_bp=share).get(60)
    rv = (roads - hall) * 100 / hall
    print("    %-26s %6.1fd  %+5.1f%%" % ("three soldiers, all day", roads, rv))
    print("    the roads on top of the hall: %+.1f%%; their budget is 5%%" % rv)
    if abs(rv) > 5:
        print("\n  OVER BUDGET: the roads move casual level 60 by %.1f%%, past the 5%% they may." % rv)
        raise SystemExit(1)
    print("    (a road pays a quarter of its wages in experience and the rest in GOLD, which the")
    print("     anvil in the same wave burns; the campaign is not here because it SPENDS energy")
    print("     to pay it back -- a first clear is three times what its own energy collects, once)")

    # The kingdom war (Wave 8), on top of everything above, with its own 2%. A
    # lord who rides out every week and whose kingdom WINS every week: the
    # ceiling, as the hall's and the roads' are.
    war = json.loads((BAL / "war.json").read_text())
    print("\n  casual level 60, the week's war on top of the gift, the daily loop, the live ops,")
    print("  the hall and the roads:")
    wars = days_to(jobs, prog, casual, commerce=commerce,
                   sources=everything + LIVEOPS + SOCIAL + ("hunt", "war"),
                   retention=retention, liveops=liveops, pvp=pvp, social=social, rewards=rewards,
                   hunt=hunt, best_tier_bp=share, war=war).get(60)
    wv = (wars - roads) * 100 / roads
    print("    %-26s %6.1fd  %+5.1f%%" % ("won every week", wars, wv))
    print("    the war on top of the roads: %+.1f%%; its budget is 2%%" % wv)
    if abs(wv) > 2:
        print("\n  OVER BUDGET: the war moves casual level 60 by %.1f%%, past the 2%% it may." % wv)
        raise SystemExit(1)
    print("    (nothing is taken in a war and nothing is spent in one: what it pays is a purse")
    print("     once a week. The kingdom's BEAST is not here for the campaign's reason -- it")
    print("     spends 198 energy a cycle to pay 85 wages back, so it slows a climb, never")
    print("     hurries it)")
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
