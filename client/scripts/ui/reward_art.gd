class_name RewardArt
extends RefCounted
## A reward line drawn large: what money buys, shown as grandly where it is
## offered (the offer popup's tiles) as where it arrives (the Royal Delivery).
## The mail's rows and the store's small tiles keep the small reward icons.
##
## Every picture is a painting that is large, drawn down to its box and never
## up:
##  - diamonds: the vessel painted for the largest pack the line holds at least
##    as many diamonds as (art/slices/diamond_packs_large.json; the steps are the
##    packs' own sizes), so 650 diamonds are the 330 pack's chest;
##  - Energy Potions and Protection Charters: the store's own large cuts;
##  - a frame: round the lord's own face (FramedFace);
##  - a name colour: the enamel chip in the line's own colour, and a title its
##    scroll (Art.reward_line_icon);
##  - a crest at its own 91x120, and the store's lasting goods at 120.
## Anything else is its reward icon at its own size.

## [pack size, vessel], from the smallest.
const VESSELS := [[0, "store/vessel_60"], [330, "store/vessel_330"], [700, "store/vessel_700"],
	[1500, "store/vessel_1500"], [4000, "store/vessel_4000"], [8500, "store/vessel_8500"]]
## Reward icon keys whose large painting is not their small one.
const LARGE := {"energy_potion": "store/tile_potions", "city_shield": "rewards/charter"}


## The vessel painted for the largest pack `amount` diamonds fill.
static func vessel(amount: int) -> String:
	var out := str(VESSELS[0][1])
	for step in VESSELS:
		if amount >= int(step[0]):
			out = str(step[1])
	return out


## The large picture for a line that is not a frame (see dress).
static func texture(line: Dictionary) -> Texture2D:
	var key := str(line.get("icon", ""))
	if str(line.get("kind", "")) == "diamonds" or key == "diamond":
		return Art.tex(vessel(int(line.get("amount", 0))))
	if LARGE.has(key):
		return Art.tex(str(LARGE[key]))
	return Art.reward_line_icon(line)


## Draws `line` into `slot`, a TextureRect laid out as the picture's box and
## already in its parent: the picture at its own size centred, or drawn down to
## fit. A frame hides the slot and is drawn beside it, round the lord's face
## (`avatar`, a portrait id); that node is returned, else null.
static func dress(slot: TextureRect, line: Dictionary, avatar: String) -> Control:
	var square := FramedFace.square_of(str(line.get("icon", "")))
	if square != "":
		slot.visible = false
		var framed := FramedFace.build(square, Rect2(slot.position, slot.size), avatar)
		slot.get_parent().add_child(framed)
		return framed
	slot.visible = true
	slot.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	slot.texture = texture(line)
	# A piece of gear on its rarity's velvet, a square round the picture.
	var side := minf(slot.size.y + 12.0, slot.size.x)
	ItemGround.for_line(slot, line, Rect2(slot.position + Vector2((slot.size.x - side) / 2.0, -6.0), Vector2(side, side)))
	var sz := slot.texture.get_size() if slot.texture != null else Vector2.ZERO
	slot.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED if sz.x <= slot.size.x and sz.y <= slot.size.y \
		else TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	return null
