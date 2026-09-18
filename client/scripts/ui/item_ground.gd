class_name ItemGround
extends RefCounted
## The rarity velvet behind an item: every piece of gear sits on its tier's
## cloth, as the inventory painting paints its tiles -- a common piece on grey,
## uncommon on green, rare on blue, epic on purple, legendary on amber, mystic
## on rose, special on red.
##
## The cloths are the owner's seven velvet paintings (art/reference/velvet_*),
## cut by art/slices/velvets.json at 256 -- the largest window, the inventory
## list tile, draws 240 -- and brought to the tone of the painting's own tile for
## each tier. Two cuts of each:
##   items/ground_<tier>  the whole square, for a window whose frame is drawn
##                        over it (the inventory's rarity ring, a gear tile's
##                        ring): the frame hides the ground's edge;
##   items/glow_<tier>    the same under a feathered ellipse, for a window with
##                        no ring of its own (the shop card's picture, the
##                        collection's painted frames): it fades into the
##                        window instead of ending in a square.
## This is the one place a ground is chosen and placed; nothing else draws one.

const TIERS := ["common", "uncommon", "rare", "epic", "legendary", "mystic", "special"]
const META := "item_ground"
## The gear tiles' windows: the opaque painted tile, the ring cut from it, and
## the ground's rect in the tile's own pixels -- the ring's opening (its gold
## line's inner edge, measured) grown a pixel so no hairline shows between them.
const GEAR_TILES := {
	"family/gear_tile_empty": {"ring": "family/gear_tile_ring", "size": Vector2(220, 192),
		"window": Rect2(4, 9, 210, 174)},
	"army/gear_tile_empty": {"ring": "army/gear_tile_ring", "size": Vector2(98, 100),
		"window": Rect2(3, 3, 92, 93)},
}
## The inventory's rarity rings (inventory/frame_<tier>) are cut hollow 6 px
## deep on a 140 tile; a ground under one reaches 4 px in on every side, 2 px
## under the ring, at whatever size the tile is drawn.
const RARITY_RING_REACH := 4.0 / 140.0


## The ground's asset key for a tier. An item view always carries a tier, so an
## id this build does not know is a real unknown and gets common's cloth.
static func key(tier: String, soft := false) -> String:
	var t := tier if TIERS.has(tier) else "common"
	return ("items/glow_" if soft else "items/ground_") + t


static func texture(tier: String, soft := false) -> Texture2D:
	return Art.tex(key(tier, soft))


## Puts the tier's ground in the painting's parent over `rect` (the painting's
## own rect when none is given), just beneath the painting -- or beneath
## `beneath`, where a window's rarity ring is drawn under the painting and the
## ground must go under the ring. The same node is kept across repaints; an
## empty tier hides it (a bare slot keeps its empty look). Returns the ground.
static func under(painting: Control, tier: String, rect := Rect2(), soft := false,
		beneath: Node = null) -> TextureRect:
	var parent := painting.get_parent()
	var g: TextureRect = painting.get_meta("ground_node") if painting.has_meta("ground_node") else null
	if g == null or not is_instance_valid(g):
		g = TextureRect.new()
		g.name = "ItemGround"
		g.mouse_filter = Control.MOUSE_FILTER_IGNORE
		g.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		g.stretch_mode = TextureRect.STRETCH_SCALE
		parent.add_child(g)
		painting.set_meta("ground_node", g)
	var anchor: Node = beneath if beneath != null else painting
	if g.get_index() < anchor.get_index():
		parent.move_child(g, anchor.get_index() - 1)
	else:
		parent.move_child(g, anchor.get_index())
	var r := rect if rect.has_area() else Rect2(painting.position, painting.size)
	g.position = r.position
	g.size = r.size
	# The ground keeps its place beside the painting when a layout moves the
	# painting afterwards (the letter card drops its foot to the card's height).
	g.set_meta("offset", r.position - painting.position)
	if not painting.has_meta("ground_follows"):
		painting.set_meta("ground_follows", true)
		painting.item_rect_changed.connect(func() -> void:
			if is_instance_valid(g):
				g.position = painting.position + (g.get_meta("offset", Vector2.ZERO) as Vector2))
	g.visible = tier != ""
	if tier != "":
		g.texture = texture(tier, soft)
	g.set_meta(META, tier)
	g.set_meta("soft", soft)
	return g


## A window's rect inset by `inset` on every side: a ground drawn under a ring
## reaches a little under the ring's inner edge, never past its outer edge.
static func inset(rect: Rect2, by: float) -> Rect2:
	return Rect2(rect.position + Vector2(by, by), rect.size - Vector2(by, by) * 2.0)


## A window's own frame drawn over its ground and its item: the gear tiles'
## gold frame is part of their opaque tile, so a hollow ring cut from the same
## painting (family/gear_tile_ring, army/gear_tile_ring) closes the ground's
## edge. Kept across repaints, above the painting.
static func ring_over(painting: Control, asset: String, rect: Rect2) -> TextureRect:
	var parent := painting.get_parent()
	var r: TextureRect = painting.get_meta("ring_node") if painting.has_meta("ring_node") else null
	if r == null or not is_instance_valid(r):
		r = TextureRect.new()
		r.name = "ItemRing"
		r.mouse_filter = Control.MOUSE_FILTER_IGNORE
		r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		r.stretch_mode = TextureRect.STRETCH_SCALE
		r.texture = Art.tex(asset)
		parent.add_child(r)
		painting.set_meta("ring_node", r)
	parent.move_child(r, painting.get_index() + 1)
	r.position = rect.position
	r.size = rect.size
	return r


## An item on a gear tile (the Family, the Inventory's equipped slots, the
## Army): its ground inside the tile's window, the ring above the item.
static func in_gear_tile(painting: Control, tile: Control, tile_asset: String, tier: String) -> void:
	var spec: Dictionary = GEAR_TILES[tile_asset]
	var k: Vector2 = tile.size / (spec["size"] as Vector2)
	var w: Rect2 = spec["window"]
	under(painting, tier, Rect2(tile.position + w.position * k, w.size * k))
	ring_over(painting, str(spec["ring"]), Rect2(tile.position, tile.size))


## An item in a tile with a rarity ring drawn under the painting (the
## inventory list, the gear picker): the ground under the ring.
static func in_ringed_tile(painting: Control, ring: Control, tile_rect: Rect2, tier: String) -> void:
	under(painting, tier, inset(tile_rect, tile_rect.size.x * RARITY_RING_REACH), false, ring)


## A reward line's picture on its ground, when the line is a piece of gear with
## its own painting and says its tier (rewards.Line.tier). A line that does not
## say it -- one stored before lines carried a tier -- gets no ground: grey
## behind what may be a legendary would say something false. The tier's stone
## (item:<tier>) is already the rarity's mark and is left bare. The ground is
## the soft one: a reward's picture has no ring of its own.
static func for_line(picture: Control, line: Dictionary, rect := Rect2()) -> TextureRect:
	var tier := str(line.get("tier", ""))
	var gear := str(line.get("kind", "")) == "item" and str(line.get("icon", "")).begins_with("items/painted/")
	return under(picture, tier if gear and TIERS.has(tier) else "", rect, true)
