extends SceneTree
## Every section of the navigation rail must be reachable without scrolling, on
## every device we ship to.
##
## Measured rather than eyeballed, because the failure is quiet: when the shell's
## column wants more than the screen gives it, the overflow lands at the bottom
## and clips whatever is there. It clipped the action button's caption on an
## iPhone SE, and the cause was nothing to do with the action bar -- two currency
## chips in the TOP bar were 142 units tall, because panel_box carries 10 units of
## padding above and below and a MarginContainer inside them added four more.
##
## The rail is deliberately NOT in a scroll view -- one running the full height of
## a phone's left edge captures every vertical drag, so swiping anywhere near it
## scrolls a rail that does not need scrolling instead of the list underneath.
## That means nothing catches an overflow at runtime, and this test is the only
## thing between a slightly taller top bar and a House button that has quietly
## fallen off the bottom of the screen.
##
## Viewport heights come from stretch mode canvas_items with aspect expand, where
## scale = min(w/720, h/1280) -- so a tall phone gets a TALLER viewport than the
## 1280 design height, and the binding devices are the ones closest to 9:16.

const DEVICES := [
	# name, viewport height in units, safe-area insets (l, t, r, b)
	["iPhone SE 3",       1281, Vector4(0, 38, 0, 0)],
	["iPhone 15 / 16",    1561, Vector4(0, 108, 0, 62)],
	["iPhone 16 Pro Max", 1564, Vector4(0, 101, 0, 56)],
	["iPad 10.9",         1280, Vector4(0, 32, 0, 28)],
]


func _fail(msg: String) -> void:
	print("FAIL  ", msg)
	quit(1)


func _initialize() -> void:
	_run()


## The rail's button column: the VBox whose children are the section buttons.
func _rail_content(node: Node) -> Control:
	if node is VBoxContainer and node.get_child_count() >= 9:
		var all_buttons := true
		for c in node.get_children():
			if not (c is Button):
				all_buttons = false
		if all_buttons:
			return node
	for c in node.get_children():
		var hit := _rail_content(c)
		if hit != null:
			return hit
	return null


func _run() -> void:
	await process_frame
	var env: Node = root.get_node_or_null("/root/Env")
	if env == null:
		_fail("Env missing")
		return

	var worst := ""
	var worst_spare := 1e9
	for device in DEVICES:
		var name: String = device[0]
		var height: float = float(device[1])
		env.set("fake_safe_area", device[2])
		env.set("fake_safe_area_on", true)

		var shell: Node = load("res://scenes/shell/shell.gd").new()
		root.add_child(shell)
		for i in 30:
			await process_frame

		var column: Control = null
		for c in shell.get_children():
			if c is VBoxContainer:
				column = c
		if column == null:
			_fail("the shell has no root column")
			return

		var needed := 0.0
		var parts := ""
		for c in column.get_children():
			var h: float = (c as Control).get_combined_minimum_size().y
			var what := c.get_class()
			var rail := _rail_content(c)
			if rail != null:
				h = rail.get_combined_minimum_size().y
				what = "rail (%d sections)" % rail.get_child_count()
			needed += h
			parts += "\n      %-22s %6.0f" % [what, h]

		shell.queue_free()
		await process_frame

		if needed > height:
			_fail("%s: the shell wants %.0f units of %.0f, so %.0f are pushed off the bottom:%s"
				% [name, needed, height, needed - height, parts])
			return
		print("  %-19s %6.0f of %.0f  (%.0f spare)" % [name, needed, height, height - needed])
		if height - needed < worst_spare:
			worst_spare = height - needed
			worst = name

	print("PASS  every section fits on every device; tightest is %s with %.0f units spare"
		% [worst, worst_spare])
	quit(0)
