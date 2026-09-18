#!/usr/bin/env python3
"""Krallik Boss ve Savaslari (Wave 8), end to end, as a kingdom meets it.

    python3 scripts/smoke-boss.py [<game-url>]

Lords are registered and driven through everything the wave added, at the same
doors a phone uses:

  * the beast: a kingdom's own, six blows a member, each one a real fight cut
    short that costs the energy a raid costs; the damage written down once as a
    total; the seventh blow refused; the chests paid by LETTER when the cycle
    closes, and paid once however often the settle runs;
  * the war: two kingdoms drawn against each other, three attacks a day and no
    fourth, a lord of one's own kingdom refused, a lord outside the war refused,
    and -- the rule the whole thing rests on -- an attack that moves POINTS and
    nothing else: no gold, no energy, no shield, and not the lord's own
    action_seq;
  * a lord who has lost every banner is routed: still worth riding at, and
    worth a quarter;
  * the week's purse by letter, the kingdom's renown and experience, and the
    Warlord's title.

The two jobs (boss_cycle, war_draw) and the two settles are run through the
panel's dev door, which only the local realm has. On a realm without it the
parts that need it say they are skipped rather than pretending.
"""
import json, os, subprocess, sys, time, urllib.error, urllib.request

BASE = (sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8080").rstrip("/")
ADMIN = os.environ.get("EMPERORS_SMOKE_ADMIN", "http://127.0.0.1:8081").rstrip("/")
ADMIN_USER = os.environ.get("EMPERORS_SMOKE_ADMIN_USER", "yigit")
ADMIN_PASS = os.environ.get("EMPERORS_SMOKE_ADMIN_PASS", "emperors admin 2026")
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOCAL = "127.0.0.1" in BASE or "localhost" in BASE
LOCAL_DB = os.environ.get("EMPERORS_SMOKE_DB",
                          "postgres://emperors@127.0.0.1:5544/emperors_dev?sslmode=disable")
failures = []


def call(method, path, body=None, token=None, base=None):
    req = urllib.request.Request(
        (base or BASE) + path, method=method,
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
    except OSError as e:
        return 0, {"error": {"code": "unreachable", "message": str(e)}}


def code(body):
    return (body.get("error") or {}).get("code", body.get("code", ""))


def check(name, ok, detail=""):
    print(("  PASS  " if ok else "  FAIL  ") + name + ("" if ok else f"  <- {detail}"))
    if not ok:
        failures.append(name)


def new_player(tag):
    user = "%s%d" % (tag, int(time.time() * 1_000_000) % 1_000_000_000)
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


def grant(user, level=0, gold=0):
    env = dict(os.environ)
    env["DATABASE_URL"] = LOCAL_DB
    env.pop("DATABASE_URL_DIRECT", None)
    subprocess.run(["go", "run", "./cmd/devgrant", "-user", user,
                    "-level", str(level), "-gold", str(gold)],
                   cwd=os.path.join(ROOT, "server"), env=env, capture_output=True, text=True)


def sql(statement):
    """A row the game has no door for: a soldier in the yard, a clock moved on.
    Only ever on the LOCAL realm."""
    return subprocess.run(["psql", LOCAL_DB, "-t", "-A", "-c", statement],
                          capture_output=True, text=True).stdout.strip()


def arm(user):
    """The army a lord of thirty would have -- three sellswords and their stats
    -- and a full pool. A naked lord does no damage worth measuring, and six
    blows at a raid's price is more energy than a fresh account is given."""
    sql("""INSERT INTO app.soldiers (player_id, slot_index, type_id, tier, level, name,
                                     rolled_config_version)
           SELECT id, n, 'mercenary', 'rare', level, 'Sellsword', 1
           FROM app.players, generate_series(1,3) n WHERE username = '%s'
           ON CONFLICT DO NOTHING;
           UPDATE app.players SET soldier_slots = GREATEST(soldier_slots, 3),
                  stat_attack = 60, stat_defense = 60, energy_milli = 400000,
                  energy_updated_at = now() WHERE username = '%s';""" % (user, user))


admin_token = ""


def run_job(name):
    st, out = call("POST", "/dev/jobs/run", {"name": name}, token=admin_token, base=ADMIN)
    return st == 200, (st, out)


print("== shut doors ==")
tok, name, pid = new_player("w8")
st, boss = call("GET", "/v1/boss", token=tok)
check("the beast answers a lord of level one", st == 200, (st, boss))
check("and says it is shut, with the level that opens it",
      not boss.get("unlocked", True) and int(boss.get("unlock_level", 0)) > 0, boss)
check("a lord with no kingdom is told so rather than shown nothing",
      boss.get("has_kingdom") is False and boss.get("beast") is None, boss)
st, shut = call("POST", "/v1/boss/hit", {"action_seq": seq_of(tok)}, token=tok)
check("a lord under the level cannot strike", st == 403 and code(shut) == "boss_locked", (st, shut))

st, war = call("GET", "/v1/war", token=tok)
check("the war answers too, and is shut", st == 200 and not war.get("unlocked", True), (st, war))
check("and says when the pairs are next drawn", int(war.get("draws_in", 0)) > 0, war)
st, nowar = call("POST", "/v1/war/attack", {"player_id": pid}, token=tok)
check("a lord cannot ride out against themselves", st in (400, 403) and code(nowar) in
      ("war_self", "war_locked"), (st, nowar))

if not LOCAL:
    print("\n(this realm has no dev door: the rest is skipped rather than pretended)")
    sys.exit(1 if failures else 0)

st, login = call("POST", "/login", {"username": ADMIN_USER, "password": ADMIN_PASS}, base=ADMIN)
if st != 200:
    print("cannot reach the local panel to run the wave's jobs:", st, login)
    sys.exit(2)
admin_token = login.get("token", "")

print("\n== a kingdom, and a beast for it ==")
grant(name, level=30, gold=5_000_000)
arm(name)
tag = name[-4:].upper()
st, found = call("POST", "/v1/kingdom/found",
                 {"name": "Smoke " + name[-8:], "tag": tag, "action_seq": seq_of(tok)}, token=tok)
check("the lord founds a kingdom", st == 200, (st, found))

mates = []
for i in range(2):
    mtok, mname, mpid = new_player("w8m")
    grant(mname, level=28, gold=5_000_000)
    arm(mname)
    sql("""UPDATE app.players SET kingdom_id = (SELECT kingdom_id FROM app.players WHERE username='%s'),
           kingdom_role = 'member', kingdom_joined_at = now() WHERE username = '%s';""" % (name, mname))
    mates.append((mtok, mname, mpid))
# GetArmy is what caches Might, and the beast's wall is cut from it.
for mtok, _, _ in mates:
    call("GET", "/v1/army", token=mtok)
call("GET", "/v1/army", token=tok)

ok, detail = run_job("boss_cycle")
check("the cycle job runs", ok, detail)
st, boss = call("GET", "/v1/boss", token=tok)
beast = boss.get("beast") or {}
check("a beast now stands against the kingdom",
      boss.get("standing") is True and beast.get("id"), boss)
check("its wall was cut from the kingdom, not from the lord",
      int(beast.get("kingdom_might", 0)) > 0 and int(beast.get("hp_max", 0)) > int(beast.get("kingdom_might", 0)),
      (beast.get("hp_max"), beast.get("kingdom_might")))
check("and the card says what a blow costs and how many are left",
      int(boss["mine"]["energy"]) > 0 and int(boss["mine"]["hits_left"]) == int(boss["mine"]["hits_total"]),
      boss.get("mine"))
check("the three chests say what they ask for and what they hold",
      len(boss.get("chests", [])) == 3 and all(c.get("need") and c.get("lines") for c in boss["chests"]),
      boss.get("chests"))

print("\n== six blows and no seventh ==")
before = state(tok)
energy_before = int(before["energy"]["current"])
cost = int(boss["mine"]["energy"])
total = int(boss["mine"]["hits_total"])
dealt = 0
for i in range(total):
    st, hit = call("POST", "/v1/boss/hit", {"action_seq": seq_of(tok)}, token=tok)
    if st != 200:
        check("blow %d lands" % (i + 1), False, (st, hit))
        break
    dealt += int(hit.get("damage", 0))
    if i == 0:
        check("a blow comes back with a replay to watch",
              isinstance(hit.get("replay"), dict) and hit["replay"].get("events"), list(hit.keys()))
        check("and it is a fight CUT SHORT, not a whole battle",
              int(hit["replay"].get("rounds", 99)) <= 8, hit["replay"].get("rounds"))
    check("blow %d leaves %d" % (i + 1, total - i - 1), int(hit.get("hits_left", -1)) == total - i - 1,
          hit.get("hits_left"))
st, seventh = call("POST", "/v1/boss/hit", {"action_seq": seq_of(tok)}, token=tok)
check("the seventh blow is refused", st == 409 and code(seventh) == "no_blows", (st, seventh))

after = state(tok)
spent = energy_before - int(after["energy"]["current"])
check("six blows cost six raids' energy", spent == cost * total, (spent, cost * total))
st, boss = call("GET", "/v1/boss", token=tok)
check("the damage list has the lord who struck at the top",
      boss["damage"] and boss["damage"][0]["mine"] is True and int(boss["damage"][0]["damage"]) == dealt,
      (dealt, boss.get("damage", [])[:1]))
check("and what the lord did is what came off the beast",
      int(boss["beast"]["hp_max"]) - int(boss["beast"]["hp_left"]) == dealt,
      (boss["beast"]["hp_max"], boss["beast"]["hp_left"], dealt))
check("the card no longer offers a blow", boss["mine"]["can_strike"] is False, boss["mine"])

print("\n== the chests come when the cycle closes ==")
sql("""UPDATE app.kingdom_bosses SET ends_at = now() - interval '1 minute'
       WHERE kingdom_id = (SELECT kingdom_id FROM app.players WHERE username='%s')
         AND settled_at IS NULL;""" % name)
ok, detail = run_job("boss_settle")
check("the settle runs", ok, detail)
letters = sql("SELECT count(*) FROM app.mail WHERE player_id = '%s' AND kind = 'boss'" % pid)
check("a lord who struck is sent one letter", letters == "1", letters)
ok, detail = run_job("boss_settle")
check("and a second settle sends no second letter", ok and
      sql("SELECT count(*) FROM app.mail WHERE player_id = '%s' AND kind = 'boss'" % pid) == "1", detail)
st, mail = call("GET", "/v1/mail", token=tok)
chest = next((m for m in mail.get("mail", []) if m.get("kind") == "boss"), {})
check("the letter carries what the chests hold", bool(chest.get("lines")), chest)
check("and it is claimable", chest.get("claimable") is True, chest)

print("\n== the war ==")
# A second kingdom, near enough in strength to be drawn against the first.
foes = []
ftok0, fname0, fpid0 = new_player("w8f")
grant(fname0, level=30, gold=5_000_000)
arm(fname0)
st, ffound = call("POST", "/v1/kingdom/found",
                  {"name": "Foes " + fname0[-8:], "tag": fname0[-4:].upper(),
                   "action_seq": seq_of(ftok0)}, token=ftok0)
check("the foes found a kingdom", st == 200, (st, ffound))
foes.append((ftok0, fname0, fpid0))
for i in range(2):
    xtok, xname, xpid = new_player("w8g")
    grant(xname, level=28, gold=5_000_000)
    arm(xname)
    sql("""UPDATE app.players SET kingdom_id = (SELECT kingdom_id FROM app.players WHERE username='%s'),
           kingdom_role = 'member', kingdom_joined_at = now() WHERE username = '%s';""" % (fname0, xname))
    foes.append((xtok, xname, xpid))
for t, _, _ in foes:
    call("GET", "/v1/army", token=t)

# A week is drawn ONCE (admin.period_closes), and the local realm's own runner
# may have drawn this one already -- with no kingdom big enough in it. The claim
# is cleared so the draw can be watched actually happening, and the week's own
# rows with it, so what is read back afterwards is this run's and not a previous
# one's. The local realm is the smoke's to sweep.
sql("""DELETE FROM app.war_attacks; DELETE FROM app.wars;
       DELETE FROM admin.period_closes WHERE what = 'war_draw';""")
ok, detail = run_job("war_draw")
check("the draw runs", ok, detail)
drawn = int(sql("SELECT count(*) FROM app.wars") or 0)
check("and the week has its pairs", drawn > 0, drawn)
# Which kingdoms the draw put together depends on every kingdom in the realm,
# and the week is drawn ONCE (admin.period_closes) -- so the rest of this is
# fought on a pair the smoke stands up itself, between the two kingdoms it made.
# The draw's own rules are held by internal/game/war's tests and the itest.
mine_id = sql("SELECT kingdom_id FROM app.players WHERE username='%s'" % name)
theirs_id = sql("SELECT kingdom_id FROM app.players WHERE username='%s'" % fname0)
# The week a war is filed under is the Monday of the week its Friday draw fell
# in, which is not always this Monday: it is read back off the rows the draw
# just wrote rather than worked out again here.
week = sql("SELECT week FROM app.wars ORDER BY week DESC LIMIT 1")
# And the realm's other pairs go with them: the settle below closes every war
# that is due, and another kingdom's would name its own Warlord.
sql("""DELETE FROM app.war_attacks; DELETE FROM app.wars;
       INSERT INTO app.wars (week, a_id, b_id, a_might, b_might, starts_at, ends_at)
       SELECT DATE '%s', '%s', '%s',
              (SELECT coalesce(sum(might),0) FROM app.players WHERE kingdom_id = '%s'),
              (SELECT coalesce(sum(might),0) FROM app.players WHERE kingdom_id = '%s'),
              now() - interval '1 hour', now() + interval '2 days';"""
    % (week, mine_id, theirs_id, mine_id, theirs_id))
st, war = call("GET", "/v1/war", token=tok)
w = war.get("war") or {}
check("the kingdom has a war this week", bool(w.get("id")) and w.get("live") is True, war)
check("and it knows both sides", w.get("mine", {}).get("name") and w.get("theirs", {}).get("name"), w)
check("the enemy's lords are offered with what each is worth",
      war.get("enemies") and all(int(e.get("worth", 0)) > 0 for e in war["enemies"]),
      war.get("enemies"))
check("the shield note is the server's own words",
      "shield" in str(war.get("rules", {}).get("shield_note", "")).lower(), war.get("rules"))

if not war.get("enemies"):
    print("\nthe war did not come back with a roster: the rest cannot be fought")
    sys.exit(1)
target = war["enemies"][0]
before = state(tok)
st, hit = call("POST", "/v1/war/attack", {"player_id": target["player_id"]}, token=tok)
check("a lord rides out", st == 200 and isinstance(hit.get("replay"), dict), (st, hit))
after = state(tok)
check("and NOTHING of theirs moved: no gold",
      int(before["player"]["gold"]) == int(after["player"]["gold"]),
      (before["player"]["gold"], after["player"]["gold"]))
check("no energy", int(before["energy"]["current"]) == int(after["energy"]["current"]),
      (before["energy"]["current"], after["energy"]["current"]))
check("and not the number the queued collects are waiting on",
      int(before["player"]["action_seq"]) == int(after["player"]["action_seq"]),
      (before["player"]["action_seq"], after["player"]["action_seq"]))
check("the points went on the board", int(hit.get("points", 0)) > 0 and
      int(hit.get("my_points", 0)) > 0, hit)

st, own = call("POST", "/v1/war/attack", {"player_id": mates[0][2]}, token=tok)
check("a lord may not ride at their own kingdom",
      st == 409 and code(own) == "war_not_foe", (st, own))
otok, oname, opid = new_player("w8o")
st, out = call("POST", "/v1/war/attack", {"player_id": opid}, token=tok)
check("nor at a lord outside the war", st == 409 and code(out) == "war_not_foe", (st, out))

per_day = int(war["rules"]["attacks_per_day"])
for i in range(per_day - 1):
    st, more = call("POST", "/v1/war/attack",
                    {"player_id": war["enemies"][(i + 1) % len(war["enemies"])]["player_id"]}, token=tok)
    check("attack %d of the day lands" % (i + 2), st == 200, (st, more))
st, fourth = call("POST", "/v1/war/attack", {"player_id": target["player_id"]}, token=tok)
check("and the day's %dth is refused" % (per_day + 1),
      st == 409 and code(fourth) == "no_war_attacks", (st, fourth))

print("\n== a routed lord ==")
war_id = w["id"]
banners = int(war["rules"]["banners"])
sql("""INSERT INTO app.war_attacks (war_id, attacker_id, defender_id, side, won, points, created_at)
       SELECT '%s', '%s', '%s', 'a', true, 10, now() FROM generate_series(1, %d);"""
    % (war_id, mates[0][2], target["player_id"], banners))
st, war2 = call("GET", "/v1/war", token=tok)
routed = next((e for e in war2.get("enemies", []) if e["player_id"] == target["player_id"]), {})
check("a lord who has lost every banner is routed",
      routed.get("routed") is True and int(routed.get("banners_lost", 0)) >= banners, routed)
check("and is still worth riding at, for a quarter",
      0 < int(routed.get("worth", 0)) < int(target.get("worth", 99)), (target.get("worth"), routed.get("worth")))

print("\n== the week's purse ==")
kingdom_id = sql("SELECT kingdom_id FROM app.players WHERE username='%s'" % name)
rep_before = int(sql("SELECT reputation FROM app.kingdoms WHERE id='%s'" % kingdom_id) or 0)
xp_before = int(sql("SELECT xp FROM app.kingdoms WHERE id='%s'" % kingdom_id) or 0)
sql("UPDATE app.wars SET ends_at = now() - interval '1 minute' WHERE settled_at IS NULL;")
ok, detail = run_job("war_settle")
check("the settle runs", ok, detail)
check("a lord who rode out is sent the purse",
      sql("SELECT count(*) FROM app.mail WHERE player_id = '%s' AND kind = 'war'" % pid) == "1")
ok, _ = run_job("war_settle")
check("and a second settle pays nobody twice", ok and
      sql("SELECT count(*) FROM app.mail WHERE player_id = '%s' AND kind = 'war'" % pid) == "1")
rep_after = int(sql("SELECT reputation FROM app.kingdoms WHERE id='%s'" % kingdom_id) or 0)
xp_after = int(sql("SELECT xp FROM app.kingdoms WHERE id='%s'" % kingdom_id) or 0)
check("the kingdom took renown for it", rep_after > rep_before, (rep_before, rep_after))
check("and experience", xp_after > xp_before, (xp_before, xp_after))
warlord = sql("""SELECT count(*) FROM app.player_cosmetics c JOIN app.players p ON p.id = c.player_id
                 WHERE c.cosmetic_id = 'title_warlord' AND p.kingdom_id IN (
                   SELECT kingdom_id FROM app.players WHERE username IN ('%s','%s'))"""
              % (name, fname0))
check("and one lord of the two kingdoms is the Warlord of the Week", warlord == "1", warlord)

print("\n== the settled war still reads ==")
st, done = call("GET", "/v1/war", token=tok)
settled = (done.get("war") or {})
check("the week's result is on the banner",
      settled.get("settled") is True and (settled.get("won") or settled.get("drawn")
                                          or settled.get("won") is False), settled)

print()
if failures:
    print("FAIL %d of the checks above" % len(failures))
    for f in failures:
        print("   -", f)
    sys.exit(1)
print("the beast and the war hold end to end")
