extends SceneTree
## The Family screen's TALENTS / DEEDS / ROAD strip (family_storehouse.png): the
## way to the Victory Road.
##
## The painting put three medallion cards under the STOREHOUSE; none was on the
## screen, so the Victory Road -- fifteen milestones the server pays for -- had
## no door. What must hold, on 941x1672 and 941x2040:
##  - the strip sits under the storehouse card at the painting's gap, its outer
##    frames on the ledger's edges, and the ledger follows it at its own gap;
##  - each card is its own painting, its count disc lifted: TALENTS is dimmed
##    only under its own level
##    like the COURT's unbuilt cards and says "Opens soon"; ROAD and, since
##    Wave 4 built the deeds, DEEDS are lit, each with its own plate and disc;
##  - ROAD's plate says what waits ("3 rewards waiting", "1 reward waiting"),
##    else the next milestone's level, else that the road is walked -- the count
##    from the heartbeat's `road`, in the COURT cards' red disc on the
##    medallion's shoulder, 9+ past nine, gone at none;
##  - the words fit their plates;
##  - a tap on ROAD opens the Victory Road page.
##
## Run: godot --headless --path client --script tests/family_road_entry.gd

const DIM := Color(0.55, 0.55, 0.55)

var _fails := 0
var _checked := 0
var _gs: Node


func _initialize() -> void:
	await process_frame
	_gs = root.get_node("GameState")
	root.get_node("Env").set("api_base_url", "http://127.0.0.1:9")
	var family: GDScript = load("res://scenes/tabs/family.gd")
	if not family.has_method("road_words"):
		print("FAIL  the Family has no ROAD card: the Victory Road has no door")
		quit(1)
		return
	_words(family)
	for canvas in [Vector2i(941, 1672), Vector2i(941, 2040)]:
		await _strip(family, canvas)
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d checks: the Family's ROAD card opens the Victory Road and counts what waits on it" % _checked)
	quit()


func _expect(ok: bool, msg: String) -> void:
	_checked += 1
	if not ok:
		_fails += 1
		print("  FAIL  " + msg)


func _road(level: int, claimed: int) -> Dictionary:
	var levels := [3, 5, 8, 10, 12, 15, 18, 20, 25, 30, 35, 40, 45, 50, 60]
	var out: Array = []
	var waiting := 0
	for i in levels.size():
		var reached: bool = level >= int(levels[i])
		out.append({"index": i, "level": levels[i], "reached": reached, "claimed": reached and i < claimed, "lines": []})
		if reached and i >= claimed:
			waiting += 1
	return {"level": level, "claimable": waiting, "milestones": out}


func _words(family: GDScript) -> void:
	for row in [[{}, _road(22, 0), "8 rewards waiting"], [{"road": 1}, _road(22, 7), "1 reward waiting"],
			[{"road": 0}, _road(22, 8), "Next at level 25"], [{"road": 0}, _road(1, 0), "Next at level 3"],
			[{"road": 0}, _road(60, 15), "The road is walked"], [{"road": 0}, {}, ""]]:
		var n: int = family.call("road_count", row[0], row[1])
		var got: String = family.call("road_words", row[1], n)
		_expect(got == row[2], "badges %s, road at level %s: the plate says \"%s\", not \"%s\"" % [row[0], row[1].get("level", "-"), got, row[2]])


