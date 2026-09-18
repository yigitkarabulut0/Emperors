extends SceneTree
## The diamond pill opens the Royal Store.
##
## Diamonds are sold now, and the pill with the "+" is where a player looks for
## more. It opened the daily calendar, which is still what it opens while the
## day's reward waits (the dot on the pill promises it): the dot always leads to
## what it says, and otherwise the "+" leads to the store.
##
## Run: godot --headless --path client --script tests/diamond_pill_store.gd

var _fails := 0


func _initialize() -> void:
	await process_frame
	var gs: Node = root.get_node("GameState")
	gs.set("snapshot", {"player": {"username": "Wwwwwwwwwwwwwwww", "level": 30, "gold": "1", "diamonds": 12,
		"action_seq": 1}, "energy": {"current": 1, "max": 2}, "sections": []})
	var parent := Control.new()
	parent.size = Vector2(941, 1672)
	root.add_child(parent)
	var shell: Control = (load("res://scenes/shell/shell.tscn") as PackedScene).instantiate()
	parent.add_child(shell)
	shell.set_anchors_preset(Control.PRESET_FULL_RECT)
	for i in 4:
		await process_frame

	var pill := _pill(shell)
	if pill == null:
		print("FAIL  the diamond pill has no tap target")
		quit(1)
		return

	# Nothing waits: the "+" opens the Royal Store.
	gs.call("set_badges", {"daily": false})
	pill.pressed.emit()
	for i in 3:
		await process_frame
	var view: Control = shell.get("_view")
	_expect(view != null, "the diamond pill opened no Court view")
	if view != null:
		var path := (view.get_script() as Script).resource_path
		_expect(path.ends_with("store_view.gd"), "the diamond pill opened %s, not the Royal Store" % path)
	shell.call("close_view")
	await process_frame

	# The day's reward waits: the pill's dot leads to the calendar, not the store.
	gs.call("set_badges", {"daily": true})
	pill.pressed.emit()
	for i in 3:
		await process_frame
	_expect(shell.get("_view") == null, "with the day's reward waiting, the pill opened the store over it")

	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  the diamond pill opens the Royal Store, and the calendar while its reward waits")
	quit()


## The invisible tap target over the diamond pill: the one whose box covers it.
func _pill(shell: Node) -> BaseButton:
	var stack: Array = [shell]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if n is Button and (n as Button).flat:
			var b := n as Button
			var r := Rect2(b.position, b.size)
			if r.has_point(Vector2(540, 50)) and r.size.x < 300 and r.size.y <= 110:
				return b
	return null


func _expect(ok: bool, why: String) -> void:
	if not ok:
		_fails += 1
		printerr("  ", why)
