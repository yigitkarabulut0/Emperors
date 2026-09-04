#!/usr/bin/env python3
"""End-to-end check of M3.5: the vertical slice — targets, battle, replay, shield."""
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
        with urllib.request.urlopen(req, data, timeout=30) as r:
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
    """Collect, keeping `reserve` energy back.

    Energy is a single pool shared by Collect and Attack — the owner's explicit
    design — so a player who spends every point collecting genuinely cannot
    raid. Holding some back is what a player does, and what this test must do.
    """
    _, s = call("GET", "/v1/state", token=token)
    for _ in range(budget):
        af = [j for j in s["jobs"] if j["unlocked"]
              and s["energy"]["current"] - j["energy_cost"] >= reserve]
        if not af:
            break
        best = max(af, key=lambda j: j["gold_payout"] / j["energy_cost"])
        st, c = call("POST", "/v1/collect", {"job_id": best["id"], "action_seq": s["player"]["action_seq"] + 1}, token=token)
        if st != 200:
            break
        s = c["snapshot"]
    return s


user = "raid" + "".join(random.choices(string.ascii_lowercase, k=6))
st, reg = call("POST", "/v1/auth/register", {"username": user, "password": "battery horse staple", "tz_offset_minutes": 0})
token = reg["access_token"]
print(f"\n== setup ==  ({user})")
# Keep enough back for two raids: attacking costs 6 + level/6.
s = grind(token, reserve=30)
call("POST", "/v1/army/slot", {"action_seq": seq(token)}, token=token)
call("POST", "/v1/army/recruit", {"slot": 1, "type_id": "peasant", "action_seq": seq(token)}, token=token)
st, a = call("GET", "/v1/army", token=token)
print(f"        lv{s['player']['level']} gold={s['player']['gold']} might={a['totals']['might']}")

st, cur = call("GET", "/v1/state", token=token)
check("energy was deliberately reserved for raiding", cur["energy"]["current"] >= 12, cur["energy"])

print("\n== stat points ==")
_, cur2 = call("GET", "/v1/state", token=token)
pts = cur2["player"]["stat_points_unspent"]
check("levelling granted stat points", pts > 0, pts)
st, bad = call("POST", "/v1/stats/spend", {"energy": 0, "attack": 0, "defense": 0, "action_seq": seq(token)}, token=token)
check("spending nothing is refused", st == 400, (st, bad))
st, greedy = call("POST", "/v1/stats/spend", {"energy": pts + 99, "attack": 0, "defense": 0, "action_seq": seq(token)}, token=token)
check("cannot spend points you do not have", st == 409 and greedy.get("code") == "no_stat_points", (st, greedy))
st, spent = call("POST", "/v1/stats/spend", {"energy": 0, "attack": pts, "defense": 0, "action_seq": seq(token)}, token=token)
check("spending stat points returns 200", st == 200, (st, spent))
if st == 200:
    check("the points were deducted", spent["player"]["stat_points_unspent"] == 0, spent["player"])
    check("attack went up", spent["player"]["stat_attack"] == cur2["player"]["stat_attack"] + pts, spent["player"])
    st, a2 = call("GET", "/v1/army", token=token)
    check("spending points raised army Might", a2["totals"]["might"] > a["totals"]["might"],
          (a["totals"]["might"], a2["totals"]["might"]))
    a = a2

print("\n== targets ==")
st, tv = call("GET", "/v1/attack/targets", token=token)
check("targets returns 200", st == 200, st)
check("a shortlist is offered, not a forced pairing", 0 < len(tv["targets"]) <= 3, len(tv.get("targets", [])))
check("energy cost is quoted up front", tv["energy_cost"] > 0, tv.get("energy_cost"))
check("my own Might is shown for comparison", tv["might"] > 0, tv.get("might"))
for t in tv["targets"]:
    print(f"        {t['name']:<24} lv{t['level']:<3} might {t['might']:>6}  steal ~{t['estimated_steal']}")
