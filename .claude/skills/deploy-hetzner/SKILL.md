---
name: deploy-hetzner
description: Ship a server or balance change to the live Hetzner VPS -- regenerate the balance, run migrations, publish the balance version, deploy and verify. Use after any change under server/, balance/ or a new migration.
---

# Deploying

Server or balance change, in this order:

```sh
python3 scripts/gen-balance.py                       # if balance changed
cd server && go run ./cmd/migrate up                 # if there is a new migration
cd server && go run ./cmd/adminctl -cmd publish-balance -note "why"
scripts/deploy-hetzner.sh 91.107.215.32
```

Then verify against `https://91-107-215-32.sslip.io`. Both `.env` (repo root) and
`infra/secrets.env` must exist; both are gitignored and neither is in git history.

`deploy-hetzner.sh` rsyncs the **working tree**, so uncommitted changes do ship —
but the image tag comes from `git rev-parse HEAD`, so it will name the wrong
commit until you commit.

**Skipping `publish-balance` is the most common way to "change" a number and see
nothing happen.** The database's active version beats the embedded seed.
