#!/usr/bin/env python3
"""The storehouse, end to end: estate income waits there, and is carried in.

    python3 scripts/smoke-storehouse.py [<game-url>]

Estate income no longer lands in the purse on every request (Wave 2): it fills
the storehouse at the hourly rate, up to 8 hours of it, and the lord carries it
to the purse or the vault. This checks what any player can see:

  * the snapshot carries the storehouse (rate, capacity, 8 hours) and tells an
    old build a zero tax rate, so its purse no longer ticks up on its own;
  * the old claim route answers 410;
  * while the app is open and polled, the purse does not move -- and polling
    fast fills the storehouse exactly as fast as leaving it alone;
  * a whole gold is carried to the purse once, an empty storehouse is refused,
    a carry to anywhere else is refused, and a level-1 lord cannot carry to the
    vault, which opens later.

Slow by design: at the level-1 rate one whole gold takes about 85 seconds, and
the carry cannot be seen without waiting for one.
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


print("== the storehouse is in the snapshot ==")
token = new_player("sth")
_, s = call("GET", "/v1/state", token=token)
sh = s.get("storehouse", {})
rate, cap = sh.get("per_hour_milli", 0), sh.get("cap_milli", 0)
check("the storehouse fills at the estates' rate", rate > 0, sh)
check("and holds eight hours of it", cap == rate * 8 and sh.get("hours") == 8, sh)
check("an old build is told a zero tax rate", s["player"].get("tax_milli_per_hour") == 0, s["player"].get("tax_milli_per_hour"))
st, _ = call("POST", "/v1/estates/tax/claim", {"action_seq": 1}, token=token)
check("the old claim route answers 410 Gone", st == 410, st)
seconds_per_gold = 3600_000 / max(rate, 1)
print(f"        {rate} milli/hour: one whole gold every {seconds_per_gold:.0f}s")

print("\n== polling fast fills it as fast as leaving it ==")
busy, idle = token, new_player("sti")
call("GET", "/v1/state", token=idle)
purse_before = s["player"]["gold"]
deadline = time.time() + seconds_per_gold * 1.3
polls = 0
while time.time() < deadline:
    call("GET", "/v1/state", token=busy)
    polls += 1
    time.sleep(0.5)
_, b = call("GET", "/v1/state", token=busy)
_, i = call("GET", "/v1/state", token=idle)
bm, im = b["storehouse"]["milli"], i["storehouse"]["milli"]
print(f"        after {polls} polls: hammered {bm} milli, untouched {im} milli")
check("the storehouse filled while the app was closed", im >= 1000, im)
check("polling fast lost nothing to rounding", bm >= im - 5, (bm, im))
check("the purse did not move on its own", b["player"]["gold"] == purse_before, (purse_before, b["player"]["gold"]))

print("\n== carried in ==")
seq = b["player"]["action_seq"]
st, r = call("POST", "/v1/estates/storehouse/carry", {"to": "treasury", "action_seq": seq + 1}, token=busy)
check("a level-1 lord cannot carry to the vault", st == 403 and r.get("code") == "level_too_low", (st, r))
st, r = call("POST", "/v1/estates/storehouse/carry", {"to": "cellar", "action_seq": seq + 1}, token=busy)
check("a carry to anywhere else is refused", st == 400, (st, r))
st, r = call("POST", "/v1/estates/storehouse/carry", {"to": "purse", "action_seq": seq + 1}, token=busy)
carried = r.get("carried", 0)
check("the storehouse is carried to the purse", st == 200 and carried >= 1, (st, r))
snap = r.get("snapshot", {})
check("its whole gold reached the purse", int(snap.get("player", {}).get("gold", "0")) == int(purse_before) + carried,
      (purse_before, carried, snap.get("player", {}).get("gold")))
check("and the storehouse is left with less than a gold", snap.get("storehouse", {}).get("gold") == 0, snap.get("storehouse"))
st, r = call("POST", "/v1/estates/storehouse/carry", {"to": "purse", "action_seq": seq + 2}, token=busy)
check("an empty storehouse is refused", st == 409 and r.get("code") == "storehouse_empty", (st, r))

print()
if failures:
    print(f"{len(failures)} FAILED: " + ", ".join(failures))
    sys.exit(1)
print("all checks passed")
