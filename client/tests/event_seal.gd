extends SceneTree
## The hourglass seal at the rail's foot says when the realm's event ends, or
## when the next one starts; with neither it is dimmed and its plate empty; a
## tap on it opens the COURT with its Events page over it (Wave 4's
## events_view.gd, which lists the operator's events under UPCOMING).
##
## snapshot.live is read through LiveEvents and counted down on the client
## from the snapshot's moment: an event running beside one announced shows the
## running one's end; the announced one alone shows its start ("in 5h 00m");
## the page's UPCOMING rows show both, each with what it gives, what it is
## worth to this lord (the server's effective_bp) and its time.
##
## Run: godot --headless --path client --script tests/event_seal.gd

const RUNNING := {"bucket": "collect_income_bp", "bp": 5000, "effective_bp": 7000, "ends_in": 12000}
const COMING := {"bucket": "xp_bp", "bp": 2500, "effective_bp": 2500, "starts_in": 18000, "ends_in": 25200}

var _fails := 0


func _initialize() -> void:
	await process_frame
	var gs := root.get_node("GameState")
	var parent := Control.new()
	parent.size = Vector2(941, 2040)
	root.add_child(parent)
	var shell: Control = (load("res://scenes/shell/shell.tscn") as PackedScene).instantiate()
	parent.add_child(shell)
	shell.set_anchors_preset(Control.PRESET_FULL_RECT)
	for i in 3:
		await process_frame
	shell.call("apply_inset", 141.0)
	await process_frame
	var seal: TextureRect = shell.get("_seal")
	var time: Label = shell.get("_seal_time")
	if seal == null or time == null:
		_fail("the rail has no event seal")
		_done()
		return
	_expect(seal.texture != null and seal.texture.resource_path.ends_with("chrome/rail_seal.png"), "the seal is not court.png's")
	var plate: TextureRect = shell.get("_seal_plate")
	_expect(plate != null and plate.texture.resource_path.ends_with("chrome/rail_seal_plate.png"), "the seal has no plate")
	var rail: Control = shell.get("_rail")
	# The time is written on the plate's inside.
	var tr := Rect2(time.position, Vector2(float(time.get_meta("box_w", time.size.x)), time.size.y))
	_expect(Rect2(plate.position, plate.size).encloses(tr), "the seal's time is not on its plate")

	# Nothing running, nothing announced.
	_live(gs, {})
	shell.call("_paint_seal")
	_expect(time.text == "" and seal.modulate.r < 0.6, "with no event the seal says \"%s\" and is %s" % [
		time.text, "lit" if seal.modulate.r >= 0.6 else "dimmed"])
	# One running beside one announced: the running one's end.
	_live(gs, {"boosts": [RUNNING], "upcoming": [COMING]})
	var age := int(gs.call("live_age_s"))
	shell.call("_paint_seal")
	var ui: GDScript = load("res://scripts/ui/ui.gd")
	var want := str(ui.call("time_left", 12000 - age))
	_expect(time.text == want and seal.modulate == Color.WHITE, "running: the seal says \"%s\", not \"%s\"" % [time.text, want])
	_expect(time.text == "3h 20m", "running: \"%s\" -- the snapshot is %ds old" % [time.text, age])
	# Only the announced one: its start.
	_live(gs, {"upcoming": [COMING]})
	shell.call("_paint_seal")
	_expect(time.text == "in 5h 00m" and seal.modulate == Color.WHITE, "announced: the seal says \"%s\"" % time.text)
	# Counted down from the snapshot, not frozen at it.
	gs.set("_energy_at_ms", Time.get_ticks_msec() - 3600 * 1000)
	shell.call("_paint_seal")
	_expect(time.text == "in 4h 00m", "an hour on, the seal still says \"%s\"" % time.text)

	# A tap: the COURT, with its list of events over it.
	_live(gs, {"boosts": [RUNNING], "upcoming": [COMING]})
	shell.call("open", "collect")
	await process_frame
	var hit: BaseButton = shell.get("_seal_hit")
	_expect(Rect2(hit.position, hit.size).encloses(Rect2(seal.position, seal.size)), "the seal's tap does not cover it")
	_expect(hit.position.y + hit.size.y <= rail.size.y, "the seal's tap runs off the screen")
	hit.pressed.emit()
	await process_frame
	_expect(str(shell.call("current_tab")) == "court", "the seal opened %s, not the COURT" % shell.call("current_tab"))
	var panel := _panel()
	_expect(panel != null, "the seal opened no list of events")
	if panel != null:
		var words: Array = []
		var stack: Array = [panel]
		while not stack.is_empty():
			var n: Node = stack.pop_back()
			for c in n.get_children():
				stack.append(c)
			if n is Label and (n as Label).text != "":
				words.append((n as Label).text)
		for w in ["Job payout +50%", "+70% for you", "Experience +25%", "+25% for you", "3h 20m", "in 5h 00m"]:
			_expect(words.has(w), "the list of events does not say \"%s\" (it says %s)" % [w, words])
		# Its rows are events.png's, on the panel, on the screen.
		var rows := 0
		stack = [panel]
		while not stack.is_empty():
			var n: Node = stack.pop_back()
			for c in n.get_children():
				stack.append(c)
			if n is TextureRect and (n as TextureRect).texture != null \
					and (n as TextureRect).texture.resource_path.ends_with("court/event_row.png") \
					and (n as Control).is_visible_in_tree():
				rows += 1
				var g := (n as Control).get_global_rect()
				_expect(g.position.y >= 141.0 and g.end.y <= 2040.0 and g.position.x >= 0.0 and g.end.x <= 941.0,
					"a row of the list runs off the screen: %s" % g)
		# The painting's three rows always stand; two of them carry the events.
		_expect(rows == 3, "UPCOMING shows %d of the painting's three rows" % rows)
		var spoken := 0
		stack = [panel]
		while not stack.is_empty():
			var n: Node = stack.pop_back()
			for c in n.get_children():
				stack.append(c)
			if n is Label and (n as Label).name.begins_with("what") and (n as Label).text != "":
				spoken += 1
		_expect(spoken <= 2, "UPCOMING speaks on %d rows for one running event and one announced" % spoken)
	parent.queue_free()
	await process_frame
	_done()


func _live(gs: Node, live: Dictionary) -> void:
	var snap: Dictionary = {"player": {"username": "Wwwwwwwwwwwwwwww", "level": 30, "gold": "1", "diamonds": 12,
		"action_seq": 1}, "energy": {"current": 1, "max": 2}, "sections": [], "live": live}
	gs.set("snapshot", snap)
	gs.set("_energy_at_ms", Time.get_ticks_msec())


## The Events page, wherever the shell hosts it.
func _panel() -> Node:
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if n.get_script() != null and (n.get_script() as Script).resource_path.ends_with("events_view.gd"):
			return n
	return null


func _done() -> void:
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  the seal counts the running event down, else the next one's start, dims with neither, and opens the list")
	quit()


func _expect(ok: bool, why: String) -> void:
	if not ok:
		_fail(why)


func _fail(why: String) -> void:
	_fails += 1
	printerr("  ", why)
