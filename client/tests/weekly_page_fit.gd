extends SceneTree
## THIS WEEK'S QUESTS, the whole week: six painted tiles three to a row, each
## under its name, and the chest bar with what every chest holds -- all of it
## inside the page, on the short canvas and the tall, at the longest names and
## the largest figures the week can carry.
##
## Before Wave 3 there was no week and no page for it (the tab's heading had
## nothing to open).
##
## Run: godot --headless --path client --script tests/weekly_page_fit.gd

var _fails := 0


func _week() -> Dictionary:
	var tasks := []
	var names := ["Faithful Attendance", "Duty Done", "The Busy Week", "The Cart Returns", "Drill Sergeant", "Vengeance Is Mine"]
	var shorts := ["Claim 5 daily rewards", "Finish 12 daily quests", "Collect 1,500 times", "Open 8 Tax Carts",
		"Reroll soldiers 5 times", "Win 2 revenge strikes"]
	var lines := [
		[{"kind": "diamonds", "amount": 15, "text": "15 diamonds", "icon": "diamond"}],
		[{"kind": "diamonds", "amount": 15, "text": "15 diamonds", "icon": "diamond"}],
		[{"kind": "gold", "amount": 9999999, "text": "9,999,999 gold", "icon": "gold"}],
		[{"kind": "token", "id": "cart", "amount": 2, "text": "2 Cart Writs", "icon": "cart"}],
		[{"kind": "item", "id": "rare", "amount": 1, "text": "Rare gear", "icon": "item:rare", "tier": "rare"}],
		[{"kind": "token", "id": "flask_large", "amount": 1, "text": "Great Flask", "icon": "flask_large"}]]
	for i in 6:
		tasks.append({"slot": i, "id": "w_%d" % i, "name": names[i], "short": shorts[i],
			"icon": ["quest_scroll", "quest_scroll", "quest_bolt", "quest_scroll", "quest_swords", "quest_swords"][i],
			"target": [5, 12, 1500, 8, 5, 2][i], "progress": [5, 12, 700, 8, 0, 2][i],
			"done": i in [0, 1, 3, 5], "claimed": i in [0, 3], "points": 40, "lines": lines[i]})
	var chests := [
		{"tier": 0, "at": 80, "ready": true, "claimed": true, "lines": [
			{"kind": "gold", "amount": 1234567, "text": "1,234,567 gold", "icon": "gold"},
			{"kind": "token", "id": "flask_small", "amount": 1, "text": "Small Flask", "icon": "flask_small"}]},
		{"tier": 1, "at": 160, "ready": true, "claimed": false, "lines": [
			{"kind": "token", "id": "cart", "amount": 2, "text": "2 Cart Writs", "icon": "cart"},
			{"kind": "token", "id": "flask_large", "amount": 1, "text": "Great Flask", "icon": "flask_large"}]},
		{"tier": 2, "at": 240, "ready": false, "claimed": false, "lines": [
			{"kind": "diamonds", "amount": 20, "text": "20 diamonds", "icon": "diamond"},
			{"kind": "item", "id": "rare", "amount": 1, "text": "Rare gear", "icon": "item:rare", "tier": "rare"},
			{"kind": "token", "id": "energy_potion", "amount": 1, "text": "Energy Potion", "icon": "energy_potion"}]}]
	return {"week": "2026-09-14", "ends_in": 345600, "points": 200, "points_max": 240, "tasks": tasks, "chests": chests}


func _initialize() -> void:
	await process_frame
	for canvas in [Vector2i(941, 1672), Vector2i(941, 2040)]:
		await _canvas(canvas)
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  the whole week fits its page: six tiles, the chests and what they hold")
	quit()


func _canvas(canvas: Vector2i) -> void:
	var vp := SubViewport.new()
	vp.size = canvas
	root.add_child(vp)
	root.get_node("Nav").set("host", vp)
	var tag := "%dx%d" % [canvas.x, canvas.y]
	var script: GDScript = load("res://scenes/pages/weekly_page.gd")
	if script == null:
		_fail("%s: there is no weekly page" % tag)
		vp.queue_free()
		return
	var host := Control.new()
	host.size = Vector2(canvas)
	vp.add_child(host)
	var s: Control = script.open(host, _week(), null)
	for i in 3:
		await process_frame
	var body: VBoxContainer = s.get("body")
	var inner_w: float = float(s.get("inner_w"))
	var tasks: Control = body.get_node_or_null("Tasks")
	var chests: Control = body.get_node_or_null("Chests")
	if tasks == null or chests == null:
		_fail("%s: the page has no tasks or no chests" % tag)
		vp.queue_free()
		return
	var tiles := 0
	for c in tasks.get_children():
		var n := c as Control
		if n == null or not n.visible:
			continue
		if n.name.begins_with("Tile"):
			tiles += 1
		if n.position.x < -0.5 or n.position.x + n.size.x > inner_w + 0.5:
			_fail("%s: %s runs %.0f..%.0f past the page's %.0f" % [tag, n.name, n.position.x, n.position.x + n.size.x, inner_w])
		if n is Label:
			_fits(n as Label, tag)
		for part in n.find_children("*", "Label", true, false):
			_fits(part as Label, tag)
	_expect(tiles == 6, "%s: the page shows %d tiles, not six" % [tag, tiles])
	for c in chests.find_children("*", "Label", true, false):
		var l := c as Label
		_fits(l, tag)
		var gx := l.get_global_rect().position.x - chests.get_global_rect().position.x
		if gx < -0.5 or gx + l.size.x > inner_w + 0.5:
			_fail("%s: the chest words \"%s\" run past the page" % [tag, l.text])
	# Everything above the foot: the body holds it without leaving the plate.
	var scroll := body.get_parent() as ScrollContainer
	var content_h := body.get_combined_minimum_size().y
	if canvas.y >= 1672:
		_expect(content_h <= scroll.size.y + 0.5, "%s: the week needs %.0f of a %.0f page" % [tag, content_h, scroll.size.y])
	var line: Label = body.get_node_or_null("WeekLine")
	_expect(line != null and line.text.begins_with("Ends in 4d 00h") and line.text.ends_with("200 of 240 points"),
		"%s: the week's line reads \"%s\"" % [tag, line.text if line != null else ""])
	s.call("close")
	await process_frame
	vp.queue_free()
	await process_frame


## A one-line label's words stay inside its box (a fitted line may shrink or
## end in an ellipsis, never run on).
func _fits(l: Label, tag: String) -> void:
	if l.text == "" or not l.visible or l.autowrap_mode != TextServer.AUTOWRAP_OFF:
		return
	var w := l.label_settings.font.get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, l.label_settings.font_size).x
	var box := float(l.get_meta("box_w", l.size.x))
	if w > box + 0.5 and l.text_overrun_behavior == TextServer.OVERRUN_NO_TRIMMING:
		_fail("%s: \"%s\" is %.0f wide in a %.0f box" % [tag, l.text, w, box])


func _expect(ok: bool, msg: String) -> void:
	if not ok:
		_fail(msg)


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)
