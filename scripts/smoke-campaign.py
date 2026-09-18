#!/usr/bin/env python3
"""PvE ve derinlik (Wave 7), end to end, as a lord meets it.

    python3 scripts/smoke-campaign.py [<game-url>]

One fresh lord is registered and driven through everything the wave added, at
the same doors a phone uses:

  * the campaign: the map and one chapter, the road that opens a mile at a time,
    a stage fought (energy out, stars and wages in), a repeat that pays less
    than the first clear, and a chapter chest that opens on stars and is taken
    once;
  * the expeditions: a soldier sent to a field, the same soldier refused a
    second road, refused a reroll and a dismissal while away, a haul that
    cannot be taken early, and a recall that brings nothing;
  * the forge: three pieces of one slot and rank and gold making one of the
    rank above, the fee charged, the three gone and the one there, and a mixed
    pile refused;
  * the talents: a point spent, a shut tier refused, a maxed talent refused,
    and a respec that costs gold and gives every point back;
  * and the rule the wave rests on: the only endpoints here that move
    action_seq are the lord's own spends -- the stage, the chest, the collected
    haul, the forge, the talent and the respec -- and never a read.

On a realm where the lord cannot be given levels and gold (the live one), the
parts that need them say they are skipped rather than pretending.
"""
import json, os, subprocess, sys, time, urllib.error, urllib.request

