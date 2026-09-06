#!/usr/bin/env python3
"""Server-wide events: they reach players, they can be ended, and they are honest.

A boost feeds the same bucket as a family upgrade or job mastery, so it shares
that bucket's cap and can never take the game somewhere its own upgrades could
not already reach. What has to be true end to end:

  * a live event changes what a player is paid
  * revoking it puts things back
  * the number ADVERTISED on the jobs list, the number REPORTED in the collect
    response, and the amount the experience bar actually moves are the same
    number -- they were three different numbers, because economy.Collect returns
    raw experience and AwardXP applies the bucket later
  * energy regeneration cannot be boosted at all
"""
import json, sys, time, urllib.error, urllib.request

ADMIN = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8081"
GAME = sys.argv[2] if len(sys.argv) > 2 else "http://127.0.0.1:8080"
ADMIN_USER = sys.argv[3] if len(sys.argv) > 3 else "claude-review"
ADMIN_PASS = sys.argv[4] if len(sys.argv) > 4 else None
failures = []


def call(base, method, path, body=None, token=None):
    req = urllib.request.Request(
        base + path, method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"content-type": "application/json",
                 **({"authorization": "Bearer " + token} if token else {})})
    try:
        with urllib.request.urlopen(req, timeout=30) as f:
            return f.status, json.load(f)
    except urllib.error.HTTPError as e:
        return e.code, json.load(e)


def check(name, ok, detail=""):
    print(("  PASS  " if ok else "  FAIL  ") + name + ("" if ok else f"  <- {detail}"))
    if not ok:
        failures.append(name)


if not ADMIN_PASS:
    print("usage: smoke-boosts.py <admin-url> <game-url> <admin-user> <admin-pass>")
    sys.exit(2)

st, r = call(ADMIN, "POST", "/login", {"username": ADMIN_USER, "password": ADMIN_PASS})
if st != 200:
    print("cannot sign in to the admin API:", r)
    sys.exit(2)
tok = r["token"]

# Start from a clean slate: anything already running would confuse the deltas.
for b in call(ADMIN, "GET", "/boosts", token=tok)[1]["boosts"]:
    if b["live"]:
        call(ADMIN, "POST", "/boosts/revoke", {"id": b["id"]}, tok)

user = "bst%d" % (int(time.time() * 1000) % 10_000_000)
pt = call(GAME, "POST", "/v1/auth/register",
          {"username": user, "password": "battery horse staple"})[1]["access_token"]


def first_job():
    s = call(GAME, "GET", "/v1/state", token=pt)[1]
    return [j for j in s["jobs"] if j["unlocked"]][0], s["player"]


print("== what cannot be boosted ==")
st, r = call(ADMIN, "POST", "/boosts",
             {"bucket": "energy_regen_bp", "amount_bp": 5000, "hours": 2, "note": "x"}, tok)
check("energy regen is refused", st == 400, (st, r.get("message")))
check("and says why", "cannot be driven" in r.get("message", ""), r.get("message"))

print("\n== an event reaches players ==")
base_job, _ = first_job()
st, _ = call(ADMIN, "POST", "/boosts",
             {"bucket": "collect_income_bp", "amount_bp": 5000, "hours": 2, "note": "smoke"}, tok)
check("the event is created", st == 200, st)
boosted_job, _ = first_job()
check("job gold went up", boosted_job["gold_payout"] > base_job["gold_payout"],
      (base_job["gold_payout"], boosted_job["gold_payout"]))

print("\n== advertised, reported and awarded agree ==")
call(ADMIN, "POST", "/boosts",
     {"bucket": "xp_bp", "amount_bp": 10000, "hours": 2, "note": "smoke"}, tok)
job, player = first_job()
before_xp = player["xp"]
st, res = call(GAME, "POST", "/v1/collect",
               {"job_id": job["id"], "action_seq": player["action_seq"] + 1}, pt)
check("the collect succeeds", st == 200, st)
_, after = first_job()
moved = after["xp"] - before_xp
check("the list advertises what the response reports",
      job["xp_payout"] == res["xp_gained"], (job["xp_payout"], res["xp_gained"]))
check("and the bar moves by exactly that",
      res["xp_gained"] == moved, (res["xp_gained"], moved))

print("\n== revoking puts it back ==")
for b in call(ADMIN, "GET", "/boosts", token=tok)[1]["boosts"]:
    if b["live"]:
        call(ADMIN, "POST", "/boosts/revoke", {"id": b["id"]}, tok)
ended_job, _ = first_job()
check("job gold is back to normal", ended_job["gold_payout"] == base_job["gold_payout"],
      (base_job["gold_payout"], ended_job["gold_payout"]))
check("a revoked event is kept, not deleted",
      any(b["revoked"] for b in call(ADMIN, "GET", "/boosts", token=tok)[1]["boosts"]))

print()
if failures:
    print(f"{len(failures)} FAILED: " + ", ".join(failures))
    sys.exit(1)
print("all checks passed")
