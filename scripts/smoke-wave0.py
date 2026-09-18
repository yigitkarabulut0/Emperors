#!/usr/bin/env python3
"""Wave 0 end to end: the Royal Mail, three refills a day, the client's events,
and a deletion that leaves the account's record behind.

    python3 scripts/smoke-wave0.py <game-url> [<admin-url> <admin-user> <admin-pass>]

Without admin credentials (the live server) it checks what any player can:
  * the store prices the day's first refill at 20 and says "Refill 1 of 3 today";
  * an empty inbox answers, the heartbeat counts letters, a letter that is not
    yours is not found, and mail takes no action_seq;
  * /v1/events keeps the listed events and drops the rest, without failing;
  * the account deletes: there is no lord left to read, and its session is gone.

With them (a local or staging API: never give this production's owner account)
it also sends a letter from the panel and claims it, and buys the day's three
refills at 20, 30 and 45 and is refused a fourth.
"""
import json, sys, time, urllib.error, urllib.request

GAME = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8080"
ADMIN = sys.argv[2] if len(sys.argv) > 2 else None
ADMIN_USER = sys.argv[3] if len(sys.argv) > 3 else None
ADMIN_PASS = sys.argv[4] if len(sys.argv) > 4 else None
PW = "battery horse staple"
failures = []


