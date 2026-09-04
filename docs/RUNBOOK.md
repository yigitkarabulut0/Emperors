# Runbook

## One-time machine setup

```bash
# 1. Go tools on PATH (air, goose, migrate, gopls, staticcheck are installed but were invisible)
echo 'export PATH="$HOME/go/bin:$PATH"' >> ~/.zshrc && exec zsh

# 2. Art pipeline venv (CPU onnxruntime; the CUDA wheels in godogen's
#    requirements.txt have no Apple Silicon build)
cd art && uv venv --python 3.12 .venv
uv pip install --python .venv/bin/python -r ../.claude/skills/asset-gen/tools/requirements.txt

# 3. Secrets
cp .env.example .env   # then fill in; .env is gitignored and chmod 600

# 4. Godot export templates — only ios.zip is installed. The full 1.28 GB pack is
#    needed for macOS/Windows/Linux/Web/Android and can wait until M9.
#    https://github.com/godotengine/godot-builds/releases/download/4.7.2-stable/Godot_v4.7.2-stable_export_templates.tpz
```

Android (JDK 17, the SDK, Godot's Android templates, a debug keystore) is
deliberately **not** set up. It is M9 work.

## Daily loop

```bash
# server
cd server && set -a && . ../.env && set +a && go run ./cmd/api

# migrations (runs against the DIRECT endpoint, never the pooled one)
cd server && set -a && . ../.env && set +a && go run ./cmd/migrate -cmd up
go run ./cmd/migrate -cmd status

# client (editor)
godot --path client

# client (headless smoke test — prints the boot result and exits)
godot --path client --headless --quit-after 300
```

## Proof captures

Every milestone must leave evidence under `proof/M<n>/`. The game screenshots
itself, so this works on desktop and on device without OS screenshot permissions:

```bash
godot --path client -- --capture "$PWD/proof/M0/boot-connected.png" --capture-after 2
```

Notes:
- Capture runs set `ALWAYS_ON_TOP` so macOS keeps drawing the window, and disable
  input — an always-on-top window under the mouse pointer will otherwise receive
  click-throughs and fire phantom button presses.
- `[proof] no fresh frame ... using last drawn frame` is expected when the
  terminal has focus. The captured frame is still current.

## Gotchas already paid for

- **Quote the DSNs in `.env`.** They contain `&`, and `set -a; . .env` is a shell
  parse error without quotes.
- **Migrations use `DATABASE_URL_DIRECT`** (the host without `-pooler`). goose
  takes a session-level advisory lock, which a transaction-mode pooler cannot
  hold across statements.
- **Never run `godogen/publish.sh` against this repo.** `--force` does `rm -rf` on
  the target and its skill install is `rsync --delete` over `.claude/skills/`.
  Use `scripts/vendor-asset-gen.sh` then `scripts/patch-asset-gen.py` (idempotent).
- **Art generation must pass `--model gemini`** — there is no xAI key. The
  vendored fork already defaults to it; `--gemini-model pro` selects Nano Banana
  Pro (13.4¢) over flash for hero references.

## Known blockers (2026-09-04)

- **Google AI Studio key has zero quota.** Every model — `gemini-3-pro-image`,
  `gemini-3.1-flash-image`, `gemini-2.5-flash-image`, even `gemini-pro-latest` —
  returns `429 RESOURCE_EXHAUSTED ... free_tier ... limit: 0`. The key is valid
  (it can list models) but the project behind it cannot generate anything.
  Fix: enable billing on that Google Cloud project at
  <https://aistudio.google.com/app/apikey> → the key's project → Billing.
  The art pipeline is otherwise built and verified and needs no other change.
- **Neon project is still in `aws-eu-west-2` (London).** The plan calls for a new
  project in `aws-eu-central-1` (Frankfurt) to sit next to the Hetzner VPS. Neon
  regions are immutable after creation, so this must be a new project. The
  database is still empty, so the only cost is regenerating `.env`.
- **No VPS yet.** `infra/` is ready (Dockerfile, compose, Caddy); it needs a
  Hetzner server and an `sslip.io` name pointed at its IP.

## Dev flags (client)

Only read in non-release builds, so a shipped game never sees them.

```bash
# sign in without the UI — needed because capture runs disable input
godot --path client -- --dev-login <user> <password>

# play N collects through the real optimistic queue, then stop
godot --path client -- --dev-login <user> <pw> --dev-collect 40

# screenshot after N seconds
godot --path client -- --capture "$PWD/proof/M1/shot.png" --capture-after 5
```

## Smoke test

```bash
python3 scripts/smoke-m1.py [http://localhost:8080]
```

27 end-to-end checks over auth, refresh rotation, state, collect, levelling,
mastery and every refusal path. Run it against any environment before calling a
deploy good.
