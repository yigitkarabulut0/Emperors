extends SceneTree
## Away's TAKE REVENGE lands on the Attack tab's REVENGE view, every time.
##
## The report's button opened the Attack tab as it stood. A player who had last
## looked at TARGETS was taken to a list of strangers, not to the raiders the
## report had just named. The shell's _revenge is what the report is handed,
## from arrival and from coming back to the game alike; this leaves Attack on
## TARGETS, goes elsewhere, and takes it.
##
## Run: godot --headless --path client --script tests/away_revenge.gd
##
## The shell is loaded at run time, never named as a class here: a class named
## in this script is compiled before the autoloads exist.

var _fails := 0


func _initialize() -> void:
	await process_frame
	root.get_node("Env").set("api_base_url", "http://127.0.0.1:9")
	# A capture run's arrival: no tour, no away report of its own.
	(root.get_node("Env").get("args") as Dictionary)["capture"] = "test"
	root.get_node("GameState").set("snapshot", {"player": {"username": "Wwwwwwwwwwwwwwww", "level": 30,
		"gold": "1000", "diamonds": 0}, "energy": {"current": 10, "max": 100},
		"sections": [{"id": "fight", "unlock_level": 10, "unlocked": true},
			{"id": "jobs", "unlock_level": 1, "unlocked": true}]})
	var parent := Control.new()
	parent.size = Vector2(941, 1672)
	root.add_child(parent)
	var shell: Control = (load("res://scenes/shell/shell.tscn") as PackedScene).instantiate()
	parent.add_child(shell)
	shell.set_anchors_preset(Control.PRESET_FULL_RECT)
	for i in 3:
		await process_frame
	if not shell.has_method("_revenge"):
		print("FAIL  the shell has no _revenge: TAKE REVENGE only opens the Attack tab as it was left")
		quit(1)
		return
	shell.call("open", "attack")
	await process_frame
	var attack: Control = (shell.get("_tabs") as Dictionary).get("attack")
	if attack == null:
		print("FAIL  the Attack tab did not open")
		quit(1)
		return
	attack.call("_set_view", "targets")
	shell.call("open", "collect")
	await process_frame
	shell.call("_revenge")
	await process_frame
	if str(shell.get("_current")) != "attack":
		_fail("TAKE REVENGE left the player on %s" % str(shell.get("_current")))
	if str(attack.get("_view")) != "revenge":
		_fail("TAKE REVENGE opened Attack on %s, not REVENGE" % str(attack.get("_view")))
	# And from Attack itself, still on TARGETS.
	attack.call("_set_view", "targets")
	shell.call("_revenge")
	await process_frame
	if str(attack.get("_view")) != "revenge":
		_fail("from Attack on TARGETS, TAKE REVENGE stayed on %s" % str(attack.get("_view")))
	# The report is handed _revenge wherever the shell asks for it.
	var src := FileAccess.get_file_as_string("res://scenes/shell/shell.gd")
	if src.contains("away.check(self, since, func() -> void: open(\"attack\"))"):
		_fail("an away report is still handed a plain open(\"attack\")")
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  TAKE REVENGE lands on the REVENGE view, from anywhere and from TARGETS")
	quit()


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)
