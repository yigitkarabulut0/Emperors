extends SceneTree
## The battle is drawn on its painting (art/reference/battle.png): every live
## thing sits in the painted place made for it, at both canvases and under a
## phone's notch.
##
## What must hold:
##  - the painted battlefield is the screen, its portrait windows see-through,
##    and each side's face is drawn in its own window, under the frame, covering
##    it with room to move -- the player's on the left under the lion, whichever
##    side of the record they fought on;
##  - names (sixteen of the widest letter), power (9,999,999,999) and HP sit in
##    their plates and fit them; the HP fills run the painted channels and fall
##    with the events;
##  - the round is set in the ROUND plate's window; Fortune of War's two rolls
##    in the windows beside it;
##  - SKIP is the painted plate while the fight runs and is darkened after it;
##    CONTINUE is darkened while it runs and is the way on after it; both take a
##    thumb;
##  - the results board says what the fight did on its three painted rows --
##    gold won or lost, experience, diamonds -- for a raid won with a level's
##    diamonds, a raid lost, a defence held, a city raided and a fight for no
##    gold; its title band says whose fight it was;
##  - the battlefield keeps the top (moved down past the notch where the phone
##    has room), the board keeps the foot, and the two never meet.
##
## Run: godot --headless --path client --script tests/battle_layout.gd
##
## Scripts are loaded at run time, never named as a class here: a class named
## in this script compiles before the autoloads exist.

const MIN_H := 95.0
const LONG := "WWWWWWWWWWWWWWWW"
var _fails := 0
var _checked := 0
var _L: GDScript


func _initialize() -> void:
	await process_frame
	_L = load("res://scripts/ui/layout.gd")
	_pieces()
	for canvas in [Vector2(941, 1672), Vector2(941, 2040)]:
		await _screen(canvas, 0.0)
	await _screen(Vector2(941, 2040), 126.0)
	await _outcomes()
	if _checked == 0:
		print("FAIL  nothing was measured")
		quit(1)
		return
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d checks: the battle sits on its painting at both canvases and under the notch" % _checked)
	quit()


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)


func _rect(id: String) -> Rect2:
	return _L.rect_of(_L.element("battle", id))


## The painted pieces: the battlefield's portrait windows are see-through and
## its frames are not; the fills are solid paint.
func _pieces() -> void:
	var art: Node = root.get_node("Art")
	for name in ["battle/scene_top", "battle/scene_bottom", "battle/skip", "battle/continue",
			"battle/hp_green", "battle/hp_red"]:
		_checked += 1
		if not bool(art.call("has", name)):
			_fail("%s is not on disk" % name)
	var img: Image = (art.call("tex", "battle/scene_top") as Texture2D).get_image()
	if img.is_compressed():
		img.decompress()
	for id in ["window_you", "window_them"]:
		var r := _rect(id)
		_checked += 1
		var mid := img.get_pixelv(Vector2i(r.get_center()))
		var gold := img.get_pixelv(Vector2i(int(r.position.x) - 8, int(r.get_center().y)))
		if mid.a > 0.05 or gold.a < 0.99:
			_fail("scene_top: the %s is %.2f opaque in its middle and its frame %.2f: the face would not show through" % [
				id, mid.a, gold.a])


static func _replay(winner: String, attacker_avatar: String, defender_avatar: String) -> Dictionary:
	var events: Array = [{"r": 1, "k": "round"},
		{"r": 1, "k": "hit", "s": "a", "src": "A", "dst": "D", "dmg": 4000, "crit": true},
		{"r": 1, "k": "hp", "s": "d", "dst": "D", "hp": 4000},
		{"r": 2, "k": "round"},
		{"r": 2, "k": "hit", "s": "d", "src": "D", "dst": "A", "dmg": 4500},
		{"r": 2, "k": "hp", "s": "a", "dst": "A", "hp": 4500}]
	if winner == "a":
		events.append_array([{"r": 3, "k": "round"},
			{"r": 3, "k": "hit", "s": "a", "src": "A", "dst": "D", "dmg": 5000},
			{"r": 3, "k": "hp", "s": "d", "dst": "D", "hp": 0}, {"r": 3, "k": "death", "s": "d", "dst": "D"}])
	else:
		events.append_array([{"r": 3, "k": "round"},
			{"r": 3, "k": "hit", "s": "d", "src": "D", "dst": "A", "dmg": 5000},
			{"r": 3, "k": "hp", "s": "a", "dst": "A", "hp": 0}, {"r": 3, "k": "death", "s": "a", "dst": "A"}])
	return {"v": 2, "rounds": 3, "winner": winner, "fortune_a_bp": 21100, "fortune_d_bp": 9700,
		"attacker_might": 9999999999, "defender_might": 3006,
		"attacker": {"player_id": "A", "name": LONG, "avatar": attacker_avatar,
			"units": [{"id": "A", "hp": 9000, "weapon": "weapon_05"}]},
		"defender": {"player_id": "D", "name": "Ulric the Bold", "avatar": defender_avatar,
			"units": [{"id": "D", "hp": 8000, "weapon": "weapon_02"}]},
		"events": events}


