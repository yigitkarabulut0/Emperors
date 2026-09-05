#!/usr/bin/env python3
"""End-to-end check of the M1 loop against a running server.

Exercises the things that are easy to get wrong and expensive to get wrong:
auth, the state snapshot, spending energy, levelling, idempotent retries, and
the server refusing actions it should refuse.

Usage: python3 scripts/smoke-m1.py [base_url]
"""
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
        with urllib.request.urlopen(req, data, timeout=20) as r:
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


user = "hero" + "".join(random.choices(string.ascii_lowercase, k=6))
PW = "battery horse staple"

print(f"\n== auth ==  ({user})")
st, reg = call("POST", "/v1/auth/register", {"username": user, "password": PW, "tz_offset_minutes": 180})
check("register returns 201", st == 201, (st, reg))
token, refresh = reg.get("access_token"), reg.get("refresh_token")

st, dup = call("POST", "/v1/auth/register", {"username": user.upper(), "password": PW, "tz_offset_minutes": 0})
check("duplicate username rejected case-insensitively", st == 409 and dup.get("code") == "username_taken", (st, dup))

st, weak = call("POST", "/v1/auth/register", {"username": "short" + user[:4], "password": "abc", "tz_offset_minutes": 0})
check("short password rejected", st == 400, (st, weak))

st, bad = call("POST", "/v1/auth/login", {"username": user, "password": "wrong password"})
check("wrong password rejected", st == 401 and bad.get("code") == "bad_credentials", (st, bad))

st, ok = call("POST", "/v1/auth/login", {"username": user.upper(), "password": PW})
check("login works and is case-insensitive", st == 200 and ok.get("access_token"), (st, ok))

st, _ = call("GET", "/v1/state")
check("state without a token is 401", st == 401, st)
st, _ = call("GET", "/v1/state", token="not-a-token")
check("state with a garbage token is 401", st == 401, st)

print("\n== refresh rotation ==")
st, r1 = call("POST", "/v1/auth/refresh", {"refresh_token": refresh})
check("refresh returns a new pair", st == 200 and r1.get("refresh_token") != refresh, (st, r1))
st, reuse = call("POST", "/v1/auth/refresh", {"refresh_token": refresh})
check("reusing a rotated refresh token is rejected", st == 401, (st, reuse))
st, chain = call("POST", "/v1/auth/refresh", {"refresh_token": r1.get("refresh_token")})
check("reuse detection burned the whole family", st == 401, (st, chain))

print("\n== state ==")
st, s = call("GET", "/v1/state", token=token)
check("state returns 200", st == 200, st)
p, e = s["player"], s["energy"]
print(f"        lv{p['level']} gold={p['gold']} xp={p['xp']}/{p['xp_to_next']} seq={p['action_seq']}")
print(f"        energy {e['current']}/{e['max']}, regen {e['regen_period_ms']}ms, full in {e['seconds_to_full']}s")
check("new player starts with a full bar", e["current"] == e["max"] > 0, e)
# The pool has to hold at least an hour of regeneration, or every minute a player
# spends away past the fill time is discarded and the regen rate stops reaching
# anyone who checks in less often than that. gameconfig.Validate blocks a publish
# that breaks this; asserting it here too catches a live server running an older
# published version.
check("the pool holds at least an hour of regen",
      e["max"] >= 3600 // (e["regen_period_ms"] // 1000),
      f'{e["max"]} max at one per {e["regen_period_ms"] // 1000}s')
unlocked = [j for j in s["jobs"] if j["unlocked"]]
check("exactly one job unlocked at level 1", len(unlocked) == 1, [j["id"] for j in unlocked])
check("locked jobs are still listed (so the ladder is visible)", len(s["jobs"]) == 15, len(s["jobs"]))
check("gold is serialised as a string (JS loses precision above 2^53)", isinstance(p["gold"], str), type(p["gold"]))

print("\n== collect ==")
job = unlocked[0]
seq = p["action_seq"] + 1
st, c = call("POST", "/v1/collect", {"job_id": job["id"], "action_seq": seq}, token=token)
check("collect returns 200", st == 200, (st, c))
check("gold matches the payout the snapshot advertised", c["gold_gained"] == job["gold_payout"], (c.get("gold_gained"), job["gold_payout"]))
after = c["snapshot"]
check("energy went down by the job cost", after["energy"]["current"] == e["current"] - job["energy_cost"], after["energy"])
check("gold went up", int(after["player"]["gold"]) == int(p["gold"]) + c["gold_gained"], after["player"]["gold"])

st, replay = call("POST", "/v1/collect", {"job_id": job["id"], "action_seq": seq}, token=token)
check("replaying the same action_seq is refused (no double spend)", st == 409 and replay.get("code") == "stale_action", (st, replay))

st, ahead = call("POST", "/v1/collect", {"job_id": job["id"], "action_seq": seq + 5}, token=token)
check("a sequence from the future is refused", st == 409, (st, ahead))

st, locked = call("POST", "/v1/collect", {"job_id": "dragon_hoard", "action_seq": seq + 1}, token=token)
check("collecting a locked job is refused", st == 403 and locked.get("code") == "job_locked", (st, locked))

st, nosuch = call("POST", "/v1/collect", {"job_id": "no_such_job", "action_seq": seq + 1}, token=token)
check("collecting an unknown job is 404", st == 404, (st, nosuch))

print("\n== grind to level up and drain energy ==")
seq += 1
levels, spent, gold0 = 0, 0, int(after["player"]["gold"])
snap = after
for _ in range(2000):
    if snap["energy"]["current"] < job["energy_cost"]:
        break
    st, c = call("POST", "/v1/collect", {"job_id": job["id"], "action_seq": seq}, token=token)
    if st != 200:
        check("grind loop stayed healthy", False, (st, c))
        break
    seq += 1
    spent += 1
    levels += c["levels_gained"]
    snap = c["snapshot"]

print(f"        {spent} collects, {levels} level-ups, now lv{snap['player']['level']}, "
      f"gold {gold0} -> {snap['player']['gold']}, energy {snap['energy']['current']}/{snap['energy']['max']}")
check("levelling happened", levels > 0, levels)
check("level-up refilled energy at some point", spent > 60, spent)
check("energy actually ran out (the loop was not capped)", snap["energy"]["current"] < job["energy_cost"], snap["energy"])

st, empty = call("POST", "/v1/collect", {"job_id": job["id"], "action_seq": seq}, token=token)
check("running out of energy is refused", st == 409 and empty.get("code") == "not_enough_energy", (st, empty))

st, s2 = call("GET", "/v1/state", token=token)
newly = [j for j in s2["jobs"] if j["unlocked"]]
check("levelling unlocked more jobs", len(newly) > 1, [j["id"] for j in newly])
mastered = [j for j in s2["jobs"] if j["collects"] >= 25]
if mastered:
    check("mastery bonus applied after 25 collects", mastered[0]["mastery_bonus_bp"] >= 500, mastered[0])

print()
if FAILURES:
    print(f"{len(FAILURES)} FAILED: " + ", ".join(FAILURES))
    sys.exit(1)
print("all checks passed")
