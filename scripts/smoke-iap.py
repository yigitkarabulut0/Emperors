#!/usr/bin/env python3
"""Wave 1 end to end: the Royal Store, App Store purchases, refunds and the
billing desk.

    python3 scripts/smoke-iap.py <game-url> [--mint <dir>] [--admin <url> <user> <pass>]

Without --mint (the live server, which trusts only Apple) it checks what any
player can:
  * the Royal Store lists every product with its US price tier, and no paid
    product gives gold, XP, favour, gear or a timed bonus (FAIR);
  * the market says how many of the day's rerolls are left;
  * the day's four deals are on the shelf, the gift is claimed once, and a deal
    without the diamonds is refused;
  * a forged purchase and a forged notification are refused, and nothing moves;
  * the wardrobe answers and wearing what one does not own is refused.

With --mint (a LOCAL API started with EMPERORS_IAP_DEV_ROOT=<dir>/root.pem; see
cmd/iapmint) it also buys through the whole path:
  * a pack is delivered once, pays double the first time, and a second send of
    the same purchase delivers nothing;
  * a purchase is its buyer's: another account sending it delivers it to the
    buyer (for_another), never to the sender;
  * the Steward serves, the Stipend pays its day once;
  * a refund notification takes the pack back, and what was spent becomes a
    debt.

With --admin (a local or staging panel API: never production's owner account)
the billing desk shows the Sandbox purchases apart from revenue and lists the
refund's notification as acted on.
"""
import argparse, base64, json, os, subprocess, sys, tempfile, time, urllib.error, urllib.request

ap = argparse.ArgumentParser()
ap.add_argument("game", nargs="?", default="http://127.0.0.1:8080")
ap.add_argument("--mint", help="the chain cmd/iapmint init wrote (local servers only)")
ap.add_argument("--admin", nargs=3, metavar=("URL", "USER", "PASS"))
args = ap.parse_args()
GAME = args.game.rstrip("/")
PW = "battery horse staple"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
failures = []

if args.mint and not (GAME.startswith("http://127.0.0.1") or GAME.startswith("http://localhost")):
    print("--mint signs with a root only a local dev server trusts; refusing", GAME)
    sys.exit(2)


def call(base, method, path, body=None, token=None, raw=None):
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    req = urllib.request.Request(
        base + path, method=method, data=data,
        headers={"content-type": "application/json",
                 **({"authorization": "Bearer " + token} if token else {})})
    try:
        with urllib.request.urlopen(req, timeout=30) as f:
            out = f.read()
            return f.status, (json.loads(out) if out else {})
    except urllib.error.HTTPError as e:
        out = e.read()
        try:
            return e.code, json.loads(out or b"{}")
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
    return user, r["access_token"], r["player_id"]


def player(tok):
    return call(GAME, "GET", "/v1/state", token=tok)[1].get("player", {})


def forged_jws():
    """A JWS-shaped string whose chain is garbage: it must never verify."""
    enc = lambda o: base64.urlsafe_b64encode(json.dumps(o).encode()).rstrip(b"=").decode()
    head = enc({"alg": "ES256", "x5c": ["AAAA", "BBBB", "CCCC"]})
    body = enc({"transactionId": "1", "productId": "com.emperors.game.gems.8500", "bundleId": "com.emperors.game",
                "environment": "Production", "signedDate": int(time.time() * 1000)})
    return head + "." + body + "." + base64.urlsafe_b64encode(b"x" * 64).rstrip(b"=").decode()


# --- what any player can see -----------------------------------------------------
print("the Royal Store")
user, tok, pid = register("iz")
st, store = call(GAME, "GET", "/v1/store/court", token=tok)
products = {p["id"]: p for p in store.get("products", [])}
check("the Royal Store answers", st == 200 and len(products) >= 10, (st, len(products)))
for want in ("gems_60", "gems_8500", "stipend", "patronage", "steward", "quartermaster", "largesse"):
    check(f"it lists {want}", want in products, sorted(products))
UNFAIR = {"gold", "gold_wages", "xp", "xp_wages", "favour", "item", "boost"}
bad = [(p["id"], l["kind"]) for p in products.values() for l in p.get("lines", []) if l.get("kind") in UNFAIR]
check("no product sells gold, experience, favour, gear or a timed bonus", not bad, bad)
check("a pack's first purchase says it pays double", products.get("gems_60", {}).get("first_bonus") is True,
      products.get("gems_60"))
check("every product says its US price tier", all(p.get("usd_cents", 0) > 0 for p in products.values()),
      [p["id"] for p in products.values() if not p.get("usd_cents")])
st, shop = call(GAME, "GET", "/v1/shop", token=tok)
check("the market says the day's rerolls", st == 200 and shop.get("rerolls_per_day", 0) > 0
      and shop.get("rerolls_left") == shop.get("rerolls_per_day"), (st, shop.get("rerolls_left"), shop.get("rerolls_per_day")))

