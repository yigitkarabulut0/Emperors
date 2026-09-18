extends SceneTree
## A KINGDOM SECTION REPORTS A HEIGHT THAT COVERS WHAT IT DREW.
##
## The Kingdom tab grows its page to the height its section claims (`grew`, then
## `_body_bottom`). A section that under-reports does not draw less -- it draws
## exactly the same and the page simply stops scrolling before the end, so
## whatever is below the fold cannot be reached at all.
##
## That shipped. `help_section`'s two panels each answered with their own HEIGHT
## where the caller wanted the y they END at; for the first panel, which starts
## at zero, those are the same number, and for the second they are not. The
## section reported the AID panel's height as the whole section's, the page
## never grew past the screen, and the calls for aid, every ANSWER and ASK FOR
## AID could not be scrolled to.
##
## Run: godot --headless --path client --script tests/section_heights.gd

var _fails := 0
var _checked := 0


func _initialize() -> void:
	await process_frame
	root.get_node("Env").set("api_base_url", "http://127.0.0.1:9")
	for case in _cases():
		await _section(str(case["script"]), case["data"], str(case["tag"]))
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d checks: every section's height covers what it drew" % _checked)
	quit()


## The sections the Kingdom tab hosts, each with the answer that makes it draw
## its whole body -- the state with the most under the fold.
func _cases() -> Array:
	return [
		{"tag": "help, a goal and calls", "script": "res://scenes/kingdom/help_section.gd",
			"data": {
				"goal": {"id": "g", "kind": "energy", "name": "Hands to the Work",
					"blurb": "Spend energy in honest work, together.", "icon": "help/goal_energy",
					"progress": 900, "target": 2400, "members": 6, "ends_in": 2219, "claim_in": 0,
					"mine": 40, "mine_need": 100,
					"chests": [
						{"index": 0, "at_bp": 4000, "at": 960, "lines": ["50 gold"], "reached": false, "claimed": false},
						{"index": 1, "at_bp": 7000, "at": 1680, "lines": ["90 gold"], "reached": false, "claimed": false},
						{"index": 2, "at_bp": 10000, "at": 2400, "lines": ["10 diamonds"], "reached": false, "claimed": false},
					]},
				"calls": [
					{"id": "a1", "name": "Aldric the Grey", "avatar": "knight", "answers": 1, "answered": false},
					{"id": "a2", "name": "Seraphine", "avatar": "lady", "answers": 0, "answered": false},
					{"id": "a3", "name": "Halvard", "avatar": "knight", "answers": 2, "answered": true},
				],
				"aid_left": 4, "ask_in": 0, "aid_stack_bp": 100, "aid_hours": 6, "aid_favour": 3,
				"my_stacks": 0, "max_stacks": 5}},
		{"tag": "help, no kingdom", "script": "res://scenes/kingdom/help_section.gd", "data": {}},
	]


func _section(path: String, data: Dictionary, tag: String) -> void:
	var host := Control.new()
	host.size = Vector2(941, 1672)
	root.add_child(host)
	var s: Control = load(path).new()
	host.add_child(s)
	# The section asks the server for itself as soon as it is in the tree. Env
	# points at a dead port, so let that answer fail and paint its empty state
	# FIRST -- otherwise it lands after the fixture and paints over it.
	for _i in 12:
		await process_frame
	s.set("_data", data)
	s.call("_paint")
	await process_frame
	await process_frame

	# The lowest thing the section drew, in the section's own coordinates.
	var bottom := 0.0
	for c in s.get_children():
		if c is Control and (c as Control).is_visible_in_tree():
			bottom = maxf(bottom, (c as Control).position.y + (c as Control).size.y)
	_checked += 1
	_expect(s.size.y + 1.0 >= bottom,
		"%s: the section says it is %.0f tall and drew down to %.0f -- %.0f units cannot be reached"
		% [tag, s.size.y, bottom, bottom - s.size.y])
	_checked += 1
	_expect(is_equal_approx(s.size.y, s.custom_minimum_size.y),
		"%s: size %.0f and custom_minimum_size %.0f disagree, so the page grows to the wrong one"
		% [tag, s.size.y, s.custom_minimum_size.y])
	host.queue_free()
	await process_frame


func _expect(ok: bool, what: String) -> void:
	if not ok:
		_fails += 1
		print("  FAIL  " + what)
