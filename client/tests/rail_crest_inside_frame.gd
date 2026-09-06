extends SceneTree
## The crest plate must sit INSIDE the rail's carved frame, not on top of it.
##
## The bug this guards: the rail's inner padding used RAIL_GAP -- the two units
## the plates keep from EACH OTHER -- as its top margin, while the frame's carved
## band is eight units deep. The avatar-and-level plate therefore started inside
## the frame's top lip, drew its own stone edge over the rail's border, and read
## as having slid up out of the column and over the banner's line.
##
## Measured rather than eyeballed because it is a few units, it only shows on the
## one plate at the head of the column, and shell_fits.gd cannot see it: that
## test sums MINIMUM SIZES to catch overflow off the BOTTOM, so a plate hanging
## off the top costs it nothing and it passes.

const DEVICES := [
	["iPhone SE 3",       Vector4(0, 38, 0, 0)],
	["iPhone 15 / 16",    Vector4(0, 108, 0, 62)],
	["iPad 10.9",         Vector4(0, 32, 0, 28)],
	["desktop (no inset)", Vector4(0, 0, 0, 0)],
]


func _fail(msg: String) -> void:
	print("FAIL  ", msg)
	quit(1)


func _initialize() -> void:
	_run()


func _find(node: Node, pred: Callable) -> Node:
	if pred.call(node):
		return node
	for c in node.get_children():
		var hit := _find(c, pred)
		if hit != null:
			return hit
	return null


func _run() -> void:
	await process_frame
	var env: Node = root.get_node_or_null("/root/Env")
	if env == null:
		_fail("Env missing")
		return

	for device in DEVICES:
		var name: String = device[0]
		env.set("fake_safe_area", device[1])
		env.set("fake_safe_area_on", true)

		var shell: Node = load("res://scenes/shell/shell.gd").new()
		root.add_child(shell)
		for i in 30:
			await process_frame

		var column := _find(shell, func(n): return n is VBoxContainer and n.name == "RailColumn")
		if column == null:
			_fail("%s: the rail has no RailColumn" % name)
			return
		# The frame is an anchored sibling of the padding, so walk up to the rail
		# panel and find it from there rather than guessing at indices.
		var rail: Node = column.get_parent().get_parent()
		var frame := _find(rail, func(n): return n is NinePatchRect)
		if frame == null:
			_fail("%s: the rail has no carved frame" % name)
			return

		var crest: Control = column.get_child(0)
		var band: float = float(frame.get("patch_margin_top"))
		var gap: float = crest.global_position.y - (rail as Control).global_position.y

		shell.queue_free()
		await process_frame

		if gap < band:
			_fail("%s: the crest starts %.0f units into a %.0f-unit frame band, so it is drawn over the rail's top border"
				% [name, gap, band])
			return
		print("  %-20s crest starts %3.0f units down, clearing a %.0f-unit band" % [name, gap, band])

	print("PASS  the crest plate sits inside the rail's frame on every device")
	quit(0)