def call(base, method, path, body=None, token=None):
    req = urllib.request.Request(
        base + path, method=method,
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


def check(name, ok, detail=""):
    print(("  PASS  " if ok else "  FAIL  ") + name + ("" if ok else f"  <- {detail}"))
    if not ok:
        failures.append(name)


def register(prefix):
    user = "%s%d" % (prefix, int(time.time() * 1000) % 10_000_000)
    st, r = call(GAME, "POST", "/v1/auth/register", {"username": user, "password": PW, "tz_offset_minutes": 0})
    if st not in (200, 201):
        print("cannot register a player:", st, r)
        sys.exit(2)
    return user, r["access_token"], r["refresh_token"], r["player_id"]


def state(tok):
    return call(GAME, "GET", "/v1/state", token=tok)[1]


# --- the store ------------------------------------------------------------------
user, tok, refresh, pid = register("wz")
st, store = call(GAME, "GET", "/v1/store", token=tok)
refill = next((g for g in store.get("goods", []) if g.get("id") == "energy_refill"), {})
check("the store answers", st == 200, st)
check("the day's first refill costs 20", refill.get("diamonds") == 20, refill)
check("and says which of the day's it is", refill.get("caption") == "Refill 1 of 3 today", refill.get("caption"))
check("the day allows three", refill.get("refills_limit") == 3, refill)
check("a full pool is not refilled", refill.get("useful") is False, refill)

# --- mail, as any player --------------------------------------------------------
st, box = call(GAME, "GET", "/v1/mail", token=tok)
check("an empty inbox answers", st == 200 and box.get("mail") == [] and box.get("waiting") == 0, (st, box))
st, beat = call(GAME, "POST", "/v1/presence", {}, tok)
check("the heartbeat counts letters", st == 200 and beat.get("badges", {}).get("mail") == 0, beat)
st, r = call(GAME, "POST", "/v1/mail/claim", {"id": 999999999}, tok)
check("a letter that is not yours is not found", st == 404, (st, r))
st, r = call(GAME, "POST", "/v1/mail/claim", {"id": 1, "action_seq": 1}, tok)
check("mail takes no action_seq", st == 400, (st, r))

# --- events ---------------------------------------------------------------------
st, r = call(GAME, "POST", "/v1/events", {"events": [
    {"name": "app_open", "props": {"cold": True}, "at": int(time.time())},
    {"name": "screen", "props": {"name": "collect"}},
    {"name": "screen", "props": {"name": "Not an id"}},
    {"name": "purchase_start"},
]}, tok)
check("events answer", st == 200, (st, r))
check("the listed ones are kept and the rest dropped", r.get("recorded") == 2 and r.get("dropped") == 2, r)

# --- with the panel -------------------------------------------------------------
if ADMIN and ADMIN_USER and ADMIN_PASS:
    st, r = call(ADMIN, "POST", "/login", {"username": ADMIN_USER, "password": ADMIN_PASS})
    if st != 200:
        print("cannot sign in to the admin API:", r)
        sys.exit(2)
    atok = r["token"]

    st, sent = call(ADMIN, "POST", "/mail/send", {
        "target": "player", "player_id": pid, "title": "A smoke-test gift",
        "body": "From the smoke test.", "attachments": {"diamonds": 7, "tokens": {"energy_potion": 1}},
        "note": "smoke-wave0"}, atok)
    check("the panel sends a letter", st == 200 and sent.get("delivered") == 1, (st, sent))
    st, box = call(GAME, "GET", "/v1/mail", token=tok)
    letter = (box.get("mail") or [{}])[0]
    check("it arrives, claimable, with its lines", letter.get("claimable") is True and len(letter.get("lines", [])) == 2, box)
    beat = call(GAME, "POST", "/v1/presence", {}, tok)[1]
    check("and the heartbeat counts it", beat.get("badges", {}).get("mail") == 1, beat)
    st, r = call(GAME, "POST", "/v1/mail/delete", {"id": letter.get("id")}, tok)
    check("a letter with something in it cannot be thrown away", st == 409 and r.get("code") == "mail_unclaimed", (st, r))
    before = state(tok)["player"]["diamonds"]
    st, r = call(GAME, "POST", "/v1/mail/claim", {"id": letter.get("id")}, tok)
    check("claiming pays it", st == 200 and r.get("snapshot", {}).get("player", {}).get("diamonds") == before + 7, (st, r))
    check("and does not move the sequence", r.get("snapshot", {}).get("player", {}).get("action_seq") == state(tok)["player"]["action_seq"], r)
    st, r = call(GAME, "POST", "/v1/mail/claim", {"id": letter.get("id")}, tok)
    check("a second claim is refused", st == 409 and r.get("code") == "already_claimed", (st, r))
    st, _ = call(GAME, "POST", "/v1/mail/delete", {"id": letter.get("id")}, tok)
    check("a claimed letter can be thrown away", st == 204, st)

    # The day's refills: the potion is one of them.
    call(ADMIN, "POST", "/players/currency", {"player_id": pid, "gold": 0, "diamonds": 200, "note": "smoke-wave0"}, atok)
    paid = []
    for i in range(3):
        call(ADMIN, "POST", "/players/energy", {"player_id": pid, "energy": 0, "note": "smoke-wave0"}, atok)
        s = state(tok)
        have = s["player"]["diamonds"]
        pay = {"pay": "token"} if i == 0 else {}
        st, r = call(GAME, "POST", "/v1/store/buy", {"good": "energy_refill", "action_seq": s["player"]["action_seq"] + 1, **pay}, tok)
        check(f"refill {i + 1} goes through", st == 200, (st, r))
        paid.append(have - state(tok)["player"]["diamonds"])
    check("a potion pays for the first, then 30 and 45", paid == [0, 30, 45], paid)
    call(ADMIN, "POST", "/players/energy", {"player_id": pid, "energy": 0, "note": "smoke-wave0"}, atok)
    s = state(tok)
    st, r = call(GAME, "POST", "/v1/store/buy", {"good": "energy_refill", "action_seq": s["player"]["action_seq"] + 1}, tok)
    check("a fourth is refused", st == 409 and r.get("code") == "refills_exhausted", (st, r))
    refill = next(g for g in call(GAME, "GET", "/v1/store", token=tok)[1]["goods"] if g["id"] == "energy_refill")
    check("and the store says so", refill.get("caption") == "No refills left today" and refill.get("useful") is False, refill)
else:
    print("  SKIP  the panel's letter and the refill ladder (no admin credentials)")

# --- deletion -------------------------------------------------------------------
st, r = call(GAME, "POST", "/v1/account/delete", {"password": PW}, tok)
check("the account deletes", st == 204, (st, r))
st, _ = call(GAME, "GET", "/v1/state", token=tok)
check("there is no lord left to read", st == 404, st)
st, r = call(GAME, "POST", "/v1/auth/refresh", {"refresh_token": refresh})
check("its session is gone", st == 401, (st, r))

print("\n%d FAILED" % len(failures) if failures else "\nwave 0 smoke clean")
sys.exit(1 if failures else 0)
