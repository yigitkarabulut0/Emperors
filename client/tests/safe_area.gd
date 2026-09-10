extends SceneTree
## On an iPhone the notch or the Dynamic Island covers the top of the canvas,
## and the shell moves the game down by it. Moved with position.y, the tab host
## kept its height, so every tab ran the inset -- 141 units under a Dynamic
## Island -- past the bottom of the screen: the Shop's and Collect's footers,
## the Army's ground and the last row of every list were drawn where nobody
## could see them. The host must start under the inset and end at the screen's
## foot, whatever the inset.
##
## Run: godot --headless --path client --script tests/safe_area.gd
##
## The shell is loaded at run time, never named as a class here: a class named
## in this script is compiled before the autoloads exist.

const INSETS := [0.0, 113.0, 141.0]
const CANVAS := Vector2(941, 2040)

var _fails := 0


func _initialize() -> void:
	await process_frame
	var checked := 0
	for inset in INSETS:
		var parent := Control.new()
		parent.size = CANVAS
		root.add_child(parent)
		var shell: Control = (load("res://scenes/shell/shell.tscn") as PackedScene).instantiate()
		parent.add_child(shell)
		shell.set_anchors_preset(Control.PRESET_FULL_RECT)
		for i in 3:
			await process_frame
		if inset > 0.0:
			shell.call("apply_inset", inset)
		await process_frame
		var host: Control = shell.get("_host")
		if host == null:
			_fail("the shell has no tab host")
		else:
			checked += 1
			var top := host.global_position.y
			var bottom := top + host.size.y
			if absf(top - inset) > 0.5:
				_fail("inset %.0f: the host starts at %.0f" % [inset, top])
			if absf(bottom - CANVAS.y) > 0.5:
				_fail("inset %.0f: the host ends at %.0f, the screen at %.0f" % [inset, bottom, CANVAS.y])
		parent.queue_free()
		await process_frame
	if checked == 0:
		print("FAIL  no shell was measured")
		quit(1)
		return
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  the tabs start under the notch and end at the screen's foot")
	quit()


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)
