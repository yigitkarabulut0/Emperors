extends SceneTree
## The steward's guide over the game: the spotlight, the gauntlet, the scroll.
##
## Checked, on the 1672 design and a 2040 phone: a step's control is ringed by
## the dim's hole, takes the tap through it while the dim refuses every other,
## and has the gauntlet's fingertip on it; the scroll and the steward keep to
## the half and the side the control is not in, the steward looking toward it,
## SKIP at the scroll's other end; the step's title and words, the longest the
## balance has fitting the parchment at a size that reads; a step waiting on a
## level says so and points at Collect's first job; the way to a control not on
## screen gets the arrow (a rail entry) and never the gauntlet; a tap step and
## a done step dim the whole screen, show "TAP TO CONTINUE" and the done words,
## and no gauntlet; a step whose control is nowhere never dims (the lord is
## never shut in); a page lying over the game hides the guide unless the
## control is in it; and a guide the server has ended takes itself away.
##
## Run: godot --headless --path client --script tests/guide_overlay.gd

var _fails := 0
var _checked := 0
var _gs: Node
var _targets: GDScript
var _guide_script: GDScript


func _initialize() -> void:
	await process_frame
	_gs = root.get_node("GameState")
	_targets = load("res://scripts/ui/guide_targets.gd")
	_guide_script = load("res://scripts/ui/guide.gd")
	if _targets == null or _guide_script == null or not FileAccess.file_exists("res://layout/guide.json"):
		_fail("the guide is missing (scripts/ui/guide.gd, layout/guide.json)")
		_done()
		return
	for h in [1672.0, 2040.0]:
		await _canvas(h)
	_done()


