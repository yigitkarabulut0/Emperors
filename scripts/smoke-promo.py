#!/usr/bin/env python3
"""Promo codes and bringing a friend, end to end.

    python3 scripts/smoke-promo.py <game-url> [--admin <url> <user> <pass>]

Without --admin (the live server) it checks what any player can:
  * a code nobody issued is refused, and a redemption without a phone is too;
  * a lord has a six-letter code of their own, a new lord may enter a friend's,
    and their own code or an unknown one is refused.

With --admin (a local or staging panel API: never production's owner account)
it also makes a code in the panel, redeems it, finds its letter in the Royal
Mail, and is refused a second time and on a second account on the same phone.
"""
import argparse, json, sys, time, urllib.error, urllib.request, uuid

ap = argparse.ArgumentParser()
ap.add_argument("game", nargs="?", default="http://127.0.0.1:8080")
ap.add_argument("--admin", nargs=3, metavar=("URL", "USER", "PASS"))
args = ap.parse_args()
GAME = args.game.rstrip("/")
PW = "battery horse staple"
failures = []


def call(base, method, path, body=None, token=None):
    req = urllib.request.Request(
        base + path, method=method, data=json.dumps(body).encode() if body is not None else None,
        headers={"content-type": "application/json", **({"authorization": "Bearer " + token} if token else {})})
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


def register(prefix, device):
    user = "%s%d" % (prefix, int(time.time() * 1000) % 10_000_000)
    st, r = call(GAME, "POST", "/v1/auth/register",
                 {"username": user, "password": PW, "tz_offset_minutes": 0, "device": device})
    if st not in (200, 201):
        print("cannot register a player:", st, r)
        sys.exit(2)
    return r["access_token"]


phone = "SMOKE-" + str(uuid.uuid4())
tok = register("pz", phone)

print("promo codes")
st, r = call(GAME, "POST", "/v1/promo/redeem", {"code": "NO" + uuid.uuid4().hex[:8].upper(), "device": phone}, tok)
check("a code nobody issued is refused", st == 404 and r.get("code") == "promo_invalid", (st, r))
st, r = call(GAME, "POST", "/v1/promo/redeem", {"code": "ANYCODE1", "device": ""}, tok)
check("a redemption without a phone is refused", st == 400 and r.get("code") == "no_device", (st, r))

print("bringing a friend")
st, mine = call(GAME, "GET", "/v1/referral", token=tok)
check("a lord has a code of their own", st == 200 and len(mine.get("code", "")) == 6, (st, mine))
check("a new lord may enter a friend's code", mine.get("can_claim") is True and mine.get("claim_in", 0) > 0, mine)
check("the rewards are said", mine.get("reward_level", 0) > 1 and mine.get("inviter_diamonds", 0) > 0, mine)
st, r = call(GAME, "POST", "/v1/referral/claim", {"code": mine.get("code", ""), "device": phone}, tok)
check("a lord's own code is refused", st == 409 and r.get("code") == "referral_self", (st, r))
st, r = call(GAME, "POST", "/v1/referral/claim", {"code": "ZZZZZZ", "device": phone}, tok)
check("an unknown code is refused", st == 404 and r.get("code") == "referral_invalid", (st, r))

if args.admin:
    print("a code from the panel")
    url, auser, apass = args.admin
    url = url.rstrip("/")
    st, r = call(url, "POST", "/login", {"username": auser, "password": apass})
    if st != 200:
        print("cannot sign in to the panel API:", st, r)
        sys.exit(2)
    atok = r["token"]
    code = "SMOKE" + uuid.uuid4().hex[:6].upper()
    st, made = call(url, "POST", "/promo", {"code": code, "note": "smoke", "max_uses": 5, "expires_days": 1,
                                            "reward": {"diamonds": 7, "tokens": {"energy_potion": 1}}}, atok)
    check("the panel makes a code", st == 200 and made.get("state") == "live", (st, made))
    st, r = call(url, "POST", "/promo", {"code": "SMOKE", "reward": {"cosmetics": ["frame_laurel"]}}, atok)
    check("a code giving a cosmetic is refused", st == 400, (st, r))
    st, box = call(GAME, "GET", "/v1/mail", token=tok)
    before = box.get("waiting", 0)
    st, r = call(GAME, "POST", "/v1/promo/redeem", {"code": code.lower(), "device": phone}, tok)
    check("the code is redeemed, in any case", st == 200 and len(r.get("lines", [])) == 2, (st, r))
    st, box = call(GAME, "GET", "/v1/mail", token=tok)
    check("its letter waits in the Royal Mail", box.get("waiting", 0) == before + 1, (before, box.get("waiting")))
    st, r = call(GAME, "POST", "/v1/promo/redeem", {"code": code, "device": phone}, tok)
    check("and only once", st == 409 and r.get("code") == "promo_used", (st, r))
    other = register("py", phone)
    st, r = call(GAME, "POST", "/v1/promo/redeem", {"code": code, "device": phone}, other)
    check("another account on the same phone is refused", st == 409 and r.get("code") == "promo_used", (st, r))
    st, list_ = call(url, "GET", f"/promo/redemptions?code={code}", token=atok)
    check("the panel lists who redeemed it", st == 200 and len(list_.get("redemptions", [])) == 1, (st, list_))
    call(url, "POST", "/promo/disable", {"code": code, "note": "smoke done"}, atok)

print()
if failures:
    print(f"{len(failures)} check(s) failed")
    sys.exit(1)
print("all checks pass")