func _build(canvas: Vector2, result: Dictionary, inset: float) -> CanvasLayer:
	# The screen measures the viewport it is drawn in, which on the phone is the
	# canvas.
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.size = Vector2i(int(canvas.x), int(canvas.y))
	var host := Control.new()
	host.size = canvas
	root.add_child(host)
	var screen: CanvasLayer = load("res://scenes/battle/battle_replay.gd").new()
	screen.setup(result)
	screen.set("top_inset", inset)
	host.add_child(screen)
	return screen


func _gr(n: Control) -> Rect2:
	return Rect2(n.global_position, n.size)


## A label's words at the size it was fitted to, against its box.
func _fits(l: Label) -> bool:
	var s := l.label_settings
	var w := s.font.get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, s.font_size).x
	return w <= float(l.get_meta("box_w", l.size.x)) + 1.0


func _screen(canvas: Vector2, inset: float) -> void:
	var tag := "%dx%d%s" % [int(canvas.x), int(canvas.y), " under a %d notch" % int(inset) if inset > 0.0 else ""]
	var screen := _build(canvas, {"won": true, "gold_stolen": "412000", "xp_gained": 640,
		"replay": _replay("a", "king", "berserk")}, inset)
	for i in 3:
		await process_frame
	var ui: Variant = screen.get("_ui")
	_checked += 1
	if not (ui is Dictionary) or (ui as Dictionary).is_empty():
		_fail("%s: the screen is not built from the painting's layout" % tag)
		screen.get_parent().queue_free()
		await process_frame
		return
	var drop := clampf(inset, 0.0, maxf(0.0, canvas.y - 1672.0))
	var top := Vector2(0, drop)
	var foot := Vector2(0, canvas.y - 1672.0)

	# The two blocks: the battlefield from the top (past the notch), the board at the foot.
	var scene_top: Control = ui["scene_top"]
	var scene_bottom: Control = ui["scene_bottom"]
	_checked += 1
	if absf(scene_top.global_position.y - drop) > 0.5 or absf(_gr(scene_bottom).end.y - canvas.y) > 0.5:
		_fail("%s: the battlefield starts at %.0f (want %.0f) and the board ends at %.0f (want %.0f)" % [
			tag, scene_top.global_position.y, drop, _gr(scene_bottom).end.y, canvas.y])
	if _gr(scene_top).end.y > scene_bottom.global_position.y + 0.5:
		_fail("%s: the battlefield (to %.0f) runs over the board (from %.0f)" % [
			tag, _gr(scene_top).end.y, scene_bottom.global_position.y])

	# The faces: each in its own window, under the frame, covering it.
	var faces: Dictionary = screen.get("_face")
	var want_face := {"a": "avatar_king", "d": "avatar_berserk"}
	for pair in [["a", "window_you"], ["d", "window_them"]]:
		var f: TextureRect = faces.get(pair[0], null)
		_checked += 1
		if f == null:
			_fail("%s: no face for side %s" % [tag, pair[0]])
			continue
		var win := _rect(pair[1])
		win.position += top
		var clip := f.get_parent() as Control
		if clip == null or not clip.clip_contents or not _gr(clip).is_equal_approx(win):
			_fail("%s: side %s's face is not clipped to its window %s (got %s)" % [tag, pair[0], str(win),
				str(_gr(clip)) if clip != null else "nothing"])
		elif not _gr(f).encloses(win.grow(8.0)):
			_fail("%s: side %s's face %s does not cover its window %s with room to move" % [tag, pair[0], str(_gr(f)), str(win)])
		if not f.texture.resource_path.get_file().begins_with(str(want_face[pair[0]]) + "."):
			_fail("%s: side %s wears %s, want %s" % [tag, pair[0], f.texture.resource_path.get_file(), want_face[pair[0]]])
		if clip != null and clip.get_index() > scene_top.get_index():
			_fail("%s: side %s's face is drawn over the frame" % [tag, pair[0]])

	# The plates: every word in its painted place, fitted.
	for id in ["name_you", "name_them", "power_you", "power_them", "round_number", "fortune_you",
			"fortune_them", "hp_you", "hp_them", "band"]:
		var l: Label = ui[id]
		var want := _rect(id)
		want.position += top if not id in ["band"] else foot
		_checked += 1
		if l.text == "":
			_fail("%s: %s says nothing" % [tag, id])
			continue
		# Where it was placed, not where an animation has scaled it to this frame.
		var at := (l.get_parent() as Control).global_position + l.position
		if absf(at.x - want.position.x) > 0.5 or absf(at.y - want.position.y) > 0.5:
			_fail("%s: %s is at %s, its plate at %s" % [tag, id, str(at), str(want.position)])
		if not _fits(l):
			_fail("%s: \"%s\" does not fit %s at %d" % [tag, l.text, id, l.label_settings.font_size])
	if (ui["name_you"] as Label).text != LONG:
		_fail("%s: the sixteen-letter name reads \"%s\"" % [tag, (ui["name_you"] as Label).text])
	if (ui["power_you"] as Label).text != "9,999,999,999":
		_fail("%s: the power reads \"%s\"" % [tag, (ui["power_you"] as Label).text])

	# The fills run the painted channels: green for the player, red for the rival.
	var fills: Dictionary = screen.get("_fill")
	for pair in [["a", "channel_you", "hp_green"], ["d", "channel_them", "hp_red"]]:
		var wrap: Control = fills.get(pair[0], null)
		var ch := _rect(pair[1])
		ch.position += top
		_checked += 1
		if wrap == null:
			_fail("%s: no HP fill for side %s" % [tag, pair[0]])
			continue
		var np := wrap.get_child(0) as NinePatchRect
		if not wrap.global_position.is_equal_approx(ch.position) or np == null \
				or not np.texture.resource_path.ends_with("/%s.png" % pair[2]) or absf(np.size.x - ch.size.x) > 0.5:
			_fail("%s: side %s's fill is not the painted %s the channel %s long" % [tag, pair[0], pair[2], str(ch)])

	# SKIP while it runs; CONTINUE darkened. Both a thumb.
	var skip: BaseButton = ui["skip"]
	var go: BaseButton = ui["continue"]
	var paint_skip := Vector2(786, 23) + top
	var skip_face := skip.global_position + (skip.size - (skip as TextureButton).texture_normal.get_size()) / 2.0
	_checked += 1
	if skip.disabled or not go.disabled or not _veiled(go) or _veiled(skip):
		_fail("%s: while the fight runs SKIP must be live and CONTINUE darkened" % tag)
	if skip_face.distance_to(paint_skip) > 1.0:
		_fail("%s: SKIP's face is at %s, the painted plate at %s" % [tag, str(skip_face), str(paint_skip)])
	var go_at := Vector2(206, 1446) + foot
	if go.global_position.distance_to(go_at) > 1.0:
		_fail("%s: CONTINUE is at %s, the painted one at %s" % [tag, str(go.global_position), str(go_at)])
	for b in [skip, go]:
		if (b as Control).size.y < MIN_H or not Rect2(Vector2.ZERO, canvas).encloses(_gr(b)):
			_fail("%s: a button %s is off the screen or too small for a thumb" % [tag, str(_gr(b))])

	# The fight, told: the rows fill and the buttons trade places.
	screen.set("_skip", true)
	var waited := 0
	while not bool(screen.get("_done")) and waited < 200:
		await process_frame
		waited += 1
	_checked += 1
	if not skip.disabled or go.disabled or _veiled(go) or not _veiled(skip):
		_fail("%s: once the fight is told SKIP must be darkened and CONTINUE the way on" % tag)
	var hp_fill: Control = fills["d"]
	if hp_fill.visible and hp_fill.size.x > 1.0:
		_fail("%s: the fallen side's bar still shows %.0f" % [tag, hp_fill.size.x])
	for id in ["row_gold", "row_crown", "row_diamond"]:
		var l: Label = ui[id]
		var want := _rect(id)
		want.position += foot
		_checked += 1
		if not Rect2(want.position, want.size).grow(0.5).encloses(_gr(l)) or not _fits(l):
			_fail("%s: \"%s\" is not in its painted row %s" % [tag, l.text, str(want)])
	# The banner over the battlefield, clear of the faces and the plates.
	var banner: Control = null
	for c in (screen.get("_root") as Control).get_children():
		if c.name == "Banner":
			banner = c
	var zone := _rect("banner_zone")
	zone.position += top
	_checked += 1
	if banner == null:
		_fail("%s: no banner" % tag)
	elif not zone.grow(0.5).encloses(_gr(banner)):
		_fail("%s: the banner %s is outside its zone over the battlefield %s" % [tag, str(_gr(banner)), str(zone)])
	var r1: Label = ui["round_number"]
	if r1.position.y < drop - 0.5 or (inset > 0.0 and r1.position.y < inset):
		_fail("%s: the round number is at %.0f, under the notch" % [tag, r1.position.y])
	screen.get_parent().queue_free()
	await process_frame