func _canvas(h: float) -> void:
	var tag := "941x%d" % int(h)
	var vp := SubViewport.new()
	vp.size = Vector2i(941, int(h))
	root.add_child(vp)
	root.get_node("Nav").set("host", vp)
	var game := Control.new()
	game.size = Vector2(941, h)
	vp.add_child(game)
	_targets.call("clear")
	# Collect's first COLLECT, where collect.png has it, and the rail's entries.
	var collect := _button(game, Rect2(732, 530, 178, 71))
	_targets.call("register", "collect.job0", collect)
	var rails := {}
	for i in 8:
		var id: String = ["family", "collect", "inventory", "shop", "army", "attack", "kingdom", "court"][i]
		rails[id] = _button(game, Rect2(0, 216 + 157 * i, 156, 157))
		_targets.call("register", "rail." + id, rails[id])
	var steps := _balance_steps()

	# A deed step on Collect: the spotlight on COLLECT.
	_state(1, _step(steps, "first_collect"))
	var g: CanvasLayer = _guide_script.call("start", null)
	await _settle()
	_expect(g != null and g.is_inside_tree(), "%s: the guide starts for an active step" % tag)
	_spotlit(g, collect, tag + " first_collect")
	_expect(_label(g, "title").text == str(_step(steps, "first_collect").get("title", "")), "%s: the step's title" % tag)
	_expect(_label(g, "body").text == str(_step(steps, "first_collect").get("text", "")), "%s: the step's words" % tag)
	var speech: Control = g.get("_speech")
	_expect(speech.position.y > h / 2.0, "%s: COLLECT is high, so the scroll is low (y %d)" % [tag, int(speech.position.y)])
	_expect(_shown(g, "steward_r") and not _shown(g, "steward_l"), "%s: COLLECT is right, so the steward stands left looking right" % tag)
	_expect(_shown(g, "skip_r") and not _shown(g, "skip_l"), "%s: SKIP stands at the scroll's other end" % tag)
	var dim: Control = g.get("_dim")
	var mid := collect.get_global_rect().get_center()
	_expect(not dim.call("_has_point", mid), "%s: a tap on COLLECT goes through the dim" % tag)
	_expect(dim.call("_has_point", Vector2(400, 300)), "%s: a tap beside it is the dim's" % tag)
	_expect(not (g.get("_hint") as Control).visible, "%s: a deed step does not ask for a tap" % tag)
	_on_screen(g, tag + " first_collect")

	# The deed done: the steward's words, the whole screen waiting on a tap.
	var done := _step(steps, "first_collect").duplicate()
	done["ready"] = true
	_state(1, done)
	await _settle()
	_expect(_label(g, "body").text == str(done.get("done", "")), "%s: a done step says the steward's done words" % tag)
	_expect(dim.visible and (dim.get("hole") as Rect2).size == Vector2.ZERO, "%s: a done step dims the whole screen" % tag)
	_expect((g.get("_hint") as Control).visible, "%s: a done step says TAP TO CONTINUE" % tag)
	_expect(not _pointer_shown(g), "%s: a done step has no gauntlet" % tag)

	# The welcome: a tap step, the story card over the steward.
	_state(1, _step(steps, "welcome"))
	await _settle()
	_expect((g.get("_story") as Control).visible, "%s: the welcome shows the story card" % tag)
	var story: Control = g.get("_story")
	var steward: Control = (g.get("_parts") as Dictionary)["steward_r"]
	_expect(story.position.y + story.size.y <= speech.position.y + steward.position.y,
		"%s: the story card clears the steward's head" % tag)
	_expect(story.position.y >= 100.0, "%s: the story card clears the pills" % tag)
	_expect((g.get("_hint") as Control).visible and not _pointer_shown(g), "%s: a tap step waits on a tap, no gauntlet" % tag)
	_fits(g, str(_step(steps, "welcome").get("text", "")), tag + " welcome")

	# Every step's words fit the parchment at a size that reads.
	for s in steps:
		for key in ["text", "done"]:
			_fits(g, str(s.get(key, "")), "%s %s.%s" % [tag, s.get("id", ""), key])

	# Karel's fight ends his step on the server: his done words stay on the
	# scroll over the next step until a tap, then the next step's own.
	_state(5, _step(steps, "farewell"))
	_guide_script.call("hold_done", _step(steps, "bandit"))
	await _settle()
	_expect(_label(g, "body").text == str(_step(steps, "bandit").get("done", "")),
		"%s: after the fight the bandit's done words are held (%s)" % [tag, _label(g, "body").text])
	g.call("_continue")
	await _settle()
	_expect(_label(g, "body").text == str(_step(steps, "farewell").get("text", "")),
		"%s: a tap moves on to the farewell's words" % tag)

	# Below the step's level: the level beside the title, the gauntlet on COLLECT.
	_state(3, _step(steps, "upgrade"))
	await _settle()
	_expect(_label(g, "level").text == "LEVEL 3 OF 4", "%s: a step waiting on level four says so (%s)" % [tag, _label(g, "level").text])
	_expect(g.get("_target") == collect, "%s: below its level a step points at Collect's first job" % tag)

	# At its level, its control not built yet: the arrow on the Family's rail entry.
	_state(4, _step(steps, "upgrade"))
	await _settle()
	_expect(_label(g, "level").text == "", "%s: at its level the step says nothing of levels" % tag)
	_expect(g.get("_target") == rails["family"], "%s: its control not on screen, the Family's rail entry" % tag)
	_expect((g.get("_arrow") as Control).visible and not (g.get("_hand") as Control).visible
		and not (g.get("_press") as Control).visible, "%s: the way there gets the arrow, not the gauntlet" % tag)
	_expect(_shown(g, "steward_l"), "%s: a rail entry is left, so the steward stands right" % tag)
	var arrow: TextureRect = g.get("_arrow")
	var rail: Rect2 = (rails["family"] as Control).get_global_rect()
	var tip: Vector2 = g.get("_arrow_tip")
	var at := arrow.position + (Vector2(arrow.size.x - tip.x, tip.y) if arrow.flip_h else tip)
	_expect(rail.grow(12).has_point(at), "%s: the arrow's tip is on the Family entry (%s in %s)" % [tag, at, rail])

	# A control low on the screen: the scroll goes high, under the notch.
	var low := _button(game, Rect2(300, h - 300, 300, 90))
	_targets.call("register", "family.estates", low)
	await _settle()
	_spotlit(g, low, tag + " a low control")
	_expect(speech.position.y + 208.0 < low.get_global_rect().position.y, "%s: the scroll goes high over a low control" % tag)
	_on_screen(g, tag + " a low control")

	# A page over the game hides the guide; one with the control in it does not.
	var page := CanvasLayer.new()
	page.layer = 60
	vp.add_child(page)
	var sheet := Control.new()
	sheet.size = Vector2(941, h)
	page.add_child(sheet)
	await _settle()
	_expect(not (g.get("_root") as Control).visible, "%s: a page over the game hides the guide" % tag)
	var claim := _button(sheet, Rect2(264, 1482, 410, 112))
	_targets.call("register", "daily.claim", claim)
	_state(2, _step(steps, "daily"))
	await _settle()
	_expect((g.get("_root") as Control).visible and g.get("_target") == claim,
		"%s: the day's page with its CLAIM in it: the guide stands over it on CLAIM" % tag)
	page.queue_free()
	await process_frame

	# Nothing to point at anywhere: no dim at all. (A step whose control is one
	# of a set -- the market's offers, the gear tiles -- asks the server which,
	# and a test has no server.)
	_targets.call("clear")
	_state(5, _step(steps, "recruit"))
	await _settle()
	_expect(not (g.get("_dim") as Control).visible, "%s: with no control anywhere, the guide never dims" % tag)
	_expect(not _pointer_shown(g) and not (g.get("_arrow") as Control).visible, "%s: and points at nothing" % tag)

	# The server ends it: it goes.
	_gs.set("snapshot", {"player": {"level": 5, "action_seq": 1}, "guide": {"active": false}})
	_gs.emit_signal("changed")
	await _settle()
	_expect(not is_instance_valid(g) or not g.is_inside_tree(), "%s: an ended guide takes itself away" % tag)
	root.get_node("Nav").set("host", null)
	vp.queue_free()
	await process_frame


