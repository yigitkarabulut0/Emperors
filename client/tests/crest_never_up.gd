extends SceneTree
## A crest is drawn down to its box, never up.
##
## The twelve crests_sheet shields are cut 182x240 and every crest box was sized
## for them. The Crown of Constancy, the calendar's day-28 crest, was for a day
## its painted 61x79 (before crest_constancy.png): a rival's card stretched it
## to 91x120 and the profile's contain fitted it to 200x264 -- three times up, a
## blur. Every crest box now goes through Look.paint_crest: a crest smaller
## than its box is drawn 1:1 and centred, a larger one drawn down to fit -- so
## no crest, painted or cut small, is ever blown up.
##
## What must hold: the rule itself in the profile's and a card's boxes; on the
## Attack tab's revenge and target cards, a lord wearing the Crown of Constancy
## shows it 1:1 and one wearing a sheet crest shows it inside the box; on the
## profile page, the asker's Crown of Constancy 1:1, and a sheet crest never
## past its own 182x240.
##
## Run: godot --headless --path client --script tests/crest_never_up.gd

const SMALL := "icons/crest_constancy"
const SHEET := "icons/crest_dragon"

var _fails := 0
var _checked := 0
var _look: GDScript


func _initialize() -> void:
	await process_frame
	root.get_node("Env").set("api_base_url", "http://127.0.0.1:9")
	_look = load("res://scripts/ui/look.gd")
	_rule()
	await _attack()
	await _profile(SMALL)
	await _profile("")
	if _checked < 10:
		_fail("only %d crest boxes were measured" % _checked)
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d crest boxes draw their crest down to fit, never up" % _checked)
	quit()


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)


func _texture_size(key: String) -> Vector2:
	var t: Texture2D = root.get_node("Art").call("tex", key)
	return t.get_size() if t != null else Vector2.ZERO


## `t`'s crest as drawn: 1:1 when it fits, else drawn down into the box, centred.
func _held(t: TextureRect, what: String) -> void:
	_checked += 1
	if t.texture == null:
		_fail("%s: no crest" % what)
		return
	var src := t.texture.get_size()
	var drawn: Vector2 = _look.call("crest_drawn", t)
	var fits := src.x <= t.size.x + 0.01 and src.y <= t.size.y + 0.01
	if fits and not drawn.is_equal_approx(src):
		_fail("%s: a %s crest in a %s box is drawn %s, not 1:1" % [what, src, t.size, drawn])
	if drawn.x > src.x + 0.01 or drawn.y > src.y + 0.01:
		_fail("%s: the crest is drawn up from %s to %s" % [what, src, drawn])
	if drawn.x > t.size.x + 0.5 or drawn.y > t.size.y + 0.5:
		_fail("%s: the crest (%s) spills out of its %s box" % [what, drawn, t.size])
	if t.stretch_mode == TextureRect.STRETCH_SCALE or t.stretch_mode == TextureRect.STRETCH_KEEP_ASPECT_COVERED:
		_fail("%s: the box stretches its crest" % what)


func _rule() -> void:
	for box in [Vector2(91, 120), Vector2(200, 264), Vector2(40, 52)]:
		for key in [SMALL, SHEET]:
			var t := TextureRect.new()
			t.size = box
			_look.call("paint_crest", t, key)
			_held(t, "paint_crest(%s) in %s" % [key.get_file(), box])
			t.free()


func _attack() -> void:
	root.get_node("GameState").set("snapshot", {"player": {"username": "Aldric", "avatar": "knight", "level": 40,
		"gold": "1", "action_seq": 1}, "energy": {"current": 1, "max": 2}})
	var host := Control.new()
	host.size = Vector2(941, 1672)
	root.add_child(host)
	var tab: Control = (load("res://scenes/tabs/attack.gd") as GDScript).new()
	tab.set_anchors_preset(Control.PRESET_FULL_RECT)
	host.add_child(tab)
	for i in 3:
		await process_frame
	var lords := [
		{"player_id": "steadfast", "name": "Constance", "avatar": "queen", "level": 30, "worn": {"crest": SMALL}},
		{"player_id": "dragon", "name": "Drago", "avatar": "king", "level": 44, "worn": {"crest": SHEET}},
		{"player_id": "plain", "name": "Aldric", "avatar": "monk", "level": 12},
	]
	tab.set("_data", {"might": 3000, "energy_cost": 11, "revenge": lords, "targets": lords})
	tab.set("_loaded", true)
	for view in ["revenge", "targets"]:
		tab.call("_set_view", view)
		tab.call("_paint")
		await process_frame
		var cards: Array = tab.get("_revenge_cards") if view == "revenge" else tab.get("_targets")
		for i in mini(cards.size(), lords.size()):
			var crest: TextureRect = cards[i]["parts"]["crest"]
			_held(crest, "attack %s card %d (%s)" % [view, i, crest.texture.resource_path.get_file() if crest.texture else "-"])
			if i == 0 and (crest.texture == null or not crest.texture.resource_path.contains(SMALL)):
				_fail("attack %s: the lord wearing the Crown of Constancy shows %s" % [view,
					crest.texture.resource_path if crest.texture else "nothing"])
	host.queue_free()
	await process_frame


func _profile(worn_crest: String) -> void:
	var worn := {"crest": worn_crest} if worn_crest != "" else {}
	root.get_node("GameState").set("snapshot", {"player": {"id": "p1", "username": "Constance", "avatar": "queen",
		"level": 30, "gold": "1", "diamonds": 5, "worn": worn}, "energy": {"current": 1, "max": 2},
		"prices": {"rename_diamonds": 20}})
	var vp := SubViewport.new()
	vp.size = Vector2i(941, 1672)
	root.add_child(vp)
	root.get_node("Nav").set("host", vp)
	var host := Control.new()
	host.size = Vector2(941, 1672)
	vp.add_child(host)
	var p: Control = (load("res://scenes/pages/profile_page.gd") as GDScript).open(host)
	await create_timer(0.3).timeout
	var crest := p.call("node", "crest") as TextureRect
	if crest == null:
		_fail("the profile has no crest box")
	else:
		_held(crest, "profile (%s)" % (worn_crest.get_file() if worn_crest != "" else "no crest worn"))
		if worn_crest != "" and (crest.texture == null or not crest.texture.resource_path.contains(worn_crest)):
			_fail("the profile shows %s, not the worn %s" % [crest.texture.resource_path if crest.texture else "nothing", worn_crest])
	p.call("close")
	await create_timer(0.3).timeout
	vp.queue_free()
	await process_frame
