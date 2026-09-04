#!/usr/bin/env bash
# Generate one item design and produce all seven tiers from it.
#
# Style comes from the prompt, which is strong enough on its own.
#
# The init image is OPTIONAL and off by default, because at any useful strength
# it locks the SILHOUETTE as well as the style: asking for a breastplate with the
# sword reference attached at 0.35 produced another sword. Use it only for
# variants of a subject the reference already depicts (a second sword design),
# never to move between slots.
#
# Usage: scripts/gen-item-art.sh <slot> <design_index> "<subject>" [init_image_strength]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SLOT="${1:?slot required (weapon|armor|horse)}"
IDX="$(printf '%02d' "${2:?design index required}")"
SUBJECT="${3:?subject description required}"
NAME="${SLOT}_${IDX}"

STYLE="Flat 2D vector game icon, art-deco noir style, in the visual language of a vintage engraved emblem. The body is a solid dark charcoal silhouette. Its form is described by VERY THICK, bold, heavy warm gold line art: chunky gold outlines of uniform generous weight, broad gold edge highlights, simple bold gold ornament. Thick confident strokes like a woodcut or a logo, not fine detail. Flat fills only, no shading, no gradients, no texture. Extremely high contrast, graphic and iconic, readable as a tiny icon. Centred, filling 85 percent of the frame. Flat solid medium teal background, RGB 45 110 110, completely uniform, no vignette, no border, no frame, no text."

INIT_STRENGTH="${4:-}"
INIT_ARGS=()
if [ -n "$INIT_STRENGTH" ]; then
  INIT_ARGS=(--image "$ROOT/art/refs/STYLE-REFERENCE.png" "$INIT_STRENGTH")
fi

# mflux does NOT overwrite: given an existing target it silently writes
# <name>_1.png instead. Without clearing first, every later step would run on the
# stale image and quietly ship the wrong art.
rm -f "$ROOT/art/refs/$NAME.png" "$ROOT/art/refs/$NAME.metadata.json"

"$ROOT/art/.venv/bin/mflux-generate-flux2" \
  --model Runpod/FLUX.2-klein-4B-mflux-4bit --base-model flux2-klein-4b \
  --prompt "$SUBJECT $STYLE" \
  ${INIT_ARGS[@]+"${INIT_ARGS[@]}"} \
  --steps 6 --width 1024 --height 1024 --low-ram --metadata \
  --output "$ROOT/art/refs/$NAME.png"

[ -f "$ROOT/art/refs/$NAME.png" ] || {
  echo "generation did not produce $NAME.png — refusing to matte a stale image" >&2
  exit 1
}

"$ROOT/art/.venv/bin/python" "$ROOT/.claude/skills/asset-gen/tools/rembg_matting.py" \
  "$ROOT/art/refs/$NAME.png" -o "$ROOT/art/matted/$NAME.png" --alpha-floor 0.06 >/dev/null

"$ROOT/art/.venv/bin/python" "$ROOT/scripts/tier-tint.py" \
  "$ROOT/art/matted/$NAME.png" "$ROOT/art/promoted" --prefix "$NAME"
