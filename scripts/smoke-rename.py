#!/usr/bin/env python3
"""Smoke test for the paid rename: POST /v1/profile/rename.

    python3 scripts/smoke-rename.py <base-url>               # the refusals, on a fresh account
    python3 scripts/smoke-rename.py <base-url> <user> <pw>   # plus the paid path, if the account can afford it

The paid path renames the account to <user>_x and leaves it there, so the next
run must log in with the new name.
"""
import json, sys, time, urllib.error, urllib.request

BASE = sys.argv[1].rstrip("/") if len(sys.argv) > 1 else "http://127.0.0.1:8080"
fails = 0


def call(method, path, body=None, token=None):
    req = urllib.request.Request(BASE + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status, _json(r.read())
    except urllib.error.HTTPError as e:
        return e.code, _json(e.read())


def _json(raw):
    # A proxy or a wrong port answers with text, not a problem document; keep
    # the run alive so the failure reads as a FAIL line rather than a traceback.
    try:
        return json.loads(raw or b"{}")
    except ValueError:
        return {"raw": raw.decode(errors="replace")[:200]}


def check(label, cond, detail=""):
    global fails
    print(("  PASS  " if cond else "  FAIL  ") + label + ("" if cond else f"   {detail}"))
    if not cond:
        fails += 1


if len(sys.argv) >= 4:
    user, pw = sys.argv[2], sys.argv[3]
    st, tok = call("POST", "/v1/auth/login", {"username": user, "password": pw})
    check("login", st == 200, (st, tok))
else:
    user, pw = f"rn{int(time.time()) % 100000000:08d}", "smoke-rename-pw-2026"
    st, tok = call("POST", "/v1/auth/register", {"username": user, "password": pw, "tz_offset_minutes": 0})
    check("register a fresh account", st == 201, (st, tok))
token = tok.get("access_token")

st, s = call("GET", "/v1/state", token=token)
price = s.get("prices", {}).get("rename_diamonds", 0)
check("state carries prices.rename_diamonds > 0", st == 200 and price > 0, s.get("prices"))
p = s["player"]
seq = p["action_seq"]
print(f"        {p['username']}: diamonds={p['diamonds']} price={price} seq={seq}")

for bad in ["ab", "1abc", "has space", "admin", "x" * 17]:
    st, r = call("POST", "/v1/profile/rename", {"name": bad, "action_seq": seq + 1}, token=token)
    check(f"bad name {bad!r} is a 400 invalid_username with the rule",
          st == 400 and r.get("code") == "invalid_username" and r.get("message"), (st, r))

st, r = call("POST", "/v1/profile/rename", {"name": p["username"], "action_seq": seq + 1}, token=token)
check("the current name is refused as same_name", st == 409 and r.get("code") == "same_name", (st, r))

st, r = call("POST", "/v1/profile/rename", {"name": user + "x", "action_seq": seq + 7}, token=token)
check("a sequence from the future is stale_action", st == 409 and r.get("code") == "stale_action", (st, r))

st, r = call("POST", "/v1/profile/rename", {"name": user + "x", "nam": 1, "action_seq": seq + 1}, token=token)
check("an unknown body field is a 400", st == 400, (st, r))

new_name = (user + "_x")[:16]
if p["diamonds"] < price:
    st, r = call("POST", "/v1/profile/rename", {"name": new_name, "action_seq": seq + 1}, token=token)
    check("without the diamonds it is refused: not_enough_diamonds",
          st == 409 and r.get("code") == "not_enough_diamonds", (st, r))
    st, s2 = call("GET", "/v1/state", token=token)
    q = s2["player"]
    check("and nothing moved: same name, diamonds and seq",
          q["username"] == p["username"] and q["diamonds"] == p["diamonds"] and q["action_seq"] == seq, q)
    print("        (fund the account to run the paid path)")
else:
    st, r = call("POST", "/v1/profile/rename", {"name": new_name, "action_seq": seq + 1}, token=token)
    check("the paid rename lands and the snapshot shows the new name",
          st == 200 and r.get("player", {}).get("username") == new_name, (st, r.get("player")))
    check("it costs exactly the quoted price",
          r.get("player", {}).get("diamonds") == p["diamonds"] - price, r.get("player", {}).get("diamonds"))
    st, dup = call("POST", "/v1/profile/rename", {"name": new_name + "y", "action_seq": seq + 1}, token=token)
    check("replaying the same action_seq is refused (no double charge)",
          st == 409 and dup.get("code") == "stale_action", (st, dup))
    st, l1 = call("POST", "/v1/auth/login", {"username": new_name, "password": pw})
    check("login works with the new name", st == 200, (st, l1))
    st, l2 = call("POST", "/v1/auth/login", {"username": user, "password": pw})
    check("login with the old name is refused", st == 401, (st, l2))
    print(f"        account is now named {new_name}")

print(f"\n{fails} FAILED" if fails else "\nrename smoke clean")
sys.exit(1 if fails else 0)
