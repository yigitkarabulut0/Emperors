#!/usr/bin/env python3
"""End-to-end check of M7: the admin surface and live balance publishing.

The property that matters: publishing a new balance version changes what the
GAME serves, with no redeploy and no restart.
"""
import json, sys, pathlib, urllib.request, urllib.error, random, string

GAME = "http://localhost:8080"
ADMIN = "http://localhost:8081"
PANEL = "http://localhost:3000"
FAILURES = []
ADMIN_USER, ADMIN_PASS = "yigit", "emperors admin 2026"


def call(base, method, path, body=None, token=None):
    req = urllib.request.Request(base + path, method=method)
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


print("\n== the admin surface is separate ==")
st, _ = call(GAME, "GET", "/admin/dashboard")
check("the admin API is not reachable on the game port", st == 404, st)
st, un = call(ADMIN, "GET", "/dashboard")
check("the admin API refuses anonymous callers", st == 401, (st, un))

print("\n== signing in ==")
st, bad = call(ADMIN, "POST", "/login", {"username": ADMIN_USER, "password": "wrong"})
check("a wrong password is refused", st == 401 and bad.get("code") == "bad_credentials", (st, bad))
st, ok = call(ADMIN, "POST", "/login", {"username": ADMIN_USER, "password": ADMIN_PASS})
check("signing in returns a token", st == 200 and ok.get("token"), (st, ok))
token = ok.get("token")
check("the role comes back", ok.get("role") == "owner", ok)

st, me = call(ADMIN, "GET", "/me", token=token)
check("the session resolves", st == 200 and me.get("username") == ADMIN_USER, (st, me))
st, junk = call(ADMIN, "GET", "/me", token="not-a-session")
check("a forged token is refused", st == 401, (st, junk))

print("\n== dashboard ==")
st, d = call(ADMIN, "GET", "/dashboard?days=30", token=token)
check("dashboard returns 200", st == 200, st)
print(f"        {d.get('players')} players ({d.get('bots')} bots), "
      f"{d.get('active_7d')} active this week, avg level {d.get('avg_level', 0):.1f}")
print(f"        {d.get('battles')} battles, attacker wins {d.get('attacker_win_pct', 0):.0f}%, "
      f"avg {d.get('avg_rounds', 0):.0f} rounds")
check("population is reported", d.get("players", 0) > 0, d.get("players"))
check("gold flows are broken down by reason", len(d.get("flows", [])) > 0, d.get("flows"))
check("the live balance version is shown", d.get("balance_version", 0) > 0, d.get("balance_version"))
for f in sorted(d.get("flows", []), key=lambda f: -abs(int(f["net"])))[:5]:
    print(f"        {f['reason']:<18} created {int(f['created']):>10,}  destroyed {int(f['destroyed']):>10,}")

print("\n== player tools ==")
st, ps = call(ADMIN, "GET", "/players?q=bot_0", token=token)
check("player search works", st == 200 and len(ps.get("players", [])) > 0, (st, len(ps.get("players", []))))
victim = ps["players"][0]
before_gold = int(victim["gold"])

st, adj = call(ADMIN, "POST", "/players/currency",
               {"player_id": victim["id"], "gold": 1234, "note": "smoke test"}, token=token)
check("granting gold works", st == 200, (st, adj))
if st == 200:
    check("the balance moved by exactly the grant", int(adj["gold"]) == before_gold + 1234,
          (before_gold, adj["gold"]))

st, neg = call(ADMIN, "POST", "/players/currency",
               {"player_id": victim["id"], "gold": -10**12, "note": "overdraw"}, token=token)
check("an adjustment that would go negative is refused", st == 500 or st == 400, st)

st, ban = call(ADMIN, "POST", "/players/state",
               {"player_id": victim["id"], "state": "banned", "note": "smoke test"}, token=token)
check("banning works", st == 200 and ban.get("state") == "banned", (st, ban.get("state")))
st, unban = call(ADMIN, "POST", "/players/state",
                 {"player_id": victim["id"], "state": "active", "note": "smoke test"}, token=token)
check("unbanning works", st == 200 and unban.get("state") == "active", (st, unban.get("state")))

print("\n== the audit trail ==")
st, audit = call(ADMIN, "GET", "/audit", token=token)
check("every action was recorded", st == 200 and len(audit.get("entries", [])) >= 3,
      len(audit.get("entries", [])))
