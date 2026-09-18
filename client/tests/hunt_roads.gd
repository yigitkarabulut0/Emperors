extends SceneTree
## THE EXPEDITIONS -- the Army tab's HUNT (scenes/tabs/army.gd) and the roads
## page (scenes/pages/hunt_page.gd).
##
## What must hold:
##  - the selected soldier's column carries three plates -- HUNT, REROLL,
##    DISMISS -- each a thumb's 95 units, none of them sharing a pixel, and all
##    of them inside the panel they stand on;
##  - HUNT's word is the soldier's state: HUNT in the yard, AWAY on a road,
##    BACK at the gate, and its crosshair only when there is somebody to send;
##  - a soldier away wears AWAY on their card and is drawn back; one at the
##    gate wears BACK;
##  - the state line says where they are and what is left of the road, from the
##    server's own seconds;
##  - the roads page is the owner's painting (art/reference/expedition.png): four
##    cards on the painting's own grid, each carrying the server's own name,
##    hours, gold, experience and gear odds on the plates the painting left
##    empty, and no figure it worked out itself;
##  - one road is chosen at a time and wears the painting's glow, the tap moves
##    it, and SEND is dark when every road is walked;
##  - under the level the hunt opens at, every card wears the painting's
##    padlock, every card is dimmed, none is lit and SEND is dark -- because the
##    Army's HUNT stands on every soldier from the first and the server refuses
##    the send.
##
## Run: godot --headless --path client --script tests/hunt_roads.gd

const THUMB := 95.0
## Where art/slices/expedition.layout.json stands the four cards, measured off
## the painting's own gold.
const CARD_AT := [Vector2(55, 441), Vector2(476, 441), Vector2(55, 967), Vector2(476, 967)]
const PANEL := Rect2(170, 898, 771, 388)

var _fails := 0
var _checked := 0


func _initialize() -> void:
	await process_frame
	root.get_node("Env").set("api_base_url", "http://127.0.0.1:9")
	_column_fits()
	_no_arithmetic()
	await _army_states()
	await _roads_page()
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d checks: the roads are the server's and the column takes a thumb" % _checked)
	quit()


func _expect(ok: bool, what: String) -> void:
	_checked += 1
	if not ok:
		_fails += 1
		print("  FAIL  " + what)


## Three plates where the painting had two: each a thumb, none overlapping, all
## inside the SELECTED SOLDIER panel.
func _column_fits() -> void:
	var LO: GDScript = load("res://scripts/ui/layout.gd")
	var rects: Array = []
	for id in ["hunt_tap", "reroll_tap", "dismiss"]:
		var e: Dictionary = LO.call("element", "army", id)
		_expect(not e.is_empty(), "the army layout has no %s" % id)
		if e.is_empty():
			continue
		var r: Rect2 = LO.call("rect_of", e)
		_expect(r.size.x >= THUMB and r.size.y >= THUMB,
			"%s takes a %.0fx%.0f tap, under a thumb's 95" % [id, r.size.x, r.size.y])
		_expect(PANEL.encloses(r), "%s stands outside the panel: %s" % [id, r])
		rects.append([id, r])
	for i in rects.size():
		for j in range(i + 1, rects.size()):
			var a: Rect2 = (rects[i] as Array)[1]
			var b: Rect2 = (rects[j] as Array)[1]
			_expect(not a.intersects(b), "%s and %s share pixels: one of them cannot be pressed"
				% [(rects[i] as Array)[0], (rects[j] as Array)[0]])


## The client works out no road: not the wages, not the rank's share, not the
## hours. Every figure on the page is the server's.
func _no_arithmetic() -> void:
	for f in ["res://scenes/pages/hunt_page.gd", "res://scenes/tabs/army.gd"]:
		var src := FileAccess.get_file_as_string(f)
		for word in ["tier_share", "spread_bp", "gold_wages *", "wages *"]:
			_expect(not src.contains(word), "%s works out %s itself" % [f, word])


func _soldier(slot: int, away: Variant) -> Dictionary:
	var s := {"id": "s%d" % slot, "name": "Mercenary", "type": "mercenary", "tier": "rare",
		"attack": 26, "defense": 22, "speed": 4, "hp": 168, "ehp": 210, "might": 132,
		"equipped": {}, "reroll_cost": 1200}
	if away is Dictionary:
		s["away"] = away
	return s


