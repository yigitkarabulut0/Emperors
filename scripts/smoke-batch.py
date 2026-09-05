#!/usr/bin/env python3
"""Batched collect: one request for a run of taps.

action_seq is per-player and monotonic, so collects can never overlap -- the
client used to send them strictly one at a time and ten taps meant ten round
trips. The risky part of batching is not the happy path, it is the batch that
cannot finish: it must apply what it can, commit that, and tell the client
exactly how far it got, so the client drops precisely those actions and no more.
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


user = "bat%d" % (int(time.time() * 1000) % 10_000_000)
st, reg = call("POST", "/v1/auth/register", {"username": user, "password": "battery horse staple"})
check("registered", st in (200, 201), (st, reg))
token = reg["access_token"]

st, s0 = call("GET", "/v1/state", token=token)
energy0 = s0["energy"]["current"]
gold0 = int(s0["player"]["gold"])
print(f"        start: {energy0} energy, {gold0} gold")

print("\n== a run of taps is one request ==")
n = 15
t0 = time.time()
st, b = call("POST", "/v1/collect/batch",
             {"job_ids": ["grapes"] * n, "action_seq": 1}, token=token)
dt = (time.time() - t0) * 1000
check("the batch is accepted", st == 200, (st, b))
check(f"all {n} collects applied", b["applied"] == n, b.get("applied"))
check("applied_through names the last sequence", b["applied_through"] == n, b.get("applied_through"))
check("gold arrived for every one", b["gold_gained"] >= 2 * n, b.get("gold_gained"))
print(f"        {n} collects in {dt:.0f} ms, one round trip")

print("\n== a batch that cannot finish applies what it can ==")
# Ask for far more than the remaining energy can pay for.
st, cur = call("GET", "/v1/state", token=token)
left = cur["energy"]["current"]
seq = cur["player"]["action_seq"] + 1
asked = 32
st, part = call("POST", "/v1/collect/batch",
                {"job_ids": ["grapes"] * asked, "action_seq": seq}, token=token)
check("a short batch still succeeds", st == 200, (st, part))
check("it applied fewer than it was asked for",
      0 < part["applied"] <= asked, (part.get("applied"), asked))
check("and said why it stopped",
      part.get("stopped_because") in ("not_enough_energy", "job_locked", None, ""),
      part.get("stopped_because"))
check("applied_through matches the count",
      part["applied_through"] == seq + part["applied"] - 1,
      (part.get("applied_through"), seq, part.get("applied")))

print("\n== the sequence is still strictly monotonic ==")
st, after = call("GET", "/v1/state", token=token)
check("action_seq is exactly applied_through",
      after["player"]["action_seq"] == part["applied_through"],
      (after["player"]["action_seq"], part["applied_through"]))
# Replaying the same first sequence must be refused, or a lost response could
# spend the whole batch twice.
st, again = call("POST", "/v1/collect/batch",
                 {"job_ids": ["grapes"], "action_seq": seq}, token=token)
check("replaying a spent sequence is refused", st == 409, (st, again))

print("\n== energy really was spent ==")
check("the pool went down by the batch, not by one",
      after["energy"]["current"] < left, (left, after["energy"]["current"]))

print()
if failures:
    print(f"{len(failures)} FAILED: " + ", ".join(failures))
    sys.exit(1)
print("all checks passed")
