#!/usr/bin/env python3
"""Who is in the game: the live board, the heartbeat, and the write-back.

A phone is never needed for this. A Godot client is an HTTP client, and Python
is a better one, so every case the phone can produce is producible here.

What has to be true end to end:

  * a READ-ONLY request puts a player on the board -- the case that never
    touched last_seen_at before, and the reason every "active" number in the
    admin surface used to undercount everyone who was merely looking around
  * a client that has never sent a heartbeat is marked `inferred`, and one that
    has is not; both kinds exist at once and the panel must not describe them
    identically
  * the leaving beacon removes a player at once rather than after the timeout
  * two devices are two devices, and one leaving does not blank the other
  * the flush actually reaches the database, so the historical series is right
"""
import json, sys, time, urllib.error, urllib.request, uuid

ADMIN = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8081"
GAME = sys.argv[2] if len(sys.argv) > 2 else "http://127.0.0.1:8080"
ADMIN_USER = sys.argv[3] if len(sys.argv) > 3 else "yigit"
ADMIN_PASS = sys.argv[4] if len(sys.argv) > 4 else "emperors admin 2026"
failures = []


def call(base, method, path, body=None, token=None):
    req = urllib.request.Request(
        base + path, method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"content-type": "application/json",
                 **({"authorization": "Bearer " + token} if token else {})})
    try:
        with urllib.request.urlopen(req, timeout=30) as f:
            raw = f.read().decode()
            return f.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, {"raw": raw[:200]}


def check(name, ok, detail=""):
    print(("  PASS  " if ok else "  FAIL  ") + name + ("" if ok else f"  <- {detail}"))
    if not ok:
        failures.append(name)


def register():
    name = "smoke" + uuid.uuid4().hex[:8]
    st, body = call(GAME, "POST", "/v1/auth/register",
                    {"username": name, "password": "smoke-password-123"})
    if st != 201:
        print(f"could not register a player: {st} {body}")
        sys.exit(1)
    return name, body["player_id"], body["access_token"]


st, body = call(ADMIN, "POST", "/login", {"username": ADMIN_USER, "password": ADMIN_PASS})
if st != 200:
    print(f"admin sign-in failed: {st} {body}")
    sys.exit(1)
atok = body["token"]


def board():
    _, b = call(ADMIN, "GET", "/live", token=atok)
    return b


def find(b, pid):
    for row in b.get("playing", []) + b.get("idle", []):
        if row["id"] == pid:
            return row
    return None


print("\n== a read-only request is enough to be here ==")
name, pid, tok = register()
before = board()
call(GAME, "GET", "/v1/state", token=tok)
time.sleep(0.4)
after = board()
row = find(after, pid)
check("a GET puts the player on the board", row is not None,
      "a read-only endpoint mutates nothing, so this is exactly the case that "
      "used to be invisible")
check("and it counts as playing", row and row["presence"] == "playing", row)
check("the registered total is unchanged by presence",
      after["registered"] == before["registered"],
      (before["registered"], after["registered"]))

print("\n== the panel says how much it actually knows ==")
check("a client with no heartbeat is marked inferred", row and row["inferred"] is True, row)
st, _ = call(GAME, "POST", "/v1/presence", {"state": "foreground"}, token=tok)
check("the heartbeat answers 204", st == 204, st)
time.sleep(0.4)
row = find(board(), pid)
check("and after one beat it is no longer inferred", row and row["inferred"] is False, row)

print("\n== leaving ==")
st, _ = call(GAME, "POST", "/v1/presence", {"state": "leaving"}, token=tok)
check("the beacon answers 204", st == 204, st)
time.sleep(0.4)
check("and the player is off the board at once", find(board(), pid) is None)

print("\n== two devices ==")
name2, pid2, tok2 = register()
# A second sign-in for the same account is a second token family, which is what
# a second phone looks like to the server.
st, second = call(GAME, "POST", "/v1/auth/login",
                  {"username": name2, "password": "smoke-password-123"})
check("a second sign-in succeeds", st == 200, st)
if st == 200:
    call(GAME, "GET", "/v1/state", token=tok2)
    call(GAME, "GET", "/v1/state", token=second["access_token"])
    time.sleep(0.4)
    row = find(board(), pid2)
    check("both devices are counted", row and row["devices"] == 2, row)
    call(GAME, "POST", "/v1/presence", {"state": "leaving"}, token=tok2)
    time.sleep(0.4)
    row = find(board(), pid2)
    check("one leaving does not blank the other", row is not None, row)

print("\n== the write-back reaches the database ==")
name3, pid3, tok3 = register()
_, d = call(ADMIN, "GET", f"/players/detail?id={pid3}", token=atok)
seen_before = d.get("last_seen")
print(f"  (waiting ~35s for a flush cycle; last_seen was {seen_before})")
time.sleep(32)
call(GAME, "GET", "/v1/state", token=tok3)
time.sleep(35)
_, d = call(ADMIN, "GET", f"/players/detail?id={pid3}", token=atok)
check("a read-only request moved last_seen_at",
      d.get("last_seen") != seen_before,
      f"{seen_before} -> {d.get('last_seen')}; the registry is the only writer now, "
      "so if this fails nothing is writing the column at all")

print()
if failures:
    print(f"{len(failures)} FAILED: " + ", ".join(failures))
    sys.exit(1)
print("all good")
