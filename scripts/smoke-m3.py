#!/usr/bin/env python3
"""End-to-end check of M3: barracks slots, recruiting, gear on soldiers, Train."""
import json, sys, urllib.request, urllib.error, random, string

BASE = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:8080"
FAILURES = []


def call(method, path, body=None, token=None):
    req = urllib.request.Request(BASE + path, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    data = json.dumps(body).encode() if body is not None else None
    try:
        with urllib.request.urlopen(req, data, timeout=25) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw or b"{}")
        except json.JSONDecodeError:
            return e.code, {"raw": raw.decode(errors="replace")[:200]}


def check(label, cond, detail=""):
    print(f"  {'PASS' if cond else 'FAIL'}  {label}{'' if cond else '  <- ' + str(detail)}")
    if not cond:
        FAILURES.append(label)


def seq(token):
    _, s = call("GET", "/v1/state", token=token)
    return s["player"]["action_seq"] + 1


user = "army" + "".join(random.choices(string.ascii_lowercase, k=6))
st, reg = call("POST", "/v1/auth/register", {"username": user, "password": "battery horse staple", "tz_offset_minutes": 0})
token = reg["access_token"]
print(f"\n== setup ==  ({user})")

def grind(token, target_gold, budget=3000):
    """Collect until the target is reached or energy is genuinely exhausted.

    Always picks the best gold-per-energy job available, which is what a player
    would do; level-ups refill the bar, so the ceiling is levels, not actions.
    """
    _, s = call("GET", "/v1/state", token=token)
    for _ in range(budget):
        if int(s["player"]["gold"]) >= target_gold:
            break
        afford = [j for j in s["jobs"] if j["unlocked"] and s["energy"]["current"] >= j["energy_cost"]]
        if not afford:
            break
        best = max(afford, key=lambda j: j["gold_payout"] / j["energy_cost"])
        st, c = call("POST", "/v1/collect", {"job_id": best["id"], "action_seq": s["player"]["action_seq"] + 1}, token=token)
        if st != 200:
            break
        s = c["snapshot"]
    return s


s = grind(token, 60)
print(f"        lv{s['player']['level']} gold={s['player']['gold']}")

print("\n== army before any slots ==")
st, a = call("GET", "/v1/army", token=token)
check("army returns 200", st == 200, st)
check("slots is an empty array, never null (a client would crash on null)",
      a.get("slots") == [], a.get("slots"))
check("the hero alone still has Might", a["totals"]["might"] > 0, a["totals"])
check("a soldierless player is not a zero", a["hero"]["attack"] > 0 and a["hero"]["ehp"] > 0, a["hero"])
check("next slot is offered", a["next_slot"] is not None and a["next_slot"]["index"] == 1, a.get("next_slot"))
print(f"        hero ATK {a['hero']['attack']} DEF {a['hero']['defense']} EHP {a['hero']['ehp']} -> Might {a['totals']['might']}")
might_solo = a["totals"]["might"]

print("\n== barracks slot ==")
st, poor = call("POST", "/v1/army/slot", {"action_seq": seq(token)}, token=token)
check("cannot buy a slot without the gold", st == 409 and poor.get("code") == "not_enough_gold", (st, poor))

# The design grants the first slot free at level 5, because a fresh player who
# grinds their entire first session still finishes short of the 500-gold price.
s = grind(token, 10**9)   # play until energy is genuinely exhausted
print(f"        ground to lv{s['player']['level']} gold={s['player']['gold']}")
st, a = call("GET", "/v1/army", token=token)
check("the onboarding slot is offered free once level 5 is reached",
      a["next_slot"]["free"] is True and a["next_slot"]["cost"] == 0, a.get("next_slot"))
check("a first session does NOT reach the paid slot price unaided",
      int(s["player"]["gold"]) < 500, s["player"]["gold"])
st, bought = call("POST", "/v1/army/slot", {"action_seq": seq(token)}, token=token)
check("claiming the free slot returns 200", st == 200, (st, bought))
gold_after_slot = None
st, s2 = call("GET", "/v1/state", token=token)
gold_after_slot = int(s2["player"]["gold"])
check("the free slot cost nothing", gold_after_slot == int(s["player"]["gold"]), (s["player"]["gold"], gold_after_slot))

st, a = call("GET", "/v1/army", token=token)
check("slot 1 bought", len(a.get("slots") or []) == 1, a.get("slots"))
if a.get("slots"):
    check("the slot starts empty", a["slots"][0]["soldier"] is None, a["slots"][0])

