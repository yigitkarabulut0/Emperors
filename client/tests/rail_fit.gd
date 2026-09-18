extends SceneTree
## The rail holds eight entries -- COURT the eighth -- and its event seal, on
## every phone: the 1672 design, a 1624 screen, and 1899 and 2040 (a 19.5:9
## phone), each with the Dynamic Island's notch (141) over its top and without.
##
## Seven entries at the collect painting's spacing (185 apart, fixed centres)
## filled the 1672 design to its foot; an eighth had nowhere to go, and on a
## short screen under a notch the rail's last entries ran off the bottom. The
## geometry is Shell.rail_geometry(h) now, from court.png: every entry's ink
## stays inside its own cell clear of both dividers, the lit plate inside its
## cell, the hit areas tile the cells, the seal and its plate sit on the rail's
## foot below the last cell and on the screen, and on the 1672 design the
## pitch is the painting's own (157).
##
## Run: godot --headless --path client --script tests/rail_fit.gd
##
## The shell is loaded at run time, never named as a class here: a class named
## in this script is compiled before the autoloads exist.

const HEIGHTS := [1672.0, 1624.0, 1899.0, 2040.0]
const INSETS := [0.0, 141.0]
## The eight entries, top to bottom, as court.png paints them.
const EIGHT := ["family", "collect", "inventory", "shop", "army", "attack", "kingdom", "court"]
## Clear space an entry's ink keeps from the dividers on either side of it.
const INK_CLEAR := 4.0

var _fails := 0


func _initialize() -> void:
	await process_frame
	root.get_node("GameState").set("snapshot", {"player": {"username": "Wwwwwwwwwwwwwwww", "level": 30, "gold": "1",
		"diamonds": 12, "action_seq": 1}, "energy": {"current": 1, "max": 2}, "sections": []})
	var script: GDScript = load("res://scenes/shell/shell.gd")
	var consts := script.get_script_constant_map()
	var order: Array = consts.get("ORDER", [])
	_expect(order == EIGHT, "the rail's entries are %s, not the painting's eight" % [order])
	_expect((consts.get("TABS", {}) as Dictionary).has("court"), "there is no COURT tab")
	if not consts.has("RAIL_TOP"):
		_fail("the shell has no rail geometry (rail_geometry)")
		_done(0)
		return
	var checked := 0
	for h in HEIGHTS:
		for inset in INSETS:
			checked += await _check(h, inset)
	# The design's own: court.png's cells are 157 apart.
	var g: Dictionary = script.call("rail_geometry", 1672.0)
	_expect(absf(float(g["pitch"]) - 157.0) < 0.6, "on the 1672 design the pitch is %.1f, court.png's 157" % float(g["pitch"]))
	_done(checked)


