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

	var shell: Node = load("res://scenes/shell/shell.gd").new()
	root.add_child(shell)
	for i in 60:
		await process_frame

	# Everything the shell can show has to fit beside the rail.
	var rail: float = float(shell.get("RAIL_WIDTH"))
	var budget := VIEWPORT_W - rail - 20.0

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
