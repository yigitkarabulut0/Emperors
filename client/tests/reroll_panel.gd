extends SceneTree
## The reroll panel fits the phone, takes a thumb, and never rolls in a pocket.
##
## AUTO ROLL runs one request at a time for as long as the player lets it. What
## must hold: every control can be pressed, the panel is on the screen at both
## canvases, a run stops the moment the game leaves the screen, and it will not
## start on a soldier that is already at the tier it would stop at.
##
## Run: godot --headless --path client --script tests/reroll_panel.gd

const PT_PER_UNIT := 440.0 / 941.0

var _fails := 0


func _initialize() -> void:
	await process_frame
	for canvas in [Vector2(941, 1672), Vector2(941, 2040)]:
		await _check(canvas)
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  the reroll panel fits, takes a thumb, and stops when the game leaves the screen")
	quit()


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)


func _odds() -> Array:
	var out: Array = []
	var bps := [870, 2648, 3580, 1997, 736, 149, 17]
	var ids := ["common", "uncommon", "rare", "epic", "legendary", "mystic", "special"]
	for i in 7:
		out.append({"tier": ids[i], "bp": bps[i]})
	return out


func _check(canvas: Vector2) -> void:
	var host := Control.new()
	host.size = canvas
	root.add_child(host)
	var soldier := {"id": "s1", "type": "gladiator", "tier": "rare", "attack": 844, "defense": 687,
		"ehp": 6950, "hp": 180, "equipped": {}, "reroll_cost": 20835}
	# Loaded at run time, not preloaded: the panel names autoloads (Nav, Art,
	# GameState) that do not exist yet while this script is being compiled, and a
	# preload that fails to compile leaves every call below failing quietly.
	var script: GDScript = load("res://scenes/army/reroll_panel.gd")
	var panel: Control = script.open(host, {"soldier": soldier, "odds": _odds(),
		"name": "GLADIATOR", "portrait": "portraits/soldier_gladiator"}) if script != null else null
	if panel == null:
		_fail("the reroll panel did not open")
		host.queue_free()
		return
	for i in 3:
		await process_frame
	var tag := "%dx%d" % [int(canvas.x), int(canvas.y)]
	var plate: Control = panel.get("_plate")
	var r := Rect2(plate.global_position, plate.size)
	if r.position.x < 0 or r.position.y < 0 or r.end.x > canvas.x or r.end.y > canvas.y:
		_fail("%s: the panel spans %s, off a %s canvas" % [tag, r, canvas])

	var buttons := 0
	var stack: Array = [plate]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if n is Button:
			buttons += 1
			var b := n as Button
			if b.size.y * PT_PER_UNIT < 44.0:
				_fail("%s: \"%s\" is %.0f pt tall, under the 44 a thumb needs" % [tag, b.text, b.size.y * PT_PER_UNIT])
			var br := Rect2(b.global_position, b.size)
			if not r.encloses(br):
				_fail("%s: \"%s\" hangs off the panel" % [tag, b.text])
	# Six STOP AT chips, ROLL ONCE, AUTO ROLL and CLOSE.
	if buttons != 9:
		_fail("%s: the panel has %d buttons, not 9" % [tag, buttons])
	if int(panel.get("_target")) != 4:
		_fail("%s: a tier III soldier should aim for IV by default, not %d" % [tag, int(panel.get("_target"))])

	# Already there: nothing to roll for.
	panel.call("_set_target", 3)
	panel.call("_toggle_auto")
	if bool(panel.get("_running")):
		_fail("%s: auto-roll started on a soldier already at the tier it would stop at" % tag)
	var status: Label = panel.get("_status")
	if not status.text.contains("already"):
		_fail("%s: refusing to start said \"%s\"" % [tag, status.text])

	# A run stops the moment the game leaves the screen.
	panel.call("_set_target", 6)
	panel.call("_start")
	if not bool(panel.get("_running")):
		_fail("%s: the run did not start" % tag)
	panel.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	if bool(panel.get("_running")):
		_fail("%s: the run kept going after the game went to the background" % tag)
	if not status.text.contains("Paused"):
		_fail("%s: stopping for the background said \"%s\"" % [tag, status.text])
	panel.call("_start")
	panel.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	if bool(panel.get("_running")):
		_fail("%s: the run kept going after the game lost focus" % tag)

	var closed := [false]
	panel.closed.connect(func() -> void: closed[0] = true)
	panel.call("_close")
	if not closed[0]:
		_fail("%s: closing did not tell the Army screen" % tag)
	host.queue_free()
	for i in 2:
		await process_frame
