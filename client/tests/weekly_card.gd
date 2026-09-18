extends SceneTree
## Collect's quests are a pager of two pages on collect_events.png's panel:
## TODAY'S QUESTS and THIS WEEK'S QUESTS, the lit dot saying which, and under
## the panel the week's chest bar.
##
## Before Wave 3 the tab had only today's three cards (collect.png): no week,
## no dots, no chests. This holds what the painting asks of the new panel --
## the week's page shows the three tasks that most need the lord (one to claim
## first, the claimed last) with what each asks on the name plate and what it
## pays on the gold plate, all inside the tile at late-game figures; the dots
## follow the page; the week's dot counts what waits; the fill reaches each
## painted marker exactly as the points reach its chest; and each chest's plate
## says what it needs, OPEN, or OPENED.
##
## Run: godot --headless --path client --script tests/weekly_card.gd

var _fails := 0


func _week(points: int, claimed_tier: int) -> Dictionary:
	var tasks := [
		{"slot": 0, "id": "w_days", "name": "Faithful Attendance", "short": "Claim 5 daily rewards", "icon": "quest_scroll",
		 "target": 5, "progress": 5, "done": true, "claimed": true, "points": 40,
		 "lines": [{"kind": "diamonds", "amount": 15, "text": "15 diamonds", "icon": "diamond"}]},
		{"slot": 1, "id": "w_dailies", "name": "Duty Done", "short": "Finish 12 daily quests", "icon": "quest_scroll",
		 "target": 12, "progress": 7, "done": false, "claimed": false, "points": 40,
		 "lines": [{"kind": "diamonds", "amount": 15, "text": "15 diamonds", "icon": "diamond"}]},
		{"slot": 2, "id": "w_collect_big", "name": "The Busy Week", "short": "Collect 1,500 times", "icon": "quest_bolt",
		 "target": 1500, "progress": 1500, "done": true, "claimed": false, "points": 40,
		 "lines": [{"kind": "gold", "amount": 9999999, "text": "9,999,999 gold", "icon": "gold"}]},
		{"slot": 3, "id": "w_rerolls", "name": "Drill Sergeant", "short": "Reroll soldiers 5 times", "icon": "quest_swords",
		 "target": 5, "progress": 1, "done": false, "claimed": false, "points": 40,
		 "lines": [{"kind": "item", "id": "rare", "amount": 1, "text": "Rare gear", "icon": "item:rare", "tier": "rare"}]},
		{"slot": 4, "id": "w_raids", "name": "Raider", "short": "Win 10 raids", "icon": "quest_swords",
		 "target": 10, "progress": 0, "done": false, "claimed": false, "points": 40,
		 "lines": [{"kind": "gold", "amount": 1234567, "text": "1,234,567 gold", "icon": "gold"}]},
		{"slot": 5, "id": "w_carts", "name": "The Cart Returns", "short": "Open 8 Tax Carts", "icon": "quest_scroll",
		 "target": 8, "progress": 8, "done": true, "claimed": true, "points": 40,
		 "lines": [{"kind": "token", "id": "cart", "amount": 2, "text": "2 Cart Writs", "icon": "cart"}]},
	]
	var chests := []
	for t in 3:
		var at: int = [80, 160, 240][t]
		chests.append({"tier": t, "at": at, "ready": points >= at, "claimed": t <= claimed_tier,
			"lines": [{"kind": "diamonds", "amount": 20, "text": "20 diamonds", "icon": "diamond"}]})
	return {"week": "2026-09-14", "ends_in": 345600, "points": points, "points_max": 240, "tasks": tasks, "chests": chests}