func _army(away_on_selected: Variant, back: bool = false) -> Dictionary:
	var slots: Array = []
	for i in 3:
		var away: Variant = null
		if i == 0:
			away = away_on_selected
		elif i == 1 and back:
			away = {"id": "e2", "field_id": "meadow", "field": "The Meadow", "ends_in": 0, "back": true}
		slots.append({"index": i + 1, "soldier": _soldier(i + 1, away)})
	return {"slots": slots, "hero": {"id": "h", "name": "Hero", "is_hero": true, "level": 30,
			"attack": 520, "defense": 520, "speed": 0, "hp": 2000, "ehp": 2400, "might": 2208,
			"equipped": {}},
		"totals": {"attack": 600, "ehp": 3000, "might": 3016, "units": 4},
		"field": {"attack": 560, "ehp": 2700, "might": 2800, "units": 3},
		"next_slot": null, "recruits": []}


func _army_states() -> void:
	var host := Control.new()
	host.size = Vector2(941, 1672)
	root.add_child(host)
	var tab: Control = (load("res://scenes/tabs/army.gd") as GDScript).new()
	host.add_child(tab)
	for i in 3:
		await process_frame

	for state in ["yard", "away", "back"]:
		var away: Variant = null
		if state == "away":
			away = {"id": "e1", "field_id": "wood", "field": "The King's Wood",
				"ends_in": 4740, "back": false}
		elif state == "back":
			away = {"id": "e1", "field_id": "wood", "field": "The King's Wood",
				"ends_in": 0, "back": true}
		tab.set("_army", _army(away))
		tab.call("_paint")
		await process_frame

		var ui: Dictionary = tab.get("_ui")
		var parts: Dictionary = (ui["hunt"] as Control).get_meta("parts")
		var word: String = (parts["label"] as Label).text
		var want: String = {"yard": "HUNT", "away": "AWAY", "back": "BACK"}[state]
		_expect(word == want, "%s: the plate says %s, not %s" % [state, word, want])
		_expect((parts["icon"] as CanvasItem).visible == (state == "yard"),
			"%s: the crosshair is %s" % [state, "shown" if (parts["icon"] as CanvasItem).visible else "hidden"])

		var line: Label = ui["sel_state"]
		if state == "yard":
			_expect(line.text == "IN THE YARD", "%s: the line reads %s" % [state, line.text])
		elif state == "away":
			_expect(line.text.contains("KING'S WOOD") and line.text.contains("1h"),
				"%s: the line reads %s" % [state, line.text])
		else:
			_expect(line.text == "AT THE GATE", "%s: the line reads %s" % [state, line.text])

		# The card's own ribbon.
		var cards: Array = tab.get("_cards")
		if not cards.is_empty():
			var card: Dictionary = cards[0]
			var ribbon: Label = card.get("ribbon")
			_expect(ribbon != null, "%s: the card has no ribbon at all" % state)
			if ribbon != null:
				_expect(ribbon.visible == (state != "yard"),
					"%s: the ribbon is %s" % [state, "shown" if ribbon.visible else "hidden"])
				if state != "yard":
					_expect(ribbon.text == ("BACK" if state == "back" else "AWAY"),
						"%s: the ribbon says %s" % [state, ribbon.text])
				var face: CanvasItem = card["parts"]["portrait"]
				_expect((face.modulate == Color.WHITE) == (state == "yard"),
					"%s: the portrait is %s" % [state, "lit" if face.modulate == Color.WHITE else "drawn back"])
	host.queue_free()
	await process_frame


func _roads(used: int, slots: int) -> Dictionary:
	var fields: Array = []
	var hours := [1, 2, 4, 8]
	for i in 4:
		fields.append({"id": "f%d" % i, "name": "The Field %d" % i, "blurb": "A road.",
			"hours": hours[i], "gold_low": 9 * (i + 1), "gold_high": 19 * (i + 1),
			"xp_low": 3 * (i + 1), "xp_high": 6 * (i + 1),
			"item_chance_bp": 200 * (i + 1), "item_tier": "common"})
	return {"unlocked": true, "unlock_level": 8, "slots": slots, "used": used,
		"next_slot_at": 20, "soldier_id": "s1", "soldier_tier": "rare",
		"fields": fields, "away": []}