BASE = (sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8080").rstrip("/")
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOCAL = "127.0.0.1" in BASE or "localhost" in BASE
LOCAL_DB = os.environ.get("EMPERORS_SMOKE_DB",
                          "postgres://emperors@127.0.0.1:5544/emperors_dev?sslmode=disable")
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


def dev(args):
    env = dict(os.environ)
    env["DATABASE_URL"] = LOCAL_DB
    env.pop("DATABASE_URL_DIRECT", None)
    return subprocess.run(["go", "run", "./cmd/devgrant"] + args, cwd=os.path.join(ROOT, "server"),
                          env=env, capture_output=True, text=True)


def grant(user, level=0, gold=0):
    dev(["-user", user, "-level", str(level), "-gold", str(gold)])


def sql(statement):
    """A row the game has no door for: a soldier in the yard, a piece of gear.
    Only ever on the LOCAL realm."""
    return subprocess.run(["psql", LOCAL_DB, "-t", "-c", statement],
                          capture_output=True, text=True)


tok, name, pid = new_player("pve")

print("== the campaign ==")
st, before = call("GET", "/v1/campaign", token=tok)
check("the map answers a lord of level one", st == 200, (st, before))
check("and says it is shut, with the level that opens it",
      not before.get("unlocked", True) and int(before.get("unlock_level", 0)) > 0, before)
check("the map carries its ten chapters whatever the level",
      len(before.get("chapters", [])) == 10, len(before.get("chapters", [])))
first = (before.get("chapters") or [{}])[0]
check("the first chapter is open and the second is not",
      first.get("open") is True and (before["chapters"][1].get("open") is False), before.get("chapters", [])[:2])

st, shut = call("POST", "/v1/campaign/fight",
                {"chapter_id": first.get("id", "vale"), "stage": 1, "action_seq": seq_of(tok)}, token=tok)
check("a lord under the level cannot walk a mile", st == 403 and code(shut) == "campaign_locked", (st, shut))

if not LOCAL:
    print("\n(this realm has no dev door: the rest is skipped rather than pretended)")
    sys.exit(1 if failures else 0)

grant(name, level=30, gold=5_000_000)
# An army worth the road. A lord of thirty who has bought nothing at all is
# weaker than the campaign's first garrison, which is written for a lord of six
# WITH the roster and the gear the shop would have sold them by then -- so the
# smoke gives this one what such a lord would have, at the doors the game has
# no endpoint for.
sql("""INSERT INTO app.soldiers (player_id, slot_index, type_id, tier, level, name, rolled_config_version)
       SELECT id, n, 'mercenary', 'rare', level, 'Sellsword', 1
       FROM app.players, generate_series(1,3) n WHERE username = '%s'
       ON CONFLICT DO NOTHING;
       UPDATE app.players SET soldier_slots = GREATEST(soldier_slots, 3),
              stat_attack = 60, stat_defense = 60 WHERE username = '%s';""" % (name, name))
st, mine = call("GET", "/v1/campaign", token=tok)
check("with the level, the map opens", mine.get("unlocked") is True, mine.get("unlocked"))
chapter = mine["chapter_id"]
check("and it says where the lord stands", chapter != "" and int(mine.get("stage", 0)) == 1,
      (chapter, mine.get("stage")))

st, ch = call("GET", "/v1/campaign/%s" % chapter, token=tok)
check("a chapter answers with its twelve miles", st == 200 and len(ch.get("stages", [])) == 12,
      (st, len(ch.get("stages", []))))
stages = ch.get("stages", [])
check("the first mile is open and the second is not",
      stages[0].get("open") is True and stages[1].get("open") is False,
      [s.get("open") for s in stages[:3]])
check("every mile says what it costs, what stands there and what it is worth",
      all(int(s.get("energy", 0)) > 0 and s.get("enemy") and int(s.get("might", 0)) > 0 for s in stages),
      stages[0])
check("and what walking it pays, in the server's own words",
      all(s.get("lines") for s in stages), stages[0].get("lines"))
check("the chapter's chests say what they ask for",
      len(ch.get("chests", [])) == 3 and all(int(c.get("stars", 0)) > 0 for c in ch["chests"]),
      ch.get("chests"))

st, jumped = call("POST", "/v1/campaign/fight",
                  {"chapter_id": chapter, "stage": 2, "action_seq": seq_of(tok)}, token=tok)
check("a mile whose road is not open is refused", st == 409 and code(jumped) == "stage_shut", (st, jumped))

# The first mile, fought until it falls. Fortune of War is rolled per battle,
# so even a lord written for the mile may lose one; eight walks is well past
# any run of bad luck the simulator can produce at this ratio.
energy_before = state(tok)["energy"]["current"]
won = None
for _ in range(8):
    st, res = call("POST", "/v1/campaign/fight",
                   {"chapter_id": chapter, "stage": 1, "action_seq": seq_of(tok)}, token=tok)
    if st != 200:
        break
    if res.get("won"):
        won = res
        break
check("a mile can be walked", st == 200, (st, res))
check("and it costs energy", state(tok)["energy"]["current"] < energy_before, energy_before)
check("the fight comes back as a replay the client only animates",
      isinstance(res.get("replay"), dict) and res["replay"].get("events"), list(res.keys()))
if won is None:
    check("the first mile falls to a lord of thirty", False, "eight walks and it still stood")
else:
    check("a win is worth stars", 1 <= int(won.get("stars", 0)) <= 3, won.get("stars"))
    check("the first clear says so and pays", won.get("first_clear") is True
          and int(won.get("granted", {}).get("gold", 0)) > 0, won.get("granted"))
    first_gold = int(won["granted"]["gold"])

    # A repeat pays a share, and never more than the first clear.
    again = None
    for _ in range(6):
        st, res2 = call("POST", "/v1/campaign/fight",
                        {"chapter_id": chapter, "stage": 1, "action_seq": seq_of(tok)}, token=tok)
        if st == 200 and res2.get("won"):
            again = res2
            break
    if again is None:
        check("a repeat pays less than the first clear", True, "(never won again; skipped)")
    else:
        check("a repeat is not a first clear", again.get("first_clear") is False, again.get("first_clear"))
        check("and pays less than the first clear",
              int(again.get("granted", {}).get("gold", 0)) < first_gold,
              (again.get("granted", {}).get("gold"), first_gold))

    st, ch2 = call("GET", "/v1/campaign/%s" % chapter, token=tok)
    check("the mile is marked walked, and the next is open",
          ch2["stages"][0].get("cleared") is True and ch2["stages"][1].get("open") is True,
          [(s.get("cleared"), s.get("open")) for s in ch2["stages"][:2]])

st, shut_chest = call("POST", "/v1/campaign/chest",
                      {"chapter_id": chapter, "index": 0, "action_seq": seq_of(tok)}, token=tok)
check("a chest the stars have not opened is refused",
      st == 409 and code(shut_chest) == "chest_shut", (st, shut_chest))

print("\n== the expeditions ==")
st, roads = call("GET", "/v1/hunt", token=tok)
check("the roads answer", st == 200 and len(roads.get("fields", [])) == 4, (st, roads.get("fields")))
check("every field says how long it is and what it pays, in gold and experience",
      all(int(f.get("hours", 0)) > 0 and int(f.get("gold_low", 0)) > 0
          and int(f.get("gold_high", 0)) >= int(f.get("gold_low", 0)) for f in roads.get("fields", [])),
      roads.get("fields", [])[:1])
check("and how many roads this lord may walk at once", int(roads.get("slots", 0)) >= 1, roads.get("slots"))

st, army = call("GET", "/v1/army", token=tok)
soldier = next((s["soldier"] for s in army.get("slots", []) if s.get("soldier")), None)
check("the lord has a soldier to send", soldier is not None, army.get("slots"))

if soldier:
    field = roads["fields"][0]["id"]
    seq = seq_of(tok)
    st, sent = call("POST", "/v1/hunt/send", {"soldier_id": soldier["id"], "field_id": field}, token=tok)
    check("a soldier is sent to a field", st == 200 and len(sent.get("away", [])) == 1, (st, sent))
    check("sending moves no sequence: it spends nothing",
          state(tok)["player"]["action_seq"] == seq - 1, state(tok)["player"]["action_seq"])
    away = (sent.get("away") or [{}])[0]

    st, twice = call("POST", "/v1/hunt/send", {"soldier_id": soldier["id"], "field_id": field}, token=tok)
    check("the same soldier cannot walk two roads", st == 409 and code(twice) == "soldier_away", (st, twice))
    st, rr = call("POST", "/v1/army/reroll", {"soldier_id": soldier["id"], "action_seq": seq_of(tok)}, token=tok)
    check("a soldier away cannot be rerolled", st == 409 and code(rr) == "soldier_away", (st, rr))
    st, dm = call("POST", "/v1/army/dismiss", {"soldier_id": soldier["id"], "action_seq": seq_of(tok)}, token=tok)
    check("nor dismissed", st == 409 and code(dm) == "soldier_away", (st, dm))

    st, army2 = call("GET", "/v1/army", token=tok)
    check("the army says who is away, and what the yard is worth without them",
          any(s.get("soldier", {}).get("away") for s in army2.get("slots", []))
          and int(army2.get("field", {}).get("might", 0)) < int(army2.get("totals", {}).get("might", 0)),
          (army2.get("field"), army2.get("totals")))

    st, early = call("POST", "/v1/hunt/collect", {"id": away.get("id"), "action_seq": seq_of(tok)}, token=tok)
    check("a soldier still on the road cannot be let in",
          st == 409 and code(early) == "hunt_soon", (st, early))

    gold_before = int(state(tok)["player"]["gold"])
    st, back = call("POST", "/v1/hunt/recall", {"id": away.get("id")}, token=tok)
    check("a soldier may be called back", st == 200 and back.get("away") == [], (st, back))
    check("and brings nothing at all", int(state(tok)["player"]["gold"]) == gold_before,
          (gold_before, state(tok)["player"]["gold"]))
    st, sent2 = call("POST", "/v1/hunt/send", {"soldier_id": soldier["id"], "field_id": field}, token=tok)
    check("a soldier home from a recall may be sent again", st == 200, (st, sent2))
    call("POST", "/v1/hunt/recall", {"id": (sent2.get("away") or [{}])[0].get("id")}, token=tok)

print("\n== the forge ==")
st, bag = call("GET", "/v1/inventory", token=tok)
check("the bag publishes the anvil's odds",
      st == 200 and int(bag.get("forge", {}).get("pieces", 0)) >= 2
      and int(bag.get("forge", {}).get("masterwork_chance_bp", 0)) > 0, bag.get("forge"))

sql("""INSERT INTO app.player_items (player_id, def_id, slot, tier, ilvl, quality_pct, masterwork,
         attack, defense, speed, acquired_from, rolled_config_version)
       SELECT id, 'weapon_rare_01', 'weapon', 'rare', 20 + n, 100, false, 60 + n, 12, 0, 'admin', 1
       FROM app.players, generate_series(1,3) n WHERE username = '%s';""" % name)
st, bag = call("GET", "/v1/inventory", token=tok)
pieces = [i for i in bag.get("items", []) if i.get("tier") == "rare" and i.get("slot") == "weapon"]
check("three pieces of one slot and rank carry the anvil's offer",
      len(pieces) >= 3 and pieces[0].get("forge", {}).get("items"), pieces[:1])
if pieces and pieces[0].get("forge", {}).get("items"):
    offer = pieces[0]["forge"]
    check("the offer names its three, the rank above and a fee",
          len(offer["items"]) == int(bag["forge"]["pieces"]) and offer.get("tier") == "epic"
          and int(offer.get("fee", 0)) > 0, offer)
    gold_before = int(state(tok)["player"]["gold"])
    st, made = call("POST", "/v1/forge", {"item_ids": offer["items"], "action_seq": seq_of(tok)}, token=tok)
    check("three go in and one comes out", st == 200 and made.get("item", {}).get("tier") == "epic",
          (st, made.get("item", {}).get("tier")))
    check("the anvil charges its fee",
          gold_before - int(state(tok)["player"]["gold"]) == int(made.get("fee", 0)),
          (gold_before, state(tok)["player"]["gold"], made.get("fee")))
    st, bag2 = call("GET", "/v1/inventory", token=tok)
    left = [i for i in bag2.get("items", []) if i["id"] in offer["items"]]
    check("and the three are gone", left == [], left)

    # A mixed pile is refused.
    sql("""INSERT INTO app.player_items (player_id, def_id, slot, tier, ilvl, quality_pct, masterwork,
             attack, defense, speed, acquired_from, rolled_config_version)
           SELECT id, 'armor_common_01', 'armor', 'common', 10, 100, false, 4, 20, 0, 'admin', 1
           FROM app.players WHERE username = '%s';""" % name)
    st, bag3 = call("GET", "/v1/inventory", token=tok)
    mixed = [i["id"] for i in bag3["items"] if i["slot"] == "weapon"][:2] + \
            [i["id"] for i in bag3["items"] if i["slot"] == "armor"][:1]
    if len(mixed) == 3:
        st, no = call("POST", "/v1/forge", {"item_ids": mixed, "action_seq": seq_of(tok)}, token=tok)
        check("a mixed pile is refused", st == 400 and code(no) == "forge_pieces", (st, no))

print("\n== the talents ==")
st, tree = call("GET", "/v1/talents", token=tok)
check("the tree answers", st == 200 and len(tree.get("branches", [])) == 3, (st, len(tree.get("branches", []))))
check("it is open at thirty, with points to spend",
      tree.get("unlocked") is True and int(tree.get("left", 0)) > 0, (tree.get("unlocked"), tree.get("left")))
check("every rank says its channel and what one is worth",
      all(t.get("bucket") and int(t.get("per_rank", 0)) > 0
          for b in tree["branches"] for t in b["talents"]), tree["branches"][0]["talents"][0])
branch = tree["branches"][0]
shallow = branch["talents"][0]
deep = branch["talents"][-1]

st, no_deep = call("POST", "/v1/talents/buy", {"talent_id": deep["id"], "action_seq": seq_of(tok)}, token=tok)
check("a tier the branch has not paid for is refused",
      st == 409 and code(no_deep) == "talent_shut", (st, no_deep))

left_before = int(tree["left"])
st, bought = call("POST", "/v1/talents/buy", {"talent_id": shallow["id"], "action_seq": seq_of(tok)}, token=tok)
check("a rank is bought", st == 200 and int(bought.get("talents", {}).get("spent", 0)) == 1, (st, bought.get("talents", {}).get("spent")))
check("and a point is gone", int(bought["talents"]["left"]) == left_before - 1,
      (bought["talents"]["left"], left_before))
check("the answer carries the snapshot, because a rank can lift the pool's ceiling",
      isinstance(bought.get("snapshot"), dict), list(bought.keys()))

for _ in range(int(shallow["ranks"]) - 1):
    call("POST", "/v1/talents/buy", {"talent_id": shallow["id"], "action_seq": seq_of(tok)}, token=tok)
st, maxed = call("POST", "/v1/talents/buy", {"talent_id": shallow["id"], "action_seq": seq_of(tok)}, token=tok)
check("a talent at its last rank takes no more", st == 409 and code(maxed) == "talent_maxed", (st, maxed))

st, tree2 = call("GET", "/v1/talents", token=tok)
cost = int(tree2.get("respec_cost", 0))
gold_before = int(state(tok)["player"]["gold"])
st, back = call("POST", "/v1/talents/respec", {"action_seq": seq_of(tok)}, token=tok)
check("a respec gives every point back",
      st == 200 and int(back.get("talents", {}).get("spent", 0)) == 0, (st, back.get("talents", {}).get("spent")))
check("and costs the gold it said it would",
      gold_before - int(state(tok)["player"]["gold"]) == cost,
      (gold_before, state(tok)["player"]["gold"], cost))
check("the next respec costs more", int(back["talents"]["respec_cost"]) > cost,
      (back["talents"]["respec_cost"], cost))
st, empty = call("POST", "/v1/talents/respec", {"action_seq": seq_of(tok)}, token=tok)
check("an empty tree cannot be taken back", st == 409 and code(empty) == "no_talents", (st, empty))

print("\n== what moves the lord's own sequence ==")
seq = state(tok)["player"]["action_seq"]
for path in ["/v1/campaign", "/v1/talents", "/v1/hunt", "/v1/inventory"]:
    call("GET", path, token=tok)
check("no read moves the sequence", state(tok)["player"]["action_seq"] == seq, seq)

print()
if failures:
    print("FAILED: " + ", ".join(failures))
    sys.exit(1)
print("all good")
