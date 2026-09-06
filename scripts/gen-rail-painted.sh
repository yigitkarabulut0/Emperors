#!/usr/bin/env bash
# Painted icons for the navigation rail.
#
# docs/ART.md draws the line at display size: "loot is generated, interface is
# authored", because a painterly render at 34 px is mush. That was written when
# the rail was 96 units wide with 40-unit glyphs. It is 152 units wide now with
# 62-unit icons -- 38 pt on a 16 Pro Max, roughly 114 device pixels -- and at
# that size a painted object reads, which is what the reference this game is
# being built to actually uses. The line moved because the rail did.
#
# The flat authored glyphs are still in scripts/gen-ui-icons.py and still the
# right answer for the 40-44 px row icons in jobs, holdings and upgrades. Only
# the nine rail icons are painted.
#
# One consequence worth knowing: a painted icon cannot be tinted. The old glyphs
# were one white path each and the client modulated them gold when a section was
# open. State is carried by the PLATE now -- red when open, stone when not --
# which is how the reference does it too.
#
# Roughly 110 seconds an icon on an M4, so about twenty minutes for all nine.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RAW="$ROOT/art/rail"
OUT="$ROOT/client/assets/ui"
mkdir -p "$RAW" "$OUT"

STYLE="Hand-painted stylised game art, the look of a Blizzard card illustration rendered for ancient Rome. Bold clear silhouette, chunky heroic forms, thick shapes. Painterly brushwork with visible strokes, warm rim lighting from the upper left, deep saturated colour, aged bronze and gold and worn marble and oiled leather. Heavy contrast between light and shadow, dark rich shadows. Not photorealistic, not flat vector, not cute, not childish. Single object centred filling 85 percent of the frame, no hands, no character, no scene, no ground, no cast shadow. Flat solid uniform mid-teal background RGB 45 110 110, no gradient, no vignette, no border, no text, no watermark."

teal_left() {
  magick "$1" -alpha off -fuzz 16% -fill white -opaque 'rgb(45,110,110)' \
    -fill black +opaque white -colorspace gray -format "%[fx:mean]" info:
}

gen() {
  local name="$1" subject="$2"
  if [ -f "$OUT/$name.png" ] && [ -f "$RAW/$name.png" ]; then
    echo "  $name already done"; return
  fi
  for attempt in 1 2 3; do
    rm -f "$RAW/$name.png" "$RAW/$name.metadata.json"
    "$ROOT/art/.venv/bin/mflux-generate-flux2" \
      --model Runpod/FLUX.2-klein-4B-mflux-4bit --base-model flux2-klein-4b \
      --prompt "$subject $STYLE" --steps 6 --width 1024 --height 1024 --low-ram \
      --output "$RAW/$name.png" >/dev/null 2>&1
    [ -f "$RAW/$name.png" ] || { echo "  $name generation FAILED" >&2; return; }

    "$ROOT/art/.venv/bin/python" "$ROOT/.claude/skills/asset-gen/tools/rembg_matting.py" \
      "$RAW/$name.png" -o "$RAW/${name}_cut.png" --alpha-floor 0.06 >/dev/null 2>&1
    # Trimmed to the object and centred, so every icon fills its plate the same
    # amount no matter how much air the model left around it.
    magick "$RAW/${name}_cut.png" -trim +repage -resize 224x224 \
      -background none -gravity center -extent 256x256 "$OUT/$name.png"

    local left
    left="$(teal_left "$OUT/$name.png")"
    if awk -v v="$left" 'BEGIN{exit !(v < 0.15)}'; then
      printf '  %-11s ok (teal %.3f)\n' "$name" "$left"
      return
    fi
    printf '  %-11s cut failed (teal %.3f), attempt %d\n' "$name" "$left" "$attempt"
    rm -f "$OUT/$name.png"
  done
  echo "  $name GAVE UP after 3 attempts" >&2
}

# The nine, named for the file the shell asks for rather than for the section.
gen house     "A Roman victory wreath of golden laurel leaves tied with a crimson ribbon, shown face on as a closed ring."
gen fields    "A neat stack of ancient Roman gold aureus coins, five or six coins piled and slightly fanned, embossed emperor faces catching the light."
gen armory    "A banded wooden treasure chest with iron straps and a heavy brass lock, lid closed, worn oak."
gen market    "A pair of antique brass balance scales with two shallow pans on chains, standing upright."
gen barracks  "A Roman legionary galea helmet in bronze with a crimson horsehair crest, cheek guards, three quarter view."
gen war_gate  "Two crossed Roman gladius short swords with bronze pommels and leather grips, blades polished steel."
gen keep      "A marble bust of a Roman emperor wearing a golden laurel crown, head and shoulders, carved white stone."
gen territory "A Roman country villa with terracotta roof tiles, cream stucco walls and a colonnade, seen in three quarter view."
gen bank      "A Roman strongbox of dark wood bound in iron, lid open, gold coins spilling over the rim."


# Two more for the Hero screen's quartered stat panel. The other two figures it
# needs -- crossed swords for Might and a galea for the field -- are already
# above, so only these are missing.
mkdir -p "$OUT/stat"
OUT="$OUT/stat"
gen sword  "A single Roman gladius short sword standing point down, bronze pommel, leather grip, polished steel blade."
gen shield "A Roman legionary scutum shield, curved rectangular, painted crimson with a golden winged thunderbolt device and bronze boss, three quarter view."
echo "done"
