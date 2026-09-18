extends SceneTree
## The Victory Road is its painting (art/reference/road.png) with the road from
## the three node-less maps, on the painted pages' host, and holds on every
## phone.
##
## The road had no screen at all: fifteen milestones the server pays for
## reaching levels 3 to 60 were nowhere to be seen or claimed. Now, for the
## hard cases -- a level-1 lord with nothing reached, one at 22 with the first
## five claimed and three waiting, one at 47 with thirteen waiting, one at 60
## with every milestone claimed -- on 941x1672 and 941x2040, with and without a
## notch, and on the short phone under a notch where the page is drawn down:
##  - the page is a PaintedPage; the road scrolls inside the window's frame, the
##    three maps stacked 2970 tall, and the window grows on a taller phone;
##  - all fifteen milestones stand where the layout measured them, each in its
##    state -- steel ahead, gold in its halo while waiting, gold once claimed --
##    with its level on its plate, fitting it;
##  - every reward box sits beside its shield on the side the layout names,
##    inside the road, clear of every other milestone and box; a claimed one
##    wears the seal;
##  - the lord stands on the highest milestone reached, and nowhere before the
##    first;
##  - CLAIM answers only while something waits; both tabs answer, DEEDS since
##    Wave 4 built it; the plate says the lord's level;
##  - nothing goes under the notch, and CLOSE closes.
##
## Run: godot --headless --path client --script tests/road_page_fit.gd

const CANVASES := [[Vector2i(941, 1672), 0.0], [Vector2i(941, 1672), 141.0], [Vector2i(941, 2040), 0.0],
	[Vector2i(941, 2040), 141.0], [Vector2i(941, 1624), 141.0]]
const STACK_H := 2970.0

var _fails := 0
var _checked := 0


func _initialize() -> void:
	await process_frame
	root.get_node("Env").set("api_base_url", "http://127.0.0.1:9")
	var road := _road_from_balance()
	if road.is_empty():
		print("FAIL  balance/retention.json has no road")
		quit(1)
		return
	var cases := {
		"level 1": _state(road, 1, 0),
		"level 22, five claimed": _state(road, 22, 5),
		"level 47, none claimed": _state(road, 47, 0),
		"level 60, all claimed": _state(road, 60, 15),
	}
	for c in CANVASES:
		for key in cases:
			await _check_case(c[0], c[1], key, cases[key])
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d checks: the Victory Road stands its fifteen milestones on the painted road on every phone" % _checked)
	quit()


func _expect(ok: bool, msg: String) -> void:
	_checked += 1
	if not ok:
		_fails += 1
		print("  FAIL  " + msg)


## The fifteen milestones as the server sends them, from the balance the server
## pays them from: each one's diamonds, then its token, gear or looks.
func _road_from_balance() -> Array:
	var f := FileAccess.open("res://../balance/retention.json", FileAccess.READ)
	if f == null:
		return []
	var doc: Variant = JSON.parse_string(f.get_as_text())
	var cos := {}
	var cf := FileAccess.open("res://../balance/cosmetics.json", FileAccess.READ)
	if cf != null:
		for c in (JSON.parse_string(cf.get_as_text()) as Dictionary).get("items", []):
			cos[str(c["id"])] = c
	var out: Array = []
	for m in (doc as Dictionary).get("road", {}).get("milestones", []):
		var g: Dictionary = m.get("grant", {})
		var lines: Array = []
		if int(g.get("diamonds", 0)) > 0:
			lines.append({"kind": "diamonds", "amount": int(g["diamonds"]), "text": "%d diamonds" % int(g["diamonds"]), "icon": "diamond"})
		for id in (g.get("tokens", {}) as Dictionary):
			lines.append({"kind": "token", "id": id, "amount": int(g["tokens"][id]), "text": str(id), "icon": str(id)})
		for it in g.get("items", []):
			lines.append({"kind": "item", "id": it["tier"], "amount": int(it["count"]), "text": "%s gear" % it["tier"],
				"icon": "item:" + str(it["tier"]), "tier": it["tier"]})
		for id in g.get("cosmetics", []):
			var c: Dictionary = cos.get(id, {})
			var icon := str(c.get("art", str(c.get("kind", "cosmetic")) + ":" + str(id)))
			lines.append({"kind": "cosmetic", "id": id, "amount": 1, "text": str(c.get("name", id)), "icon": icon})
		out.append({"level": int(m["level"]), "crown": bool(m.get("crown", false)), "lines": lines})
	return out


func _state(road: Array, level: int, claimed: int) -> Dictionary:
	var stones: Array = []
	var waiting := 0
	for i in road.size():
		var m: Dictionary = road[i].duplicate(true)
		m["index"] = i
		m["reached"] = level >= int(m["level"])
		m["claimed"] = m["reached"] and i < claimed
		if m["reached"] and not m["claimed"]:
			waiting += 1
		stones.append(m)
	return {"level": level, "claimable": waiting, "diamonds_total": 435, "milestones": stones}


