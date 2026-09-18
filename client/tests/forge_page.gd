extends SceneTree
## THE FORGE -- the anvil page (scenes/pages/forge_page.gd), built from the
## owner's painting (art/reference/forge.png).
##
## What must hold:
##  - the three sockets and the result socket stand where the painting stands
##    them, measured off its own gold;
##  - the three pieces going in are the SERVER'S three, drawn as the Armory
##    draws a piece: its tier's ring, its tier's cloth under that, and its own
##    painting -- never a second kind of tile;
##  - the result socket wears the ring, the cloth and the painted badge of the
##    rank the server says comes out, and NO piece painting, because which piece
##    is rolled when the anvil strikes;
##  - the fee and the masterwork chance are printed as the server sent them,
##    on the painting's plates and inside them, and the page works out neither;
##  - FORGE is lit only when all three pieces are still in the bag.
##
## Run: godot --headless --path client --script tests/forge_page.gd

## Where art/slices/forge.layout.json stands the sockets, off the painting's gold.
const SOCKETS := [Rect2(134, 747, 177, 172), Rect2(382, 747, 177, 172), Rect2(630, 747, 176, 172)]
const RESULT := Rect2(371, 1052, 200, 190)
## The painted plates the two figures stand on (art/slices/forge.json).
const COST_PLATE := Rect2(208, 1281, 239, 68)
const ODDS_PLATE := Rect2(515, 1281, 229, 68)

var _fails := 0
var _checked := 0
## A --script test cannot name an autoload as an identifier, so Art is reached
## through the tree -- and it must not NAME a class that uses one either (UI,
## ItemGround), because naming it compiles it before the autoloads exist and
## every call on it then fails silently. They are loaded here instead.
var _art: Node = null
var _ui: GDScript = null
var _ground: GDScript = null


func _initialize() -> void:
	await process_frame
	root.get_node("Env").set("api_base_url", "http://127.0.0.1:9")
	_art = root.get_node("Art")
	_ui = load("res://scripts/ui/ui.gd")
	_ground = load("res://scripts/ui/item_ground.gd")
	_layout_is_the_painting()
	_no_arithmetic()
	await _page()
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d checks: the anvil is the painting's, and every figure on it is the server's" % _checked)
	quit()


func _expect(ok: bool, what: String) -> void:
	_checked += 1
	if not ok:
		_fails += 1
		print("  FAIL  " + what)


func _layout_is_the_painting() -> void:
	var LO: GDScript = load("res://scripts/ui/layout.gd")
	for i in SOCKETS.size():
		var e: Dictionary = LO.call("element", "forge", "ring_%d" % (i + 1))
		_expect(not e.is_empty(), "the forge layout has no ring_%d" % (i + 1))
		if e.is_empty():
			continue
		var r: Rect2 = LO.call("rect_of", e)
		_expect(r.is_equal_approx(SOCKETS[i]),
			"socket %d is at %s, not the painting's %s" % [i + 1, r, SOCKETS[i]])
	var out: Dictionary = LO.call("element", "forge", "out_ring")
	_expect(not out.is_empty() and (LO.call("rect_of", out) as Rect2).is_equal_approx(RESULT),
		"the result socket is not where the painting stands it")
	# The two figures must sit on the painted plates, not beside them.
	for pair in [["fee", COST_PLATE], ["odds", ODDS_PLATE], ["odds_label", ODDS_PLATE]]:
		var t: Dictionary = LO.call("element", "forge", str(pair[0]))
		_expect(not t.is_empty(), "the forge layout has no %s" % str(pair[0]))
		if t.is_empty():
			continue
		var tr: Rect2 = LO.call("rect_of", t)
		_expect((pair[1] as Rect2).encloses(tr),
			"%s runs off its painted plate: %s outside %s" % [str(pair[0]), tr, pair[1]])


## The fee, the rank that comes out and the odds are the server's. The page may
## print a basis point as "3 in 100"; it may not price the work.
func _no_arithmetic() -> void:
	var src := FileAccess.get_file_as_string("res://scenes/pages/forge_page.gd")
	for word in ["fee_bp", "next_price", "NextTier", "sell_price", "* 0.6", "0.6 *"]:
		_expect(not src.contains(word), "the anvil page works out %s itself" % word)


func _item(id: String, tier: String, art: String, power: int) -> Dictionary:
	return {"id": id, "def_id": "weapon_%s_01" % tier, "name": "Silvered Arming Sword",
		"slot": "weapon", "tier": tier, "art": art, "ilvl": 30, "quality_pct": 101,
		"attack": 412, "defense": 0, "speed": 0, "power": power, "sell_price": 400,
		"equipped": false, "equipped_on": ""}