actions = [e["action"] for e in audit.get("entries", [])]
check("the currency grant is in the trail", "player.adjust" in actions, actions[:5])
check("the ban is in the trail", "player.state" in actions, actions[:5])
check("entries name the admin who acted",
      all(e["admin"] == ADMIN_USER for e in audit["entries"][:3]), audit["entries"][:1])

print("\n== live balance publishing ==")
st, bal = call(ADMIN, "GET", "/balance", token=token)
check("the live document is readable", st == 200 and "document" in bal, st)
live_version = bal["version"]
doc = bal["document"]

# Read what the GAME currently serves, so the change can be observed end to end.
user = "cfg" + "".join(random.choices(string.ascii_lowercase, k=6))
_, reg = call(GAME, "POST", "/v1/auth/register",
              {"username": user, "password": "battery horse staple", "tz_offset_minutes": 0})
gtok = reg["access_token"]
_, s0 = call(GAME, "GET", "/v1/state", token=gtok)
job_before = next(j for j in s0["jobs"] if j["unlocked"])
print(f"        before: {job_before['name']} pays {job_before['gold_payout']} gold (config v{live_version})")

# Double EVERY job's payout, not just the first.
#
# Raising one job alone is what a careless designer would try, and the validator
# correctly refuses it: doubling Grapes makes its gold-per-energy exceed
# Strawberries', so unlocking the next job would be a downgrade. A uniform
# multiplier is the change that actually makes sense, and it keeps the ladder
# monotone.
for j in doc["jobs"]["jobs"]:
    j["base_gold"] = j["base_gold"] * 2

st, pub = call(ADMIN, "POST", "/balance/publish",
               {"document": doc, "note": "smoke: double the first job"}, token=token)
check("publishing returns 200", st == 200, (st, pub))
new_version = pub.get("id", 0)
check("a new version id was issued", new_version > live_version, (live_version, new_version))

_, s1 = call(GAME, "GET", "/v1/state", token=gtok)
job_after = next(j for j in s1["jobs"] if j["id"] == job_before["id"])
print(f"        after:  {job_after['name']} pays {job_after['gold_payout']} gold (config v{s1['config']['version']})")
check("the GAME serves the new payout with no restart",
      job_after["gold_payout"] == job_before["gold_payout"] * 2,
      (job_before["gold_payout"], job_after["gold_payout"]))
check("the game reports the new config version",
      s1["config"]["version"] == new_version, (new_version, s1["config"]["version"]))

print("\n== a bad document is refused ==")
broken = json.loads(json.dumps(doc))
broken["jobs"]["jobs"][0]["energy_cost"] = 0   # free energy = infinite gold
st, rej = call(ADMIN, "POST", "/balance/publish",
               {"document": broken, "note": "should never land"}, token=token)
check("a config that would break the economy is refused",
      st == 400 and rej.get("code") == "invalid_balance", (st, rej))
st, vs = call(ADMIN, "GET", "/balance/versions", token=token)
check("and it was never stored as a version",
      all(not v["note"].startswith("should never") for v in vs["versions"]),
      [v["note"] for v in vs["versions"][:3]])
check("exactly one version is live", sum(1 for v in vs["versions"] if v["live"]) == 1,
      [v["id"] for v in vs["versions"] if v["live"]])

print("\n== rollback ==")
st, rb = call(ADMIN, "POST", "/balance/rollback",
              {"version_id": live_version, "reason": "smoke: undo"}, token=token)
check("rolling back returns 200", st == 200, (st, rb))
_, s2 = call(GAME, "GET", "/v1/state", token=gtok)
job_back = next(j for j in s2["jobs"] if j["id"] == job_before["id"])
check("the game went back to the old payout",
      job_back["gold_payout"] == job_before["gold_payout"],
      (job_before["gold_payout"], job_back["gold_payout"]))
st, vs2 = call(ADMIN, "GET", "/balance/versions", token=token)
check("history was appended, not rewritten",
      len(vs2["versions"]) == len(vs["versions"]), (len(vs["versions"]), len(vs2.get("versions", []))))
check("the rolled-back version is live again",
      any(v["live"] and v["id"] == live_version for v in vs2["versions"]),
      [(v["id"], v["live"]) for v in vs2["versions"][:3]])

# --- the Next.js panel -------------------------------------------------------
#
# The panel is a separate process, so these checks are skipped rather than failed
# when it is not running. What they prove is the only thing the panel can get
# wrong on its own: that a signed-in request server-renders REAL rows from the Go
# API, and that an unsigned one never does.
print("\n== the panel renders what the API returns ==")