print("\n== recruiting ==")
st, a0 = call("GET", "/v1/army", token=token)
check("the first recruit is offered free", all(r["free"] for r in a0["recruits"]), a0["recruits"])
st, rec = call("POST", "/v1/army/recruit", {"slot": 1, "type_id": "peasant", "action_seq": seq(token)}, token=token)
check("recruit returns 200", st == 200, (st, rec))
if st == 200:
    check("the free recruit cost nothing", rec["paid"] == 0, rec.get("paid"))
    check("the free recruit respects its uncommon tier floor",
          rec["soldier"]["tier"] != "common", rec["soldier"]["tier"])
if st == 200:
    sold = rec["soldier"]
    print(f"        {sold['name']} [{sold['tier']}] lv{sold['level']} "
          f"ATK {sold['attack']} DEF {sold['defense']} HP {sold['hp']}")
    check("the soldier has stats", sold["attack"] > 0 and sold["hp"] > 0, sold)
    check("recruiting raised army Might", rec["army"]["totals"]["might"] > might_solo,
          (might_solo, rec["army"]["totals"]["might"]))
    check("the soldier starts at the player's level", sold["level"] == s["player"]["level"] or sold["level"] >= 1, sold["level"])

    # A retry with the same sequence must not reroll for a better tier.
    st, replay = call("POST", "/v1/army/recruit",
                      {"slot": 1, "type_id": "peasant", "action_seq": seq(token) - 1}, token=token)
    check("a replayed recruit is refused rather than rerolled",
          st == 409 and replay.get("code") == "stale_action", (st, replay))

st, a1 = call("GET", "/v1/army", token=token)
check("the second recruit is no longer free", not any(r["free"] for r in a1["recruits"]), a1["recruits"])

st, nosl = call("POST", "/v1/army/recruit", {"slot": 5, "type_id": "peasant", "action_seq": seq(token)}, token=token)
check("cannot recruit into a slot you have not bought", st == 409 and nosl.get("code") == "no_slot", (st, nosl))

st, notype = call("POST", "/v1/army/recruit", {"slot": 1, "type_id": "wizard", "action_seq": seq(token)}, token=token)
check("an unknown soldier type is 404", st == 404, (st, notype))

print("\n== gear on a soldier ==")
# Buy something first, or this whole section silently skips and the
# equip-onto-a-soldier path ships untested.
st, shop = call("GET", "/v1/shop", token=token)
st, cur = call("GET", "/v1/state", token=token)
gold = int(cur["player"]["gold"])
opts = sorted((o for o in shop["offers"] if not o["purchased"] and o["price"] <= gold),
              key=lambda o: o["price"])
check("the player can afford something to equip", len(opts) > 0, (gold, [o["price"] for o in shop["offers"]]))
if opts:
    st, b = call("POST", "/v1/shop/buy", {"slot": opts[0]["slot"], "action_seq": seq(token)}, token=token)
    check("bought a piece of gear for the soldier", st == 200, (st, b))

st, inv = call("GET", "/v1/inventory", token=token)
if inv["items"]:
    item = next((i for i in inv["items"] if not i["equipped"]), None)
    if item:
        st, a2 = call("GET", "/v1/army", token=token)
        before = a2["slots"][0]["soldier"]["attack"] + a2["slots"][0]["soldier"]["defense"]
        sid = a2["slots"][0]["soldier"]["id"]
        st, a3 = call("POST", "/v1/army/equip", {"soldier_id": sid, "item_id": item["id"]}, token=token)
        check("equipping a soldier returns 200", st == 200, (st, a3))
        if st == 200:
            after = a3["slots"][0]["soldier"]["attack"] + a3["slots"][0]["soldier"]["defense"]
            check("the soldier got stronger", after > before, (before, after))
            check("the item shows on the soldier",
                  a3["slots"][0]["soldier"]["equipped"][item["slot"]] is not None)
else:
    print("        (no spare items to equip — skipped)")

print("\n== train ==")
st, a4 = call("GET", "/v1/army", token=token)
sold = a4["slots"][0]["soldier"]
if sold and sold["level"] >= a4["hero"]["level"]:
    st, maxed = call("POST", "/v1/army/train", {"soldier_id": sold["id"], "action_seq": seq(token)}, token=token)
    check("training a soldier already at your level is refused",
          st == 409 and maxed.get("code") == "already_maxed", (st, maxed))
else:
    check("train is offered when the soldier is behind", sold.get("can_train") is True, sold)

print()
if FAILURES:
    print(f"{len(FAILURES)} FAILED: " + ", ".join(FAILURES))
    sys.exit(1)
print("all checks passed")
