#!/usr/bin/env bash
# Local, free, offline image generation on Apple Silicon.
#
# Model: FLUX.2-klein-4B, 4-bit, via mflux (MLX). Apache-2.0, so the output is
# usable in a commercial game. ~4.6 GB on disk, no API key, no per-image cost.
#
# This is the fallback path while the Google AI Studio key has zero quota. Gemini
# follows a prompt more precisely — which matters for grid sheets where each cell
# must be a specific tier — so switch back if billing is ever enabled.
#
# Usage: scripts/gen-local.sh "<prompt>" <output.png> [width] [height] [steps]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROMPT="${1:?prompt required}"
OUT="${2:?output path required}"
W="${3:-1024}"; H="${4:-1024}"; STEPS="${5:-4}"

mkdir -p "$(dirname "$OUT")"
"$ROOT/art/.venv/bin/mflux-generate-flux2" \
  --model Runpod/FLUX.2-klein-4B-mflux-4bit \
  --base-model flux2-klein-4b \
  --prompt "$PROMPT" \
  --steps "$STEPS" --width "$W" --height "$H" \
  --low-ram --metadata \
  --output "$OUT"