func _veiled(b: BaseButton) -> bool:
	for c in b.get_children():
		if c.name == "Veil" and (c as CanvasItem).visible and (c as CanvasItem).modulate.a > 0.5:
			return true
	return false


## The board says what the fight did, from the player's side.
func _outcomes() -> void:
	var cases := [
		["a raid won with a level's diamonds", {"won": true, "gold_stolen": "412000", "xp_gained": 640, "diamonds_gained": 5},
			["+412,000 gold", "+640 experience", "+5 diamonds for the level"], "Your raid on Ulric the Bold"],
		["a raid lost", {"won": false, "ransom_paid": "300", "xp_gained": 12},
			["Their defence earned them 300 ransom", "+12 experience", "No diamonds"], "Your raid on Ulric the Bold"],
		["a defence held", {"won": true, "perspective": "defender", "gold": "900"},
			["+900 ransom for holding", "No experience", "No diamonds"], "Your defence held"],
		["a city raided", {"won": false, "perspective": "defender", "gold": "-4000"},
			["-4,000 gold stolen", "No experience", "No diamonds"], "Your city was raided"],
		["a fight for no gold", {"won": true, "gold_stolen": "0", "xp_gained": 0},
			["No gold changed hands", "No experience", "No diamonds"], "Your raid on Ulric the Bold"],
	]
	for c in cases:
		var r: Dictionary = (c[1] as Dictionary).duplicate()
		var defender := str(r.get("perspective", "")) == "defender"
		r["replay"] = _replay("a" if bool(r["won"]) != defender else "d", "king", "berserk")
		var screen := _build(Vector2(941, 1672), r, 0.0)
		screen.set("_skip", true)
		var waited := 0
		while not bool(screen.get("_done")) and waited < 200:
			await process_frame
			waited += 1
		var ui: Variant = screen.get("_ui")
		_checked += 1
		if not (ui is Dictionary) or not bool(screen.get("_done")):
			_fail("%s: the board was never filled" % c[0])
			screen.get_parent().queue_free()
			await process_frame
			continue
		var got := [(ui["row_gold"] as Label).text, (ui["row_crown"] as Label).text, (ui["row_diamond"] as Label).text]
		if got != c[2]:
			_fail("%s: the rows read %s, want %s" % [c[0], str(got), str(c[2])])
		if (ui["band"] as Label).text != c[3]:
			_fail("%s: the band reads \"%s\", want \"%s\"" % [c[0], (ui["band"] as Label).text, c[3]])
		# The player is on the left, whichever side of the record they fought on.
		var faces: Dictionary = screen.get("_face")
		var you := "d" if defender else "a"
		var left: Control = faces[you]
		if left.global_position.x > 470.0:
			_fail("%s: the player's face is on the right" % c[0])
		screen.get_parent().queue_free()
		await process_frame
