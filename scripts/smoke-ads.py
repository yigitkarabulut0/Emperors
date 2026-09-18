#!/usr/bin/env python3
"""Herald's Tidings, end to end: the rewarded advert.

    python3 scripts/smoke-ads.py [<game-url>]

The rule the whole feature rests on is that THE CLIENT NEVER SAYS "I WATCHED
IT". A client that could say that could say it a hundred times, and the diamonds
it would mint are the ones the Royal Store sells. So a tap buys a TICKET, and
only a callback signed by Google turns that ticket into diamonds.

This drives both doors over real HTTP:

  * the store's section, which is hidden while the realm has no adverts;
  * the tap, its allowance, its cooldown and its one-at-a-time ticket;
  * the callback: a forgery, another lord's ticket, a replay, and the genuine
    article -- which pays once, however many times Google retries it.

On a realm with adverts configured (the local one, set up by this script's own
key) it plays the whole thing. On one without -- the deployed server, which
ships shut until the owner has an AdMob account -- it checks that the herald IS
shut and says the rest is skipped rather than pretending.

The local realm's server must be started with the pair this script makes:

    EMPERORS_ADMOB_UNIT=ca-app-pub-smoke/1 \\
    EMPERORS_ADMOB_DEV_KEY="$(cat $AD_DIR/ad.pub)" ...
"""
import base64, json, os, subprocess, sys, time, urllib.error, urllib.parse, urllib.request

BASE = (sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8080").rstrip("/")
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOCAL = "127.0.0.1" in BASE or "localhost" in BASE
LOCAL_DB = os.environ.get("EMPERORS_SMOKE_DB",
                          "postgres://emperors@127.0.0.1:5544/emperors_dev?sslmode=disable")
# The private half of the key the local server was given. Only ever local: a
# server that trusted this in prod would let anyone mint diamonds, and
# internal/config refuses to start with it set there.
AD_KEY = os.environ.get("EMPERORS_SMOKE_AD_KEY", "")
AD_KEY_ID = 1
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


def store(token):
    _, s = call("GET", "/v1/store/court", token=token)
    return s


def diamonds(token):
    _, s = call("GET", "/v1/state", token=token)
    return int(s.get("player", {}).get("diamonds", 0))


def grant(user, level=0, gold=0):
    env = dict(os.environ)
    env["DATABASE_URL"] = LOCAL_DB
    env.pop("DATABASE_URL_DIRECT", None)
    subprocess.run(["go", "run", "./cmd/devgrant", "-user", user,
                    "-level", str(level), "-gold", str(gold)],
                   cwd=os.path.join(ROOT, "server"), env=env, capture_output=True, text=True)


def sql(statement):
    return subprocess.run(["psql", LOCAL_DB, "-t", "-A", "-c", statement],
                          capture_output=True, text=True).stdout.strip()


def signed_callback(ticket, lord, txn, at_ms=None, key=None):
    """A callback the way Google sends one: the query signed byte for byte as it
    will arrive. The signature is over everything BEFORE "&signature=", so the
    string is built once and signed as-is -- re-encoding it would reorder it and
    the server would (rightly) refuse it."""
    at_ms = at_ms if at_ms is not None else int(time.time() * 1000)
    fields = [
        ("ad_network", "5450213213286189855"),
        ("ad_unit", "ca-app-pub-smoke/1"),
        ("custom_data", ticket),
        ("reward_amount", "1"),
        ("reward_item", "diamonds"),
        ("timestamp", str(at_ms)),
        ("transaction_id", txn),
        ("user_id", lord),
    ]
    body = "&".join("%s=%s" % (k, urllib.parse.quote(v, safe="")) for k, v in fields)
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key or AD_KEY],
                         input=body.encode(), capture_output=True).stdout
    sig = base64.urlsafe_b64encode(der).decode().rstrip("=")
    return "%s&signature=%s&key_id=%d" % (body, sig, AD_KEY_ID)


def ssv(query):
    st, out = call("GET", "/v1/ads/admob/ssv?" + query)
    return st, out


print("== the store's own section ==")
tok, name, pid = new_player("ad")
s = store(tok)
herald = s.get("herald", {})
check("the store answers with a herald block at all", isinstance(herald, dict), s.keys())
open_here = bool(herald.get("enabled", False))

if not open_here:
    check("a realm with no adverts hides the herald", herald.get("enabled") is False, herald)
    st, shut = call("POST", "/v1/ads/watch", {}, token=tok)
    check("and hands out no ticket", st == 409 and code(shut) == "herald_shut", (st, shut))
    st, _ = ssv("ad_unit=x&user_id=y&signature=zz&key_id=1")
    check("the callback answers 200 even so, so Google stops retrying", st == 200, st)
    print("\n(this realm has no adverts configured: the rest is skipped rather than pretended)")
    sys.exit(1 if failures else 0)

# The realm HAS one. A new lord is below the level it opens at, and that is a
# plate with a level on it -- not a hidden section, and not a ticket.
min_level = int(herald.get("unlock_level", 0))
check("a lord below the level still sees the plate",
      herald.get("unlocked") is False and min_level > 1, herald)
