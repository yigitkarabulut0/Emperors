#!/usr/bin/env python3
"""End-to-end check of raiding as the Attack tab shows it.

    python3 scripts/smoke-attack.py https://91-107-215-32.sslip.io

What must hold, against the live API:
  - nobody under the Attack tab's level can raid or be raided;
  - the take the card promises is the take the raid pays;
  - a revenge row is drawn from the same fields as a target row, costs what it
    says, takes the rate it prints, and the strike it offers goes through;
  - a stored battle read back by the lord who was raided is told as their
    defence, with the gold that left their purse;
  - a level reached in a raid pays its diamonds.
"""
import json, os, subprocess, sys, random, string, urllib.request, urllib.error

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

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


def grind(token, reserve=0, budget=4000):
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


def grant(user, level=0, gold=0):
    """Sets a level with the local devgrant tool, as smoke-m6 does: a fresh
    account's energy runs out around level 8, and raids open at 10."""
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


def account(prefix):
    user = prefix + "".join(random.choices(string.ascii_lowercase, k=6))
    st, reg = call("POST", "/v1/auth/register", {"username": user, "password": "battery horse staple", "tz_offset_minutes": 0})
    if st not in (200, 201):
        print(f"cannot register {user}: {st} {reg.get('code', '')}")
        sys.exit(1)
    return user, reg["access_token"], reg["player_id"]


print("\n== setup ==")
a_user, A, a_id = account("rdr")
b_user, B, b_id = account("vic")
c_user, C, c_id = account("new")
sa = grind(A, reserve=60)
# The raider buys a soldier and puts every point into attack, so the raid on B
# is one they should win: a revenge token only exists after a raid that won.
call("POST", "/v1/army/slot", {"action_seq": seq(A)}, token=A)
call("POST", "/v1/army/recruit", {"slot": 1, "type_id": "peasant", "action_seq": seq(A)}, token=A)
pts = call("GET", "/v1/state", token=A)[1]["player"]["stat_points_unspent"]
if pts:
    call("POST", "/v1/stats/spend", {"energy": 0, "attack": pts, "defense": 0, "action_seq": seq(A)}, token=A)
sb = grind(B, reserve=30)
fight = next((s["unlock_level"] for s in sa["sections"] if s["id"] == "fight"), 1)
# Both lords are raised past the Attack tab's level, keeping the energy they
# held back. The lord who never grinds (C) stays at 1.
for u, t in ((a_user, A), (b_user, B)):
    grant(u, level=fight + 10)
sa = call("GET", "/v1/state", token=A)[1]
sb = call("GET", "/v1/state", token=B)[1]
la, lb = sa["player"]["level"], sb["player"]["level"]
print(f"        {a_user} lv{la}, {b_user} lv{lb}, {c_user} lv1; raids open at lv{fight}")

print("\n== the Attack tab's level is a rule ==")
st, r = call("POST", "/v1/attack", {"target_id": a_id, "action_seq": seq(C)}, token=C)
check("a lord under it cannot raid", st == 403 and r.get("code") == "level_too_low", (st, r))
if la >= fight:
    st, r = call("POST", "/v1/attack", {"target_id": c_id, "action_seq": seq(A)}, token=A)
    check("and cannot be raided", st == 409 and r.get("code") == "too_new_to_raid", (st, r))
    st, tv = call("GET", "/v1/attack/targets", token=A)
    check("no target on the list is under it", all(t["level"] >= fight for t in tv["targets"]),
          [t["level"] for t in tv["targets"]])
    check("every target row carries its rate and its cost",
          all(t.get("steal_rate_bp") == 300 and t.get("energy_cost", 0) > 0 for t in tv["targets"]),
          [(t.get("steal_rate_bp"), t.get("energy_cost")) for t in tv["targets"]])
else:
    print(f"        (the raider only reached lv{la}; the raid checks need lv{fight})")

if la < fight or lb < fight:
    print("\nSKIPPED the raid checks: the grind did not reach the Attack tab's level")
