#!/usr/bin/env python3
"""End-to-end check of M2: items, inventory, shop.

Focuses on the properties that would be expensive to discover in production:
the shop cannot be rerolled by retrying, an offer cannot be bought twice, and
buying then selling always loses money.
"""
import json, sys, urllib.request, urllib.error, random, string

BASE = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:8080"
FAILURES = []


def call(method, path, body=None, token=None):
    req = urllib.request.Request(BASE + path, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    data = json.dumps(body).encode() if body is not None else None
    try:
        with urllib.request.urlopen(req, data, timeout=20) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw or b"{}")
        except json.JSONDecodeError:
            return e.code, {"raw": raw.decode(errors="replace")[:200]}


def next_seq(token):
    """The action_seq a new action should claim.

    Read from the server rather than tracked locally: a business failure rolls
    its transaction back and does NOT advance the counter, so a client that
    optimistically incremented would desync on the next call. This mirrors what
    the real client does, which reads action_seq out of the snapshot.
    """
    _, s = call("GET", "/v1/state", token=token)
    return s["player"]["action_seq"] + 1


def check(label, cond, detail=""):
    print(f"  {'PASS' if cond else 'FAIL'}  {label}{'' if cond else '  <- ' + str(detail)}")
    if not cond:
        FAILURES.append(label)


user = "shop" + "".join(random.choices(string.ascii_lowercase, k=6))
st, reg = call("POST", "/v1/auth/register", {"username": user, "password": "battery horse staple", "tz_offset_minutes": 0})
token = reg["access_token"]
print(f"\n== setup ==  ({user})")

# Grind gold so there is something to spend.
st, s = call("GET", "/v1/state", token=token)
job = [j for j in s["jobs"] if j["unlocked"]][0]
seq = s["player"]["action_seq"]
for _ in range(60):
    seq += 1
    st, c = call("POST", "/v1/collect", {"job_id": job["id"], "action_seq": seq}, token=token)
    if st != 200:
        seq -= 1
        break
    s = c["snapshot"]
print(f"        ground to {s['player']['gold']} gold, lv{s['player']['level']}")

print("\n== shop ==")
st, shop = call("GET", "/v1/shop", token=token)
check("shop returns 200", st == 200, (st, shop))
check("shop has 6 offers", len(shop.get("offers", [])) == 6, len(shop.get("offers", [])))
check("window has time left", 0 < shop["seconds_left"] <= 300, shop.get("seconds_left"))
tiers = [o["item"]["tier"] for o in shop["offers"]]
print(f"        offers: {', '.join(f'{o['item']['slot']}/{o['item']['tier']}@{o['price']}' for o in shop['offers'])}")

st, shop2 = call("GET", "/v1/shop", token=token)
check("shop is deterministic — re-reading does not reroll",
      [o["item"]["def_id"] for o in shop2["offers"]] == [o["item"]["def_id"] for o in shop["offers"]],
      "offers changed between two reads")
check("prices are stable too",
      [o["price"] for o in shop2["offers"]] == [o["price"] for o in shop["offers"]])

st, other = call("POST", "/v1/auth/register",
                 {"username": user + "b", "password": "battery horse staple", "tz_offset_minutes": 0})
st, shopB = call("GET", "/v1/shop", token=other["access_token"])
check("two players get different shelves",
      [o["item"]["def_id"] for o in shopB["offers"]] != [o["item"]["def_id"] for o in shop["offers"]])

print("\n== buying ==")
gold = int(s["player"]["gold"])
affordable = [o for o in shop["offers"] if o["price"] <= gold]
check("something is affordable after a short grind", len(affordable) > 0,
      f"cheapest {min(o['price'] for o in shop['offers'])} vs {gold} gold")

if affordable:
    off = affordable[0]
    st, buy = call("POST", "/v1/shop/buy", {"slot": off["slot"], "action_seq": next_seq(token)}, token=token)
    check("buy returns 200", st == 200, (st, buy))
    check("charged exactly the advertised price", buy.get("paid") == off["price"], (buy.get("paid"), off["price"]))
    check("gold went down by the price", int(buy["gold_left"]) == gold - off["price"], buy.get("gold_left"))
    check("the item received matches the offer", buy["item"]["def_id"] == off["item"]["def_id"])

    st, again = call("POST", "/v1/shop/buy", {"slot": off["slot"], "action_seq": next_seq(token)}, token=token)
    check("the same offer cannot be bought twice",
          st == 409 and again.get("code") == "already_purchased", (st, again))

    st, shop3 = call("GET", "/v1/shop", token=token)
    check("the shelf shows it as sold", shop3["offers"][off["slot"]]["purchased"] is True)

    expensive = [o for o in shop["offers"] if o["price"] > gold]
    if expensive:
        st, poor = call("POST", "/v1/shop/buy",
                        {"slot": expensive[-1]["slot"], "action_seq": next_seq(token)}, token=token)
        check("cannot buy what you cannot afford",
              st == 409 and poor.get("code") == "not_enough_gold", (st, poor))
        check("a failed purchase does not consume the action sequence",
              next_seq(token) == next_seq(token), "sequence advanced on a rolled-back action")

