extends SceneTree
## Every item design the balance names has a painting, and every screen draws
## it inset inside an empty tile: the painting's box lies within the tile's box
## and keeps its own proportions there. Before this, a slot showed one fixed
## picture whatever was worn in it, because the paintings only held one item
## per slot per screen.
##
## Run: godot --headless --path client --script tests/item_art.gd

## screen -> [template id, tile part id, painting part id]
const TILES := {
	"family": [["tile_weapon", "art", "painting"], ["tile_armor", "art", "painting"], ["tile_horse", "art", "painting"]],
	"inventory": [["equipped_slot", "tile", "painting"], ["item_card", "tile", "painting"]],
	"shop": [["offer_card", "frame", "painting"]],
	"army": [["gear_tile", "art", "painting"]],
}

var _fails: int = 0
var _L: GDScript


func _initialize() -> void:
	await process_frame
	_L = load("res://scripts/ui/layout.gd")
	_every_design_has_a_painting()
	_every_painting_is_a_clean_cutout()
	for screen in TILES:
		for spec in TILES[screen]:
			_painting_sits_inside_its_tile(screen, spec[0], spec[1], spec[2])
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  item designs have clean paintings and every screen insets them in a tile")
	quit()


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)


func _every_design_has_a_painting() -> void:
	var f := FileAccess.open("res://../balance/items.json", FileAccess.READ)
	if f == null:
		_fail("could not read balance/items.json")
		return
	var d: Variant = JSON.parse_string(f.get_as_text())
	var keys := {}
	for it in d.get("definitions", []):
		keys[str(it.get("art", ""))] = true
	if keys.is_empty():
		_fail("balance/items.json names no art keys")
	for k in keys:
		if not ResourceLoader.exists("res://assets/items/painted/%s.png" % k):
			_fail("design %s has no painting at assets/items/painted/%s.png" % [k, k])


func _painting_sits_inside_its_tile(screen: String, tpl_id: String, tile_id: String, painting_id: String) -> void:
	var tpl: Dictionary = _L.find(screen, tpl_id)
	if tpl.is_empty():
		_fail("%s: no template %s" % [screen, tpl_id])
		return
	var tile := {}
	var painting := {}
	for p in tpl.get("parts", []):
		if str(p.get("id", "")) == tile_id:
			tile = p
		if str(p.get("id", "")) == painting_id:
			painting = p
	var tag := "%s/%s" % [screen, tpl_id]
	if tile.is_empty() or painting.is_empty():
		_fail("%s: needs both a %s and a %s part" % [tag, tile_id, painting_id])
		return
	var t: Rect2 = _L.rect_of(tile)
	var pr: Rect2 = _L.rect_of(painting)
	if not t.encloses(pr):
		_fail("%s: painting %s is not inside its tile %s" % [tag, pr, t])
	if str(painting.get("fit", "")) != "contain":
		_fail("%s: the painting must fit: contain, or a design is stretched to the box" % tag)
	if not str(painting.get("asset", "")).contains("{"):
		_fail("%s: the painting's asset should be a placeholder the screen fills" % tag)
	# The painting must be drawn over the tile, so it has to come later in the part list.
	var order := []
	for p in tpl.get("parts", []):
		order.append(str(p.get("id", "")))
	if order.find(painting_id) < order.find(tile_id):
		_fail("%s: the painting is listed before its tile and would be hidden under it" % tag)


## A painting must be the item and nothing else.
##
## The cut used to keep the glow around each item -- the haze on a shadow blade,
## the flames on a red one -- as semi-opaque pixels reaching well past the
## silhouette. Over the dark tiles that read as atmosphere, so it looked right
## wherever it was reviewed; over the shop's lit gold card the same pixels were
## a dark smear with a visible edge. A backdrop cannot be correct over two
## grounds at once, so there must not be one: nothing survives at the border,
## and the soft fringe stays a fringe rather than a field.
func _every_painting_is_a_clean_cutout() -> void:
	for k in _art_keys():
		var path := "res://assets/items/painted/%s.png" % k
		if not ResourceLoader.exists(path):
			continue
		var im := Image.load_from_file(path)
		im.convert(Image.FORMAT_RGBA8)
		var w := im.get_width()
		var h := im.get_height()
		var edge := 0.0
		for x in w:
			for y in [0, 1, 2, 3, h - 4, h - 3, h - 2, h - 1]:
				edge = maxf(edge, im.get_pixel(x, y).a)
		for y in h:
			for x in [0, 1, 2, 3, w - 4, w - 3, w - 2, w - 1]:
				edge = maxf(edge, im.get_pixel(x, y).a)
		if edge > 0.02:
			_fail("%s: backdrop survives at the border (alpha %.2f there)" % [k, edge])
		var faint := 0
		var solid := 0
		for y in h:
			for x in w:
				var a := im.get_pixel(x, y).a
				if a > 0.02 and a < 0.5:
					faint += 1
				elif a >= 0.5:
					solid += 1
		# An edge fringe is a few pixels around a silhouette; a kept backdrop is
		# a field of them, and outweighs the item itself.
		if solid > 0 and faint > solid:
			_fail("%s: %d faint pixels against %d solid -- that is a backdrop, not an edge"
				% [k, faint, solid])


func _art_keys() -> Array:
	var f := FileAccess.open("res://../balance/items.json", FileAccess.READ)
	if f == null:
		return []
	var d: Variant = JSON.parse_string(f.get_as_text())
	var keys := {}
	for it in d.get("definitions", []):
		keys[str(it.get("art", ""))] = true
	return keys.keys()
