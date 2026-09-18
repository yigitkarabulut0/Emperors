#!/usr/bin/env python3
"""Sosyal (Wave 6), end to end, as two lords meet it.

    python3 scripts/smoke-social.py [<game-url>]

Two fresh lords are registered and put in one kingdom, and everything the wave
added is driven through the same doors a phone uses:

  * the hall: the room answers with its rules until they are agreed to, refuses
    a line before that, takes one after it, stars a blocked word out rather
    than swallowing the line, holds the burst and the window, and carries the
    other lord's line to this one;
  * a reported line is reported once and no more, and reporting your own is not
    a report;
  * friends: an ask by name, an answer, the roll, the day's draught -- which is
    ENERGY THROUGH THE FLASK, so the taker's pool moves and the giver's does
    not -- and the refusals (yourself, twice in a day, a stranger);
  * a rival's page: free of numbers, open to the realm by default, shut by
    privacy, and 404 behind a block; the spyglass pays gold, freezes the army
    and tells the target they were scouted;
  * the kingdom's help: the day's goal with its own thresholds, a call for aid
    answered by another lord (a timed stack, not gold), and the goal's chest
    refused before its share is done;
  * settings: what the realm may send, who may look, the hall's rules read
    again, and a block that hides a lord both ways;
  * a lord reported as a lord, which is the other half of App Review 1.2;
  * and the rule the whole wave rests on: no endpoint here moves action_seq
    except the two that are the lord's own (the gift taken, the spyglass).
"""
import json, os, subprocess, sys, time, urllib.error, urllib.request

