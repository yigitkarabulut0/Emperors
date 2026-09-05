extends SceneTree
## A hidden overlay must not eat the game's input.
##
## reconnect.gd is a CanvasLayer that lives for the whole session with a
## full-screen ColorRect at MOUSE_FILTER_STOP, hidden until the connection drops.
## CanvasLayer is NOT a CanvasItem, so Control.is_visible_in_tree() does not walk
## up through it -- the question is whether Godot's input picking checks the
## layer's own visibility, or whether that invisible rectangle swallows every tap
## and drag in the entire game.
##
## Asserted through visibility rather than by synthesising clicks: headless Godot
## does not route input at all, so a click-based version of this test fails for
## the wrong reason and proves nothing.


func _fail(msg: String) -> void:
	print("FAIL  ", msg)
	quit(1)


func _initialize() -> void:
	_run()


func _find_blocker(node: Node) -> Control:
	if node is Control:
		var c := node as Control
		if c.mouse_filter != Control.MOUSE_FILTER_IGNORE and c.is_visible_in_tree():
			return c
	for ch in node.get_children():
		var hit := _find_blocker(ch)
		if hit != null:
			return hit
	return null


func _run() -> void:
	await process_frame

	var overlay: CanvasLayer = load("res://scenes/shell/reconnect.gd").new()
	root.add_child(overlay)
	await process_frame
	await process_frame

	if overlay.visible:
		_fail("the reconnect overlay started visible")
		return

	# Anything inside a hidden overlay that still reports itself visible and still
	# accepts the mouse is sitting between the player and the game.
	var blocker := _find_blocker(overlay)
	if blocker != null:
		_fail("%s inside the hidden overlay is visible_in_tree and takes input (filter %d) — it covers the whole game"
			% [blocker.get_class(), blocker.mouse_filter])
		return

	print("PASS  nothing in the hidden overlay is left able to take input")
	quit(0)
