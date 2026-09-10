extends SceneTree
## The Attack page's two tabs say different things, and each says something.
##
## REVENGE lists every score waiting to be settled -- as many cards as there are
## raiders -- then the other targets; TARGETS lists the targets alone. Either
## one with nothing in it says so. What must hold, at both canvases: the
## cards flow top to bottom without overlapping, the history and the notice
## follow the last card rather than a painted position, a revenge card prints
## the revenge rate the server sent, and nothing is drawn before the server
## has answered.
##
## Run: godot --headless --path client --script tests/attack_views.gd

var _fails := 0


func _initialize() -> void:
	await process_frame
	for canvas in [Vector2(941, 1672), Vector2(941, 2040)]:
		await _check(canvas)
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  the Attack tabs differ, flow, and say when they are empty")
	quit()


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)


func _target(i: int) -> Dictionary:
	return {"player_id": "t%d" % i, "name": "Target %d" % i, "avatar": ["king", "queen", "knight"][i % 3],
		"level": 30 + i, "might": 3000 + i, "estimated_steal": 1200 + i, "steal_rate_bp": 300, "energy_cost": 11}


func _revenge(i: int) -> Dictionary:
	return {"battle_id": "b%d" % i, "player_id": "r%d" % i, "name": "Raider %d" % i, "avatar": "witch",
		"level": 31, "might": 2980, "estimated_steal": 1600, "steal_rate_bp": 400, "energy_cost": 5,
		"expires_at": "2026-09-11T12:00:00Z", "expires_in": 5400}


func _shown(n: Control) -> bool:
	return n.is_visible_in_tree()


func _check(canvas: Vector2) -> void:
	var tag := "%dx%d" % [int(canvas.x), int(canvas.y)]
	var host := Control.new()
	host.size = canvas
	root.add_child(host)
	var script: GDScript = load("res://scenes/tabs/attack.gd")
	var tab: Control = script.new()
	tab.size = canvas
	host.add_child(tab)
	await process_frame

	# Before the server answers: no card, no history, no notice.
	for c in tab.get("_targets"):
		if _shown(c["node"]):
			_fail("%s: a target card is drawn before the server answered" % tag)
	if _shown(tab.get("_history_panel")):
		_fail("%s: the history panel is drawn before the server answered" % tag)

	tab.set("_data", {"might": 3100, "energy_cost": 11,
		"revenge": [_revenge(0), _revenge(1)], "targets": [_target(0), _target(1), _target(2)]})
	tab.set("_history", [])
	tab.set("_loaded", true)
	tab.call("_paint")
	await process_frame

	# REVENGE: two scores, then the divider and the three targets.
	var cards: Array = tab.get("_revenge_cards")
	var shown := 0
	for c in cards:
		if _shown(c["node"]):
			shown += 1
	if shown != 2:
		_fail("%s: two raiders, %d revenge cards" % [tag, shown])
	if cards.size() >= 2:
		var rate: Label = cards[1]["rate"]
		if rate.text != "Steal up to 4% gold":
			_fail("%s: the second revenge card says \"%s\"" % [tag, rate.text])
		if str(cards[1]["parts"]["name"].text) != "Raider 1":
			_fail("%s: the second revenge card names \"%s\"" % [tag, cards[1]["parts"]["name"].text])
	_flows(tab, tag + " revenge")
	var hist: Label = tab.get("_history_empty")
	if not _shown(hist) or hist.text == "":
		_fail("%s: an empty history says nothing" % tag)

	# TARGETS: the targets alone.
	tab.call("_set_view", "targets")
	await process_frame
	for c in tab.get("_revenge_cards"):
		if _shown(c["node"]):
			_fail("%s: a revenge card shows on TARGETS" % tag)
	if _shown(tab.get("_ui")["divider_targets"]):
		_fail("%s: OTHER TARGETS shows on TARGETS" % tag)
	_flows(tab, tag + " targets")

	# Nobody to avenge, nobody to raid.
	tab.set("_data", {"might": 3100, "energy_cost": 11, "revenge": [], "targets": []})
	tab.call("_set_view", "revenge")
	await process_frame
	var empty: Control = tab.get("_empty")
	if not _shown(empty) or str(tab.get("_empty_title").text) == "":
		_fail("%s: REVENGE with no raiders says nothing" % tag)
	tab.call("_set_view", "targets")
	await process_frame
	if not _shown(empty) or str(tab.get("_empty_title").text) != "NO RIVALS IN REACH":
		_fail("%s: TARGETS with no rivals says \"%s\"" % [tag, str(tab.get("_empty_title").text)])
	_flows(tab, tag + " empty")

	host.queue_free()
	await process_frame


## Everything drawn on the page, top to bottom, with no two overlapping and the
## page tall enough to scroll to the last of them.
func _flows(tab: Control, tag: String) -> void:
	var boxes: Array = []
	var ui: Dictionary = tab.get("_ui")
	for c in tab.get("_revenge_cards") + tab.get("_targets"):
		if _shown(c["node"]):
			boxes.append([c["parts"]["name"].text, Rect2(c["node"].position, c["node"].size)])
	for pair in [["empty", tab.get("_empty")], ["divider", ui["divider_targets"]],
			["history", tab.get("_history_panel")], ["notice", ui["notice_bar"]]]:
		var n: Control = pair[1]
		if _shown(n):
			boxes.append([pair[0], Rect2(n.position, n.size)])
	boxes.sort_custom(func(a, b): return a[1].position.y < b[1].position.y)
	for i in range(1, boxes.size()):
		var prev: Rect2 = boxes[i - 1][1]
		var cur: Rect2 = boxes[i][1]
		if cur.position.y < prev.end.y - 1.0:
			_fail("%s: %s overlaps %s" % [tag, boxes[i][0], boxes[i - 1][0]])
	if boxes.is_empty() or str(boxes[boxes.size() - 1][0]) != "notice":
		_fail("%s: the notice is not last" % tag)
		return
	var content: Control = tab.get("_content")
	var last: Rect2 = boxes[boxes.size() - 1][1]
	if content.custom_minimum_size.y < last.end.y:
		_fail("%s: the page is %.0f tall, the notice ends at %.0f" % [tag, content.custom_minimum_size.y, last.end.y])
	var hist: Rect2 = Rect2(tab.get("_history_panel").position, tab.get("_history_panel").size)
	for b in boxes:
		if b[0] != "history" and b[0] != "notice" and b[1].end.y > hist.position.y:
			_fail("%s: %s ends below the history" % [tag, b[0]])
	# The history follows the cards, not a painted position: no hole above it.
	var above := 0.0
	for b in boxes:
		if b[0] != "history" and b[0] != "notice":
			above = maxf(above, b[1].end.y)
	if hist.position.y - above > 40.0:
		_fail("%s: a %.0f-unit hole above the history" % [tag, hist.position.y - above])