func _initialize() -> void:
	await process_frame
	var host := Control.new()
	host.size = Vector2(941, 1672)
	root.add_child(host)
	root.get_node("GameState").set("badges", {"quests": 0, "weekly": 3})
	var screen: Control = (load("res://scenes/tabs/collect.gd") as GDScript).new()
	screen.size = Vector2(941, 1672)
	host.add_child(screen)
	for i in 3:
		await process_frame
	var ui: Dictionary = screen.get("_ui")
	for id in ["quests_title", "page_dot_0", "page_dot_1", "week_bar", "quests_touch"]:
		if not ui.has(id):
			_fail("the Collect tab has no %s: it is still collect.png's single page" % id)
	if _fails > 0:
		_done()
		return

	# Today's page: the day's three, in their words.
	screen.set("_quests", [
		{"slot": 0, "id": "collect_20", "target": 20, "progress": 7, "xp": 240, "gold": 720, "done": false, "claimed": false},
		{"slot": 1, "id": "energy_300", "target": 300, "progress": 300, "xp": 99999, "gold": 9999999, "done": true, "claimed": false},
		{"slot": 2, "id": "win_3", "target": 3, "progress": 3, "xp": 720, "gold": 2160, "done": true, "claimed": true}])
	screen.call("set_weekly", _week(170, 0))
	await process_frame
	var cards: Array = screen.get("_quest_cards")
	_expect((ui["quests_title"] as Label).text == "TODAY'S QUESTS", "today's page is titled %s" % (ui["quests_title"] as Label).text)
	_expect((cards[0]["parts"]["title"] as Label).text == "Collect 20 times", "today's first tile says %s" % (cards[0]["parts"]["title"] as Label).text)
	_expect(_dot(ui, 0) == "collect/page_dot_on" and _dot(ui, 1) == "collect/page_dot_off", "today's page lights the second dot")
	for i in cards.size():
		_inside(cards[i], "today %d" % i)

	# The week's page: one to claim first, the open ones, the claimed last.
	screen.call("turn_page", 1, false)
	await process_frame
	_expect((ui["quests_title"] as Label).text == "THIS WEEK'S QUESTS", "the week's page is titled %s" % (ui["quests_title"] as Label).text)
	_expect(_dot(ui, 1) == "collect/page_dot_on" and _dot(ui, 0) == "collect/page_dot_off", "the week's page lights the first dot")
	var shown: Array = screen.get("_shown")
	var slots := []
	for q in shown:
		slots.append(int(q["slot"]))
	_expect(slots == [2, 1, 3], "the week's tiles show slots %s, want [2, 1, 3] (to claim, then open, in order)" % str(slots))
	_expect((cards[0]["parts"]["title"] as Label).text == "Collect 1,500 times", "a week's tile says %s, not its short line" % (cards[0]["parts"]["title"] as Label).text)
	_expect((cards[0]["parts"]["progress"] as Label).text == "TAP TO CLAIM", "a finished week's task says %s" % (cards[0]["parts"]["progress"] as Label).text)
	_expect((cards[1]["parts"]["progress"] as Label).text == "7 / 12", "an open week's task says %s" % (cards[1]["parts"]["progress"] as Label).text)
	for i in cards.size():
		_inside(cards[i], "week %d" % i)
	var more: Control = ui["quests_more"]
	var title: Label = ui["quests_title"]
	_expect(more.visible and more.position.x > title.position.x + 200.0, "the week's heading has no chevron after it")

	# What waits in the week, on its dot: the one task to claim and the silver chest.
	var bubble: TextureRect = screen.get("_dot_bubble")
	_expect(bubble != null and bubble.visible and (bubble.get_meta("count") as Label).text == "2",
		"the week's dot counts %s waiting, want 2" % ((bubble.get_meta("count") as Label).text if bubble != null else "nothing"))

	# The fill stops on each painted marker as the points reach its chest.
	var bar: Dictionary = (ui["week_bar"] as Control).get_meta("parts")
	var fill: Control = bar["fill"]
	var full: float = float((fill.get_meta("full") as Vector2).x)
	var collect: GDScript = load("res://scenes/tabs/collect.gd")
	var chests: Array = _week(0, -1)["chests"]
	for i in 3:
		var m: Control = bar[collect.CHEST_MARKERS[i]]
		var want := m.position.x + m.size.x / 2.0
		var at: int = int(chests[i]["at"])
		var got := fill.position.x + full * float(collect.bar_fraction(bar, chests, at, 240))
		if i < 2:
			_expect(absf(got - want) < 0.5, "at %d points the fill ends at %.1f, not on its marker at %.1f" % [at, got, want])
	_expect(is_equal_approx(collect.bar_fraction(bar, chests, 240, 240), 1.0), "a finished week's bar is not full")
	_expect(collect.bar_fraction(bar, chests, 0, 240) == 0.0, "an empty week's bar is not empty")
	var half := fill.position.x + full * float(collect.bar_fraction(bar, chests, 40, 240))
	var m0: Control = bar[collect.CHEST_MARKERS[0]]
	_expect(absf(half - (fill.position.x + (m0.position.x + m0.size.x / 2.0 - fill.position.x) / 2.0)) < 0.5,
		"at 40 of 80 the fill is not halfway to the first marker")

	# Each chest's plate.
	var words := []
	for i in 3:
		words.append((bar[collect.CHEST_NEEDS[i]] as Label).text)
	_expect(words == ["OPENED", "OPEN", "240 POINTS"], "the chests' plates say %s" % str(words))
	for i in 3:
		var need: Label = bar[collect.CHEST_NEEDS[i]]
		var w := need.label_settings.font.get_string_size(need.text, HORIZONTAL_ALIGNMENT_LEFT, -1, need.label_settings.font_size).x
		var plate: Control = bar[collect.CHEST_PLATES[i]]
		_expect(w <= plate.size.x - 10.0, "the plate's \"%s\" is %.0f wide on a %.0f plate" % [need.text, w, plate.size.x])

	# A week with nothing done yet: no bubble.
	var quiet := _week(0, -1)
	for t in quiet["tasks"]:
		if not bool(t["claimed"]):
			t["done"] = false
	screen.call("set_weekly", quiet)
	root.get_node("GameState").set("badges", {})
	screen.call("_paint_dots")
	_expect(not bubble.visible, "a week with nothing waiting shows a bubble")
	_done()


