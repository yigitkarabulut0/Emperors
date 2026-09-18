extends SceneTree
## A quest tile's reward stays inside its plate, in every state it can be in.
##
## The finished card said "CLAIM +396 XP" in a 30-point box that began a third
## of the way across a 241-unit card, and ran off its right edge; the gold the
## task also paid was never shown at all. The tile (collect_events.png's, since
## Wave 3) shows both rewards as a centred pair on its gold-rimmed plate, and
## says what state it is in on the progress plate instead.
##
## Run: godot --headless --path client --script tests/quest_cards.gd

var _fails := 0


func _initialize() -> void:
	await process_frame
	var host := Control.new()
	host.size = Vector2(941, 1672)
	root.add_child(host)
	var screen: Control = load("res://scenes/tabs/collect.gd").new()
	screen.size = Vector2(941, 1672)
	host.add_child(screen)
	for i in 3:
		await process_frame

	# The largest a daily pays at the level cap, and a good deal past it, so a
	# rebalance that doubles the rewards does not break the card either.
	var cases := [
		[{"id": "collect_20", "target": 20, "progress": 7, "xp": 240, "gold": 720, "done": false, "claimed": false},
		 {"id": "energy_300", "target": 300, "progress": 300, "xp": 720, "gold": 2160, "done": true, "claimed": false},
		 {"id": "win_3", "target": 3, "progress": 3, "xp": 720, "gold": 2160, "done": true, "claimed": true}],
		[{"id": "buy_3", "target": 3, "progress": 0, "xp": 99999, "gold": 9999999, "done": false, "claimed": false},
		 {"id": "collect_60", "target": 60, "progress": 60, "xp": 99999, "gold": 9999999, "done": true, "claimed": false},
		 {"id": "energy_150", "target": 150, "progress": 150, "xp": 99999, "gold": 9999999, "done": true, "claimed": true}],
	]
	for quests in cases:
		screen.set("_quests", quests)
		screen.call("_paint_tiles")
		for i in 2:
			await process_frame
		var cards: Array = screen.get("_quest_cards")
		for i in cards.size():
			_check_card(cards[i], quests[i])

	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  every quest tile keeps its rewards and its state inside its plates")
	quit()


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)


func _check_card(card: Dictionary, q: Dictionary) -> void:
	var node: Control = card["node"]
	var p: Dictionary = card["parts"]
	var tag := "%s (%s)" % [str(q["id"]), "claimed" if q["claimed"] else ("done" if q["done"] else "in progress")]
	var row: Control = p["reward_row"]
	var parts: Dictionary = row.get_meta("parts", {})
	var right_edge := row.position.x + row.size.x
	var last_end := -1.0
	for id in ["icon_a", "figure_a", "icon_b", "figure_b"]:
		var c: Control = parts[id]
		if not c.visible:
			_fail("%s: the %s is hidden" % [tag, id])
			continue
		var x0 := row.position.x + c.position.x
		var x1 := x0 + _drawn_width(c)
		if x0 < row.position.x - 0.5 or x1 > right_edge + 0.5:
			_fail("%s: the %s runs from x %.0f to %.0f on a plate %.0f..%.0f" % [tag, id, x0, x1, row.position.x, right_edge])
		if x0 < last_end - 0.5:
			_fail("%s: the %s starts at %.0f, under the %.0f the part before it reaches" % [tag, id, x0, last_end])
		last_end = x1
	var gold: Label = parts["figure_b"]
	if not gold.text.begins_with("+"):
		_fail("%s: the gold reads %s" % [tag, gold.text])
	var bar: Label = p["progress"]
	var bar_w := bar.label_settings.font.get_string_size(bar.text, HORIZONTAL_ALIGNMENT_LEFT, -1,
		bar.label_settings.font_size).x
	if bar_w > bar.size.x:
		_fail("%s: the bar's \"%s\" is %.0f wide in a %.0f bar" % [tag, bar.text, bar_w, bar.size.x])
	var want := "CLAIMED" if q["claimed"] else ("TAP TO CLAIM" if q["done"] else "%d / %d" % [q["progress"], q["target"]])
	if bar.text != want:
		_fail("%s: the bar says \"%s\", want \"%s\"" % [tag, bar.text, want])


## A Label is as wide as its text; an image is as wide as its rect.
func _drawn_width(c: Control) -> float:
	if c is Label:
		var l := c as Label
		return l.label_settings.font.get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1,
			l.label_settings.font_size).x
	return c.size.x