func _roads_page() -> void:
	var host := Control.new()
	host.size = Vector2(941, 1672)
	root.add_child(host)
	await process_frame
	var HP: GDScript = load("res://scenes/pages/hunt_page.gd")
	# [roads walked, roads held, SEND lit, the hunt open]
	for c in [[0, 2, true, true], [2, 2, false, true], [0, 2, false, false]]:
		var open_hunt := bool(c[3])
		var view := _roads(int(c[0]), int(c[1]))
		view["unlocked"] = open_hunt
		var page: Control = HP.call("open", host, null,
			{"id": "s1", "name": "Mercenary", "tier": "rare", "type": "mercenary"}, view)
		await process_frame
		var tag := "%d of %d walked%s" % [c[0], c[1], "" if open_hunt else ", hunt shut"]

		var cards: Array = page.get_meta("cards", [])
		_expect(cards.size() == 4, "%s: the page lays out %d cards, not four" % [tag, cards.size()])

		var lit := 0
		for i in cards.size():
			var card: Control = cards[i]
			# The painting's own grid: 421 across, 526 down, off its gold.
			_expect(card.position == CARD_AT[i],
				"%s: card %d stands at %s, not the painting's %s" % [tag, i + 1, card.position, CARD_AT[i]])
			_expect(card.size == Vector2(410, 512),
				"%s: card %d is %s, not the painting's 410x512" % [tag, i + 1, card.size])
			var parts: Dictionary = card.get_meta("parts", {})
			for id in ["plate", "lit", "scene", "name", "time", "gold", "xp", "gear", "lock", "hit"]:
				_expect(parts.has(id), "%s: card %d has no %s" % [tag, i + 1, id])
			if parts.is_empty():
				continue
			if (parts["lit"] as CanvasItem).visible:
				lit += 1
			_expect((parts["lock"] as CanvasItem).visible != open_hunt,
				"%s: card %d's padlock is %s" % [tag, i + 1,
					"shown" if (parts["lock"] as CanvasItem).visible else "hidden"])
			_expect((card.modulate == Color.WHITE) == open_hunt,
				"%s: card %d is %s" % [tag, i + 1, "lit" if card.modulate == Color.WHITE else "dimmed"])
			# The server's own figures, on the painting's plates and inside them.
			var f: Dictionary = (view["fields"] as Array)[i]
			_expect((parts["name"] as Label).text.to_upper() == str(f["name"]).to_upper(),
				"%s: card %d is named %s, not %s" % [tag, i + 1, (parts["name"] as Label).text, f["name"]])
			var figures := {"gold": "%d - %d" % [f["gold_low"], f["gold_high"]],
				"xp": "%d - %d" % [f["xp_low"], f["xp_high"]],
				"gear": "%d in 100" % int(round(float(f["item_chance_bp"]) / 100.0))}
			for id in figures:
				_expect((parts[id] as Label).text == str(figures[id]),
					"%s: card %d's %s reads %s, not %s" % [tag, i + 1, id,
						(parts[id] as Label).text, figures[id]])
			_expect((parts["time"] as Label).text.contains("%dh" % int(f["hours"])),
				"%s: card %d's road takes %s, not %dh" % [tag, i + 1,
					(parts["time"] as Label).text, int(f["hours"])])
			for id in ["name", "time", "gold", "xp", "gear"]:
				var l: Label = parts[id]
				var box := Rect2(l.position, Vector2(l.get_minimum_size().x, l.size.y))
				_expect(Rect2(Vector2.ZERO, card.size).encloses(box),
					"%s: card %d's %s runs outside the card: %s" % [tag, i + 1, id, box])
		_expect(lit == (1 if open_hunt else 0),
			"%s: %d roads wear the glow, not %d" % [tag, lit, 1 if open_hunt else 0])

		var sends: Array = []
		var texts: Array = []
		_walk(page, sends, texts)
		_expect(sends.size() == 1, "%s: the page has %d SEND buttons, not one" % [tag, sends.size()])
		for b in sends:
			_expect((b as BaseButton).disabled != bool(c[2]),
				"%s: SEND is %s" % [tag, "dark" if (b as BaseButton).disabled else "lit"])
		var joined := " | ".join(texts)
		if open_hunt:
			_expect(joined.contains("%d of %d roads walked" % [c[0], c[1]]),
				"%s: the page does not say how many roads are walked: %s" % [tag, joined])
		else:
			_expect(joined.contains("open at level 8"),
				"%s: a shut hunt does not say when it opens: %s" % [tag, joined])

		# The tap moves the glow, and moves it alone.
		if open_hunt and cards.size() == 4:
			var third: Dictionary = (cards[2] as Control).get_meta("parts", {})
			(third["hit"] as BaseButton).pressed.emit()
			await process_frame
			var after: Array = page.get_meta("cards", [])
			var on := -1
			for i in after.size():
				if ((after[i] as Control).get_meta("parts", {})["lit"] as CanvasItem).visible:
					on = i
			# The page ignores taps for the quarter second after it opens, so
			# an un-armed page keeps the first road: either is right, one road.
			_expect(on == 2 or on == 0, "%s: the tap lit road %d" % [tag, on + 1])

		page.call("close")
		await process_frame
	host.queue_free()
	await process_frame


## Every button and every line under a node, so a page can be read without
## knowing how it was built.
func _walk(n: Node, buttons: Array, texts: Array) -> void:
	for c in n.get_children():
		if c is BaseButton and str(c.get_meta("action", "")) == "send":
			buttons.append(c)
		if c is Label and (c as Label).text != "":
			texts.append((c as Label).text)
		_walk(c, buttons, texts)
