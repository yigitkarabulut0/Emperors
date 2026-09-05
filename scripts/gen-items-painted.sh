#!/usr/bin/env bash
# Generate the painted item set: seven designs for each of the three slots.
#
# Replaces the flat gold line art. That style was chosen so ONE render could be
# hue-shifted into all seven tiers, which was efficient and looked like an
# outline rather than an object. Painted icons cannot be recoloured that way, so
# tier is carried by the card instead -- its border, its glow and its pip count --
# which is how the reference game does it and how most RPGs do it.
#
# Roughly 100 seconds a design on an M4, so about half an hour for all 21.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RAW="$ROOT/art/painted"
OUT="$ROOT/client/assets/items"
mkdir -p "$RAW" "$OUT"

STYLE="Painted 2D RPG loot icon, mobile game inventory art. Rendered with real volume and material: polished steel with visible specular highlights, worn leather, warm gold trim. Dramatic rim lighting from the upper left, soft ambient occlusion, rich saturated colour. Clean semi-realistic painterly rendering, crisp edges, high contrast so it reads at small size. Single object centred, filling 85 percent of the frame, no hands, no character, no scene, no ground, no shadow cast on the background. Flat solid uniform mid-teal background RGB 45 110 110, no gradient, no vignette, no border, no text, no watermark."

gen() {
  local name="$1" subject="$2"
  if [ -f "$OUT/$name.png" ]; then echo "  $name already done"; return; fi
  rm -f "$RAW/$name.png" "$RAW/$name.metadata.json"
  "$ROOT/art/.venv/bin/mflux-generate-flux2" \
    --model Runpod/FLUX.2-klein-4B-mflux-4bit --base-model flux2-klein-4b \
    --prompt "$subject $STYLE" --steps 6 --width 1024 --height 1024 --low-ram \
    --output "$RAW/$name.png" >/dev/null 2>&1
  [ -f "$RAW/$name.png" ] || { echo "  $name FAILED" >&2; return; }

  # Cut the teal away and trim to the object, so every icon fills its box no
  # matter how much empty background the model left around it.
  "$ROOT/art/.venv/bin/python" "$ROOT/.claude/skills/asset-gen/tools/rembg_matting.py" \
    "$RAW/$name.png" -o "$RAW/${name}_cut.png" --alpha-floor 0.06 >/dev/null 2>&1
  magick "$RAW/${name}_cut.png" -trim +repage -resize 220x220 \
    -background none -gravity center -extent 256x256 "$OUT/$name.png"
  echo "  $name"
}

gen weapon_01 "A medieval knight's arming sword, straight double-edged steel blade, gold crossguard, leather-wrapped grip."
gen weapon_02 "A curved single-edged falchion with a heavy cleaver-like steel blade and a brass hand guard."
gen weapon_03 "A broad medieval broadsword with a wide fullered steel blade and a plain iron crossguard."
gen weapon_04 "A huge two-handed greatsword with a long steel blade, a long leather grip and a round steel pommel."
gen weapon_05 "A flamberge sword with a dramatically wavy undulating steel blade and an ornate gold hilt."
gen weapon_06 "A slender duelling rapier with a very thin blade and an ornate swept basket hilt of curling steel bars."
gen weapon_07 "A short broad leaf-shaped bronze sword with a wide triangular blade and a disc pommel."

gen armor_01 "A quilted cloth gambeson, padded linen torso armour, worn and travel-stained."
gen armor_02 "A studded brown leather jerkin with iron rivets and buckled straps."
gen armor_03 "A riveted steel mail hauberk, chainmail shirt with a leather collar."
gen armor_04 "A plain steel breastplate cuirass with leather shoulder straps."
gen armor_05 "An ornate polished steel cuirass with engraved gold filigree and a fluted breastplate."
gen armor_06 "A blackened steel plate cuirass etched with glowing red runes, sinister and heavy."
gen armor_07 "A gilded royal cuirass of polished gold and white enamel with a lion crest on the chest."

gen horse_01 "A shaggy brown plough horse, heavy working animal, plain rope halter, standing in profile."
gen horse_02 "A small stocky grey pony with a shaggy mane, plain leather halter, standing in profile."
gen horse_03 "A brown rouncey riding horse with a worn leather saddle and bridle, standing in profile."
gen horse_04 "A sleek black courser, fast lean riding horse with a fine leather saddle, standing in profile."
gen horse_05 "A powerful white destrier warhorse in steel chanfron head armour, standing in profile."
gen horse_06 "A dark warhorse in full steel barding plate armour with a crimson caparison, standing in profile."
gen horse_07 "A magnificent royal charger in gilded gold barding with a white and gold caparison, standing in profile."

echo "painted items in $OUT"
