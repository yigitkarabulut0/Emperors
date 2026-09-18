#!/usr/bin/env python3
"""Live ops (Wave 4), end to end, as a new lord sees them.

    python3 scripts/smoke-liveops.py [<game-url>]

Checks what any player can see, with no panel and no clock of its own:

  * the snapshot carries the hour's event (what is on, until when, the next
    hour's), the season and this lord's Charter, and the festival if one is on;
  * the Events page publishes the hourly table's odds (10000 bp, "none"
    included), and a claim with no festival running is refused;
  * the Royal Courier's gift is taken once when it is in the realm, and
    refused as over when it is not;
  * the Season Pass: fifty tiers, 170 free and 625 royal diamonds, the royal
    lane for 900 diamonds or the Charter product; a day's reward earns 60
    points; nothing to claim below tier 1; a lord short of 900 cannot open it;
  * the deeds: 24 in 7 medallions, the day's claim counted, nothing to claim
    for a new lord and an unknown deed refused;
  * the boards: the week's and the season's beside the standing three, with
    their period, their end and what their places pay;
  * the market says how many free rerolls the hour gives, and the store's
    refill how much a sale takes off.
"""
import json, sys, time, urllib.error, urllib.request

BASE = (sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8080").rstrip("/")
failures = []


def call(method, path, body=None, token=None):
    req = urllib.request.Request(
        BASE + path, method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"content-type": "application/json",
                 **({"authorization": "Bearer " + token} if token else {})})
    try:
        with urllib.request.urlopen(req, timeout=30) as f:
            raw = f.read()
            return f.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw or b"{}")
        except json.JSONDecodeError:
            return e.code, {}


def code(body):
    return (body.get("error") or {}).get("code", body.get("code", ""))


def check(name, ok, detail=""):
    print(("  PASS  " if ok else "  FAIL  ") + name + ("" if ok else f"  <- {detail}"))
    if not ok:
        failures.append(name)


def new_player(tag):
    user = "%s%d" % (tag, int(time.time() * 1000) % 10_000_000)
    st, reg = call("POST", "/v1/auth/register", {"username": user, "password": "battery horse staple"})
    if st not in (200, 201):
        print("cannot register a player:", st, reg)
        sys.exit(2)
    return reg["access_token"]


print("== the snapshot ==")
token = new_player("lo")
_, s = call("GET", "/v1/state", token=token)
live = s.get("live", {})
h, season = live.get("hourly", {}), live.get("season", {})
check("the hour's event is on the snapshot", "next_in" in h and 0 < h["next_in"] <= 3600 and "active" in h, h)
check("an event that is on ends within its hour", not h.get("active") or 0 < h.get("ends_in", 0) <= 3600, h)
check("the next hour is announced or quiet", h.get("next") is None or h["next"].get("name"), h.get("next"))
check("the season and a new lord's Charter", season.get("number", 0) >= 1 and season.get("tiers") == 50
      and season.get("tier") == 0 and season.get("royal") is False and season.get("ends_in", 0) > 0, season)
fest = live.get("festival")
check("a festival, if one is on or announced, says so", fest is None or (fest.get("name") and "running" in fest), fest)

print("\n== the Events page ==")
st, ev = call("GET", "/v1/festivals", token=token)
table = ev.get("hourly_table", [])
check("the hourly table's odds are the whole of an hour", st == 200 and sum(r["bp"] for r in table) == 10000
      and any(r["id"] == "none" for r in table) and len(table) == 9, table)
honor = next((r for r in table if r["id"] == "honor_hour"), {})
check("the Honour Arena has an hour of its own", honor.get("minutes") == 60 and honor.get("bp", 0) > 0
      and honor.get("icon") == "hourly/honor_hour", honor)
check("the page carries the hour, and its lists", isinstance(ev.get("upcoming"), list) and isinstance(ev.get("past"), list)
      and ev.get("hourly", {}).get("next_in", 0) > 0, ev.keys())
if ev.get("current") and ev["current"].get("running"):
    c = ev["current"]
    check("the running festival has five tasks and four milestones", len(c["tasks"]) == 5 and len(c["milestones"]) == 4
          and c["day_cap"] > 0 and c["milestones"][-1]["crown"], c)
    st, b = call("POST", "/v1/festivals/claim", {}, token=token)
    check("a new lord has nothing in it to claim", st == 409 and code(b) == "nothing_to_claim", (st, b))
else:
    st, b = call("POST", "/v1/festivals/claim", {}, token=token)
    check("a claim with no festival running is refused", st == 409 and code(b) == "no_festival", (st, b))

print("\n== the hour's gift ==")
st, b = call("POST", "/v1/hourly/claim", {}, token=token)
if h.get("id") == "royal_courier" and h.get("active"):
    check("the courier's gift is taken", st == 200 and b["granted"]["tokens"].get("cart") == 1, (st, b))
    st, b = call("POST", "/v1/hourly/claim", {}, token=token)
    check("and not twice", st == 409 and code(b) == "already_claimed", (st, b))
