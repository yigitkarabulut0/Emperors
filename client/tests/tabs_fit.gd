extends SceneTree
## No section may be wider than the screen.
##
## Godot propagates a child's minimum size up through every container, so ONE
## label that does not wrap makes its whole tab too wide -- and because the tabs
## and the top bar share the shell's root column, that tab drags the top bar off
## the right edge with it. The Bank page did exactly this: a sentence about the
## deposit fee reported its full unwrapped width as a minimum, and half the
## screen, chrome included, was cut off.
##
## Measured per tab, so the failure names the screen and the number.

## 720 stretch units is the guaranteed width: with canvas_items + expand the
## viewport is never NARROWER than this, but it is exactly this on every phone.
const VIEWPORT_W := 720.0


func _fail(msg: String) -> void:
	print("FAIL  ", msg)
	quit(1)


func _initialize() -> void:
	_run()


## The widest thing inside, and what it is -- so a failure says which label.
func _widest(node: Node, depth: int = 0) -> Array:
	var worst := 0.0
	var what := ""
	if node is Control:
		var c := node as Control
		var w: float = c.get_combined_minimum_size().x
		if w > worst:
			worst = w
			what = c.get_class()
			if c is Label:
				what = "Label \"%s\"" % (c as Label).text.substr(0, 46)
			elif c is Button:
				what = "Button \"%s\"" % (c as Button).text.substr(0, 46)
	for ch in node.get_children():
		var r := _widest(ch, depth + 1)
		if float(r[0]) > worst:
			worst = float(r[0])
			what = str(r[1])
	return [worst, what]


func _run() -> void:
	await process_frame
	var env: Node = root.get_node_or_null("/root/Env")
	var session: Node = root.get_node_or_null("/root/Session")
	var gs: Node = root.get_node_or_null("/root/GameState")

	session.call("sign_out")
	var err: String = await session.call("login", "proofking", "hunter2hunter2")
	if err != "":
		err = await session.call("register", "proofking", "hunter2hunter2")
	if err != "":
		_fail("could not sign in: %s" % err)
		return
	await gs.call("refresh")

	# Measured against a notched phone, because that is the narrowest the content
	# column ever gets: the row is inset by the safe area AND by the shell's own
	# edge margin on both sides.
	var fake: Node = root.get_node_or_null("/root/Env")
	if fake != null:
		fake.set("fake_safe_area", Vector4(0, 101, 0, 56))
		fake.set("fake_safe_area_on", true)

	var shell: Node = load("res://scenes/shell/shell.gd").new()
	root.add_child(shell)
	for i in 60:
		await process_frame

	# The budget is MEASURED off the laid-out shell, not re-derived from its
	# constants.
	#
	# It used to be VIEWPORT_W - RAIL_WIDTH - 20, and that number went stale the
	# moment the row gained a safe-area inset and an edge margin on both sides: it
	# claimed 540 where the real column is 464, a 76-unit lie, and the widest tab
	# wants 439. The test would have passed a layout that clips. Asking the
	# container how wide it actually is cannot go stale.
	# Derived, not measured off the tree: this shell is parented to the root
	# without anchors, so its laid-out width is whatever Godot gave it and not
	# what the game runs at. Measuring it reported 429 where the real column is
	# 488 -- and failed three tabs that fit perfectly well.
	#
	# EDGE is charged three times across the row: once at each screen edge, and
	# once between the rail and the content. The corner allowance is charged at
	# both edges, and every device with a rounded display gets it.
	var rail: float = float(shell.get("RAIL_WIDTH"))
	var edge: float = float(shell.get("EDGE"))
	var budget := VIEWPORT_W - 3.0 * edge - 2.0 * float(UI.CORNER) - rail

	var bad: Array[String] = []
	var report := ""
	for id in ["hero", "jobs", "shop", "items", "estates", "army", "bank", "fight", "house"]:
		shell.call("_build_tab", id)
		for i in 40:
			await process_frame
		var tabs: Dictionary = shell.get("_tabs")
		if not tabs.has(id):
			continue
		var node: Node = tabs[id]
		var w: float = (node as Control).get_combined_minimum_size().x
		var worst := _widest(node)
		report += "\n  %-9s wants %5.0f of %5.0f" % [id, w, budget]
		if w > budget:
			report += "   <-- %s" % str(worst[1])
			bad.append(id)

	# The whole shell, chrome included.
	var column: Control = null
	for c in shell.get_children():
		if c is VBoxContainer:
			column = c
	var total: float = column.get_combined_minimum_size().x if column != null else 0.0
	report += "\n  %-9s wants %5.0f of %5.0f" % ["SHELL", total, VIEWPORT_W]

	print(report)
	if not bad.is_empty() or total > VIEWPORT_W:
		_fail("these sections are wider than the screen: %s" % ", ".join(bad))
		return
	print("PASS  every section fits the width of the screen")
	quit(0)
