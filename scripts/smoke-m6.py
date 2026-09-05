#!/usr/bin/env python3
"""End-to-end check of M6: kingdoms, roles, donations, upgrades, reputation.

Founding needs level 20 and 250,000 gold, which no test can grind to, so this
uses cmd/devgrant — a local-only tool that refuses to run against production.
"""
import json, subprocess, sys, urllib.request, urllib.error, random, string, os

BASE = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:8080"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FAILURES = []
PW = "battery horse staple"


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


def register(name):
    st, r = call("POST", "/v1/auth/register", {"username": name, "password": PW, "tz_offset_minutes": 0})
    if st != 201:
        st, r = call("POST", "/v1/auth/login", {"username": name, "password": PW})
    return r["access_token"], r["player_id"]


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


sfx = "".join(random.choices(string.ascii_lowercase, k=5))
king_name, vassal_name, outsider_name = "king" + sfx, "vass" + sfx, "outs" + sfx
king, king_id = register(king_name)
vassal, vassal_id = register(vassal_name)
outsider, outsider_id = register(outsider_name)
print(f"\n== setup ==  ({king_name}, {vassal_name}, {outsider_name})")

print("\n== founding ==")
st, kv = call("GET", "/v1/kingdom", token=king)
check("kingdom endpoint returns 200", st == 200, st)
check("a landless player is not in a kingdom", kv["in_kingdom"] is False, kv.get("in_kingdom"))
check("the founding price is advertised", kv["found_cost"] == 250000 and kv["found_level"] == 20, kv)

st, poor = call("POST", "/v1/kingdom/found",
                {"name": "House " + sfx, "tag": sfx[:3].upper(), "action_seq": seq(king)}, token=king)
check("a low-level player cannot found one", st == 403 and poor.get("code") == "level_too_low", (st, poor))

grant(king_name, level=20, gold=300000)
st, poor2 = call("POST", "/v1/kingdom/found", {"name": "X", "tag": "AB", "action_seq": seq(king)}, token=king)
check("a too-short name is refused", st == 400, (st, poor2))

st, kv = call("POST", "/v1/kingdom/found",
              {"name": "House " + sfx, "tag": sfx[:3].upper(), "action_seq": seq(king)}, token=king)
check("founding returns 200", st == 200, (st, kv))
if st != 200:
    print("cannot continue without a kingdom"); sys.exit(1)

kid = kv["kingdom"]["id"]
print(f"        {kv['kingdom']['name']} [{kv['kingdom']['tag']}] "
      f"lv{kv['kingdom']['level']} cap {kv['kingdom']['member_cap']}")
check("the founder is king", kv["me"]["role"] == "king", kv["me"])
check("the treasury starts empty", kv["kingdom"]["treasury"] == "0", kv["kingdom"])
_, ks = call("GET", "/v1/state", token=king)
check("the founding cost was paid", int(ks["player"]["gold"]) == 50000, ks["player"]["gold"])

st, dup = call("POST", "/v1/kingdom/found",
               {"name": "House " + sfx, "tag": "ZZ", "action_seq": seq(king)}, token=king)
check("you cannot found a second kingdom", st == 409 and dup.get("code") == "already_in_kingdom", (st, dup))

# Invite takes a player UUID, and until now nothing turned a name into one --
# so a founded kingdom was a dead end: you sat in it alone and no one could join.
print("\n== finding someone to invite ==")
st, found = call("GET", "/v1/kingdom/search?q=" + outsider_name[:6], token=king)
check("search returns 200", st == 200, st)
names = [p["name"] for p in found.get("players", [])]
check("it finds the player by the start of their name", outsider_name in names, names)
hit = next((p for p in found["players"] if p["name"] == outsider_name), {})
check("the result carries an id to invite with", bool(hit.get("player_id")), hit)
check("and a face and a level to recognise them by",
      bool(hit.get("avatar")) and hit.get("level", 0) >= 1, hit)
check("it says whether they already hold a banner", "in_kingdom" in hit, hit)

st, tiny = call("GET", "/v1/kingdom/search?q=a", token=king)
check("a one-letter search returns nothing, so the roster cannot be enumerated",
      tiny.get("players") == [], tiny)
st, bots = call("GET", "/v1/kingdom/search?q=bot_", token=king)
check("bots are not offered — they exist to fill the Attack tab and cannot accept",
      bots.get("players") == [], len(bots.get("players", [])))
st, me = call("GET", "/v1/kingdom/search?q=" + king_name[:6], token=king)
check("you cannot find yourself",
      king_name not in [p["name"] for p in me.get("players", [])],
      [p["name"] for p in me.get("players", [])])

print("\n== invitations ==")
st, no = call("POST", "/v1/kingdom/accept", {"kingdom_id": kid}, token=vassal)
check("you cannot join uninvited", st == 403 and no.get("code") == "not_invited", (st, no))

st, notallowed = call("POST", "/v1/kingdom/invite", {"player_id": outsider_id}, token=vassal)
check("a non-member cannot invite", st == 409 and notallowed.get("code") == "not_in_kingdom", (st, notallowed))

st, inv = call("POST", "/v1/kingdom/invite", {"player_id": vassal_id}, token=king)
check("the king can invite", st == 200, (st, inv))

st, vkv = call("GET", "/v1/kingdom", token=vassal)
check("the invite is visible to the invitee", len(vkv["invites"]) == 1, vkv.get("invites"))

st, joined = call("POST", "/v1/kingdom/accept", {"kingdom_id": kid}, token=vassal)
check("accepting works", st == 200 and joined["in_kingdom"], (st, joined.get("in_kingdom")))
check("the newcomer is a plain member", joined["me"]["role"] == "member", joined.get("me"))
check("the roster shows both", len(joined["members"]) == 2, joined.get("members"))