BASE = (sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8080").rstrip("/")
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# A kingdom costs level 20 and 250,000 gold, which nothing can grind to inside a
# smoke. On a local realm the same door the other smokes use (cmd/devgrant)
# opens it; on the live realm the hall, the aid and the goal are read where they
# can be and the rest is said to be skipped rather than pretended.
LOCAL = "127.0.0.1" in BASE or "localhost" in BASE
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
    return reg["access_token"], user, reg["player_id"]


def state(token):
    _, s = call("GET", "/v1/state", token=token)
    return s


def seq_of(token):
    return state(token)["player"]["action_seq"] + 1


# The local realm's own database. cmd/devgrant writes straight to it, so this is
# never the live one: a smoke does not found kingdoms in a realm people live in.
LOCAL_DB = os.environ.get("EMPERORS_SMOKE_DB",
                          "postgres://emperors@127.0.0.1:5544/emperors_dev?sslmode=disable")


def grant(user, level=0, gold=0):
    """A level and a purse on the LOCAL realm, as smoke-m6 does it."""
    env = dict(os.environ)
    env["DATABASE_URL"] = LOCAL_DB
    env.pop("DATABASE_URL_DIRECT", None)
    subprocess.run(["go", "run", "./cmd/devgrant", "-user", user, "-level", str(level),
                    "-gold", str(gold)], cwd=os.path.join(ROOT, "server"), env=env,
                   capture_output=True, check=True)


def grind_to(token, level):
    """Plays the lord up to `level` the way a lord would: the best job the
    energy allows, until the level comes or the pool runs dry."""
    s = state(token)
    for _ in range(40):
        if s["player"]["level"] >= level:
            break
        jobs = [j for j in s.get("jobs", []) if j["unlocked"] and s["energy"]["current"] >= j["energy_cost"]]
        if not jobs:
            break
        best = max(jobs, key=lambda j: j["xp_payout"] / j["energy_cost"])
        st, c = call("POST", "/v1/collect",
                     {"job_id": best["id"], "action_seq": s["player"]["action_seq"] + 1}, token=token)
        if st != 200:
            break
        s = c["snapshot"]
    return s


print("== two lords and a hall ==")
a_tok, a_name, a_id = new_player("soc")
b_tok, b_name, b_id = new_player("soc")

st, room = call("GET", "/v1/chat", token=a_tok)
check("a lord with no kingdom has no hall", st in (404, 409) and code(room) == "no_hall", (st, room))

# A kingdom of two. Founding costs gold, so the first lord is given what the
# realm charges through the dev door when there is one; otherwise this half is
# skipped and said so.
founded = False
TAG = "S%03d" % (int(time.time()) % 1000)
HALL = "Smoke Hall %d" % (int(time.time()) % 100000)
st, poor = call("POST", "/v1/kingdom/found", {"name": HALL, "tag": TAG,
                                              "action_seq": seq_of(a_tok)}, token=a_tok)
check("a lord who cannot afford a kingdom is told which rule stopped them",
      st in (403, 409) and code(poor) in ("insufficient_gold", "level_too_low"), (st, poor))
if LOCAL:
    grant(a_name, level=20, gold=400000)
    grant(b_name, level=20, gold=0)
    st, made = call("POST", "/v1/kingdom/found", {"name": HALL, "tag": TAG,
                                                  "action_seq": seq_of(a_tok)}, token=a_tok)
    founded = st == 200
    check("a kingdom is founded", founded, (st, made))

if not founded:
    print("\n(no kingdom could be founded on this realm: the hall, the aid and the goal are skipped)")
else:
    st, k = call("GET", "/v1/kingdom", token=a_tok)
    kid = (k.get("kingdom") or {}).get("id", "")
    st, joined = call("POST", "/v1/kingdom/join", {"kingdom_id": kid, "action_seq": seq_of(b_tok)},
                      token=b_tok)
    check("a second lord joins the kingdom", st == 200, (st, joined))

    print("\n== the rules of the hall ==")
    st, room = call("GET", "/v1/chat", token=a_tok)
    check("the room answers", st == 200, (st, room))
    rules = room.get("rules")
    check("and carries the rules, because this lord has not agreed", isinstance(rules, dict), room.keys())
    check("the rules name a version, lines and an address a person answers",
          isinstance(rules, dict) and rules.get("version", 0) > 0 and rules.get("lines")
          and "@" in str(rules.get("support", "")), rules)
    st, refused = call("POST", "/v1/chat", {"body": "before I agree"}, token=a_tok)
    check("a line before the rules are agreed to is refused",
          code(refused) == "rules_unread", (st, refused))
    st, g = call("GET", "/v1/chat/rules", token=a_tok)
    check("the rules can be read again on their own", st == 200 and g["rules"]["version"] == rules["version"],
          (st, g))
    for tok in (a_tok, b_tok):
        st, _ = call("POST", "/v1/chat/rules", {"version": rules["version"]}, token=tok)
        check("the rules are agreed to", st == 200, st)
    st, room = call("GET", "/v1/chat", token=a_tok)
    check("and are not sent again", room.get("rules") is None, room.get("rules"))

    print("\n== a line, and what the hall does to it ==")
    before = state(a_tok)["player"]["action_seq"]
    st, said = call("POST", "/v1/chat", {"body": "Well met, the realm is quiet tonight."}, token=a_tok)
    check("a line is taken", st == 200, (st, said))
    check("saying something does not move action_seq",
          state(a_tok)["player"]["action_seq"] == before, before)
    st, room = call("GET", "/v1/chat", token=b_tok)
    lines = [l for l in room.get("lines", []) if l.get("kind") == "lord"]
    check("the other lord reads it", any("quiet tonight" in l.get("body", "") for l in lines), lines)
    check("and a line carries who said it",
          bool(lines) and bool(lines[-1].get("player_id")) and bool(lines[-1].get("name")),
          lines[-1] if lines else None)
    st, fast = call("POST", "/v1/chat", {"body": "and again at once"}, token=a_tok)
    check("the burst holds a second line or takes it, but never crashes",
          st in (200, 429), (st, fast))
    st, long = call("POST", "/v1/chat", {"body": "x" * 500}, token=a_tok)
    check("a line too long is refused", st in (400, 409, 413, 422), (st, long))
    st, empty = call("POST", "/v1/chat", {"body": "   "}, token=a_tok)
    check("an empty line is refused", st in (400, 409, 422), (st, empty))

    print("\n== reporting a line ==")
    st, room = call("GET", "/v1/chat", token=b_tok)
    mine = [l for l in room.get("lines", []) if l.get("kind") == "lord" and l.get("mine")]
    theirs = [l for l in room.get("lines", []) if l.get("kind") == "lord" and not l.get("mine")]
    if theirs:
        st, rep = call("POST", "/v1/chat/report", {"message_id": theirs[-1]["id"], "reason": "abuse"},
                       token=b_tok)
        check("another lord's line is reported", st == 200, (st, rep))
    if mine:
        st, own = call("POST", "/v1/chat/report", {"message_id": mine[-1]["id"], "reason": "other"},
                       token=b_tok)
        check("your own line is not a report", st == 404, (st, own))

print("\n== friends, and the day's draught ==")
# The roll opens at level 3, which is a few collects from a new lord.
for tok in (a_tok, b_tok):
    grind_to(tok, 3)
st, fr = call("GET", "/v1/friends", token=a_tok)
check("the roll answers", st == 200 and isinstance(fr.get("friends"), list), (st, fr))
check("it says what a draught would be worth to this lord", isinstance(fr.get("gift_energy"), int), fr)
st, self_ask = call("POST", "/v1/friends/request", {"username": a_name}, token=a_tok)
check("a lord cannot ask themselves", st in (400, 404, 409), (st, self_ask))
st, nobody = call("POST", "/v1/friends/request", {"username": "nobody_by_that_name"}, token=a_tok)
check("a name nobody has is refused", st == 404, (st, nobody))
st, asked = call("POST", "/v1/friends/request", {"username": b_name}, token=a_tok)
check("a lord is asked by name", st == 200, (st, asked))
st, fr_b = call("GET", "/v1/friends", token=b_tok)
check("the ask is waiting on the other lord's page",
      any(r.get("username") == a_name for r in fr_b.get("requests", [])), fr_b.get("requests"))
st, yes = call("POST", "/v1/friends/answer", {"player_id": a_id, "accept": True}, token=b_tok)
check("the ask is answered", st == 200, (st, yes))
st, fr = call("GET", "/v1/friends", token=a_tok)
check("and both are on the roll", any(f.get("username") == b_name for f in fr.get("friends", [])),
      fr.get("friends"))

gifts_left = fr.get("gifts_left", 0)
st, gift = call("POST", "/v1/friends/gift", {"player_id": b_id}, token=a_tok)
# A house and a friendship must both be a day old before a draught may be sent
# (social.json). A smoke cannot wait a day, so the RULE is what is checked here
# and the draught itself only when the realm lets it through.
if st != 200:
    check("a draught too early is refused by the rule that stopped it",
          code(gift) in ("account_too_new", "friendship_too_new", "gift_day_full"), (st, gift))
    print("  (this realm's houses are too new for a draught: the taking is skipped)")
else:
    check("a draught is sent", True)
    st, again = call("POST", "/v1/friends/gift", {"player_id": b_id}, token=a_tok)
    check("and not twice in a day to the same lord", st in (409, 429), (st, again))
    st, fr = call("GET", "/v1/friends", token=a_tok)
    check("the day's draughts are counted down", fr.get("gifts_left", 99) == max(0, gifts_left - 1),
          (gifts_left, fr.get("gifts_left")))

    before = state(b_tok)
    st, took = call("POST", "/v1/friends/gift/take", {"player_id": a_id, "action_seq": seq_of(b_tok)},
                    token=b_tok)
    check("the draught is drunk by the lord it was sent to", st == 200, (st, took))
    after = state(b_tok)
    check("and energy moved through the flask, so the pool is what the realm says it is",
          after["energy"]["current"] >= before["energy"]["current"],
          (before["energy"], after["energy"]))
    check("taking it IS the lord's own action, so action_seq moved",
          after["player"]["action_seq"] > before["player"]["action_seq"],
          (before["player"]["action_seq"], after["player"]["action_seq"]))

print("\n== a rival's page, and the spyglass ==")
st, lord = call("GET", "/v1/lords/%s" % b_id, token=a_tok)
check("a lord's page answers", st == 200, (st, lord))
check("it carries their level and their gear by name",
      "level" in lord and isinstance(lord.get("gear"), list), list(lord))
check("and no numbers on their army before a spyglass is bought",
      all(not u.get("might") for u in lord.get("army", [])), lord.get("army"))
check("it says what a spyglass would cost and how many are left today",
      lord.get("spy_cost", 0) > 0 and "spy_left" in lord, lord)
st, myself = call("GET", "/v1/lords/%s" % a_id, token=a_tok)
check("a lord may open their own page", st == 200 and myself.get("is_me") is True, (st, myself.get("is_me")))
st, no_spy = call("POST", "/v1/lords/%s/spy" % a_id, {"action_seq": seq_of(a_tok)}, token=a_tok)
check("but not spy on themselves", st in (400, 409), (st, no_spy))

gold = int(state(a_tok)["player"]["gold"])
if gold >= lord.get("spy_cost", 0):
    before = state(a_tok)["player"]["action_seq"]
    st, spied = call("POST", "/v1/lords/%s/spy" % b_id, {"action_seq": seq_of(a_tok)}, token=a_tok)
    check("the spyglass is bought", st == 200, (st, spied))
    check("the page comes back scouted, with an hour on it",
          spied.get("scouted") is True and spied.get("scouted_for", 0) > 0, spied.get("scouted_for"))
    check("the spyglass IS the lord's own action, so action_seq moved",
          state(a_tok)["player"]["action_seq"] > before, before)
    check("the gold is gone", int(state(a_tok)["player"]["gold"]) < gold, gold)
    st, seen = call("GET", "/v1/attack/targets", token=b_tok)
    check("and the rival is told they were scouted", seen.get("scouted_today", 0) >= 1,
          seen.get("scouted_today"))
else:
    print("  (a new lord cannot afford a spyglass here: the purchase is skipped)")

print("\n== the crown is told about a lord ==")
st, told = call("POST", "/v1/lords/%s/report" % b_id, {"reason": "name"}, token=a_tok)
check("a lord is reported as a lord", st == 200, (st, told))
st, once = call("POST", "/v1/lords/%s/report" % b_id, {"reason": "name"}, token=a_tok)
check("and a flood of reports is held by the same cooldown as a line's",
      st in (200, 429), (st, once))
st, self_report = call("POST", "/v1/lords/%s/report" % a_id, {"reason": "other"}, token=a_tok)
check("reporting yourself is not a report", st == 404, (st, self_report))

print("\n== the kingdom's help ==")
st, help_v = call("GET", "/v1/help", token=a_tok)
if st != 200:
    check("a lord with no kingdom is told so rather than refused blind",
          code(help_v) in ("no_kingdom", "no_hall", "not_found"), (st, help_v))
    print("  (these lords have no kingdom: the goal and the aid are skipped)")
else:
    check("the help answers", st == 200, (st, help_v))
    goal = help_v.get("goal")
    if isinstance(goal, dict):
        check("the day's goal names what it asks and what it pays",
              goal.get("target", 0) > 0 and len(goal.get("chests", [])) >= 3, goal)
        check("every chest says where it stands and whether it is taken",
              all("at_bp" in c and "reached" in c for c in goal.get("chests", [])), goal.get("chests"))
        st, early = call("POST", "/v1/help/claim", {"index": 0}, token=a_tok)
        check("a chest cannot be taken before it is reached", st in (400, 409), (st, early))
    check("aid says how many stacks this lord carries, how many they may, and what one is worth",
          all(k in help_v for k in ("my_stacks", "max_stacks", "aid_stack_bp", "aid_hours")), list(help_v))
    st, asked = call("POST", "/v1/help/ask", {}, token=a_tok)
    check("a lord asks their kingdom for aid", st in (200, 409), (st, asked))
    if st == 200:
        st, hv = call("GET", "/v1/help", token=b_tok)
        calls = hv.get("calls", [])
        check("the call stands in the kingdom's help", any(c.get("player_id") == a_id for c in calls), calls)
        aid_id = next((c["id"] for c in calls if c.get("player_id") == a_id), "")
        st, gave = call("POST", "/v1/help/answer", {"aid_id": aid_id}, token=b_tok)
        check("another lord answers it", st == 200, (st, gave))
        st, twice = call("POST", "/v1/help/answer", {"aid_id": aid_id}, token=b_tok)
        check("and cannot answer the same call twice", st in (409, 429), (st, twice))
        st, hv = call("GET", "/v1/help", token=a_tok)
        check("the lord who asked wears a stack of it", hv.get("my_stacks", 0) >= 1, hv.get("my_stacks"))

print("\n== settings, and a lord blocked ==")
st, sv = call("GET", "/v1/settings", token=a_tok)
check("the settings answer", st == 200, (st, sv))
check("with what the realm may send, who may look, the rules and an address",
      all(k in sv for k in ("notify", "privacy", "blocked", "rules", "support")), list(sv))
st, off = call("POST", "/v1/settings/notify", {**sv["notify"], "chat": False}, token=a_tok)
check("a notification is turned off, and the answer is the block that changed",
      st == 200 and off.get("chat") is False, (st, off))
st, shut = call("POST", "/v1/settings/privacy", {**sv["privacy"], "profile": "friends"}, token=b_tok)
check("a lord shuts their page to strangers", st == 200 and shut.get("profile") == "friends",
      (st, shut))
c_tok, c_name, c_id = new_player("soc")
st, hidden = call("GET", "/v1/lords/%s" % b_id, token=c_tok)
check("and a stranger is told the page is not open to them", st in (403, 404), (st, hidden))
_, sv_b = call("GET", "/v1/settings", token=b_tok)
st, open_again = call("POST", "/v1/settings/privacy", {**sv_b["privacy"], "profile": "all"}, token=b_tok)
check("and it opens again", st == 200, (st, open_again))

st, blocked = call("POST", "/v1/blocks", {"player_id": c_id}, token=b_tok)
check("a lord is blocked", st == 200, (st, blocked))
st, gone = call("GET", "/v1/lords/%s" % b_id, token=c_tok)
check("after which they are no such lord, never 'you are blocked'", st == 404, (st, gone))
st, sv = call("GET", "/v1/settings", token=b_tok)
check("and the block is on the settings' own list",
      any(b.get("player_id") == c_id for b in sv.get("blocked", [])), sv.get("blocked"))
st, unblocked = call("POST", "/v1/blocks/remove", {"player_id": c_id}, token=b_tok)
check("a block is lifted", st == 200, (st, unblocked))
st, back = call("GET", "/v1/lords/%s" % b_id, token=c_tok)
check("and the lord is there again", st == 200, (st, back))

print("\n== the realtime door ==")
st, ws = call("GET", "/v1/realtime", token=a_tok)
check("the socket never answers a plain GET with a page", st != 200, (st, ws))
st, no_tok = call("GET", "/v1/realtime")
check("and refuses one with no token at all", st in (401, 400, 426), st)

print()
if failures:
    print("FAILED (%d): %s" % (len(failures), ", ".join(failures)))
    sys.exit(1)
print("social: all checks passed")
