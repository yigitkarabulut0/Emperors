extends SceneTree
## Every portrait id has its own painted face, and the profile offers all of
## them in a grid that fits the phone and takes a thumb.
##
## Until avatars_sheet.png the twelve ids in balance/progression.json shared
## four faces: a lord who chose the monk was drawn as a captain, and the queen,
## the princess and the witch were one woman. Each id now names its own bust,
## cut at 236 (the battle's portrait) with a 96 cut for the rows that draw a
## face near 70.
##
## Run: godot --headless --path client --script tests/avatar_faces.gd

const MIN_H := 95.0
var _fails := 0
var _checked := 0


func _initialize() -> void:
	await process_frame
	var art: Node = root.get_node("Art")
	var ids: Array = _balance_ids()
	_expect(ids.size() == 12, "the balance lists 12 portrait ids, not %d" % ids.size())

	var seen := {}
	for id in ids:
		var face: String = art.call("avatar", id)
		_checked += 1
		_expect(face != str(art.get("AVATAR_DEFAULT")) or id == "knight", "%s falls back to the default face" % id)
		_expect(not seen.has(face), "%s shares its face with %s" % [id, seen.get(face, "")])
		seen[face] = id
		for path in [face, str(art.call("avatar_small", id))]:
			_expect(ResourceLoader.exists("res://assets/%s.png" % path), "%s is not on disk" % path)
		var big: Texture2D = load("res://assets/%s.png" % face)
		var small: Texture2D = load("res://assets/%s_small.png" % face)
		if big != null and small != null:
			_expect(big.get_width() == 236 and big.get_height() == 236, "%s is %s, want 236 square" % [face, big.get_size()])
			_expect(small.get_width() == 96 and small.get_height() == 96, "%s_small is %s, want 96 square" % [face, small.get_size()])
	_expect(str(art.call("avatar", "no-such-id")) == "portraits/avatar_knight", "an unknown id is the server's default, the knight")

	# The picker offers exactly the balance's ids, one face each, in its order.
	var choices: Array = art.get("AVATAR_CHOICES")
	_expect(choices.size() == 12, "the picker offers %d faces, want 12" % choices.size())
	for i in mini(choices.size(), ids.size()):
		var c: Array = choices[i]
		_expect((c[1] as Array).size() == 1 and c[1][0] == ids[i], "choice %d is %s, want %s" % [i, str(c[1]), ids[i]])
		_expect(c[0] == art.call("avatar", ids[i]), "choice %d draws %s, not %s's face" % [i, c[0], ids[i]])

	var gs: Node = root.get_node("GameState")
	gs.set("snapshot", {"player": {"username": "Wwwwwwwwwwwwwwww", "avatar": "monk", "level": 30,
		"gold": "987654321", "diamonds": 12, "action_seq": 1}, "energy": {"current": 1, "max": 2},
		"prices": {"rename_diamonds": 20}})
	for canvas in [Vector2(941, 1672), Vector2(941, 2040)]:
		await _picker(canvas)

	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  12 portrait ids, 12 faces, and a picker of %d checks that fits the phone" % _checked)
	quit()


func _picker(canvas: Vector2) -> void:
	var tag := "%dx%d" % [int(canvas.x), int(canvas.y)]
	var host := Control.new()
	host.size = canvas
	root.add_child(host)
	# The faces are chosen on their own page over the profile, opened from the
	# profile's portrait (profile_page.face_picker).
	var s: Control = load("res://scenes/pages/profile_page.gd").face_picker(host)
	for i in 4:
		await process_frame
	var grid: GridContainer = _find_grid(s)
	_expect(grid != null, "%s: the face picker has no grid of faces" % tag)
	if grid != null:
		_expect(grid.get_child_count() == 12, "%s: the grid holds %d faces, want 12" % [tag, grid.get_child_count()])
		var plate: Control = s.get("_plate")
		var pr := Rect2(plate.global_position, plate.size)
		var yours := 0
		for tile in grid.get_children():
			var tr := Rect2((tile as Control).global_position, (tile as Control).size)
			_checked += 1
			_expect(pr.encloses(tr), "%s: a face tile %s runs off the plate %s" % [tag, tr, pr])
			for c in tile.get_children():
				if c is Button:
					_expect((c as Button).size.y >= MIN_H, "%s: a face is %.0f tall to the thumb" % [tag, (c as Button).size.y])
				if c is Label and (c as Label).text == "YOURS":
					yours += 1
		_expect(yours == 1, "%s: %d faces say YOURS, want the monk's alone" % [tag, yours])
	s.call("close")
	host.queue_free()
	await process_frame


func _find_grid(n: Node) -> GridContainer:
	if n is GridContainer:
		return n
	for c in n.get_children():
		var g := _find_grid(c)
		if g != null:
			return g
	return null


func _balance_ids() -> Array:
	var path := ProjectSettings.globalize_path("res://").path_join("../balance/progression.json")
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return []
	var d: Variant = JSON.parse_string(f.get_as_text())
	return (d as Dictionary).get("avatars", []) if d is Dictionary else []


func _expect(cond: bool, what: String) -> void:
	if not cond:
		_fails += 1
		print("  FAIL  " + what)