check("no target is myself", all(t["player_id"] != reg["player_id"] for t in tv["targets"]))
ratios = [t["might"] / max(tv["might"], 1) for t in tv["targets"]]
check("targets sit in a sane band around my Might",
      all(0.3 <= r <= 4.0 for r in ratios), [round(r, 2) for r in ratios])
check("at least one target is actually worth raiding",
      any(t["estimated_steal"] >= 10 for t in tv["targets"]),
      [t["estimated_steal"] for t in tv["targets"]])
# The list must not be all uphill fights: inside 0.85x-1.35x the win rate spans
# ~25%-87%, which is what makes choosing a target a decision.
in_band = [r for r in ratios if 0.85 <= r <= 1.35]
check("the shortlist offers winnable fights, not only stronger foes",
      len(in_band) > 0, [round(r, 2) for r in ratios])

print("\n== the raid ==")
# Pick the most valuable target, which is what a player would do.
target = max(tv["targets"], key=lambda t: t["estimated_steal"])
_, before = call("GET", "/v1/state", token=token)
st, res = call("POST", "/v1/attack", {"target_id": target["player_id"], "action_seq": seq(token)}, token=token)
check("attack returns 200", st == 200, (st, res))
if st == 200:
    rep = res["replay"]
    print(f"        {'WON' if res['won'] else 'LOST'} in {rep['rounds']} rounds, "
          f"{len(rep['events'])} events, stole {res['gold_stolen']}, ransom {res['ransom_paid']}, +{res['xp_gained']} xp")
    check("the replay names a winner", rep["winner"] in ("a", "d"), rep.get("winner"))
    check("fortune was rolled for both sides",
          rep["fortune_a_bp"] > 0 and rep["fortune_d_bp"] > 0, (rep.get("fortune_a_bp"), rep.get("fortune_d_bp")))
    check("the replay has events to animate", len(rep["events"]) > 0, len(rep.get("events", [])))
    check("both armies are frozen into the replay",
          len(rep["attacker"]["units"]) > 0 and len(rep["defender"]["units"]) > 0)
    check("energy was spent", res["snapshot"]["energy"]["current"] == before["energy"]["current"] - tv["energy_cost"],
          (before["energy"]["current"], res["snapshot"]["energy"]["current"], tv["energy_cost"]))
    check("xp was awarded", res["xp_gained"] > 0, res.get("xp_gained"))
    if res["won"]:
        check("winning moved gold when the target had any",
              res["gold_stolen"] > 0 or target["estimated_steal"] == 0,
              (res.get("gold_stolen"), target["estimated_steal"]))
        check("the attacker's gold went up by the steal",
              int(res["snapshot"]["player"]["gold"]) == int(before["player"]["gold"]) + res["gold_stolen"])
    else:
        check("losing costs no gold, only energy",
              int(res["snapshot"]["player"]["gold"]) == int(before["player"]["gold"]),
              (before["player"]["gold"], res["snapshot"]["player"]["gold"]))
        check("the defender collects a ransom", res["ransom_paid"] > 0, res.get("ransom_paid"))

print("\n== protection and cooldown ==")
st, again = call("POST", "/v1/attack", {"target_id": target["player_id"], "action_seq": seq(token)}, token=token)
check("the same target cannot be raided again immediately",
      st == 409 and again.get("code") in ("on_cooldown", "shielded"), (st, again))

st, self_ = call("POST", "/v1/attack", {"target_id": reg["player_id"], "action_seq": seq(token)}, token=token)
check("you cannot attack yourself", st == 400 and self_.get("code") == "self_attack", (st, self_))

st, tv2 = call("GET", "/v1/attack/targets", token=token)
check("the raided target drops off the list",
      all(t["player_id"] != target["player_id"] for t in tv2["targets"]),
      [t["name"] for t in tv2["targets"]])

print("\n== a second raid still works ==")
if tv2["targets"]:
    st, res2 = call("POST", "/v1/attack", {"target_id": tv2["targets"][0]["player_id"], "action_seq": seq(token)}, token=token)
    check("a different target can be raided", st == 200, (st, res2.get("code")))

print()
if FAILURES:
    print(f"{len(FAILURES)} FAILED: " + ", ".join(FAILURES))
    sys.exit(1)
print("all checks passed")
