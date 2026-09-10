#!/usr/bin/env python3
"""End-to-end check of the account's own endpoints: the away summary and
deleting the account.

    python3 scripts/smoke-account.py https://91-107-215-32.sslip.io

What must hold, against the live API:
  - "while you were away" answers for any moment, and says nothing happened to
    a city nobody raided;
  - a deletion is refused without the right password, and refused as 403 --
    not 401, which would make the client refresh and sign itself out;
  - a deletion with it removes the account: its tokens stop working and its
    name no longer signs in;
  - a king who deletes their account leaves the kingdom a king.
"""
import json, os, subprocess, sys, time, random, string, urllib.request, urllib.error

BASE = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:8080"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PW = "battery horse staple"
FAILURES = []


def call(method, path, body=None, token=None):
    req = urllib.request.Request(BASE + path, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    data = json.dumps(body).encode() if body is not None else None
    try:
        with urllib.request.urlopen(req, data, timeout=25) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw or b"{}")
        except json.JSONDecodeError:
            return e.code, {}


def check(label, cond, detail=""):
    print(f"  {'PASS' if cond else 'FAIL'}  {label}{'' if cond else '  <- ' + str(detail)}")
    if not cond:
        FAILURES.append(label)


def seq(token):
    _, s = call("GET", "/v1/state", token=token)
    return s["player"]["action_seq"] + 1


def grant(user, level=0, gold=0):
    env = dict(os.environ)
    for line in open(os.path.join(ROOT, ".env")):
        line = line.strip()
        if "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            env[k] = v.strip().strip("'\"")
    subprocess.run(["go", "run", "./cmd/devgrant", "-user", user, "-level", str(level), "-gold", str(gold)],
                   cwd=os.path.join(ROOT, "server"), env=env, capture_output=True, check=True)


def register(prefix):
    name = prefix + "".join(random.choices(string.ascii_lowercase, k=6))
    st, r = call("POST", "/v1/auth/register", {"username": name, "password": PW, "tz_offset_minutes": 0})
    if st not in (200, 201):
        print(f"cannot register {name}: {st}")
        sys.exit(1)
    return name, r["access_token"], r["refresh_token"], r["player_id"]


print("\n== while you were away ==")
name, tok, refresh, pid = register("away")
st, away = call("GET", f"/v1/away?since={int(time.time()) - 3600}", token=tok)
check("the summary answers", st == 200, (st, away))
check("and a city nobody raided was raided no times", away.get("raids") == 0 and away.get("gold_lost") == 0, away)
st, bad = call("GET", "/v1/away?since=yesterday", token=tok)
check("a moment that is not a time is refused", st == 400, st)

print("\n== deleting an account ==")
st, r = call("POST", "/v1/account/delete", {"password": "not the password"}, token=tok)
check("the wrong password is refused, as 403", st == 403 and r.get("code") == "wrong_password", (st, r))
st, s = call("GET", "/v1/state", token=tok)
check("and nothing was deleted", st == 200, st)
st, r = call("POST", "/v1/account/delete", {"password": PW}, token=tok)
check("the right password deletes it", st == 204, (st, r))
st, r = call("POST", "/v1/auth/refresh", {"refresh_token": refresh})
check("its refresh token is refused", st == 401, (st, r))
st, r = call("POST", "/v1/auth/login", {"username": name, "password": PW})
check("its name no longer signs in", st == 401, (st, r))

print("\n== a king's crown passes on ==")
kname, king, _, king_id = register("kdel")
mname, member, _, member_id = register("mdel")
grant(kname, level=20, gold=300000)
grant(mname, level=20)
sfx = "".join(random.choices(string.ascii_uppercase, k=3))
st, kv = call("POST", "/v1/kingdom/found", {"name": "Crown " + sfx.lower(), "tag": sfx, "action_seq": seq(king)}, token=king)
check("the king founds a kingdom", st == 200, (st, kv))
if st == 200:
    kid = kv["kingdom"]["id"]
    st, j = call("POST", "/v1/kingdom/join", {"kingdom_id": kid, "action_seq": seq(member)}, token=member)
    check("a lord joins it", st == 200, (st, j))
    st, r = call("POST", "/v1/account/delete", {"password": PW}, token=king)
    check("the king deletes their account", st == 204, (st, r))
    st, mv = call("GET", "/v1/kingdom", token=member)
    check("the lord who stayed is crowned", st == 200 and (mv.get("me") or {}).get("role") == "king", (st, mv.get("me")))
    check("and the kingdom stands", (mv.get("kingdom") or {}).get("id") == kid, mv.get("kingdom"))
    # Leave nothing behind: the new king leaves, and the empty kingdom goes.
    call("POST", "/v1/kingdom/leave", {"action_seq": seq(member)}, token=member)
call("POST", "/v1/account/delete", {"password": PW}, token=member)

print()
if FAILURES:
    print(f"{len(FAILURES)} FAILED: " + ", ".join(FAILURES))
    sys.exit(1)
print("all checks passed")