func _check(h: float, inset: float) -> int:
	var parent := Control.new()
	parent.size = Vector2(941, h)
	root.add_child(parent)
	var shell: Control = (load("res://scenes/shell/shell.tscn") as PackedScene).instantiate()
	parent.add_child(shell)
	shell.set_anchors_preset(Control.PRESET_FULL_RECT)
	for i in 3:
		await process_frame
	if inset > 0.0:
		shell.call("apply_inset", inset)
	await process_frame
	var tag := "%.0f%s" % [h, " under a %.0f notch" % inset if inset > 0.0 else ""]
	var rail: Control = shell.get("_rail")
	var rail_h := rail.size.y
	_expect(absf(rail.global_position.y - inset) < 0.5 and absf(rail_h - (h - inset)) < 0.5,
		"%s: the rail runs %.0f..%.0f, not the screen under the notch" % [tag, rail.global_position.y, rail.global_position.y + rail_h])
	var geo: Dictionary = shell.get("_geo")
	var pitch: float = geo.get("pitch", 0.0)
	var centres: Dictionary = geo.get("centres", {})
	var entries: Dictionary = shell.get("_entries")
	var hits: Dictionary = shell.get("_hits")
	var badges: Dictionary = shell.get("_badges")
	var e: float = geo.get("entry_scale", 1.0)
	var prev_hit_end := -1.0
	for i in EIGHT.size():
		var id: String = EIGHT[i]
		if not entries.has(id) or not centres.has(id):
			_fail("%s: there is no %s entry" % [tag, id])
			continue
		var c: float = centres[id]
		var top := c - pitch / 2.0
		var bottom := c + pitch / 2.0
		var img: TextureRect = entries[id]
		_expect(img.texture != null and not img.texture.resource_path.contains("magenta"), "%s: %s has no mark" % [tag, id])
		# The crop's ink is inside its 8 units (drawn down with it) of ground.
		var ink_top := img.position.y + 8.0 * e
		var ink_bottom := img.position.y + img.size.y - 8.0 * e
		_expect(ink_top >= top + INK_CLEAR and ink_bottom <= bottom - INK_CLEAR,
			"%s: %s's ink runs %.0f..%.0f, its cell %.0f..%.0f" % [tag, id, ink_top, ink_bottom, top, bottom])
		_expect(img.position.x >= 8.0 and img.position.x + img.size.x <= 146.0,
			"%s: %s runs x %.0f..%.0f, off the rail's ground" % [tag, id, img.position.x, img.position.x + img.size.x])
		var hit: Control = hits[id]
		_expect(hit.position.y >= prev_hit_end - 1.0, "%s: %s's tap area overlaps the one above" % [tag, id])
		_expect(hit.size.y >= 96.0, "%s: %s's tap area is %.0f tall, under a thumb's 96" % [tag, id, hit.size.y])
		prev_hit_end = hit.position.y + hit.size.y
		var bubble: Control = badges[id]
		_expect(bubble.position.y >= top and bubble.position.x + bubble.size.x <= 150.0,
			"%s: %s's count bubble at (%.0f, %.0f) leaves its cell or the rail" % [tag, id, bubble.position.x, bubble.position.y])
		# Lit, the entry's plate stays in its cell and its rim on the rail.
		shell.call("open", id)
		await process_frame
		var plate: TextureRect = shell.get("_plate")
		var s: float = geo.get("lit_scale", 1.0)
		var rim_top := plate.position.y + 3.0 * s
		var rim_bottom := plate.position.y + 158.0 * s
		_expect(plate.visible and plate.texture != null and plate.texture.resource_path.ends_with("nav/%s_lit.png" % id),
			"%s: %s lit is not nav/%s_lit" % [tag, id, id])
		_expect(rim_top >= top - 0.5 and rim_bottom <= bottom + 0.5,
			"%s: %s's lit plate runs %.0f..%.0f, its cell %.0f..%.0f" % [tag, id, rim_top, rim_bottom, top, bottom])
		_expect(plate.position.x + 2.0 * s >= 2.0 and plate.position.x + 166.0 * s <= 154.0,
			"%s: %s's lit rim runs x %.0f..%.0f, off the rail" % [tag, id, plate.position.x + 2.0 * s, plate.position.x + 166.0 * s])
		_expect(not img.visible, "%s: %s's unlit mark shows under its lit plate" % [tag, id])
	# The seal and its plate: under the last cell, on the screen.
	var seal: Control = shell.get("_seal")
	var seal_plate: Control = shell.get("_seal_plate")
	var cells_end: float = geo.get("cells_end", 0.0)
	_expect(seal.position.y >= cells_end, "%s: the seal (top %.0f) is over the last cell (ends %.0f)" % [tag, seal.position.y, cells_end])
	_expect(seal_plate.position.y + seal_plate.size.y <= rail_h - 30.0,
		"%s: the seal's plate ends at %.0f, the rail at %.0f" % [tag, seal_plate.position.y + seal_plate.size.y, rail_h])
	_expect(seal_plate.position.y >= seal.position.y + seal.size.y - 3.0, "%s: the seal's plate is over the seal" % tag)
	var dividers: Array = shell.get("_dividers")
	_expect(dividers.size() == EIGHT.size(), "%s: %d dividers for eight entries" % [tag, dividers.size()])
	if not dividers.is_empty():
		_expect(absf((dividers[0] as Control).position.y - 208.0) < 0.5, "%s: the portrait's divider moved" % tag)
	parent.queue_free()
	await process_frame
	return 1


func _done(checked: int) -> void:
	if checked == 0:
		_fail("no rail was measured")
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  eight entries, their lit plates and the seal fit the rail on %d screens (1624..2040, notch or none)" % checked)
	quit()


func _expect(ok: bool, why: String) -> void:
	if not ok:
		_fail(why)


func _fail(why: String) -> void:
	_fails += 1
	printerr("  ", why)
