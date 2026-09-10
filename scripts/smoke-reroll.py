#!/usr/bin/env python3
"""End-to-end check of the Army's REROLL: a soldier's tier drawn again for gold.

    python3 scripts/smoke-reroll.py [BASE]

Levels and gold come from cmd/devgrant, which refuses to run against a
production-flagged environment and reads .env for the database.
"""
import json, os, random, string, subprocess, sys, urllib.error, urllib.request

BASE = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:8080"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FAILURES = []
PW = "battery horse staple"
TIERS = ["common", "uncommon", "rare", "epic", "legendary", "mystic", "special"]


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


def grant(user, level=0, gold=0):
    env = dict(os.environ)
    for line in open(os.path.join(ROOT, ".env")):
        line = line.strip()
        if "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            env[k] = v.strip().strip("'\"")
    subprocess.run(["go", "run", "./cmd/devgrant", "-user", user,
                    "-level", str(level), "-gold", str(gold)],
                   cwd=os.path.join(ROOT, "server"), env=env,
                   capture_output=True, check=True)


def seq(token):
    _, s = call("GET", "/v1/state", token=token)
    return s["player"]["action_seq"] + 1


user = "roll" + "".join(random.choices(string.ascii_lowercase, k=6))
st, reg = call("POST", "/v1/auth/register", {"username": user, "password": PW, "tz_offset_minutes": 0})
check("register returns 201", st == 201, (st, reg))
token = reg["access_token"]
print(f"\n== setup ==  ({user})")

grant(user, level=30, gold=5_000_000)
st, _ = call("POST", "/v1/army/slot", {"action_seq": seq(token)}, token=token)
check("the first slot can be claimed", st == 200, st)
st, rec = call("POST", "/v1/army/recruit", {"slot": 1, "type_id": "gladiator", "action_seq": seq(token)}, token=token)
check("a gladiator is recruited", st == 200, (st, rec))
soldier = rec["soldier"]
sid = soldier["id"]
print(f"        a {soldier['tier']} gladiator, id {sid[:8]}")

st, army = call("GET", "/v1/army", token=token)
card = army["slots"][0]["soldier"]
check("the army quotes a reroll price for the soldier", card.get("reroll_cost", 0) > 0, card)
price = card["reroll_cost"]
gladiator = next(r for r in army["recruits"] if r["type_id"] == "gladiator")
check("a reroll costs less than a recruit and more than nothing",
      0 < price < gladiator["cost"], (price, gladiator["cost"]))

print("\n== rolling ==")
_, s = call("GET", "/v1/state", token=token)
gold = int(s["player"]["gold"])
tier = soldier["tier"]
seen = set()
for i in range(12):
    want = seq(token)
    st, r = call("POST", "/v1/army/reroll", {"soldier_id": sid, "action_seq": want}, token=token)
    if st != 200:
        check(f"roll {i + 1} returns 200", False, (st, r))
        break
    seen.add(r["soldier"]["tier"])
    if i == 0:
        check("the roll names the tier it replaced", r["tier_before"] == tier, (r["tier_before"], tier))
        check("it is the same soldier, slot and type",
              r["soldier"]["id"] == sid and r["soldier"]["type"] == "gladiator", r["soldier"])
        check("the tier is a real tier", r["soldier"]["tier"] in TIERS, r["soldier"]["tier"])
        check("the whole state comes back, so the client need not ask for it",
              isinstance(r.get("snapshot"), dict) and "player" in r["snapshot"], list(r.keys()))
        check("the price paid is the price quoted", r["paid"] == price, (r["paid"], price))
    check_gold = int(r["gold_left"])
    if check_gold != gold - r["paid"]:
        check(f"roll {i + 1}: gold fell by exactly what was paid", False, (gold, r["paid"], check_gold))
    if int(r["snapshot"]["player"]["gold"]) != check_gold:
        check(f"roll {i + 1}: the snapshot agrees with gold_left", False,
              (r["snapshot"]["player"]["gold"], check_gold))
    gold = check_gold
    tier = r["soldier"]["tier"]
    last_seq = want
print(f"        12 rolls drew {sorted(seen, key=TIERS.index)}; {gold:,} gold left")
check("twelve rolls did not all land on one tier", len(seen) > 1, seen)

st, again = call("POST", "/v1/army/reroll", {"soldier_id": sid, "action_seq": last_seq}, token=token)
check("a replayed request is refused, so a retry cannot roll again for free",
      st == 409 and again.get("code") == "stale_action", (st, again))

st, army = call("GET", "/v1/army", token=token)
check("the Army screen shows the tier the last roll left", army["slots"][0]["soldier"]["tier"] == tier,
      (army["slots"][0]["soldier"]["tier"], tier))

print("\n== refusals ==")
grant(user, gold=price - 1)
st, poor = call("POST", "/v1/army/reroll", {"soldier_id": sid, "action_seq": seq(token)}, token=token)
check("a player one gold short is refused", st == 409 and poor.get("code") == "not_enough_gold", (st, poor))
st, nobody = call("POST", "/v1/army/reroll",
                  {"soldier_id": "00000000-0000-0000-0000-000000000000", "action_seq": seq(token)}, token=token)
check("a soldier that is not yours is not found", st == 404, (st, nobody))
st, bad = call("POST", "/v1/army/reroll", {"soldier": sid, "action_seq": seq(token)}, token=token)
check("an unknown field is refused, not ignored", st == 400, (st, bad))

print()
if FAILURES:
    print(f"{len(FAILURES)} FAILED: " + ", ".join(FAILURES))
    sys.exit(1)
print("all checks passed")