func _dot(ui: Dictionary, i: int) -> String:
	var t: Texture2D = (ui["page_dot_%d" % i] as TextureRect).texture
	return t.resource_path.get_file().get_basename().insert(0, "collect/") if t != null else ""


## Every word and mark on a tile stays inside the tile, and the pair on the
## reward plate stays inside the plate's row.
func _inside(card: Dictionary, tag: String) -> void:
	var node: Control = card["node"]
	if not node.visible:
		return
	var p: Dictionary = card["parts"]
	var title: Label = p["title"]
	var tw := title.label_settings.font.get_string_size(title.text, HORIZONTAL_ALIGNMENT_LEFT, -1, title.label_settings.font_size).x
	if tw > float(title.get_meta("box_w", title.size.x)) + 0.5 and title.text_overrun_behavior == TextServer.OVERRUN_NO_TRIMMING:
		_fail("%s: \"%s\" runs past its plate" % [tag, title.text])
	var row: Control = p["reward_row"]
	var parts: Dictionary = row.get_meta("parts", {})
	for id in ["icon_a", "figure_a", "icon_b", "figure_b"]:
		var c: Control = parts[id]
		if not c.visible:
			continue
		var w := c.size.x
		if c is Label:
			var l := c as Label
			w = l.label_settings.font.get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, l.label_settings.font_size).x
		if c.position.x < -0.5 or c.position.x + w > row.size.x + 0.5:
			_fail("%s: the reward's %s runs from %.0f to %.0f in a %.0f row" % [tag, id, c.position.x, c.position.x + w, row.size.x])
	var bar: Label = p["progress"]
	var bw := bar.label_settings.font.get_string_size(bar.text, HORIZONTAL_ALIGNMENT_LEFT, -1, bar.label_settings.font_size).x
	if bw > bar.size.x + 0.5:
		_fail("%s: the progress \"%s\" is %.0f wide on a %.0f plate" % [tag, bar.text, bw, bar.size.x])


func _expect(ok: bool, msg: String) -> void:
	if not ok:
		_fail(msg)


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)


func _done() -> void:
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  the quests pager shows today's and the week's on the painted panel, and the chest bar reads the week")
	quit()
