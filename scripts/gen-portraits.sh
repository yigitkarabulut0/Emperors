#!/usr/bin/env bash
# Generate the pickable player portraits.
#
# Unlike item art these are NOT tier-tinted -- a portrait is an identity, not a
# rarity -- and they are not matted to transparency either. They are baked into
# circular tokens with a rim, because that is how they are shown everywhere:
# beside your name, on the opponent list, and on both sides of a battle.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/art/portraits"
PROMOTE="$ROOT/client/assets/portraits"
mkdir -p "$OUT" "$PROMOTE"

STYLE="Flat 2D vector character portrait, art-deco noir style, in the visual language of a vintage engraved emblem. Head and shoulders bust facing the viewer. The figure is a solid dark charcoal silhouette. Its form is described by VERY THICK, bold, heavy warm gold line art: chunky gold outlines of uniform generous weight, broad gold edge highlights, simple bold gold ornament. Thick confident strokes like a woodcut or a logo, not fine detail. Flat fills only, no shading, no gradients, no texture. Extremely high contrast, graphic and iconic, readable as a tiny icon. Head centred, filling 80 percent of the frame. Flat solid dark charcoal background, RGB 26 22 20, completely uniform, no vignette, no border, no frame, no text."

gen() {
  local name="$1" subject="$2"
  [ -f "$PROMOTE/$name.png" ] && { echo "  $name already done"; return; }
  rm -f "$OUT/$name.png" "$OUT/$name.metadata.json"
  "$ROOT/art/.venv/bin/mflux-generate-flux2" \
    --model Runpod/FLUX.2-klein-4B-mflux-4bit --base-model flux2-klein-4b \
    --prompt "$subject $STYLE" \
    --steps 6 --width 1024 --height 1024 --low-ram \
    --output "$OUT/$name.png" >/dev/null 2>&1
  [ -f "$OUT/$name.png" ] || { echo "  $name FAILED" >&2; return; }

  # Bake the circular token: square crop, round mask, thin gold rim.
  magick "$OUT/$name.png" -resize 256x256^ -gravity center -extent 256x256 \
    \( -size 256x256 xc:none -fill white -draw "circle 128,128 128,4" \) \
    -alpha set -compose DstIn -composite \
    \( -size 256x256 xc:none -stroke '#E5C97B' -strokewidth 6 -fill none \
       -draw "circle 128,128 128,7" \) -compose Over -composite \
    "$PROMOTE/$name.png"
  echo "  $name"
}

gen knight   "A stern medieval knight in a visored helm."
gen king     "A crowned medieval king with a full beard."
gen queen    "A crowned medieval queen with braided hair."
gen archer   "A medieval archer in a hood, quiver strap across the chest."
gen monk     "A tonsured medieval monk in a cowled robe."
gen berserk  "A wild bearded northern warrior in a horned helm."
gen knave    "A sly hooded rogue with a scarf over the mouth."
gen herald   "A medieval herald in a plumed cap blowing a horn."
gen templar  "A crusader knight in a great helm with a cross on the surcoat."
gen witch    "A hooded sorceress with a circlet and long hair."
gen captain  "A grizzled mercenary captain with an eyepatch and a scar."
gen princess "A young noblewoman in a tall pointed hennin headdress."
echo "portraits in $PROMOTE"