func _strip(family: GDScript, canvas: Vector2i) -> void:
	var tag := "%dx%d" % [canvas.x, canvas.y]
	var vp := SubViewport.new()
	vp.size = canvas
	root.add_child(vp)
	root.get_node("Nav").set("host", vp)
	_gs.call("adopt", {"player": {"username": "Wwwwwwwwwwwwwwww", "level": 22, "gold": "1000", "action_seq": 1,
		"xp": 0, "xp_to_next": 100, "tax_milli_per_hour": 0}, "energy": {"current": 10, "max": 10}})
	var tab: Control = family.new()
	tab.size = Vector2(canvas)
	vp.add_child(tab)
	await process_frame
	var honours: Dictionary = tab.get("_honours")
	var store: Dictionary = tab.get("_store")
	_expect(not honours.is_empty(), "%s: the Family has no TALENTS / DEEDS / ROAD strip" % tag)
	if honours.is_empty():
		vp.queue_free()
		return
	var strip: Control = honours["node"]
	var p: Dictionary = honours["parts"]
	# The card above the strip: the ROYAL TREASURY, itself under the storehouse.
	# family_storehouse.png lays the strip 11 under the storehouse;
	# family_treasury.png 7 under the treasury (the hairlines 11 apart).
	var card: Control = store["node"]
	var gap := 11.0
	var bank: Variant = tab.get("_treasury")
	if bank is Dictionary and not (bank as Dictionary).is_empty():
		card = bank["node"]
		gap = 7.0
	_expect(absf(strip.position.y - (card.position.y + card.size.y) - gap) < 0.5,
		"%s: the strip starts at %.0f, not %.0f under the card above it (%.0f)" % [tag, strip.position.y, gap, card.position.y + card.size.y])
	# Its outer frames on the ledger's edges (x 172..920): each crop keeps a unit of ground outside its frame.
	var left: Control = p["card_talents"]
	var right: Control = p["card_road"]
	_expect(absf(strip.position.x + left.position.x + 1.0 - 172.0) < 0.5
		and absf(strip.position.x + right.position.x + right.size.x - 1.0 - 920.0) < 0.5,
		"%s: the strip's frames run %.0f..%.0f, not the ledger's 172..920" % [tag,
		strip.position.x + left.position.x + 1.0, strip.position.x + right.position.x + right.size.x - 1.0])
	for id in ["talents", "deeds", "road"]:
		var c: TextureRect = p["card_" + id]
		_expect(c.texture != null and c.size.is_equal_approx(c.texture.get_size()),
			"%s: the %s card is not its painting at its painted size" % [tag, id])
	# The ledger under the strip.
	tab.set("_estates", {"upgrades": [{"id": "granary", "name": "Granary", "bucket": "collect_income_bp",
		"level": 0, "max_level": 20, "per_level": 300, "effect_now": 0, "next_cost": 400}], "upgrades_unlocked": true,
		"holdings": [], "treasury": {"vault": "0", "deposit_fee_bp": 1000, "unlock_level": 8, "unlocked": false}})
	tab.set("_road", _road(22, 0))
	_gs.call("set_badges", {"road": 3})
	tab.call("_paint_all")
	await process_frame
	var cards: Array = tab.get("_cards")
	if not cards.is_empty():
		var first: Control = cards[0]["node"]
		_expect(absf(first.position.y - (strip.position.y + strip.size.y) - 9.0) < 0.5,
			"%s: the ledger starts at %.0f, not 9 under the strip (%.0f)" % [tag, first.position.y, strip.position.y + strip.size.y])
	# TALENTS: lit for a lord past its level, its plate the points waiting to be
	# spent, else the ranks taken, and its disc the count -- the same three
	# states DEEDS and ROAD wear.
	_expect((p["card_talents"] as CanvasItem).modulate.is_equal_approx(Color.WHITE),
		"%s: TALENTS is dimmed for a lord past its level" % tag)
	var talents_status: Label = p["status_talents"]
	for row in [[{"left": 3, "spent": 4}, "3 points to spend", "3"],
			[{"left": 1, "spent": 9}, "1 point to spend", "1"],
			[{"left": 0, "spent": 9}, "9 ranks taken", ""],
			[{"left": 0, "spent": 0}, "Choose your three", ""]]:
		tab.call("talents_changed", (row as Array)[0])
		await process_frame
		_expect(talents_status.text == str((row as Array)[1]),
			"%s: TALENTS says \"%s\", not \"%s\"" % [tag, talents_status.text, (row as Array)[1]])
		var want_disc := str((row as Array)[2])
		_expect((p["badge_talents"] as CanvasItem).visible == (want_disc != ""),
			"%s: the TALENTS disc shows with \"%s\" waiting" % [tag, want_disc])
		if want_disc != "":
			_expect((p["count_talents"] as Label).text == want_disc,
				"%s: the TALENTS disc reads \"%s\"" % [tag, (p["count_talents"] as Label).text])
	# DEEDS: lit, its plate the medals waiting or won, its disc the count.
	_expect((p["card_deeds"] as CanvasItem).modulate.is_equal_approx(Color.WHITE), "%s: DEEDS is dimmed" % tag)
	var deeds_page := {"achievements": [{"claimed": 2, "tiers": [1, 2, 3, 4]}, {"claimed": 4, "tiers": [1, 2, 3, 4]}]}
	for row in [[3, "3 medals to claim", "3"], [1, "1 medal to claim", "1"], [0, "6 of 8 medals", ""]]:
		tab.set("_deeds", deeds_page)
		_gs.call("set_badges", {"achievements": int(row[0]), "road": 0})
		tab.call("_paint_honours")
		var st: Label = p["status_deeds"]
		var count: Label = p["count_deeds"]
		_expect(st.text == row[1], "%s: with %d waiting DEEDS says \"%s\"" % [tag, int(row[0]), st.text])
		_expect((p["badge_deeds"] as CanvasItem).visible == (int(row[0]) > 0),
			"%s: the DEEDS disc shows with %d waiting" % [tag, int(row[0])])
		if int(row[0]) > 0:
			_expect(count.text == row[2], "%s: the DEEDS disc says \"%s\" for %d" % [tag, count.text, int(row[0])])
	# Every medal won says so.
	tab.set("_deeds", {"achievements": [{"claimed": 4, "tiers": [1, 2, 3, 4]}]})
	_gs.call("set_badges", {"achievements": 0, "road": 0})
	tab.call("_paint_honours")
	_expect((p["status_deeds"] as Label).text == "Every medal won",
		"%s: with every medal won DEEDS says \"%s\"" % [tag, (p["status_deeds"] as Label).text])
	# ROAD: lit, the count and the words.
	_expect((p["card_road"] as CanvasItem).modulate.is_equal_approx(Color.WHITE), "%s: ROAD is dimmed" % tag)
	for row in [[3, "3 rewards waiting", "3"], [12, "12 rewards waiting", "9+"], [0, "Next at level 25", ""]]:
		var road := _road(22, 8) if int(row[0]) == 0 else _road(22, 0)
		tab.set("_road", road)
		_gs.call("set_badges", {"road": int(row[0])})
		tab.call("_paint_honours")
		var st: Label = p["status_road"]
		var count: Label = p["count_road"]
		_expect(st.text == row[1], "%s: with %d waiting ROAD says \"%s\"" % [tag, row[0], st.text])
		_expect((p["badge_road"] as CanvasItem).visible == (int(row[0]) > 0) and count.visible == (int(row[0]) > 0),
			"%s: the disc shows with %d waiting: %s" % [tag, row[0], (p["badge_road"] as CanvasItem).visible])
		if int(row[0]) > 0:
			_expect(count.text == row[2], "%s: the disc says \"%s\" for %d" % [tag, count.text, row[0]])
		# The words inside the plate.
		var ink := st.label_settings.font.get_string_size(st.text, HORIZONTAL_ALIGNMENT_LEFT, -1, st.label_settings.font_size).x
		_expect(ink <= st.size.x + 0.5, "%s: \"%s\" is %.0f wide in a %.0f plate" % [tag, st.text, ink, st.size.x])
	# A tap on ROAD opens the Victory Road.
	(p["hit_road"] as BaseButton).pressed.emit()
	for i in 4:
		await process_frame
	var opened := false
	for layer in root.get_node("Nav").call("overlay_parent").get_children():
		for n in layer.get_children():
			if n.get_script() != null and str(n.get_script().resource_path).ends_with("painted_page.gd") and str(n.get("id")) == "road":
				opened = true
				n.call("close")
	_expect(opened, "%s: a tap on ROAD did not open the Victory Road" % tag)
	for i in 4:
		await process_frame
	vp.queue_free()
	await process_frame
