#!/usr/bin/env python3
"""The daily loop (Wave 3), end to end, as a new lord sees it.

    python3 scripts/smoke-daily-loop.py [<game-url>]

Checks what any player can see, with no panel and no clock of its own:

  * the snapshot carries the Tax Cart, the Golden Hour and the guide, and a new
    lord's guide starts at its first step;
  * the guide's welcome is tapped on; the first collect is refused until done;
  * the day's square is claimed once, with a Royal Pardon for the first cycle;
  * the Tax Cart is locked at level 1 and opens once the lord is level 2, with
    a prize from its published odds (10000 bp), and a second opening is refused;
  * the week's board has six tasks, the two diamond ones first, three chests;
  * the Victory Road has 15 milestones worth 435 diamonds, nothing claimable at 1;
  * a flask the lord does not hold is refused, and a pardon is not drunk;
  * skipping the guide ends it.
"""
import json, sys, time, urllib.error, urllib.request

BASE = (sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8080").rstrip("/")
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
    return reg["access_token"]


print("== a new lord's snapshot ==")
token = new_player("dl")
_, s = call("GET", "/v1/state", token=token)
g, c, f = s.get("guide", {}), s.get("cart", {}), s.get("frenzy", {})
check("the guide begins at welcome", g.get("active") and g.get("step") == "welcome" and g.get("count") == 12, g)
check("the Tax Cart is on the snapshot, locked at level 1", c.get("unlocked") is False and c.get("stock") == 1, c)
check("the Golden Hour is on the snapshot", f.get("per_day") == 3 and f.get("duration") == 60 and f.get("meter") == 0, f)

print("\n== the guide ==")
st, b = call("POST", "/v1/guide/advance", {"step": "first_collect"}, token=token)
check("a step the lord is not on is refused", st == 409 and code(b) == "guide_moved", (st, b))
st, b = call("POST", "/v1/guide/advance", {"step": "welcome"}, token=token)
check("the welcome is tapped on", st == 200 and b["guide"]["step"] == "first_collect", (st, b))
st, b = call("POST", "/v1/guide/advance", {"step": "first_collect"}, token=token)
check("the first collect is refused until it is done", st == 409 and code(b) == "guide_not_ready", (st, b))
job = s["jobs"][0]["id"]
st, b = call("POST", "/v1/collect", {"job_id": job, "action_seq": s["player"]["action_seq"] + 1}, token=token)
check("a collect", st == 200 and "frenzy_gold" in b, (st, b))
st, b = call("POST", "/v1/guide/advance", {"step": "first_collect"}, token=token)
check("then the step is done", st == 200 and b["guide"]["step"] == "reach_2", (st, b))

print("\n== the calendar ==")
st, d = call("GET", "/v1/daily", token=token)
check("28 squares, the crowns on 7/14/21/28", st == 200 and len(d["squares"]) == 28
      and [q["day"] for q in d["squares"] if q["crown"]] == [7, 14, 21, 28], d.get("squares", [])[:2])
check("day 1 is today's", d.get("day") == 1 and d.get("claimable") and d["squares"][0]["state"] == "today", d)
st, b = call("POST", "/v1/daily/claim", {}, token=token)
check("the square is claimed, with a pardon", st == 200 and b["daily"]["claimed_today"] and b["daily"]["pardons"] == 1
      and any(l.get("kind") == "diamonds" for l in b["lines"]), (st, b))
st, b = call("POST", "/v1/daily/claim", {}, token=token)
check("a second claim today is refused", st == 409 and code(b) == "already_claimed", (st, b))
st, b = call("POST", "/v1/daily/claim", {"mend": "pardon"}, token=token)
check("a mend with nothing broken is refused", st == 409, (st, b))

print("\n== the Tax Cart ==")
st, b = call("POST", "/v1/cart/open", {}, token=token)
check("locked at level 1", st == 403 and code(b) == "locked", (st, b))
st, v = call("GET", "/v1/cart", token=token)
check("the published odds are the whole of it", st == 200 and sum(o["bp"] for o in v["odds"]) == 10000
      and all(o["lines"] for o in v["odds"]), v.get("odds"))
# Work up to level 2 (a few grapes).
_, s = call("GET", "/v1/state", token=token)
for _ in range(40):
    if s["player"]["level"] >= 2:
        break
    st, r = call("POST", "/v1/collect/batch", {"job_ids": [job] * 8, "action_seq": s["player"]["action_seq"] + 1}, token=token)
    s = r.get("snapshot", s)
check("the lord reaches level 2", s["player"]["level"] >= 2, s["player"]["level"])
st, b = call("POST", "/v1/cart/open", {}, token=token)
check("the waiting cart opens to a prize", st == 200 and b.get("prize") and b["lines"] and b["cart"]["stock"] == 0
      and b["cart"]["opened"] == 1, (st, b))
st, b = call("POST", "/v1/cart/open", {}, token=token)
check("an empty yard is refused", st == 409 and code(b) == "cart_empty", (st, b))

print("\n== the week, the road, flasks ==")
st, w = call("GET", "/v1/weekly", token=token)
check("six tasks, the two diamond ones first, three chests", st == 200 and len(w["tasks"]) == 6
      and [t["id"] for t in w["tasks"][:2]] == ["w_days", "w_dailies"] and [c["at"] for c in w["chests"]] == [80, 160, 240]
      and all(len(t["short"]) <= 24 for t in w["tasks"]), w)
st, r = call("GET", "/v1/road", token=token)
check("15 milestones, 435 diamonds", st == 200 and len(r["milestones"]) == 15 and r["diamonds_total"] == 435, r)
st, b = call("POST", "/v1/road/claim", {}, token=token)
check("nothing on the road at level 2", st == 409 and code(b) == "nothing_to_claim", (st, b))
_, s = call("GET", "/v1/state", token=token)
st, b = call("POST", "/v1/tokens/use", {"token": "flask_small", "action_seq": s["player"]["action_seq"] + 1}, token=token)
check("a flask not held is refused", st == 409 and code(b) in ("no_token", "energy_full"), (st, b))
st, b = call("POST", "/v1/tokens/use", {"token": "pardon", "action_seq": s["player"]["action_seq"] + 1}, token=token)
check("a pardon is not drunk", st == 400, (st, b))
st, store = call("GET", "/v1/store", token=token)
# The friend's draught (Wave 6) is a flask like the other two: it is listed with
# them, it is never sold, and a lord holds one only because a friend sent it.
flask_ids = [x["id"] for x in store.get("flasks", [])]
check("the store lists the flasks apart from its goods",
      st == 200 and flask_ids[:2] == ["flask_small", "flask_large"]
      and all(g["id"] not in flask_ids for g in store["goods"]), store)
check("a friend's draught is one of them, and carries no price",
      "flask_friend" in flask_ids
      and all("diamonds" not in f for f in store.get("flasks", [])), flask_ids)

print("\n== skipping the guide ==")
st, b = call("POST", "/v1/guide/skip", {}, token=token)
check("SKIP ends it", st == 200 and b["guide"].get("active") is False, (st, b))
_, s = call("GET", "/v1/state", token=token)
check("and it stays ended", s["guide"].get("active") is False, s["guide"])

print()
if failures:
    print(f"{len(failures)} FAILED: " + ", ".join(failures))
    sys.exit(1)
print("all passed")