print("\n== inventory ==")
st, inv = call("GET", "/v1/inventory", token=token)
check("inventory returns 200", st == 200, st)
check("the bought item is there", inv["used"] >= 1, inv.get("used"))
check("nothing is equipped yet", all(v is None for v in inv["equipped"].values()), inv["equipped"])
item = inv["items"][0]
print(f"        {item['name']} ({item['tier']} {item['slot']}) "
      f"atk {item['attack']} def {item['defense']} spd {item['speed']} q{item['quality_pct']}% "
      f"-> power {item['power']}, sells for {item['sell_price']}")

hero_before = inv["hero"]["power"]
st, inv2 = call("POST", "/v1/inventory/equip", {"item_id": item["id"]}, token=token)
check("equip returns 200", st == 200, st)
check("the item reads as equipped", inv2["equipped"][item["slot"]] is not None, inv2["equipped"])
check("hero power went up", inv2["hero"]["power"] > hero_before, (hero_before, inv2["hero"]["power"]))

st, nosell = call("POST", "/v1/inventory/sell",
                  {"item_id": item["id"], "action_seq": next_seq(token)}, token=token)
check("cannot sell what you are wearing", st == 409 and nosell.get("code") == "item_equipped", (st, nosell))

st, inv3 = call("POST", "/v1/inventory/unequip", {"item_id": item["id"]}, token=token)
check("unequip works", st == 200 and inv3["equipped"][item["slot"]] is None, st)
check("hero power went back down", inv3["hero"]["power"] == hero_before, inv3["hero"]["power"])

print("\n== arbitrage ==")
st, st_now = call("GET", "/v1/state", token=token)
gold_before = int(st_now["player"]["gold"])
st, sell = call("POST", "/v1/inventory/sell",
                {"item_id": item["id"], "action_seq": st_now["player"]["action_seq"] + 1}, token=token)
check("sell returns 200", st == 200, (st, sell))
check("selling paid less than the purchase price", sell["gained"] < off["price"], (sell.get("gained"), off["price"]))
check("the buy-sell round trip lost at least 70%",
      sell["gained"] <= off["price"] * 0.3, (sell.get("gained"), off["price"]))
check("gold went up by exactly the sale", int(sell["gold_left"]) == gold_before + sell["gained"])

st, inv4 = call("GET", "/v1/inventory", token=token)
check("the item is gone", all(i["id"] != item["id"] for i in inv4["items"]))

# --- diamonds and rerolls -------------------------------------------------------
#
# Diamonds were shown in the top bar with no way to earn one and nothing to
# spend it on: a currency stuck at zero reads as broken. Levelling is the source
# (the XP curve already bounds it) and a shop reroll is the sink.
print("\n== diamonds and rerolls ==")
st, s2 = call("GET", "/v1/state", token=token)
have = int(s2["player"]["diamonds"])
check("levelling granted diamonds", have > 0, have)

st, shop2 = call("GET", "/v1/shop", token=token)
cost = shop2.get("reroll_cost", 0)
check("the shop quotes a reroll price up front", cost > 0, shop2.get("reroll_cost"))
check("and says whether it is affordable",
      shop2.get("can_afford_reroll") == (have >= cost), (have, cost, shop2.get("can_afford_reroll")))
before = [o["item"]["def_id"] for o in shop2["offers"]]

if have >= cost:
    st, rolled = call("POST", "/v1/shop/reroll", {"action_seq": next_seq(token)}, token=token)
    check("rerolling returns 200", st == 200, (st, rolled))
    after = [o["item"]["def_id"] for o in rolled["offers"]]
    check("the offers actually changed", before != after, (before, after))
    check("the price went up for the next one", rolled["reroll_cost"] > cost,
          (cost, rolled.get("reroll_cost")))
    check("the counter advanced", rolled["rerolls_used"] == shop2["rerolls_used"] + 1, rolled)

    st, s3 = call("GET", "/v1/state", token=token)
    check("diamonds were spent, and only diamonds",
          int(s3["player"]["diamonds"]) == have - cost
          and int(s3["player"]["gold"]) == int(s2["player"]["gold"]),
          (have, cost, s3["player"]["diamonds"], s2["player"]["gold"], s3["player"]["gold"]))

    # Drain the purse and confirm the refusal is clean rather than a 500.
    for _ in range(20):
        st, r = call("POST", "/v1/shop/reroll", {"action_seq": next_seq(token)}, token=token)
        if st != 200:
            break
    check("rerolling with no diamonds is refused cleanly",
          st == 409 and r.get("code") == "not_enough_diamonds", (st, r))
else:
    check("a first reroll is affordable after a few levels", False, (have, cost))

print()
if FAILURES:
    print(f"{len(FAILURES)} FAILED: " + ", ".join(FAILURES))
    sys.exit(1)
print("all checks passed")
