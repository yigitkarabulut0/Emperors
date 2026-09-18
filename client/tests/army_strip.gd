extends SceneTree
## Every slot a player can own is on the screen, and the next one to buy is at
## the end of them.
##
## The army row was four cards at fixed positions, because that is what the
## reference painting happened to show. balance/soldiers.json allows ten, so
## slots five upward existed on the server, held soldiers, counted toward might
## -- and could not be seen, selected, geared or dismissed. The row scrolls
## sideways now and is built from the slot count.
##
## Run: godot --headless --path client --script tests/army_strip.gd

var _fails: int = 0
var _L: GDScript


func _initialize() -> void:
	await process_frame
	_L = load("res://scripts/ui/layout.gd")
	_the_row_scrolls_sideways()
	_it_holds_every_slot_the_balance_allows()
	_the_next_slot_comes_after_the_last_one()
	_no_portrait_carries_the_paintings_selection()
	await _the_screen_selects_by_tap_and_not_by_drag()
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  the army row carries every slot, selects by tap alone, and rings the chosen card whole")
	quit()


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)


func _strip() -> Dictionary:
	return _L.element("army", "soldier_strip")


func _the_row_scrolls_sideways() -> void:
	var s := _strip()
	if s.is_empty():
		_fail("army has no soldier_strip")
		return
	if str(s.get("kind", "")) != "scroll":
		_fail("soldier_strip is a %s, not a scroll" % str(s.get("kind", "")))
	if str(s.get("axis", "")) != "horizontal":
		_fail("soldier_strip does not scroll horizontally, so it can only ever show what fits")
	var ids := []
	for c in s.get("content", []):
		ids.append(str(c.get("id", "")))
	for want in ["soldier_card", "next_slot_card"]:
		if not ids.has(want):
			_fail("soldier_strip has no %s in it (has %s)" % [want, str(ids)])


## The strip must be able to lay out max_slots cards, not just the few the
## painting showed.
func _it_holds_every_slot_the_balance_allows() -> void:
	var maxs := _max_slots()
	if maxs <= 0:
		_fail("could not read max_slots from balance/soldiers.json")
		return
	var card: Dictionary = _L.find("army", "soldier_card")
	if card.has("instances"):
		_fail("soldier_card still carries %d fixed instances; the screen must build one per slot"
			% card["instances"].size())
	var pitch := float(card.get("pitch", 0))
	if pitch <= 0:
		_fail("soldier_card has no pitch, so a row of them cannot be spaced")
		return
	var r: Rect2 = _L.rect_of(card)
	if pitch < r.size.x:
		_fail("pitch %.0f is narrower than the card (%.0f); they would overlap" % [pitch, r.size.x])
	# The strip is a window, not the whole row: it must be narrower than the row
	# it scrolls, or scrolling was never needed and something else is wrong.
	var strip: Rect2 = _L.rect_of(_strip())
	if strip.size.x >= maxs * pitch:
		_fail("the strip is %.0f wide and %d slots need %.0f; nothing would scroll"
			% [strip.size.x, maxs, maxs * pitch])


func _the_next_slot_comes_after_the_last_one() -> void:
	var ns: Dictionary = _L.find("army", "next_slot_card")
	if ns.is_empty():
		_fail("no next_slot_card")
		return
	var ids := []
	for q in ns.get("parts", []):
		ids.append(str(q.get("id", "")))
	for want in ["tile", "price", "unlock"]:
		if not ids.has(want):
			_fail("next_slot_card has no %s (has %s)" % [want, str(ids)])
	# It must not still be a fixed element sitting to the right of four cards.
	if not _L.element("army", "next_slot").is_empty():
		_fail("the old fixed next_slot element is still in the layout")


## The painting's selection -- the gold frame round its first card -- was cut
## into the portraits along with the soldiers: a gold line along the villager's
## top, another down the mercenary's left. On the phone that read as a
## highlight that never moved, whatever was selected. A portrait is its own
## card's window and nothing of the frame round it -- the soldier sheet's cards
## have gold frames too, so every type in every look, small and large, is held
## to it.
func _no_portrait_carries_the_paintings_selection() -> void:
	var names: Array[String] = []
	for type in ["peasant", "mercenary", "gladiator"]:
		for look in ["rough", "fine", "gilded"]:
			names.append("soldier_%s_%s" % [type, look])
			names.append("soldier_%s_%s_large" % [type, look])
	for type in names:
		var img := Image.load_from_file("res://assets/portraits/%s.png" % type)
		if img == null:
			_fail("no portrait %s" % type)
			continue
		# The painting's gold is pale where it catches the light -- 254,254,174 --
		# so the test is warm and bright, not merely yellow. Three pixels deep,
		# because the frame's band sits a pixel or two in from the crop's edge.
		var w := img.get_width()
		var h := img.get_height()
		var bands := {"top": [], "left": [], "right": []}
		for d in 3:
			for x in w:
				bands["top"].append(img.get_pixel(x, d))
			for y in h:
				bands["left"].append(img.get_pixel(d, y))
				bands["right"].append(img.get_pixel(w - 1 - d, y))
		for side in bands:
			var warm := 0
			for c: Color in bands[side]:
				if c.r > 0.7 and c.g > 0.55 and c.r - c.b > 0.2:
					warm += 1
			var share := float(warm) / float((bands[side] as Array).size())
			if share > 0.3:
				_fail("the %s portrait's %s edge is %.0f%% the painting's gold frame"
					% [type, side, share * 100.0])