else:
    print("\n== the take is the take ==")
    # The raid follows the list by milliseconds, and the lords in this band are
    # bots and idle test accounts, so the purse the estimate was made from is
    # the purse the raid takes from.
    _, tv = call("GET", "/v1/attack/targets", token=A)
    if not tv["targets"]:
        print("        (nobody in the band this draw)")
    for t in tv["targets"][:2]:
        _, before = call("GET", "/v1/state", token=A)
        st, res = call("POST", "/v1/attack", {"target_id": t["player_id"], "action_seq": seq(A)}, token=A)
        if st != 200:
            check(f"raiding {t['name']} returns 200", False, (st, res))
            break
        check("the result is told from the raider's side", res.get("perspective") == "attacker", res.get("perspective"))
        if res["won"]:
            check("a won raid pays exactly the card's take",
                  res["gold_stolen"] == t["estimated_steal"], (res["gold_stolen"], t["estimated_steal"]))
            check("and says so from the purse's side", res["gold"] == res["gold_stolen"], (res["gold"], res["gold_stolen"]))
        else:
            check("a lost raid moves no gold of the raider's", res["gold"] == 0, res.get("gold"))
            check("and pays the defender a ransom", res["ransom_paid"] > 0, res.get("ransom_paid"))
        if res["snapshot"]["player"]["level"] > before["player"]["level"]:
            check("a level reached in a raid pays its diamonds",
                  res.get("diamonds_gained", 0) > 0 and
                  res["snapshot"]["player"]["diamonds"] > before["player"]["diamonds"],
                  (res.get("diamonds_gained"), before["player"]["diamonds"], res["snapshot"]["player"]["diamonds"]))
        if res["won"]:
            break

    print("\n== revenge ==")
    st, raid = call("POST", "/v1/attack", {"target_id": b_id, "action_seq": seq(A)}, token=A)
    check("the raider can hit the victim", st == 200, (st, raid))
    if st == 200 and not raid["won"]:
        print("        (the raid on the victim was lost, so no score was left to settle)")
    elif st == 200:
        _, tv = call("GET", "/v1/attack/targets", token=B)
        rows = [r for r in tv["revenge"] if r.get("player_id") == a_id]
        check("the victim is offered revenge on the raider", len(rows) == 1, tv["revenge"])
        if rows:
            r = rows[0]
            check("the row names the raider as a target row would",
                  r.get("name") == sa["player"]["username"] and r.get("level", 0) >= fight, r)
            check("with the raider's might and a take", r.get("might", 0) > 0 and r.get("estimated_steal", -1) >= 0, r)
            check("at the revenge rate", r.get("steal_rate_bp") == 400, r.get("steal_rate_bp"))
            check("at half the energy", 0 < r.get("energy_cost", 0) <= tv["energy_cost"] // 2 + 1,
                  (r.get("energy_cost"), tv["energy_cost"]))
            check("with the time left to answer", 0 < r.get("expires_in", 0) <= 86400, r.get("expires_in"))

        _, log = call("GET", "/v1/attack/history", token=B)
        top = log["entries"][0] if log["entries"] else {}
        check("the victim's history says they were raided",
              top.get("raided") is True and top.get("won") is False and top.get("gold") == -raid["gold_stolen"],
              (top, raid["gold_stolen"]))
        st, rep = call("GET", f"/v1/battles/{raid['battle_id']}", token=B)
        check("the stored battle is told as the victim's defence",
              st == 200 and rep.get("perspective") == "defender" and rep.get("won") is False
              and rep.get("gold") == -raid["gold_stolen"] and "events" in rep.get("replay", {}),
              (st, {k: rep.get(k) for k in ("perspective", "won", "gold")}))

        if rows:
            _, before = call("GET", "/v1/state", token=B)
            st, strike = call("POST", "/v1/attack", {"target_id": a_id, "revenge": True, "action_seq": seq(B)}, token=B)
            check("the strike the row offers goes through", st == 200 and strike.get("revenge") is True, (st, strike))
            if st == 200:
                levelled = strike["snapshot"]["player"]["level"] > before["player"]["level"]
                check("and costs what the row said",
                      levelled or before["energy"]["current"] - strike["snapshot"]["energy"]["current"] == rows[0]["energy_cost"],
                      (before["energy"]["current"], strike["snapshot"]["energy"]["current"], rows[0]["energy_cost"]))
                _, tv2 = call("GET", "/v1/attack/targets", token=B)
                check("and the score is settled", all(r.get("player_id") != a_id for r in tv2["revenge"]), tv2["revenge"])

# Leave nothing on the live rankings: the three test lords delete themselves.
for t in (A, B, C):
    call("POST", "/v1/account/delete", {"password": "battery horse staple"}, token=t)

print()
if FAILURES:
    print(f"{len(FAILURES)} FAILED: " + ", ".join(FAILURES))
    sys.exit(1)
print("all checks passed")