print("\n== ranks ==")
st, notking = call("POST", "/v1/kingdom/role", {"player_id": king_id, "role": "member"}, token=vassal)
check("a member cannot change ranks", st == 403 and notking.get("code") == "not_permitted", (st, notking))

st, promoted = call("POST", "/v1/kingdom/role", {"player_id": vassal_id, "role": "marshal"}, token=king)
check("the king can promote", st == 200, (st, promoted))
if st == 200:
    m = next(m for m in promoted["members"] if m["player_id"] == vassal_id)
    check("the promotion stuck", m["role"] == "marshal", m)

st, cannot_leave = call("POST", "/v1/kingdom/leave", {}, token=king)
check("the last king cannot abandon a populated kingdom",
      st == 409 and cannot_leave.get("code") == "last_king", (st, cannot_leave))

print("\n== donations ==")
grant(vassal_name, level=20, gold=200000)
st, kv2 = call("GET", "/v1/kingdom", token=vassal)
cap = kv2["me"]["daily_cap"]
check("a daily donation cap is set", cap == 20000 + 800 * 20, cap)

st, don = call("POST", "/v1/kingdom/donate", {"amount": 5000, "action_seq": seq(vassal)}, token=vassal)
check("donating returns 200", st == 200, (st, don))
if st == 200:
    check("the treasury grew", don["kingdom"]["treasury"] == "5000", don["kingdom"])
    check("the kingdom gained xp", don["kingdom"]["xp"] == 5000, don["kingdom"])
    check("the donor earned favour", don["me"]["favour"] == 50, don["me"])
    check("the daily total was recorded", don["me"]["donated_today"] == 5000, don["me"])

st, over = call("POST", "/v1/kingdom/donate", {"amount": cap * 2, "action_seq": seq(vassal)}, token=vassal)
check("an oversized donation is clamped to the cap, not refused", st == 200, (st, over))
if st == 200:
    check("the cap held", over["me"]["donated_today"] == cap, over["me"])
    check("nothing remains today", over["me"]["remaining_today"] == 0, over["me"])
st, blocked = call("POST", "/v1/kingdom/donate", {"amount": 100, "action_seq": seq(vassal)}, token=vassal)
check("further donations are refused once capped",
      st == 409 and blocked.get("code") == "donation_cap", (st, blocked))

print("\n== kingdom upgrades ==")
# One member's daily cap (36,000 at level 20) does not cover the first upgrade
# at 50,000. That is the design working: kingdom upgrades are a collective
# goal, not something one player buys alone. So the king donates too.
grant(king_name, gold=100000)
st, kdon = call("POST", "/v1/kingdom/donate", {"amount": cap, "action_seq": seq(king)}, token=king)
check("a second member's donation is needed to afford the first upgrade", st == 200, (st, kdon))

st, kv3 = call("GET", "/v1/kingdom", token=king)
gran = next(u for u in kv3["upgrades"] if u["id"] == "royal_granaries")
treasury = int(kv3["kingdom"]["treasury"])
check("the treasury holds both donations", treasury == cap * 2, (treasury, cap * 2))
check("one member alone could not have afforded it", cap < gran["next_cost"], (cap, gran["next_cost"]))
_, before_state = call("GET", "/v1/state", token=vassal)
# The most valuable unlocked job, not the first: Royal Granaries is +2%, and
# 2 gold x 1.02 floors straight back to 2. A percentage bonus is only observable
# on a payout with headroom.
job_before = max((j for j in before_state["jobs"] if j["unlocked"]), key=lambda j: j["gold_payout"])

st, up = call("POST", "/v1/kingdom/upgrade", {"id": "royal_granaries"}, token=king)
check("the king can buy a kingdom upgrade", st == 200, (st, up))
if st == 200:
    g = next(u for u in up["upgrades"] if u["id"] == "royal_granaries")
    check("the upgrade level rose", g["level"] == 1, g)
    check("the treasury paid for it", int(up["kingdom"]["treasury"]) == treasury - gran["next_cost"],
          (treasury, gran["next_cost"], up["kingdom"]["treasury"]))
    _, after_state = call("GET", "/v1/state", token=vassal)
    job_after = next(j for j in after_state["jobs"] if j["id"] == job_before["id"])
    check("EVERY member's collect income rose, not just the buyer's",
          job_after["gold_payout"] > job_before["gold_payout"],
          (job_before["gold_payout"], job_after["gold_payout"]))

st, notallowed2 = call("POST", "/v1/kingdom/upgrade", {"id": "royal_archives"}, token=outsider)
check("an outsider cannot spend the treasury",
      st == 409 and notallowed2.get("code") == "not_in_kingdom", (st, notallowed2))

print("\n== allies are not targets ==")
st, tv = call("GET", "/v1/attack/targets", token=king)
check("kingdom-mates never appear in the target list",
      all(t["player_id"] != vassal_id for t in tv["targets"]),
      [t["name"] for t in tv["targets"]])
st, ally = call("POST", "/v1/attack", {"target_id": vassal_id, "action_seq": seq(king)}, token=king)
check("and raiding one directly is refused",
      st == 403 and ally.get("code") == "same_kingdom", (st, ally))

print("\n== leaderboard ==")
st, lb = call("GET", "/v1/kingdom", token=outsider)
check("the leaderboard is public", len(lb["leaderboard"]) >= 1, len(lb.get("leaderboard", [])))
mine = next((k for k in lb["leaderboard"] if k["id"] == kid), None)
check("the new kingdom is listed", mine is not None, [k["name"] for k in lb["leaderboard"][:5]])

print()
if FAILURES:
    print(f"{len(FAILURES)} FAILED: " + ", ".join(FAILURES))
    sys.exit(1)
print("all checks passed")
