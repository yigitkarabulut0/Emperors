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