else:
    check("no gift is in the realm this hour", st == 409 and code(b) == "hourly_over", (st, b))

print("\n== the Season Pass ==")
st, p = call("GET", "/v1/season", token=token)
check("fifty tiers, 170 free and 625 royal diamonds", st == 200 and len(p["charter"]) == 50 and p["free_diamonds"] == 170
      and p["royal_diamonds"] == 625 and p["points_per_tier"] == 120 and p["day_cap"] == 800, {k: p.get(k) for k in
      ("free_diamonds", "royal_diamonds", "points_per_tier", "day_cap")})
check("the royal lane opens for 900 diamonds or the Charter", p.get("unlock", {}).get("diamonds") == 900
      and p["unlock"].get("store_id", "").endswith("season.pass") and p["unlock"].get("usd_cents") == 799, p.get("unlock"))
check("the ways to earn are written out", p["sources"] and all(x["text"] and x["points"] > 0 for x in p["sources"]),
      p["sources"])
check("every tier says what its lanes hold", all(t["free"] and t["royal"] for t in p["charter"])
      and p["charter"][49]["crown"] and p["charter"][9]["crown"], p["charter"][:2])
st, b = call("POST", "/v1/season/claim", {}, token=token)
check("nothing to claim below tier 1", st == 409 and code(b) == "nothing_to_claim", (st, b))
st, b = call("POST", "/v1/season/claim", {"tier": 1, "lane": "royal"}, token=token)
check("a royal tier with the lane shut is refused", st == 403 and code(b) == "charter_locked", (st, b))
st, b = call("POST", "/v1/season/unlock", {}, token=token)
check("a lord short of 900 diamonds cannot open it", st == 409 and code(b) == "not_enough_diamonds", (st, b))
st, b = call("POST", "/v1/daily/claim", {}, token=token)
check("the day's reward is claimed", st == 200, (st, b))
st, p = call("GET", "/v1/season", token=token)
check("and earns its 60 points", p.get("points") == 60 and p.get("day_points") == 60, {k: p.get(k) for k in ("points", "day_points")})

print("\n== the deeds ==")
st, a = call("GET", "/v1/achievements", token=token)
deeds = {x["id"]: x for x in a.get("achievements", [])}
# 24 in Wave 4, 26 with Wave 5's champion and headhunter, 28 with Wave 6's
# open-handed and shoulder-to-shoulder. The deeds' own counters run ahead of
# the medallions: a counter exists so a later wave can hang one on it.
check("28 deeds in 7 medallions", st == 200 and len(deeds) == 28 and len(a["categories"]) == 7
      and all(len(x["tiers"]) == 4 for x in deeds.values()), (st, len(deeds)))
check("the day's claim is counted", deeds.get("faithful_attendance", {}).get("progress") == 1, deeds.get("faithful_attendance"))
check("every fourth tier gives a title", all(x["title"] and x["tiers"][3]["medal"] == "imperial" for x in deeds.values()),
      [x["id"] for x in deeds.values() if not x["title"]])
st, b = call("POST", "/v1/achievements/claim", {}, token=token)
check("a new lord has no deed to claim", st == 409 and code(b) == "nothing_to_claim", (st, b))
st, b = call("POST", "/v1/achievements/claim", {"id": "no_such_deed"}, token=token)
check("an unknown deed is refused", st == 404, (st, b))

print("\n== the boards ==")
for board, period in (("week_raids", "week"), ("season_renown", "season"), ("might", "all"),
                      ("week_arena", "week"), ("season_arena", "season")):
    st, v = call("GET", "/v1/leaderboards/" + board, token=token)
    ok = st == 200 and v.get("period") == period and len(v.get("boards", [])) == 11
    if period != "all":
        ok = ok and v.get("ends_in", 0) > 0 and len(v.get("rewards", [])) == 4 and v["rewards"][0]["lines"]
    check("%s: its period, end and prizes" % board, ok, (st, {k: v.get(k) for k in ("period", "ends_in", "rewards")}))

print("\n== the market and the store ==")
st, m = call("GET", "/v1/shop", token=token)
check("the market says its free rerolls", st == 200 and isinstance(m.get("free_rerolls"), int), (st, m.keys()))
st, g = call("GET", "/v1/store", token=token)
refill = next((x for x in g.get("goods", []) if x["id"] == "energy_refill"), {})
sale = h.get("kind") == "refill_discount" and h.get("active")
check("the refill says what a sale takes off", st == 200 and ((refill.get("regular_diamonds", 0) > refill.get("diamonds", 0))
      if sale else "regular_diamonds" not in refill), refill)

print()
if failures:
    print("%d FAILED" % len(failures))
    sys.exit(1)
print("all live-ops checks passed against", BASE)
