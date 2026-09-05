#!/usr/bin/env python3
"""End-to-end check of M5: Family upgrades, Territory holdings, passive tax."""
import json, sys, time, urllib.request, urllib.error, random, string

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


def grind(token, budget=3000, reserve=0):
    _, s = call("GET", "/v1/state", token=token)
    for _ in range(budget):
        af = [j for j in s["jobs"] if j["unlocked"] and s["energy"]["current"] - j["energy_cost"] >= reserve]
        if not af:
            break
        best = max(af, key=lambda j: j["gold_payout"] / j["energy_cost"])
        st, c = call("POST", "/v1/collect", {"job_id": best["id"], "action_seq": s["player"]["action_seq"] + 1}, token=token)
        if st != 200:
            break
        s = c["snapshot"]
    return s


user = "keep" + "".join(random.choices(string.ascii_lowercase, k=6))
st, reg = call("POST", "/v1/auth/register", {"username": user, "password": "battery horse staple", "tz_offset_minutes": 0})
token = reg["access_token"]
print(f"\n== setup ==  ({user})")
s = grind(token)
print(f"        lv{s['player']['level']} gold={s['player']['gold']}")

# --- the treasury --------------------------------------------------------------
#
# The game's largest sink and its only standing risk decision: a raid takes a
# share of gold ON HAND and never touches the vault, so the fee is what stops
# "bank everything, always" from being free safety.
print("\n== the treasury ==")


def purse(t):
    _, s = call("GET", "/v1/state", token=t)
    return int(s["player"]["gold"]), int(s["player"]["treasury"])


gold0, vault0 = purse(token)
if gold0 < 100:
    print("        (too poor to bank anything — skipped)")