func _button(parent: Control, r: Rect2) -> Control:
	var b := Control.new()
	b.position = r.position
	b.size = r.size
	parent.add_child(b)
	return b


func _state(level: int, step: Dictionary) -> void:
	var g := step.duplicate()
	g["active"] = true
	g["step"] = str(step.get("id", ""))
	g["tap"] = str(step.get("kind", "")) == "tap"
	_gs.set("snapshot", {"player": {"level": level, "action_seq": 1, "avatar": "knight"}, "guide": g})
	_gs.emit_signal("changed")


func _settle() -> void:
	# The guide looks for its control four times a second.
	await create_timer(0.35).timeout
	await process_frame
	await process_frame


func _spotlit(g: CanvasLayer, c: Control, tag: String) -> void:
	_expect(g.get("_target") == c, "%s: the guide found its control" % tag)
	var hole: Rect2 = (g.get("_dim") as Control).get("hole")
	_expect(hole.encloses(c.get_global_rect()), "%s: the spotlight rings the control (%s round %s)" % [tag, hole, c.get_global_rect()])
	var hand: TextureRect = g.get("_hand")
	var press: TextureRect = g.get("_press")
	var shown: TextureRect = hand if hand.visible else press
	_expect(hand.visible != press.visible, "%s: one gauntlet pose at a time" % tag)
	var tip: Vector2 = g.get("_hand_tip") if shown == hand else g.get("_press_tip")
	var at := shown.position + Vector2(shown.size.x - tip.x if shown.flip_h else tip.x, shown.size.y - tip.y if shown.flip_v else tip.y)
	_expect(c.get_global_rect().grow(float(_guide_script.get_script_constant_map()["HOVER"]) + 2.0).has_point(at),
		"%s: the fingertip is on the control (%s in %s)" % [tag, at, c.get_global_rect()])


## Nothing the guide draws runs off the canvas.
func _on_screen(g: CanvasLayer, tag: String) -> void:
	var canvas := (g.get("_root") as Control).size
	var screen := Rect2(Vector2.ZERO, canvas)
	for n in ["_hand", "_press", "_arrow"]:
		var t: Control = g.get(n)
		if t.visible:
			_expect(screen.encloses(Rect2(t.position, t.size)), "%s: %s stays on the canvas (%s)" % [tag, n, Rect2(t.position, t.size)])
	var speech: Control = g.get("_speech")
	var parts: Dictionary = g.get("_parts")
	for id in ["scroll", "steward_r", "steward_l", "skip_r", "skip_l"]:
		var p: Control = parts[id]
		if p.visible:
			var r := Rect2(speech.position + p.position, p.size)
			_expect(screen.encloses(r), "%s: %s stays on the canvas (%s)" % [tag, id, r])


func _fits(g: CanvasLayer, words: String, tag: String) -> void:
	if words == "":
		return
	var body := _label(g, "body")
	var box: Rect2 = g.get("_body_box")
	var font: Font = body.label_settings.font
	var fits_at := 0
	for size in range(24, 19, -1):
		if font.get_multiline_string_size(words, HORIZONTAL_ALIGNMENT_LEFT, box.size.x, size).y <= box.size.y:
			fits_at = size
			break
	_expect(fits_at >= 20, "%s: \"%s\" fits the parchment at 20 or more (%d)" % [tag, words.left(40), fits_at])


func _label(g: CanvasLayer, id: String) -> Label:
	return (g.get("_parts") as Dictionary)[id]


func _shown(g: CanvasLayer, id: String) -> bool:
	return ((g.get("_parts") as Dictionary)[id] as CanvasItem).visible


func _pointer_shown(g: CanvasLayer) -> bool:
	return (g.get("_hand") as Control).visible or (g.get("_press") as Control).visible


func _step(steps: Array, id: String) -> Dictionary:
	for s in steps:
		if str(s.get("id", "")) == id:
			return s
	return {"id": id}


func _balance_steps() -> Array:
	var path := ProjectSettings.globalize_path("res://").path_join("../balance/retention.json")
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return []
	var d: Variant = JSON.parse_string(f.get_as_text())
	return (d as Dictionary).get("guide", {}).get("steps", []) if d is Dictionary else []


func _expect(ok: bool, what: String) -> void:
	_checked += 1
	if not ok:
		_fail(what)


func _fail(what: String) -> void:
	_fails += 1
	print("FAIL guide_overlay: " + what)


func _done() -> void:
	if _fails == 0:
		print("PASS guide_overlay: %d checks" % _checked)
	quit(1 if _fails > 0 else 0)