before = player(tok).get("diamonds")
st, r = call(GAME, "POST", "/v1/iap/apple/verify", {"jws": forged_jws()}, tok)
check("a forged purchase is refused", st == 400 and r.get("code") == "iap_invalid", (st, r))
check("and gives nothing", player(tok).get("diamonds") == before)
st, r = call(GAME, "POST", "/v1/iap/apple/verify", {"jws": "not a jws"}, tok)
check("a purchase that is not a JWS is refused", st == 400, (st, r))
st, r = call(GAME, "POST", "/v1/iap/apple/notify", {"signedPayload": forged_jws()})
check("a forged notification is refused", st == 400, (st, r))
st, r = call(GAME, "POST", "/v1/iap/apple/notify", raw=b"{}")
check("a notification with no payload is refused", st == 400, (st, r))
st, r = call(GAME, "POST", "/v1/iap/apple/verify", {"jws": forged_jws()})
check("a purchase without a session is refused", st == 401, st)

deals = store.get("deals", {})
slots = {d["slot"]: d for d in deals.get("slots", [])}
check("the day's deals are on the shelf", len(slots) >= 3 and 0 < deals.get("resets_in", 0) <= 86400,
      (len(slots), deals.get("resets_in")))
check("the gift is free and the rest cost diamonds",
      slots.get(0, {}).get("kind") == "free" and all(d.get("diamonds", 0) > 0 for k, d in slots.items() if k),
      slots)
check("each deal says what it saves", all(d.get("was", 0) > d.get("diamonds", 0) for k, d in slots.items() if k),
      [(d.get("diamonds"), d.get("was")) for d in slots.values()])
# The herald, from the store's side. Whether the REALM has an advert to play is
# the deployment's business (scripts/smoke-ads.py drives that end to end); what
# must hold on any realm is that THIS lord -- freshly registered, level one --
# is offered nothing to watch.
herald = store.get("herald", {})
check("the store answers with a herald block", isinstance(herald, dict), store.keys())
check("and offers a new lord no advert", herald.get("unlocked", False) is False, herald)
seq = player(tok).get("action_seq", 0)
st, r = call(GAME, "POST", "/v1/store/deals/claim", {"slot": 0, "action_seq": seq + 1}, tok)
check("the day's gift is claimed", st == 200 and len(r.get("lines", [])) > 0, (st, r))
seq = player(tok).get("action_seq", 0)
st, r = call(GAME, "POST", "/v1/store/deals/claim", {"slot": 0, "action_seq": seq + 1}, tok)
check("and only once", st == 409 and r.get("code") == "nothing_to_claim", (st, r))
st, r = call(GAME, "POST", "/v1/store/deals/claim", {"slot": 1, "action_seq": seq + 1}, tok)
if player(tok).get("diamonds", 0) < slots.get(1, {}).get("diamonds", 0):
    check("a deal without the diamonds is refused", st == 409 and r.get("code") == "not_enough_diamonds", (st, r))
before = player(tok).get("diamonds")

st, wr = call(GAME, "GET", "/v1/cosmetics", token=tok)
check("the wardrobe answers", st == 200 and len(wr.get("items", [])) > 10, st)
locked = next((c for c in wr.get("items", []) if not c.get("owned") and c.get("kind") == "frame"), None)
if locked:
    st, r = call(GAME, "POST", "/v1/cosmetics/wear", {"kind": "frame", "id": locked["id"]}, tok)
    check("wearing a frame one does not own is refused", st == 409 and r.get("code") == "cosmetic_locked", (st, r))