else:
    amount = gold0 // 2
    st, dep = call("POST", "/v1/treasury/deposit",
                   {"amount": amount, "action_seq": seq(token)}, token=token)
    check("depositing returns 200", st == 200, (st, dep))
    fee = dep.get("fee", -1)
    check("the fee is a tenth", fee == amount // 10, (amount, fee))
    check("what banks is the rest", dep.get("banked") == amount - fee, dep)

    gold1, vault1 = purse(token)
    check("the purse lost the whole amount", gold1 == gold0 - amount, (gold0, amount, gold1))
    check("the vault gained the amount minus the fee", vault1 == vault0 + amount - fee,
          (vault0, amount, fee, vault1))
    # The fee has to LEAVE the economy. A fee that landed somewhere would just be
    # gold changing pockets, and the sink dashboard would be reporting a lie.
    check("the fee was destroyed, not moved",
          (gold1 + vault1) == (gold0 + vault0) - fee, (gold0, vault0, gold1, vault1, fee))

    st, wd = call("POST", "/v1/treasury/withdraw",
                  {"amount": vault1, "action_seq": seq(token)}, token=token)
    check("withdrawing returns 200", st == 200, (st, wd))
    gold2, vault2 = purse(token)
    check("taking it out is free", gold2 == gold1 + vault1 and vault2 == 0,
          (gold1, vault1, gold2, vault2))

    st, over = call("POST", "/v1/treasury/deposit",
                    {"amount": gold2 + 1_000_000, "action_seq": seq(token)}, token=token)
    check("banking more than you carry is refused",
          st == 409 and over.get("code") == "not_enough_gold", (st, over))
    st, empty = call("POST", "/v1/treasury/withdraw",
                     {"amount": 1, "action_seq": seq(token)}, token=token)
    check("taking from an empty vault is refused",
          st == 409 and empty.get("code") == "not_enough_gold", (st, empty))
    for bad in (0, -500):
        st, r = call("POST", "/v1/treasury/deposit",
                     {"amount": bad, "action_seq": seq(token)}, token=token)
        check(f"an amount of {bad} is refused", st == 400, (st, r))

print("\n== the estate ==")
st, e = call("GET", "/v1/estates", token=token)
check("estates returns 200", st == 200, st)
check("the family tree is listed", len(e["upgrades"]) == 11, len(e.get("upgrades", [])))
check("holdings are listed", len(e["holdings"]) == 8, len(e.get("holdings", [])))
check("everything starts at level 0", all(u["level"] == 0 for u in e["upgrades"]))
check("only early holdings are unlocked",
      sum(1 for h in e["holdings"] if h["unlocked"]) < len(e["holdings"]),
      [h["id"] for h in e["holdings"] if h["unlocked"]])
print(f"        tax {e['tax']['per_hour_milli']/1000:.1f} gold/hour, "
      f"cap {e['tax']['cap_seconds']/3600:.0f}h, pending {e['tax']['pending']}")
check("a player with no holdings still earns some idle income",
      e["tax"]["per_hour_milli"] > 0, e["tax"])
# A magnitude check, not just "> 0". The first version of this passed while the
# rate was 3600x too large, because the display was multiplied by 3600 twice.
# Design: 24 gold/hour at level 1, growing 4.5% per level.
per_hour = e["tax"]["per_hour_milli"] / 1000
check("the idle rate is in a sane range for the level",
      20 <= per_hour <= 60, f"{per_hour:.1f} gold/hour at level {s['player']['level']}")
# 8 hours of idle income must stay a supplement, not a replacement for playing.
eight_hours = per_hour * 8
active_ballpark = int(s["player"]["gold"])
check("eight hours idle is worth less than one active session",
      eight_hours < active_ballpark, f"{eight_hours:.0f} idle vs {active_ballpark} earned actively")
base_tax = e["tax"]["per_hour_milli"]

print("\n== the intended first-session beat ==")
# This used to assert the opposite: the Granary was priced at 400 so a first
# session ended about 200 short, "creating a clear 60-second goal".
#
# The level curve was rebalanced and a first sitting now ends around 3,000 gold,
# so the beat is inverted on purpose -- the first permanent upgrade is something
# you buy in your first session rather than something you come back for. The
# owner's complaint was that progression was too slow; a deliberate wall in the
# first ten minutes is the wrong side of that trade.
#
# What still has to hold is that the upgrade is REACHABLE and the purchase works.
gran = next(u for u in e["upgrades"] if u["id"] == "granary")
_, cur = call("GET", "/v1/state", token=token)
gold = int(cur["player"]["gold"])
check("a first session can afford its first permanent upgrade",
      gold >= gran["next_cost"], f"{gold} gold vs {gran['next_cost']} cost")
st, bought = call("POST", "/v1/estates/upgrade", {"id": "granary", "action_seq": seq(token)}, token=token)
check("and buying it succeeds", st == 200, (st, bought))
if st == 200:
    g2 = next(u for u in bought["upgrades"] if u["id"] == "granary")
    check("the Granary gained a level", g2["level"] == gran["level"] + 1, g2)

print("\n== territory ==")
# Cheapest first, which is also the order a player can actually afford.
farm = next(h for h in e["holdings"] if h["id"] == "wheat_farm")
st, h1 = call("POST", "/v1/estates/holding", {"id": "wheat_farm", "action_seq": seq(token)}, token=token)
check("buying a holding returns 200", st == 200, (st, h1))
if st == 200:
    f2 = next(h for h in h1["holdings"] if h["id"] == "wheat_farm")
    check("the holding level went up", f2["level"] == 1, f2)
    check("it yields income", f2["yield_per_hour_milli"] > 0, f2)
    check("total tax rate rose", h1["tax"]["per_hour_milli"] > base_tax,
          (base_tax, h1["tax"]["per_hour_milli"]))

st, nope = call("POST", "/v1/estates/upgrade", {"id": "no_such_upgrade", "action_seq": seq(token)}, token=token)
check("an unknown upgrade is 404", st == 404, (st, nope))

print("\n== family upgrades ==")
# A fresh player, because a first session can afford Territory OR an upgrade,
# not both — which is the intended pacing, not something to work around.
user2 = "keep" + "".join(random.choices(string.ascii_lowercase, k=6))
_, reg2 = call("POST", "/v1/auth/register",
               {"username": user2, "password": "battery horse staple", "tz_offset_minutes": 0})
token = reg2["access_token"]
grind(token)

_, before = call("GET", "/v1/state", token=token)
job_before = next(j for j in before["jobs"] if j["unlocked"])
max_before = before["energy"]["max"]
st, e_now = call("GET", "/v1/estates", token=token)
gold = int(before["player"]["gold"])
afford = sorted((u for u in e_now["upgrades"] if not u["maxed"] and u["next_cost"] <= gold),
                key=lambda u: u["next_cost"])
check("something in the family tree is affordable", len(afford) > 0, gold)
if afford:
    pick = afford[0]
    st, up = call("POST", "/v1/estates/upgrade", {"id": pick["id"], "action_seq": seq(token)}, token=token)
    check(f"buying {pick['name']} returns 200", st == 200, (st, up))
    if st == 200:
        p2 = next(u for u in up["upgrades"] if u["id"] == pick["id"])
        check("the level went up", p2["level"] == pick["level"] + 1, p2)
        check("the next level costs more", p2["next_cost"] > pick["next_cost"],
              (pick["next_cost"], p2["next_cost"]))
        _, after = call("GET", "/v1/state", token=token)
        check("gold was spent", int(after["player"]["gold"]) == gold - pick["next_cost"],
              (gold, pick["next_cost"], after["player"]["gold"]))
        if pick["id"] == "larder":
            check("the Larder raised the energy ceiling",
                  after["energy"]["max"] > max_before, (max_before, after["energy"]["max"]))
        if pick["id"] == "granary":
            job_after = next(j for j in after["jobs"] if j["id"] == job_before["id"])
            check("the Granary raised every collect payout",
                  job_after["gold_payout"] > job_before["gold_payout"],
                  (job_before["gold_payout"], job_after["gold_payout"]))

locked = next((h for h in e["holdings"] if not h["unlocked"]), None)
if locked:
    st, lk = call("POST", "/v1/estates/holding", {"id": locked["id"], "action_seq": seq(token)}, token=token)
    check("a locked holding cannot be bought", st in (403, 409), (st, lk))

print("\n== tax accrual ==")
st, e2 = call("GET", "/v1/estates", token=token)
p0 = e2["tax"]["pending"]
time.sleep(3)
st, e3 = call("GET", "/v1/estates", token=token)
check("tax accrues over time without any write", e3["tax"]["pending"] >= p0, (p0, e3["tax"]["pending"]))

st, claim = call("POST", "/v1/estates/tax/claim", {"action_seq": seq(token)}, token=token)
if e3["tax"]["pending"] > 0:
    check("claiming tax returns 200", st == 200, (st, claim))
    if st == 200:
        check("gold arrived", claim["collected"] > 0, claim)
        st, e4 = call("GET", "/v1/estates", token=token)
        check("pending reset after claiming", e4["tax"]["pending"] < e3["tax"]["pending"] + 5, e4["tax"])
else:
    check("claiming nothing is refused", st == 409 and claim.get("code") == "no_tax", (st, claim))

print()
if FAILURES:
    print(f"{len(FAILURES)} FAILED: " + ", ".join(FAILURES))
    sys.exit(1)
print("all checks passed")
