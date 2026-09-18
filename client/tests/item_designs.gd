extends SceneTree
## Every item the game sells is drawn as its own design.
##
## Seven designs served twenty-one items a slot, so a Rusted Arming Sword and
## The Gilded Verdict were the same sword, a Warden's Falchion wore the
## Farmhand's, and a rare Warden's Charger was the common Guard's Rouncey --
## the same painting under two keys, which a check of keys alone never saw. The
## weapon, armour and horse sheets (art/reference/items_weapons.png,
## items_armor.png, items_horses.png) paint fourteen more of each slot by name,
## and the balance gives every definition its own art key.
##
## SHARED is every definition that borrows another's design, as
## scripts/gen-balance.py's ART_SHARED declares it -- none since the Village
## Pony was painted: any share not declared fails, and so does a declared one
## whose definition has its own design.
##
## Reads the balance the server ships (balance/items.json) and the designs the
## client ships (assets/items/painted/): each named design exists, is the
## 256-unit matted canvas every tile insets, stands clear of its ground, is not
## a ghost, and is a different picture from every other design.
##
## Run: godot --headless --path client --script tests/item_designs.gd

const SHARED := {}

var _fails := 0
var _looked := {}
var _pictures := {}   ## content hash -> the art key it was first seen as


func _initialize() -> void:
	await process_frame
	var f := FileAccess.open("res://../balance/items.json", FileAccess.READ)
	if f == null:
		print("FAIL  could not read balance/items.json")
		quit(1)
		return
	var doc: Variant = JSON.parse_string(f.get_as_text())
	var defs: Array = doc.get("definitions", []) if doc is Dictionary else []
	if defs.size() != 63:
		_fail("balance/items.json has %d definitions, not 63" % defs.size())
	var by_art := {}       ## art key -> the definitions drawn with it
	var per_slot := {}     ## slot -> {art key: true}
	for d in defs:
		var id := str(d.get("id", ""))
		var slot := str(d.get("slot", ""))
		var art := str(d.get("art", ""))
		if not by_art.has(art):
			by_art[art] = []
		(by_art[art] as Array).append(id)
		if not per_slot.has(slot):
			per_slot[slot] = {}
		per_slot[slot][art] = true
		_check_design(art, str(d.get("name", "")))
		if SHARED.has(id) and art != SHARED[id]:
			_fail("%s has its own design (%s) now: take it out of SHARED here and ART_SHARED in gen-balance.py" % [id, art])
	for art in by_art:
		var ids: Array = by_art[art]
		for id in ids.slice(1):
			if not (SHARED.has(id) and SHARED[id] == art):
				_fail("%s are all drawn as %s" % [", ".join(ids), art])
				break
	for slot in ["weapon", "armor", "horse"]:
		var want := 21 - _shared_in(slot)
		var n: int = (per_slot.get(slot, {}) as Dictionary).size()
		if n != want:
			_fail("the %ss have %d designs between 21 definitions, want %d" % [slot, n, want])
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d definitions in %d designs, each its own but the %d declared" % [defs.size(), _looked.size(), SHARED.size()])
	quit()


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)


func _shared_in(slot: String) -> int:
	var n := 0
	for id in SHARED:
		if str(id).begins_with(slot + "_"):
			n += 1
	return n


func _check_design(art: String, name: String) -> void:
	if _looked.has(art):
		return
	_looked[art] = true
	var img := Image.load_from_file("res://assets/items/painted/%s.png" % art)
	if img == null:
		_fail("%s (%s) has no design at items/painted/%s" % [name, art, art])
		return
	if img.get_size() != Vector2i(256, 256):
		_fail("%s is %s, not the 256 canvas every tile insets" % [art, img.get_size()])
		return
	# Two keys, one picture: a design painted once and cut twice.
	var hash := img.get_data().hex_encode().sha256_text()
	if _pictures.has(hash):
		_fail("%s is the same picture as %s" % [art, _pictures[hash]])
	_pictures[hash] = art
	# Matted: the ground is gone at the corners and round the edge, and the item
	# itself is solid somewhere -- a cut that kept its backdrop would draw a
	# square on the tile, and an over-keyed one a ghost.
	var edge := 0.0
	for i in 256:
		for p in [Vector2i(i, 0), Vector2i(i, 255), Vector2i(0, i), Vector2i(255, i)]:
			edge = maxf(edge, img.get_pixelv(p).a)
	if edge > 0.05:
		_fail("%s's edge is not clear (alpha %.2f): it would draw its own ground on the tile" % [art, edge])
	# A ghost -- the object mask reading a fiery blade as backdrop left the
	# Crown of Flame a hilt and some wisps -- shows mostly half-clear pixels.
	# Solid against shown, so a slender rapier is not taken for one.
	var solid := 0
	var shown := 0
	for y in range(0, 256, 2):
		for x in range(0, 256, 2):
			var a := img.get_pixel(x, y).a
			if a > 0.1:
				shown += 1
			if a > 0.9:
				solid += 1
	if shown < 500 or float(solid) < 0.45 * float(shown):
		_fail("%s is a ghost: %d of %d shown samples are solid -- the cut lost the item" % [art, solid, shown])
