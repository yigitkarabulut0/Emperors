# Emperors

A 2D portrait mobile idle/RPG kingdom game. Godot 4.7 client, Go backend, Postgres (Neon),
Next.js admin panel. iPhone first, then Android, then Steam.

## Layout

| Path | What |
|---|---|
| `client/` | Godot 4.7 project (GDScript) |
| `server/` | Go 1.27 API — authoritative for every number |
| `admin/` | Next.js live-ops console |
| `balance/` | Seed balance documents (JSON) — the tunable game rules |
| `art/` | Gemini asset-generation workspace. **Never** imported by Godot |
| `contract/` | OpenAPI spec + generated clients |
| `infra/` | Dockerfile, compose, Caddy, deploy |
| `docs/` | Architecture and the full design corpus under `docs/design/` |
| `proof/` | Per-milestone evidence from the real device |

## Start here

- `docs/PLAN.md` — the build plan and milestones
- `docs/design/` — seven subsystem designs, each with its adversarial review appended

## Development

Requires: Go 1.27, Godot 4.7.2, Node 22+, Python 3.12+ with `uv`, `psql`.
See `docs/RUNBOOK.md` for one-time machine setup.