st, early = call("POST", "/v1/ads/watch", {}, token=tok)
check("and is told which level, not that the realm has none",
      st == 409 and code(early) == "herald_early", (st, early))

if not LOCAL or not AD_KEY:
    print("\n(the herald is open but this smoke has no signing key: the rest is skipped)")
    sys.exit(1 if failures else 0)

grant(name, level=max(min_level, 5), gold=0)
s = store(tok)
herald = s["herald"]
per_day = int(herald.get("per_day", 0))
check("at the level it opens", herald.get("unlocked") is True, herald)
check("the herald says what one is worth", bool(herald.get("lines")) and int(herald.get("diamonds", 0)) > 0,
      herald)
check("and how many are left today", int(herald.get("left", 0)) == per_day and per_day > 0, herald)
check("and which advert the client is to play", str(herald.get("unit", "")) != "", herald)

print("\n== a tap is a ticket ==")
st, t1 = call("POST", "/v1/ads/watch", {}, token=tok)
check("a tap hands back a ticket", st == 200 and t1.get("ticket") and t1.get("user_id") == pid, (st, t1))
st, t2 = call("POST", "/v1/ads/watch", {}, token=tok)
check("and a second tap hands back the SAME one", st == 200 and t2.get("ticket") == t1.get("ticket"),
      (t1.get("ticket"), t2.get("ticket")))
check("one row, not two", sql("SELECT count(*) FROM app.ad_watches WHERE player_id = '%s'" % pid) == "1")
before = diamonds(tok)

print("\n== only Google's signature pays ==")
forged = signed_callback(t1["ticket"], pid, "smoke-forged")
tampered = forged.replace("reward_amount=1", "reward_amount=9")
st, _ = ssv(tampered)
check("a tampered callback answers 200", st == 200, st)
check("and pays nothing", diamonds(tok) == before, (before, diamonds(tok)))

stranger_tok, stranger_name, stranger_pid = new_player("adx")
wrong = signed_callback(t1["ticket"], stranger_pid, "smoke-wrong-lord")
ssv(wrong)
check("a callback pointing one lord's watch at another pays nobody",
      diamonds(tok) == before and diamonds(stranger_tok) == 0)

good = signed_callback(t1["ticket"], pid, "smoke-%d" % int(time.time() * 1000))
st, _ = ssv(good)
check("the genuine article answers 200", st == 200, st)
paid = diamonds(tok)
check("and pays the advert's diamonds", paid == before + int(herald["diamonds"]),
      (before, paid, herald["diamonds"]))

st, _ = ssv(good)
check("Google's retry pays nothing more", diamonds(tok) == paid, (paid, diamonds(tok)))
check("and the watch is written down once",
      sql("SELECT count(*) FROM app.ad_watches WHERE player_id = '%s' AND paid_at IS NOT NULL" % pid) == "1")
check("the diamonds are on the ledger as the herald's own flow",
      sql("SELECT count(*) FROM app.diamond_ledger WHERE player_id = '%s' AND reason = 'advert'" % pid) == "1")

print("\n== the leashes ==")
cooldown = int(sql("SELECT (v.doc_json->'commerce'->'ads'->>'cooldown_minutes')::int "
                   "FROM admin.balance_activations a "
                   "JOIN admin.balance_versions v ON v.id = a.version_id "
                   "ORDER BY a.activated_at DESC, a.id DESC LIMIT 1") or 0)
st, soon = call("POST", "/v1/ads/watch", {}, token=tok)
if cooldown > 0:
    check("the herald catches his breath between adverts",
          st == 429 and code(soon) == "herald_soon", (st, soon))
    # Stepped over by moving the row, not by reaching past the rule.
    sql("UPDATE app.ad_watches SET paid_at = paid_at - interval '%d minutes' WHERE player_id = '%s'"
        % (cooldown + 1, pid))

left = per_day - 1
for i in range(left):
    st, t = call("POST", "/v1/ads/watch", {}, token=tok)
    if st != 200:
        check("advert %d of the day" % (i + 2), False, (st, t))
        break
    st, _ = ssv(signed_callback(t["ticket"], pid, "smoke-day-%d-%d" % (int(time.time() * 1000), i)))
    sql("UPDATE app.ad_watches SET paid_at = paid_at - interval '%d minutes' WHERE player_id = '%s'"
        % (cooldown + 1, pid))
check("the day's allowance pays what it says",
      diamonds(tok) == before + int(herald["diamonds"]) * per_day,
      (diamonds(tok), before + int(herald["diamonds"]) * per_day))
st, spent = call("POST", "/v1/ads/watch", {}, token=tok)
check("and the one after it is refused", st == 409 and code(spent) == "herald_spent", (st, spent))
s = store(tok)
check("the store says none are left", int(s["herald"].get("left", -1)) == 0, s.get("herald"))

print()
if failures:
    print("FAIL %d of the checks above" % len(failures))
    for f in failures:
        print("   -", f)
    sys.exit(1)
print("the herald pays only for what Google says was watched")