# --- the whole path, signed locally ------------------------------------------------
if args.mint:
    print("purchases, signed under the dev root")
    mint_bin = os.path.join(tempfile.mkdtemp(), "iapmint")
    subprocess.run(["go", "build", "-o", mint_bin, "./cmd/iapmint"], cwd=os.path.join(ROOT, "server"), check=True)
    mint_dir = os.path.abspath(args.mint)

    def mint(*a):
        out = subprocess.run([mint_bin, *a, "-dir", mint_dir], capture_output=True, text=True)
        if out.returncode != 0:
            print("iapmint failed:", out.stderr)
            sys.exit(2)
        return out.stdout.strip(), out.stderr.strip().split()[-1] if "transaction" in out.stderr else ""

    jws, txid = mint("txn", "-player", pid, "-product", "com.emperors.game.gems.330", "-price", "4990")
    st, d = call(GAME, "POST", "/v1/iap/apple/verify", {"jws": jws}, tok)
    check("a pack is delivered", st == 200 and d.get("already") is False, (st, d))
    check("the first pack pays double", d.get("first_bonus") is True and player(tok).get("diamonds") == before + 660,
          (d.get("first_bonus"), player(tok).get("diamonds")))
    check("the delivery says what it gave", any(l.get("kind") == "diamonds" for l in d.get("lines", [])), d.get("lines"))
    check("and hands back the confirmed snapshot", "snapshot" in d, list(d))
    st, d = call(GAME, "POST", "/v1/iap/apple/verify", {"jws": jws}, tok)
    check("the same purchase sent again delivers nothing", st == 200 and d.get("already") is True
          and player(tok).get("diamonds") == before + 660, (st, d.get("already")))

    other, otok, opid = register("iy")
    theirs = player(otok).get("diamonds")
    st, r = call(GAME, "POST", "/v1/iap/apple/verify", {"jws": jws}, otok)
    check("another account sending it delivers to the buyer, not to them",
          st == 200 and r.get("for_another") is True and player(otok).get("diamonds") == theirs
          and player(tok).get("diamonds") == before + 660, (st, r.get("for_another"), player(otok).get("diamonds")))

    jws2, _ = mint("txn", "-player", pid, "-product", "com.emperors.game.comfort.steward", "-type", "Non-Consumable")
    st, d = call(GAME, "POST", "/v1/iap/apple/verify", {"jws": jws2}, tok)
    check("the Steward is delivered", st == 200, (st, d))
    st, r = call(GAME, "POST", "/v1/steward/run", {}, tok)
    check("the Steward serves", st == 200 and "lines" in r, (st, r))
    st, r = call(GAME, "POST", "/v1/steward/run", {}, otok)
    check("and serves nobody who did not buy him", st == 403 and r.get("code") == "not_steward", (st, r))

    jws3, _ = mint("txn", "-player", pid, "-product", "com.emperors.game.stipend.30")
    st, d = call(GAME, "POST", "/v1/iap/apple/verify", {"jws": jws3}, tok)
    check("the Stipend is delivered", st == 200, (st, d))
    st, r = call(GAME, "POST", "/v1/stipend/claim", {}, tok)
    st2, r2 = call(GAME, "POST", "/v1/stipend/claim", {}, tok)
    check("the Stipend pays its day once", st in (200, 409) and st2 == 409 and r2.get("code") == "nothing_to_claim",
          (st, r, st2, r2))

    # Spend 250 on a frame, then refund the pack: 660 back from 410 held leaves a debt of 250.
    p = player(tok)
    st, r = call(GAME, "POST", "/v1/cosmetics/buy", {"id": "frame_laurel", "action_seq": p.get("action_seq", 0) + 1}, tok)
    check("a frame is bought with diamonds", st == 200, (st, r))
    held = player(tok).get("diamonds")
    body, _ = mint("notify", "-type", "REFUND", "-player", pid, "-product", "com.emperors.game.gems.330", "-id", txid)
    st, r = call(GAME, "POST", "/v1/iap/apple/notify", raw=body.encode())
    check("a refund notification is taken", st == 200, (st, r))
    p = player(tok)
    want_debt = max(0, 660 - held)
    check("the refund takes the pack back", p.get("diamonds") == max(0, held - 660), (held, p.get("diamonds")))
    check("what was spent becomes a debt", p.get("diamond_debt", 0) == want_debt, (p.get("diamond_debt"), want_debt))
    st, r = call(GAME, "POST", "/v1/iap/apple/notify", raw=body.encode())
    check("the same notification again takes nothing more", st == 200 and player(tok).get("diamond_debt", 0) == want_debt,
          (st, player(tok).get("diamond_debt")))

# --- the billing desk ---------------------------------------------------------------
if args.admin:
    print("the billing desk")
    url, auser, apass = args.admin
    url = url.rstrip("/")
    st, r = call(url, "POST", "/login", {"username": auser, "password": apass})
    if st != 200:
        print("cannot sign in to the panel API:", st, r)
        sys.exit(2)
    atok = r["token"]
    st, s = call(url, "GET", "/billing/summary?days=7", token=atok)
    check("the takings answer", st == 200 and len(s.get("daily", [])) == 7, (st, len(s.get("daily", []))))
    if args.mint:
        check("Sandbox purchases are counted apart", s.get("sandbox_purchases", 0) >= 3, s.get("sandbox_purchases"))
        st, t = call(url, "GET", f"/billing/transactions?player={pid}", token=atok)
        rows = t.get("transactions", [])
        check("the lord's purchases are listed, labelled Sandbox", st == 200 and len(rows) == 3
              and all(x.get("sandbox") for x in rows), (st, len(rows)))
        check("the refunded pack reads refunded", any(x.get("state") == "refunded" for x in rows),
              [x.get("state") for x in rows])
        st, n = call(url, "GET", "/billing/notifications?limit=20", token=atok)
        refund = next((x for x in n.get("notifications", []) if x.get("transaction_id") == txid), None)
        check("the refund's notification is listed as acted on", refund is not None and refund.get("status") == "done",
              refund)
        st, b = call(url, "GET", f"/players/billing?id={pid}", token=atok)
        check("the lord's billing shows the Steward and the debt", st == 200 and b.get("steward") is True
              and b.get("diamond_debt") == want_debt, (st, b.get("steward"), b.get("diamond_debt")))

print()
if failures:
    print(f"{len(failures)} check(s) failed")
    sys.exit(1)
print("all checks pass")
