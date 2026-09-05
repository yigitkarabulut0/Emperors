#!/usr/bin/env python3
"""Estate income arrives on its own, and polling faster never earns less.

The Collect button is gone: income is credited on every authenticated request
from a rate cached on the player row. Two things about that are easy to get
wrong and impossible to notice by looking:

  * elapsed time must be measured finer than whole seconds, or a client polling
    several times a second sees zero elapsed on every call and earns nothing;
  * the anchor must not move when the amount earned rounds down to zero, or the
    remainder is discarded on every request and a fast poller is robbed.

Slow by design: at the level-1 rate one whole gold takes a couple of minutes,
and there is no way to observe the credit without waiting for it.
"""
import json, sys, time, urllib.error, urllib.request

BASE = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8080"
failures = []


def call(method, path, body=None, token=None):
    req = urllib.request.Request(
        BASE + path, method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"content-type": "application/json",
                 **({"authorization": "Bearer " + token} if token else {})})
    try:
        with urllib.request.urlopen(req, timeout=30) as f:
            return f.status, json.load(f)
    except urllib.error.HTTPError as e:
        return e.code, json.load(e)


def check(name, ok, detail=""):
    print(("  PASS  " if ok else "  FAIL  ") + name + ("" if ok else f"  <- {detail}"))
    if not ok:
        failures.append(name)


def new_player(tag):
    user = "%s%d" % (tag, int(time.time() * 1000) % 10_000_000)
    _, reg = call("POST", "/v1/auth/register",
                  {"username": user, "password": "battery horse staple"})
    return reg["access_token"]


print("== the claim endpoint is gone ==")
token = new_player("tax")
st, _ = call("POST", "/v1/estates/tax/claim", {"action_seq": 1}, token=token)
check("POST /v1/estates/tax/claim answers 410 Gone", st == 410, st)

_, s = call("GET", "/v1/state", token=token)
rate = s["player"]["tax_milli_per_hour"]
check("the snapshot carries the hourly rate so the client can tick", rate > 0, rate)
seconds_per_gold = 3600_000 / max(rate, 1)
print(f"        {rate} milli/hour — one whole gold every {seconds_per_gold:.0f}s")

print("\n== the estates view no longer describes a pot ==")
st, e = call("GET", "/v1/estates", token=token)
check("estates returns 200", st == 200, st)
check("there is no pending pot any more", "pending" not in e.get("tax", {}), e.get("tax"))
check("and no offline cap", "cap_seconds" not in e.get("tax", {}), e.get("tax"))

print("\n== polling fast must not earn less than polling slowly ==")
# Two accounts, the same elapsed time. One is hammered, one is left alone. If
# elapsed is truncated or the anchor moves on a zero credit, the hammered one
# ends up behind.
#
# Both are opened once first. A brand-new player's cached rate is zero until
# their first state read establishes it -- they do not earn for the time before
# they ever played -- so the idle account has to be opened and then abandoned,
# which is also exactly the case that matters: close the app, come back later,
# and the gold is waiting.
busy, idle = new_player("bsy"), new_player("idl")
call("GET", "/v1/state", token=busy)
call("GET", "/v1/state", token=idle)
wait = seconds_per_gold * 1.6
deadline = time.time() + wait
polls = 0
while time.time() < deadline:
    call("GET", "/v1/state", token=busy)
    polls += 1
    time.sleep(0.25)

_, b = call("GET", "/v1/state", token=busy)
_, i = call("GET", "/v1/state", token=idle)
bg, ig = int(b["player"]["gold"]), int(i["player"]["gold"])
print(f"        after {wait:.0f}s: hammered ({polls} polls) {bg} gold, untouched {ig} gold")
check("income arrived while the app was closed, with nothing collected", ig > 0, ig)
check("the fast poller was not robbed by rounding", bg >= ig, (bg, ig))

print()
if failures:
    print(f"{len(failures)} FAILED: " + ", ".join(failures))
    sys.exit(1)
print("all checks passed")