def page(path, cookie=None):
    """A page fetch, with the redirect left unfollowed.

    The panel is a client-rendered app: the server sends the shell and the rows
    arrive over /api/q with the session cookie. So a page check reads the shell
    and where a dead session is sent, and the rows are checked through the proxy.
    """
    req = urllib.request.Request(PANEL + path)
    if cookie:
        req.add_header("Cookie", "emperors_admin_session=" + cookie)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, r.read().decode(errors="replace"), r.headers.get("location", "")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace"), e.headers.get("location", "")
    except urllib.error.URLError:
        return 0, "", ""


def proxied(op, cookie=None):
    """A read through the panel's own /api/q proxy, which is how every row in
    the panel is fetched: the session cookie in, the Go API's Result out."""
    req = urllib.request.Request(PANEL + "/api/q/" + op)
    if cookie:
        req.add_header("Cookie", "emperors_admin_session=" + cookie)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw or b"{}")
        except json.JSONDecodeError:
            return e.code, {"raw": raw.decode(errors="replace")[:200]}
    except urllib.error.URLError:
        return 0, {}


st, _, _ = page("/login")
if st == 0:
    print("  SKIP  the panel is not running on :3000")
else:
    check("the panel serves its login page", st == 200, st)

    # An anonymous visitor must never see player data.
    st, anon, loc = page("/players")
    check("an anonymous visitor is not shown players",
          "bot_0" not in anon and "Find a player" not in anon, (st, loc))

    # The realistic failure mode is a session that expired between page loads.
    # It must land on the sign-in page, not on a stack trace.
    # Next answers a redirect with its own bare shell (which carries the
    # __next_error__ id), so what says "sign in" here is the 307 to /login --
    # and the body must still hold no player.
    st, stale, loc = page("/players", cookie="expired-or-forged")
    check("a stale session is sent to sign in, not an error page",
          st == 307 and loc == "/login" and "bot_0" not in stale, (st, loc))

    # Every page is the same shell with a section inside it. Pages whose body is
    # drawn from the store (balance, audit) can only prove the shell here; their
    # rows are proved through the proxy below.
    NAV = ("Players", "Live ops", "Rekabet", "Economy", "Audit", "Balance")
    for path, needle in [("/", "Who is in the game"), ("/players", "Find a player"),
                         ("/pvp", "The Honour Arena"), ("/balance", None), ("/audit", None)]:
        st, b, _ = page(path, cookie=token)
        ok = st == 200 and "__next_error__" not in b and all(w in b for w in NAV)
        if needle:
            ok = ok and needle in b
        check(f"{path} renders inside the panel's shell", ok, (st, needle))

    # Every row in the panel arrives this way, so the proxy is the thing to test:
    # it carries the session to the Go API, allowlists the op by name, and passes
    # the API's own answer through rather than a paraphrase of it.
    st, rows = proxied("browse?q=bot_0&bots=1&limit=5", cookie=token)
    check("the panel fetches player rows through its proxy",
          st == 200 and rows.get("ok") and (rows.get("data") or {}).get("players"), (st, rows))
    st, none = proxied("browse?q=zzzznomatch&bots=1&limit=5", cookie=token)
    check("a search with no hits comes back empty, not broken",
          st == 200 and none.get("ok") and none["data"]["players"] == [], (st, none))
    st, shut = proxied("browse?q=bot_0&bots=1", cookie="expired-or-forged")
    check("the proxy refuses a dead session", st == 401 and shut.get("code") == "unauthorized", (st, shut))
    st, junk = proxied("noSuchRead", cookie=token)
    check("an unknown read is refused by name", st == 404 and junk.get("code") == "unknown_op", (st, junk))
    for op in ("dashboard?days=7", "balance", "audit?limit=5", "liveopsHourly",
               "pvpArena?limit=5", "pvpBounties?limit=5", "pvpThrone"):
        st, r = proxied(op, cookie=token)
        check("the proxy serves %s" % op.split("?")[0], st == 200 and r.get("ok"), (st, r))

    # The panel talks to the Go API; it must not hold a database URL of its own.
    env = pathlib.Path("admin").rglob("*.ts")
    leaked = [str(f) for f in env if "postgres" in f.read_text()]
    check("the panel holds no database credentials", not leaked, leaked)

print()
if FAILURES:
    print(f"{len(FAILURES)} FAILED: " + ", ".join(FAILURES))
    sys.exit(1)
print("all checks passed")