func _check_case(canvas: Vector2i, inset: float, key: String, road: Dictionary) -> void:
	var tag := "%dx%d inset %d, %s" % [canvas.x, canvas.y, int(inset), key]
	var vp := SubViewport.new()
	vp.size = canvas
	root.add_child(vp)
	root.get_node("Nav").set("host", vp)
	var host := Control.new()
	host.size = Vector2(canvas)
	vp.add_child(host)
	var gs := root.get_node("GameState")
	gs.set("snapshot", {"player": {"username": "Aldric", "level": int(road["level"]), "gold": "1", "action_seq": 1},
		"energy": {"current": 1, "max": 2}})
	var script: GDScript = load("res://scenes/pages/road_page.gd")
	var page: Control = script.open(host, {"inset": inset})
	for i in 3:
		await process_frame
	# By its script, not its class: naming the class here would compile the host
	# with this test, before the autoloads it uses exist.
	_expect(page != null and page.get_script().resource_path.ends_with("scripts/ui/painted_page.gd"),
		"%s: the road is not a painted page" % tag)
	script.paint(page, road)
	for i in 3:
		await process_frame
	var layout: GDScript = load("res://scripts/ui/layout.gd")
	var spec: Dictionary = layout.call("find", "road", "road")
	var spots: Array = spec.get("nodes", [])
	_expect(spots.size() == 15, "%s: the layout measures %d places on the road, not 15" % [tag, spots.size()])

	# The road in its window.
	var sc: ScrollContainer = page.call("node", "road")
	var content: Control = page.call("content", "road")
	var frame: Control = page.call("node", "frame")
	_expect(sc != null and content != null and frame != null, "%s: the road, or its frame, is missing" % tag)
	if sc == null or content == null or frame == null:
		vp.queue_free()
		return
	_expect(absf(content.custom_minimum_size.y - STACK_H) < 0.5, "%s: the road is %.0f tall, not the maps' %.0f" % [tag, content.custom_minimum_size.y, STACK_H])
	var win := Rect2(sc.position, sc.size)
	var rim := Rect2(frame.position, frame.size)
	_expect(rim.grow(-3.0).encloses(win) and win.grow(5.0).encloses(rim),
		"%s: the road %s is not 4 inside its frame %s" % [tag, win, rim])
	var extra := float(canvas.y) - inset - 1672.0
	if extra > 0.0:
		_expect(sc.size.y > 1276.0 + extra - 2.0, "%s: the window stays %.0f tall on a taller phone" % [tag, sc.size.y])
	var body: Control = page.get_child(0) if page.get_child_count() > 0 else page
	_expect(body.position.y >= inset - 0.5, "%s: the page starts at %.0f, under the notch's %.0f" % [tag, body.position.y, inset])
	var maps := 0
	for n in content.get_children():
		if n is TextureRect and (n as TextureRect).texture != null and str((n as TextureRect).texture.resource_path).contains("road/map_"):
			maps += 1
	_expect(maps == 3, "%s: %d road maps in the window, not 3" % [tag, maps])

	# The milestones.
	var built: Array = page.get_meta("milestones", [])
	_expect(built.size() == 15, "%s: %d milestones built, not 15" % [tag, built.size()])
	var stones: Array = road["milestones"]
	var consts: Dictionary = script.get_script_constant_map()
	var rects: Array = []
	var highest := -1
	for i in mini(built.size(), stones.size()):
		var b: Dictionary = built[i]
		var m: Dictionary = stones[i]
		var node: Control = b["node"]
		var parts: Dictionary = b["parts"]
		var at := Vector2(float(spots[i][0]), float(spots[i][1]))
		var disc: Vector2 = node.position + consts["DISC"]
		_expect(disc.distance_to(at) < 0.5, "%s: milestone %d stands at %s, not the road's %s" % [tag, i, disc, at])
		var reached := bool(m["reached"])
		var claimed := bool(m["claimed"])
		if reached:
			highest = i
		var state := "current" if reached and not claimed else ("reached" if claimed else "ahead")
		for s in ["ahead", "reached", "current"]:
			_expect((parts["shield_" + s] as CanvasItem).visible == (s == state),
				"%s: milestone %d (%s) shows its %s shield %s" % [tag, i, state, s, "shown" if (parts["shield_" + s] as CanvasItem).visible else "hidden"])
		_expect((parts["crown"] as CanvasItem).visible == bool(m["crown"]), "%s: milestone %d's crown" % [tag, i])
		var numeral: Label = parts["numeral"]
		_expect(numeral.text == "LV %d" % int(m["level"]), "%s: milestone %d reads \"%s\"" % [tag, i, numeral.text])
		var ink := numeral.label_settings.font.get_string_size(numeral.text, HORIZONTAL_ALIGNMENT_LEFT, -1,
			numeral.label_settings.font_size).x
		_expect(ink <= 76.0, "%s: milestone %d's \"%s\" is %.0f wide, past its plate's 76" % [tag, i, numeral.text, ink])
		# Its reward box, on its side of the road, inside the road.
		var box: Control = b["box"]["node"]
		var br := Rect2(box.position, box.size)
		_expect(br.position.x >= 6.0 - 0.5 and br.end.x <= 770.0 + 0.5, "%s: milestone %d's box %s runs off the road" % [tag, i, br])
		var side := str(spots[i][2])
		var clear := br.position.x >= at.x + 50.0 if side == "right" else br.end.x <= at.x - 50.0
		_expect(clear, "%s: milestone %d's box %s is not on its %s, clear of its shield at %s" % [tag, i, br, side, at])
		var lines: Array = m["lines"]
		_expect(is_equal_approx(br.size.x, 24.0 + 64.0 * float(maxi(1, lines.size()))),
			"%s: milestone %d's box is %.0f wide for %d rewards" % [tag, i, br.size.x, lines.size()])
		_expect((b["box"]["tiles"] as Array).size() == lines.size(), "%s: milestone %d draws %d tiles for %d rewards" % [tag, i, (b["box"]["tiles"] as Array).size(), lines.size()])
		_expect((b["box"]["parts"]["seal"] as CanvasItem).visible == claimed, "%s: milestone %d's seal" % [tag, i])
		for t in b["box"]["tiles"]:
			var a: Label = t["amount"]
			var w := a.label_settings.font.get_string_size(a.text, HORIZONTAL_ALIGNMENT_LEFT, -1, a.label_settings.font_size).x
			_expect(w <= 64.0, "%s: milestone %d's \"%s\" is wider than its tile" % [tag, i, a.text])
			var ic: TextureRect = t["icon"]
			_expect(ic.texture != null and Rect2(Vector2.ZERO, br.size).encloses(Rect2(ic.position, ic.size)),
				"%s: milestone %d's picture is missing or outside its box" % [tag, i])
			if ic.texture != null:
				_expect(ic.size.x <= ic.texture.get_width() + 0.5 and ic.size.y <= ic.texture.get_height() + 0.5,
					"%s: milestone %d's picture is drawn up" % [tag, i])
		# The shield as two blocks -- its ring round the disc and the numeral plate
		# under it -- and its box.
		rects.append([Rect2(at - Vector2(48, 48), Vector2(96, 96)), "shield %d" % i, i])
		rects.append([Rect2(at + Vector2(-47, 44), Vector2(94, 34)), "plate %d" % i, i])
		rects.append([br, "box %d" % i, i])
	for a in rects.size():
		for c in range(a + 1, rects.size()):
			var ra: Rect2 = rects[a][0]
			var rc: Rect2 = rects[c][0]
			# A shield and its own box are 12 apart; nothing may touch another milestone's.
			if rects[a][2] == rects[c][2]:
				continue
			_expect(not ra.grow(-2.0).intersects(rc.grow(-2.0)), "%s: %s %s and %s %s overlap" % [tag, rects[a][1], ra, rects[c][1], rc])

	# The lord on the highest milestone reached.
	var lord: Control = page.get_meta("lord") if page.has_meta("lord") else null
	if highest < 0:
		_expect(lord == null or not lord.visible, "%s: the lord walks the road before its first milestone" % tag)
	else:
		_expect(lord != null and lord.visible, "%s: the lord is not on the road" % tag)
		if lord != null:
			var base: Vector2 = lord.position + consts["LORD_BASE"]
			var want := Vector2(float(spots[highest][0]), float(spots[highest][1]) + float(consts["LORD_DROP"]))
			_expect(base.distance_to(want) < 0.5, "%s: the lord stands at %s, not on milestone %d" % [tag, base, highest])

	# CLAIM, DEEDS, the level.
	var claim: BaseButton = page.call("node", "claim")
	_expect(claim != null and claim.disabled == (int(road["claimable"]) == 0),
		"%s: CLAIM is %s with %d waiting" % [tag, "off" if claim != null and claim.disabled else "on", int(road["claimable"])])
	var tabs: Control = page.get_meta("tabs")
	_expect(tabs.call("is_enabled", "victory_road") and tabs.call("is_enabled", "deeds"),
		"%s: the strip does not answer on both DEEDS and VICTORY ROAD" % tag)
	var level: Label = page.call("node", "level")
	_expect(level != null and level.text == "LEVEL %d" % int(road["level"]), "%s: the plate reads \"%s\"" % [tag, level.text if level else ""])

	# CLOSE closes.
	var closed := [false]
	page.connect("closed", func() -> void: closed[0] = true)
	page.call("close")
	await process_frame
	_expect(closed[0], "%s: CLOSE did not close" % tag)
	vp.queue_free()
	await process_frame