## A card is chosen by a tap, and never by a drag that happens to start on one;
## the gold ring round the chosen card is whole, and the tier badge sits on top
## of it.
func _the_screen_selects_by_tap_and_not_by_drag() -> void:
	var host := Control.new()
	host.size = Vector2(941, 1672)
	root.add_child(host)
	var screen: Control = load("res://scenes/tabs/army.gd").new()
	screen.size = Vector2(941, 1672)
	host.add_child(screen)
	for i in 3:
		await process_frame
	var slots: Array = []
	var types := ["peasant", "mercenary", "gladiator"]
	var tiers := ["common", "rare", "epic", "special", "uncommon", "legendary"]
	for i in 6:
		slots.append({"index": i + 1, "soldier": {"id": "s%d" % i, "type": types[i % 3], "tier": tiers[i],
			"attack": 500, "defense": 400, "ehp": 3000, "hp": 300, "equipped": {}, "reroll_cost": 20000}})
	screen.set("_army", {"slots": slots, "totals": {"might": 1000},
		"next_slot": {"index": 7, "cost": 1000, "unlocked": true}, "recruits": []})
	screen.call("_paint")
	for i in 3:
		await process_frame
	var cards: Array = screen.get("_cards")
	if cards.size() != 6:
		_fail("six slots built %d cards" % cards.size())
		host.queue_free()
		return

	var tap: BaseButton = cards[2]["parts"]["tap"]
	# A swipe up the screen that begins on card three: the row does not move,
	# so nothing but the finger's travel can tell it from a tap.
	tap.button_down.emit()
	var swipe := InputEventMouseMotion.new()
	swipe.relative = Vector2(2, 48)
	swipe.button_mask = MOUSE_BUTTON_MASK_LEFT
	tap.gui_input.emit(swipe)
	tap.pressed.emit()
	if int(screen.get("_selected")) != 1:
		_fail("a swipe that began on card three selected it")
	# The row itself scrolled under the finger: not a tap either.
	tap.button_down.emit()
	(screen.get("_ui")["soldier_strip"] as ScrollContainer).scroll_started.emit()
	tap.pressed.emit()
	if int(screen.get("_selected")) != 1:
		_fail("dragging the row selected the card the drag began on")
	# A tap that stays put chooses.
	tap.button_down.emit()
	tap.pressed.emit()
	if int(screen.get("_selected")) != 3:
		_fail("a clean tap on card three did not select it")
	await process_frame

	var strip: ScrollContainer = screen.get("_ui")["soldier_strip"]
	for i in [0, 2]:
		screen.call("_select", i + 1)
		await process_frame
		var card: Control = cards[i]["node"]
		var ring: Control = cards[i]["parts"]["selected_frame"]
		if not ring.visible:
			_fail("card %d is selected and shows no ring" % (i + 1))
			continue
		var top := card.position.y + ring.position.y
		var left := card.position.x + ring.position.x
		var bottom := top + ring.size.y
		if top < 0.0 or left < 0.0 or bottom > strip.size.y:
			_fail("card %d's ring runs from (%.0f, %.0f) to y %.0f in a %.0fx%.0f strip -- it is clipped"
				% [i + 1, left, top, bottom, strip.size.x, strip.size.y])
		var numeral: Control = cards[i]["parts"]["numeral"]
		if numeral.get_index() < ring.get_index():
			_fail("card %d's tier badge is drawn under its ring" % (i + 1))
	host.queue_free()
	await process_frame


func _max_slots() -> int:
	var f := FileAccess.open("res://../balance/soldiers.json", FileAccess.READ)
	if f == null:
		return 0
	var d: Variant = JSON.parse_string(f.get_as_text())
	return int(d.get("max_slots", 0)) if d is Dictionary else 0
