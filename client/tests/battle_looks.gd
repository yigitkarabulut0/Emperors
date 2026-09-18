extends SceneTree
## The battle names its two lords as every screen names a lord.
##
## The replay set each name in plain ivory capitals, so a lord who wears a
## colour and Royal Favour's seal on the rankings, the raid cards and the
## battle history was an unmarked name in the fight itself. Both plates now go
## through Look.paint_name: the player's own look from their snapshot, the
## other lord's from what opened the replay (`target.look`).
##
## - The other lord's name is in the colour they wear, with the seal beside it
##   when they have one, and plain with no seal when they wear nothing.
## - The player's own name wears their own colour and seal.
## - The longest names -- sixteen of the widest letter -- stay whole, seal and
##   all, inside the name plate, at both canvases and under the notch.
##
## Run: godot --headless --path client --script tests/battle_looks.gd

const LONG := "Wwwwwwwwwwwwwwww"
const MINE := "#8FB8FF"
const THEIRS := "#E8C46A"

var _fails := 0
var _checked := 0


func _initialize() -> void:
	await process_frame
	root.get_node("Env").set("api_base_url", "http://127.0.0.1:9")
	root.get_node("GameState").set("snapshot", {"player": {"username": LONG, "level": 30, "gold": "1",
		"action_seq": 1, "worn": {"color": MINE}, "vip_seal": true}, "energy": {"current": 1, "max": 2}})
	for c in [[Vector2(941, 1672), 0.0], [Vector2(941, 2040), 141.0]]:
		await _case(c[0], c[1], {"worn": {"color": THEIRS}, "vip_seal": true}, true)
		await _case(c[0], c[1], {}, false)
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d checks: the battle names both lords in the looks they wear" % _checked)
	quit()


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)


func _result() -> Dictionary:
	return {"v": 2, "rounds": 1, "winner": "a", "fortune_a_bp": 10000, "fortune_d_bp": 10000,
		"attacker_might": 9999, "defender_might": 3006,
		"attacker": {"player_id": "A", "name": LONG, "avatar": "knight", "units": [{"id": "A", "hp": 9000}]},
		"defender": {"player_id": "D", "name": "Mmmmmmmmmmmmmmmm", "avatar": "queen", "units": [{"id": "D", "hp": 8000}]},
		"events": [{"r": 1, "k": "round"}]}


func _case(canvas: Vector2, inset: float, look: Dictionary, sealed: bool) -> void:
	var tag := "%dx%d/%d %s" % [int(canvas.x), int(canvas.y), int(inset), "sealed" if sealed else "plain"]
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.size = Vector2i(int(canvas.x), int(canvas.y))
	var host := Control.new()
	host.size = canvas
	root.add_child(host)
	var screen: CanvasLayer = load("res://scenes/battle/battle_replay.gd").new()
	var target := {"name": "Mmmmmmmmmmmmmmmm", "avatar": "queen"}
	if not look.is_empty():
		target["look"] = look
	screen.setup(_result(), target)
	screen.set("top_inset", inset)
	host.add_child(screen)
	for i in 3:
		await process_frame
	var ui: Dictionary = screen.get("_ui")
	_checked += 1
	_name(ui["name_them"], "name_them", "the other lord " + tag, Color(THEIRS) if sealed else Color("#F1E9DA"), sealed)
	_name(ui["name_you"], "name_you", "the player " + tag, Color(MINE), true)
	screen.queue_free()
	host.queue_free()
	await process_frame


func _name(l: Label, part: String, tag: String, colour: Color, sealed: bool) -> void:
	if not l.label_settings.font_color.is_equal_approx(colour):
		_fail("%s is %s, want %s" % [tag, l.label_settings.font_color.to_html(false), colour.to_html(false)])
	var seal: TextureRect = l.get_meta("look_seal") if l.has_meta("look_seal") else null
	var shown := seal != null and seal.visible
	if shown != sealed:
		_fail("%s %s Royal Favour's seal" % [tag, "shows" if shown else "lacks"])
	var L: GDScript = load("res://scripts/ui/layout.gd")
	var box: Rect2 = L.rect_of(L.element("battle", part))
	var s := l.label_settings
	var words := s.font.get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, s.font_size).x
	# Cut with an ellipsis where the words run past what the label is given.
	if words > l.size.x + 0.5:
		_fail("%s is cut short: \"%s\" is %.0f wide at %d in %.0f" % [tag, l.text, words, s.font_size, l.size.x])
	var end := l.position.x + words
	if shown:
		end = seal.position.x + seal.size.x
	if l.position.x < box.position.x - 0.5 or end > box.end.x + 0.5:
		_fail("%s runs from %.0f to %.0f, outside its plate %.0f..%.0f" % [tag, l.position.x, end, box.position.x, box.end.x])
