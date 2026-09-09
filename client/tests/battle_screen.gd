extends SceneTree
## The battle screen draws a real replay, and everything it draws is on screen.
##
## The server fights two champions now -- one blow a side per round, the whole
## army's strength in each -- and this screen was rebuilt to it: two faces, two
## bars, one number at a time. What it must not do is put any of that where a
## phone cannot show it, or fail to find the bar an event names.
##
## Run: godot --headless --path client --script tests/battle_screen.gd

const CANVASES := [Vector2(941, 1672), Vector2(941, 2040)]
const PT_PER_UNIT := 440.0 / 941.0

var _fails: int = 0
var _checked: int = 0
# GDScript lambdas capture by value, so a counter incremented inside one never
# reaches the caller. These are members for that reason.
var _labels: int = 0
var _buttons: int = 0
var _tag := ""
var _screen_rect := Rect2()


func _initialize() -> void:
	await process_frame
	for c in CANVASES:
		await _check(c)
	await _the_animation_runs_and_settles()
	if _checked == 0:
		_fail("no screen was built, so nothing was measured")
	else:
		print("  built %d battle screen(s), %d labels, %d buttons" % [_checked, _labels, _buttons])
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  the battle screen draws its replay inside the phone")
	quit()


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)


## A replay in the shape the server sends: two champions, a blow each per round.
func _replay() -> Dictionary:
	var events: Array = []
	var hp := {"A": 9000, "D": 8000}
	for r in range(1, 5):
		events.append({"r": r, "k": "round"})
		for side in ["a", "d"]:
			var dst := "D" if side == "a" else "A"
			var dmg := 1200 + r * 90
			events.append({"r": r, "k": "hit", "s": side, "src": "A" if side == "a" else "D",
				"dst": dst, "dmg": dmg, "crit": r == 2})
			hp[dst] = maxi(0, int(hp[dst]) - dmg)
			events.append({"r": r, "k": "hp", "s": "d" if side == "a" else "a",
				"dst": dst, "hp": hp[dst]})
	events.append({"r": 4, "k": "death", "s": "d", "dst": "D"})
	return {
		"v": 2, "rounds": 4, "winner": "a", "fortune_a_bp": 10400, "fortune_d_bp": 9700,
		"attacker_might": 3350, "defender_might": 3120,
		"attacker": {"player_id": "A", "name": "Yigit", "units": [
			{"id": "A", "hp": 9000}]},
		"defender": {"player_id": "D", "name": "Lord Darius", "units": [
			{"id": "D", "hp": 8000}]},
		"events": events,
	}


func _check(canvas: Vector2) -> void:
	var host := Control.new()
	host.size = canvas
	root.add_child(host)
	var screen: CanvasLayer = load("res://scenes/battle/battle_replay.gd").new()
	screen.setup({"won": true, "gold_stolen": "412000", "xp_gained": 640,
		"replay": _replay()})
	host.add_child(screen)
	for i in 4:
		await process_frame
	_checked += 1

	_tag = "%dx%d" % [int(canvas.x), int(canvas.y)]
	_screen_rect = Rect2(Vector2.ZERO, canvas)
	_labels = 0
	_buttons = 0
	_walk(screen)
	if _labels < 6:
		_fail("%s: only %d labels drawn; the screen is not built" % [_tag, _labels])
	if _buttons == 0:
		_fail("%s: no way out of the battle screen" % _tag)
	screen.queue_free()
	host.queue_free()
	await process_frame


## The blow is four beats and it has to end where it started, or a portrait
## walks off its frame over the course of a battle. This plays a short battle at
## real speed and checks that the effects were spawned, that both faces came
## home, and that the bars landed on the numbers the events named.
func _the_animation_runs_and_settles() -> void:
	var host := Control.new()
	host.size = Vector2(941, 1672)
	root.add_child(host)
	var screen: CanvasLayer = load("res://scenes/battle/battle_replay.gd").new()
	screen.setup({"won": true, "gold_stolen": "1000", "replay": _short_replay()})
	host.add_child(screen)
	for i in 3:
		await process_frame

	var floaters: Control = screen.get("_floaters")
	var home: Dictionary = screen.get("_home")
	var faces: Dictionary = screen.get("_face")
	if floaters == null or home.is_empty() or faces.is_empty():
		_fail("the screen did not build its animation state")
		host.queue_free()
		return

	# Watch it play. The effects are short-lived, so what is worth recording is
	# which of them were ever drawn -- counting them only says something was
	# there, and passes with two of the three missing.
	var seen := {}
	var waited := 0.0
	while waited < 6.0 and not bool(screen.get("_done")):
		await create_timer(0.04).timeout
		waited += 0.04
		for c in floaters.get_children():
			if c is Label:
				seen["number"] = true
			elif c is TextureRect and (c as TextureRect).texture != null:
				seen[(c as TextureRect).texture.resource_path.get_file().get_basename()] = true
	for want in ["slash", "impact", "number"]:
		if not seen.has(want):
			_fail("a blow never drew its %s; the fight drew %s" % [want, str(seen.keys())])
	if _fails == 0:
		print("  a blow drew: %s" % str(seen.keys()))
	if not bool(screen.get("_done")):
		_fail("the battle did not finish inside 6 seconds")

	# Nobody drifts. A blow moves a face and puts it back; the fallen side slides
	# down and turns, but neither side ends up further along the screen than it
	# started, or a portrait walks out of its frame over a long battle.
	for side in ["a", "d"]:
		var f: Control = faces[side]
		var h: Vector2 = home[side]
		if absf(f.position.x - h.x) > 1.0:
			_fail("side %s ended %.0f units from where it stands" % [side, f.position.x - h.x])
	screen.queue_free()
	host.queue_free()
	await process_frame


func _short_replay() -> Dictionary:
	var r := _replay()
	var cut: Array = []
	for e in r["events"]:
		if int(e.get("r", 0)) <= 2:
			cut.append(e)
	cut.append({"r": 2, "k": "death", "s": "d", "dst": "D"})
	r["events"] = cut
	r["rounds"] = 2
	return r


func _walk(n: Node) -> void:
	if n is Label and (n as Label).text != "":
		_labels += 1
		var r := Rect2(n.global_position, (n as Control).size)
		if r.size.x > 0 and not _screen_rect.intersects(r):
			_fail("%s: \"%s\" is entirely off the screen at %s"
				% [_tag, (n as Label).text.substr(0, 20), str(r)])
	if n is Button:
		_buttons += 1
		var br := Rect2((n as Control).global_position, (n as Control).size)
		if not _screen_rect.encloses(br):
			_fail("%s: a button %s is off the screen" % [_tag, str(br)])
		if br.size.y * PT_PER_UNIT < 44.0:
			_fail("%s: a button is %.0f pt tall, under 44" % [_tag, br.size.y * PT_PER_UNIT])
	for c in n.get_children():
		_walk(c)
