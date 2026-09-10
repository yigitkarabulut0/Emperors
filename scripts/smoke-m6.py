#!/usr/bin/env python3
"""End-to-end check of M6: kingdoms, roles, donations, upgrades, reputation,
and joining one without an invitation -- search, suggestions, open and
by-request kingdoms, removal and its cooldown, the crown handed on, and a
kingdom disbanding when its last lord leaves.

Founding needs level 20 and 250,000 gold, which no test can grind to, so this
uses cmd/devgrant — a local-only tool that refuses to run against production.
Everything it founds it disbands again at the end, so a run leaves no kingdom
behind to be suggested to real players.
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
rover_name = "rove" + sfx
king, king_id = register(king_name)
vassal, vassal_id = register(vassal_name)
outsider, outsider_id = register(outsider_name)
rover, rover_id = register(rover_name)
print(f"\n== setup ==  ({king_name}, {vassal_name}, {outsider_name}, {rover_name})")

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
# There is no daily cap any more: a lord gives the treasury whatever they have,
# and DonateGold's own WHERE clause is what refuses more than that.
grant(vassal_name, level=20, gold=200000)
st, don = call("POST", "/v1/kingdom/donate", {"amount": 5000, "action_seq": seq(vassal)}, token=vassal)
check("donating returns 200", st == 200, (st, don))
if st == 200:
    check("the treasury grew", don["kingdom"]["treasury"] == "5000", don["kingdom"])
    check("the kingdom gained xp", don["kingdom"]["xp"] == 5000, don["kingdom"])
    check("the donor earned favour", don["me"]["favour"] == 50, don["me"])
    check("the day's total was recorded", don["me"]["donated_today"] == 5000, don["me"])

st, big = call("POST", "/v1/kingdom/donate", {"amount": 60000, "action_seq": seq(vassal)}, token=vassal)
check("a large donation is accepted whole", st == 200, (st, big))
st, over = call("POST", "/v1/kingdom/donate", {"amount": 10**9, "action_seq": seq(vassal)}, token=vassal)
check("more gold than the lord has is refused", st == 409 and over.get("code") == "not_enough_gold", (st, over))

print("\n== kingdom upgrades ==")
st, kv3 = call("GET", "/v1/kingdom", token=king)
gran = next(u for u in kv3["upgrades"] if u["id"] == "royal_granaries")
treasury = int(kv3["kingdom"]["treasury"])
check("the treasury holds the donations", treasury == 65000, treasury)
check("it can afford the first granary", treasury >= gran["next_cost"], (treasury, gran["next_cost"]))
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
check("no kingdom on the table is empty", all(k["members"] > 0 for k in lb["leaderboard"]),
      [(k["name"], k["members"]) for k in lb["leaderboard"] if k["members"] == 0])

print("\n== the hall: finding a kingdom ==")
check("a lord with no kingdom is offered suggestions", isinstance(lb.get("recommended"), list), lb.keys())
check("every suggestion has a seat free",
      all(c["members"] < c["member_cap"] for c in lb["recommended"]),
      [(c["name"], c["members"], c["member_cap"]) for c in lb["recommended"]])
check("every suggestion says what can be done about it",
      all(c["action"] in ("join", "request") for c in lb["recommended"]),
      [c["action"] for c in lb["recommended"]])
check("they may join a kingdom now", lb["rejoin_in"] == 0, lb.get("rejoin_in"))

st, found = call("GET", "/v1/kingdoms/search?q=" + sfx, token=outsider)
check("kingdom search returns 200", st == 200, (st, found))
hit = next((c for c in found.get("kingdoms", []) if c["id"] == kid), None)
check("it finds the kingdom by part of its name", hit is not None, found)
if hit:
    check("an open kingdom offers JOIN", hit["action"] == "join" and hit["join_policy"] == "open", hit)
    check("the card names its king", hit["king"] == king_name, hit)
st, by_tag = call("GET", "/v1/kingdoms/search?q=" + sfx[:3], token=outsider)
check("an exact tag comes first", by_tag["kingdoms"] and by_tag["kingdoms"][0]["tag"].lower() == sfx[:3],
      [c["tag"] for c in by_tag.get("kingdoms", [])][:5])
st, pct = call("GET", "/v1/kingdoms/search?q=%25%25", token=outsider)
check("a percent sign is searched for, not treated as a wildcard", pct.get("kingdoms") == [], pct)
st, one = call("GET", "/v1/kingdoms/search?q=h", token=outsider)
check("a one-letter search finds nothing", one.get("kingdoms") == [], one)

print("\n== joining by request ==")
st, pol = call("POST", "/v1/kingdom/policy", {"policy": "request"}, token=vassal)
check("only the king chooses how the kingdom is joined", st == 403 and pol.get("code") == "not_permitted", (st, pol))
st, pol = call("POST", "/v1/kingdom/policy", {"policy": "closed"}, token=king)
check("an unknown policy is refused", st == 400 and pol.get("code") == "bad_policy", (st, pol))
st, pol = call("POST", "/v1/kingdom/policy", {"policy": "request"}, token=king)
check("the king can make the kingdom join by request",
      st == 200 and pol["kingdom"]["join_policy"] == "request", (st, pol.get("kingdom")))

st, asked = call("POST", "/v1/kingdom/join", {"kingdom_id": kid}, token=outsider)
check("joining a by-request kingdom stores a request", st == 200 and asked.get("result") == "requested"
      and asked["in_kingdom"] is False, (st, asked.get("result"), asked.get("in_kingdom")))
st, twice = call("POST", "/v1/kingdom/join", {"kingdom_id": kid}, token=outsider)
check("asking twice is refused", st == 409 and twice.get("code") == "already_requested", (st, twice))
st, sneak = call("POST", "/v1/kingdom/accept", {"kingdom_id": kid}, token=outsider)
check("a request is not an invitation: /accept cannot seat its sender",
      st == 403 and sneak.get("code") == "not_invited", (st, sneak))
st, found = call("GET", "/v1/kingdoms/search?q=" + sfx, token=outsider)
card = next((c for c in found["kingdoms"] if c["id"] == kid), {})
check("the card now says REQUESTED", card.get("action") == "requested", card)

st, gone = call("POST", "/v1/kingdom/request/cancel", {"kingdom_id": kid}, token=outsider)
check("a request can be withdrawn", st == 200, (st, gone))
st, found = call("GET", "/v1/kingdoms/search?q=" + sfx, token=outsider)
card = next((c for c in found["kingdoms"] if c["id"] == kid), {})
check("and the card offers REQUEST again", card.get("action") == "request", card)

call("POST", "/v1/kingdom/join", {"kingdom_id": kid}, token=outsider)
st, kv = call("GET", "/v1/kingdom", token=vassal)
check("the captain sees who is asking", any(r["player_id"] == outsider_id for r in kv.get("requests", [])),
      kv.get("requests"))
st, mem = call("GET", "/v1/kingdom", token=king)
st, no = call("POST", "/v1/kingdom/requests/answer", {"player_id": outsider_id}, token=vassal)
check("an answer must say accept or refuse", st == 400, (st, no))
st, refused = call("POST", "/v1/kingdom/requests/answer", {"player_id": outsider_id, "accept": False}, token=vassal)
check("the captain can refuse a request", st == 200 and all(
    r["player_id"] != outsider_id for r in refused.get("requests", [])), (st, refused.get("requests")))
_, ov = call("GET", "/v1/kingdom", token=outsider)
check("the refused lord is still outside", ov["in_kingdom"] is False, ov.get("in_kingdom"))

call("POST", "/v1/kingdom/join", {"kingdom_id": kid}, token=outsider)
st, seated = call("POST", "/v1/kingdom/requests/answer", {"player_id": outsider_id, "accept": True}, token=king)
check("the king can accept a request", st == 200, (st, seated))
_, ov = call("GET", "/v1/kingdom", token=outsider)
check("the accepted lord is seated as a plain member",
      ov["in_kingdom"] and ov["me"]["role"] == "member", (ov.get("in_kingdom"), ov.get("me")))

print("\n== removal and the rejoin cooldown ==")
st, bad = call("POST", "/v1/kingdom/kick", {"player_id": king_id}, token=vassal)
check("a captain cannot remove the king", st == 403 and bad.get("code") == "not_permitted", (st, bad))
st, bad = call("POST", "/v1/kingdom/kick", {"player_id": king_id}, token=king)
check("the king cannot remove himself", st == 400 and bad.get("code") == "bad_target", (st, bad))
st, out = call("POST", "/v1/kingdom/kick", {"player_id": outsider_id}, token=vassal)
check("a captain can remove a lord", st == 200 and all(
    m["player_id"] != outsider_id for m in out.get("members", [])), (st, out.get("members")))
_, ov = call("GET", "/v1/kingdom", token=outsider)
check("the removed lord has no kingdom", ov["in_kingdom"] is False, ov.get("in_kingdom"))
check("and must wait before joining again", ov["rejoin_in"] > 0, ov.get("rejoin_in"))
check("the cards say so", all(c["action"] == "cooldown" for c in ov.get("recommended", [])),
      [c["action"] for c in ov.get("recommended", [])])
call("POST", "/v1/kingdom/policy", {"policy": "open"}, token=king)
st, back = call("POST", "/v1/kingdom/join", {"kingdom_id": kid}, token=outsider)
check("walking straight back into an open kingdom is refused, with the wait named",
      st == 409 and back.get("code") == "rejoin_cooldown" and "m" in back.get("message", ""), (st, back))

print("\n== joining an open kingdom ==")
st, open_join = call("POST", "/v1/kingdom/join", {"kingdom_id": kid}, token=rover)
check("an open kingdom seats a lord at once", st == 200 and open_join.get("result") == "joined"
      and open_join["in_kingdom"], (st, open_join.get("result")))
st, dup = call("POST", "/v1/kingdom/join", {"kingdom_id": kid}, token=rover)
check("a member cannot join again", st == 409 and dup.get("code") == "already_in_kingdom", (st, dup))

print("\n== the crown ==")
st, bad = call("POST", "/v1/kingdom/role", {"player_id": vassal_id, "role": "captain"}, token=king)
check("a rank the server does not know is a 400, not a 404",
      st == 400 and bad.get("code") == "bad_role", (st, bad))
st, bad = call("POST", "/v1/kingdom/role", {"player_id": king_id, "role": "king"}, token=king)
check("a king cannot name himself anything", st == 400 and bad.get("code") == "bad_target", (st, bad))
st, handed = call("POST", "/v1/kingdom/role", {"player_id": vassal_id, "role": "king"}, token=king)
check("the king can hand over the crown", st == 200, (st, handed))
_, vk = call("GET", "/v1/kingdom", token=vassal)
check("the new king holds it", vk["me"]["role"] == "king", vk.get("me"))
st, renamed = call("POST", "/v1/kingdom/rename", {"name": "Hall " + sfx}, token=vassal)
check("the new king can rename the kingdom he rules", st == 200 and renamed["kingdom"]["name"] == "Hall " + sfx,
      (st, renamed))
st, old = call("POST", "/v1/kingdom/rename", {"name": "Keep " + sfx}, token=king)
check("and the old one no longer can", st == 403, (st, old))
st, bad = call("POST", "/v1/kingdom/rename", {"name": "x"}, token=vassal)
check("a bad name is a 400 with the rule in it, not a 500",
      st == 400 and bad.get("code") == "invalid_name" and "3 and 24" in bad.get("message", ""), (st, bad))

print("\n== disbanding ==")
for tok in (rover, king):
    st, left = call("POST", "/v1/kingdom/leave", {}, token=tok)
    check("a lord can leave", st == 200 and left["in_kingdom"] is False, (st, left.get("in_kingdom")))
st, left = call("POST", "/v1/kingdom/leave", {}, token=vassal)
check("the last lord can leave", st == 200, (st, left))
st, found = call("GET", "/v1/kingdoms/search?q=" + sfx, token=outsider)
check("and the kingdom goes with them", all(c["id"] != kid for c in found.get("kingdoms", [])), found)
st, refound = call("POST", "/v1/kingdom/found",
                   {"name": "Hall " + sfx, "tag": sfx[:3].upper(), "action_seq": seq(vassal)}, token=vassal)
check("its name and tag are free again", st in (200, 409) and refound.get("code") != "name_taken", (st, refound))
if st == 200:
    call("POST", "/v1/kingdom/leave", {}, token=vassal)

print()
if FAILURES:
    print(f"{len(FAILURES)} FAILED: " + ", ".join(FAILURES))
    sys.exit(1)
print("all checks passed")