func _bag() -> Array:
	return [_item("a", "rare", "weapon_07", 400), _item("b", "rare", "weapon_08", 420),
		_item("c", "rare", "weapon_09", 380)]


func _rules() -> Dictionary:
	return {"unlocked": true, "unlock_level": 12, "pieces": 3, "quality_min_pct": 95,
		"quality_max_pct": 105, "masterwork_chance_bp": 300,
		"tiers": ["common", "uncommon", "rare", "epic", "legendary", "mystic"]}


func _page() -> void:
	var host := Control.new()
	host.size = Vector2(941, 1672)
	root.add_child(host)
	await process_frame
	var FP: GDScript = load("res://scenes/pages/forge_page.gd")
	# [how many of the three the bag still holds, FORGE lit]
	for c in [[3, true], [2, false]]:
		var bag := _bag()
		var offer := {"items": ["a", "b", "c"], "tier": "epic", "ilvl": 30, "fee": 2043, "have": 3}
		if int(c[0]) < 3:
			bag.resize(int(c[0]))
		var page: Control = FP.call("open", host, null, bag[0], offer, _rules(), bag)
		await process_frame
		var tag := "%d of three in the bag" % int(c[0])

		for i in SOCKETS.size():
			var ring := page.call("node", "ring_%d" % (i + 1)) as TextureRect
			var art := page.call("node", "art_%d" % (i + 1)) as TextureRect
			_expect(ring != null and art != null, "%s: socket %d was not built" % [tag, i + 1])
			if ring == null or art == null:
				continue
			var filled := i < int(c[0])
			_expect(ring.visible == filled and art.visible == filled,
				"%s: socket %d is %s" % [tag, i + 1, "shown" if ring.visible else "hidden"])
			if not filled:
				continue
			# The Armory's own object: the tier's ring, the tier's cloth under
			# it, the piece's own painting in the middle.
			_expect(ring.texture == _art.call("tex", "inventory/frame_rare"),
				"%s: socket %d does not wear the rare ring" % [tag, i + 1])
			_expect(art.texture == _art.call("item", str((bag[i] as Dictionary)["art"])),
				"%s: socket %d does not show the piece the server named" % [tag, i + 1])
			var ground: Variant = art.get_meta("ground_node") if art.has_meta("ground_node") else null
			_expect(ground is TextureRect and (ground as TextureRect).texture == _ground.call("texture", "rare"),
				"%s: socket %d has no rare cloth under its ring" % [tag, i + 1])

		var out := page.call("node", "out_ring") as TextureRect
		var out_art := page.call("node", "out_art") as TextureRect
		var badge := page.call("node", "out_badge") as TextureRect
		_expect(out != null and out.texture == _art.call("tex", "inventory/frame_epic"),
			"%s: the result socket does not wear the epic ring" % tag)
		_expect(out_art != null and out_art.texture == null,
			"%s: the result socket shows a piece the anvil has not rolled" % tag)
		_expect(badge != null and badge.texture == _art.call("tex", "inventory/badge_epic"),
			"%s: the result socket does not say EPIC in the Armory's badge" % tag)
		if badge != null and out != null:
			_expect(Rect2(out.position, out.size).encloses(Rect2(badge.position, badge.size)),
				"%s: the rank's badge is not on the cloth: %s" % [tag, badge.position])

		var fee := page.call("node", "fee") as Label
		var odds := page.call("node", "odds") as Label
		_expect(fee != null and fee.text == _ui.call("grouped", 2043),
			"%s: the fee reads %s, not 2,043" % [tag, fee.text if fee != null else "nothing"])
		_expect(odds != null and odds.text == "3 in 100",
			"%s: the chance reads %s, not 3 in 100" % [tag, odds.text if odds != null else "nothing"])
		for l in [fee, odds]:
			if l == null:
				continue
			var box := Rect2(l.position, Vector2(l.get_minimum_size().x, l.size.y))
			_expect(Rect2(Vector2.ZERO, Vector2(941, 1672)).encloses(box),
				"%s: a figure runs off the page: %s" % [tag, box])

		var lit: Array = []
		_buttons(page, lit)
		var forge_btn: BaseButton = null
		for b in lit:
			if str((b as BaseButton).get_meta("action", "")) == "forge":
				forge_btn = b
		_expect(forge_btn != null, "%s: the page has no FORGE" % tag)
		if forge_btn != null:
			_expect(forge_btn.disabled != bool(c[1]),
				"%s: FORGE is %s" % [tag, "dark" if forge_btn.disabled else "lit"])
		page.call("close")
		await process_frame
	host.queue_free()
	await process_frame


func _buttons(n: Node, out: Array) -> void:
	for c in n.get_children():
		if c is BaseButton:
			out.append(c)
		_buttons(c, out)
