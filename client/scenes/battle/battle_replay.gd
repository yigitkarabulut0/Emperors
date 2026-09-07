extends CanvasLayer
## Plays back a battle the server already resolved.
##
## Nothing here decides anything: the server simulated once and sent an event
## log, and this draws it blow by blow. Two champions face each other, each
## with one pooled health bar for their whole warband; a hit lands as a damage
## number over the struck side, a death drops that side's standing count.
## Assembled from the cut pieces (portraits, crests, bar segments, buttons).

signal finished

const BLOW_SECONDS := 0.06
const ROUND_PAUSE := 0.25

var _replay: Dictionary = {}
var _result: Dictionary = {}
var _target: Dictionary = {}

var _hp: Dictionary = {}          ## unit id -> hp
var _max_hp: Dictionary = {}
var _side_of: Dictionary = {}     ## unit id -> "a" | "d"
var _pool_max := {"a": 0, "d": 0}
var _alive := {"a": 0, "d": 0}
var _units := {"a": 0, "d": 0}
var _fills: Dictionary = {}       ## side -> fill Control
var _standing: Dictionary = {}    ## side -> Label
var _anchor: Dictionary = {}      ## side -> Vector2 (where floaters rise from)
var _root: Control
var _round_label: Label
var _skip := false
var _done := false
var _floaters: Control


## `result` is the /v1/attack response (or a stored battle: then it IS the replay).
func setup(result: Dictionary, target: Dictionary = {}) -> void:
	_result = result
	_target = target
	_replay = result if result.has("events") else result.get("replay", {})


func _ready() -> void:
	layer = 90
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_root)
	var dim := ColorRect.new()
	dim.color = Color(UI.GROUND.r, UI.GROUND.g, UI.GROUND.b, 0.97)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(dim)

	var title := UI.label("BATTLE", 64, UI.GOLD, "title", 700, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(title, Rect2(0, 120, 941, 90))
	_root.add_child(title)
	_round_label = UI.label("", 28, UI.DIM, "body", 500, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(_round_label, Rect2(0, 215, 941, 40))
	_root.add_child(_round_label)

	var fa := int(_replay.get("fortune_a_bp", 10000)) / 100
	var fd := int(_replay.get("fortune_d_bp", 10000)) / 100
	var fortune := UI.label("Fortune of War  %d%%  ·  %d%%" % [fa, fd], 24, UI.GOLD_DIM, "body", 500, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(fortune, Rect2(0, 258, 941, 34))
	_root.add_child(fortune)

	_side_block(_replay.get("attacker", {}), "a", 120, "chrome/avatar", int(_replay.get("attacker_might", 0)))
	_side_block(_replay.get("defender", {}), "d", 560, _portrait_for(_replay.get("defender", {})), int(_replay.get("defender_might", 0)))

	var vs := UI.label("VS", 54, UI.RED, "title", 800, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(vs, Rect2(420, 420, 100, 80))
	_root.add_child(vs)

	_floaters = Control.new()
	_floaters.set_anchors_preset(Control.PRESET_FULL_RECT)
	_floaters.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_floaters)

	var skip := UI.tex_button("family/btn_upgrade_plate", Rect2(307, 1440, 326, 90))
	skip.pressed.connect(func() -> void: _skip = true)
	_root.add_child(skip)
	var skip_label := UI.label("SKIP", 28, UI.INK, "title", 700, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(skip_label, Rect2(307, 1440, 326, 90))
	skip_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(skip_label)
	_play.call_deferred()


func _portrait_for(army: Dictionary) -> String:
	var names := ["portraits/rival_darius", "portraits/rival_seraphine", "portraits/rival_keldric", "portraits/rival_malric"]
	return names[absi(str(army.get("player_id", army.get("name", ""))).hash()) % names.size()]


func _side_block(army: Dictionary, side: String, x: float, portrait: String, might: int) -> void:
	var accent := UI.GREEN if side == "a" else UI.RED
	var box := Control.new()
	UI.place(box, Rect2(x, 320, 260, 420))
	_root.add_child(box)
	var tex: Texture2D = Art.tex(portrait)
	var face := UI.image(portrait, Rect2(0, 0, tex.get_width(), tex.get_height()))
	face.position = Vector2(130 - tex.get_width() / 2.0, 0)
	box.add_child(face)
	var top_after := tex.get_height() + 12
	var name := UI.label(str(army.get("name", "")).to_upper(), 26, UI.INK, "title", 700, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(name, Rect2(-20, top_after, 300, 34))
	UI.fit_label(name, 26, 16)
	box.add_child(name)
	var m := UI.label("Might %s" % UI.grouped(might), 22, accent, "body", 600, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(m, Rect2(0, top_after + 36, 260, 30))
	box.add_child(m)

	# Pooled health: the painting's bar track with the green or red segment as fill.
	var track := UI.image("family/xp_track", Rect2(0, top_after + 74, 260, 24))
	box.add_child(track)
	var wrap := Control.new()
	UI.place(wrap, Rect2(4, top_after + 77, 252, 18))
	wrap.clip_contents = true
	wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var fill := UI.image("attack/bar_green" if side == "a" else "attack/bar_red", Rect2(0, -4, 252, 26))
	wrap.add_child(fill)
	wrap.set_meta("full", Vector2(252, 18))
	box.add_child(wrap)
	_fills[side] = wrap

	var units: Array = army.get("units", [])
	var pool := 0
	for u in units:
		var id := str(u.get("id", ""))
		var hp := maxi(int(u.get("hp", 1)), 1)
		_hp[id] = hp
		_max_hp[id] = hp
		_side_of[id] = side
		pool += hp
	_pool_max[side] = maxi(pool, 1)
	_alive[side] = units.size()
	_units[side] = units.size()
	var standing := UI.label("", 22, UI.DIM, "body", 500, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(standing, Rect2(0, top_after + 108, 260, 30))
	box.add_child(standing)
	_standing[side] = standing
	_paint_side(side)
	_anchor[side] = Vector2(x + 130, 320 + tex.get_height() / 2.0)


func _paint_side(side: String) -> void:
	var total := 0
	for id in _hp:
		if _side_of[id] == side:
			total += maxi(int(_hp[id]), 0)
	Layout.set_fill(_fills[side], float(total) / float(_pool_max[side]))
	_standing[side].text = "%d of %d standing" % [_alive[side], _units[side]]


func _play() -> void:
	var events: Array = _replay.get("events", [])
	var last_round := 0
	for e in events:
		if _done:
			return
		var r := int(e.get("r", 0))
		if r != last_round:
			last_round = r
			_round_label.text = "Round %d" % r
			if not _skip:
				await get_tree().create_timer(ROUND_PAUSE).timeout
		var dst := str(e.get("dst", ""))
		match str(e.get("k", "")):
			"hit":
				_float(dst, ("-%d" % int(e.get("dmg", 0))) + ("!" if bool(e.get("crit", false)) else ""), UI.INK if not bool(e.get("crit", false)) else UI.GOLD)
				if not _skip:
					await get_tree().create_timer(BLOW_SECONDS).timeout
			"miss":
				_float(dst, "miss", UI.DIM)
				if not _skip:
					await get_tree().create_timer(BLOW_SECONDS).timeout
			"hp":
				_hp[dst] = int(e.get("hp", 0))
				if _side_of.has(dst):
					_paint_side(_side_of[dst])
			"dead", "death", "kill":
				_hp[dst] = 0
				if _side_of.has(dst):
					_alive[_side_of[dst]] = maxi(0, _alive[_side_of[dst]] - 1)
					_paint_side(_side_of[dst])
					_float(dst, "fallen", UI.RED)
	_finish()


func _float(unit_id: String, text: String, color: Color) -> void:
	if _skip or not _side_of.has(unit_id):
		return
	var side: String = _side_of[unit_id]
	var l := UI.label(text, 34, color, "body", 700, HORIZONTAL_ALIGNMENT_CENTER)
	var at: Vector2 = _anchor[side]
	UI.place(l, Rect2(at.x - 80 + randf_range(-30, 30), at.y - 20, 160, 44))
	_floaters.add_child(l)
	var tw := create_tween()
	tw.tween_property(l, "position:y", l.position.y - 90, 0.7)
	tw.parallel().tween_property(l, "modulate:a", 0.0, 0.7)
	tw.tween_callback(l.queue_free)


func _finish() -> void:
	if _done:
		return
	_done = true
	var won: bool = bool(_result.get("won", str(_replay.get("winner", "")) == "a"))
	var plate := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color("#0E1A26")
	sb.border_color = UI.GOLD_DIM if won else UI.RED
	sb.set_border_width_all(3)
	sb.set_corner_radius_all(8)
	sb.set_content_margin_all(28)
	plate.add_theme_stylebox_override("panel", sb)
	UI.place(plate, Rect2(170, 880, 600, 0))
	_root.add_child(plate)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	plate.add_child(col)
	col.add_child(UI.label("VICTORY" if won else "DEFEAT", 48, UI.GOLD if won else UI.RED, "title", 800, HORIZONTAL_ALIGNMENT_CENTER))
	col.add_child(UI.label("%d rounds" % int(_replay.get("rounds", 0)), 24, UI.DIM, "body", 500, HORIZONTAL_ALIGNMENT_CENTER))
	var gold := int(str(_result.get("gold_stolen", _result.get("gold", "0"))))
	if gold > 0:
		col.add_child(UI.label("+%s gold" % UI.grouped(gold), 30, UI.GOLD, "body", 700, HORIZONTAL_ALIGNMENT_CENTER))
	var xp := int(_result.get("xp_gained", 0))
	if xp > 0:
		col.add_child(UI.label("+%d experience" % xp, 26, UI.INK, "body", 600, HORIZONTAL_ALIGNMENT_CENTER))
	var btn := UI.tex_button("family/btn_upgrade_plate", Rect2(0, 0, 326, 90))
	btn.custom_minimum_size = Vector2(326, 90)
	var wrap := CenterContainer.new()
	wrap.add_child(btn)
	col.add_child(wrap)
	var lab := UI.label("CONTINUE", 28, UI.INK, "title", 700, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(lab, Rect2(0, 0, 326, 90))
	lab.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(lab)
	btn.pressed.connect(func() -> void:
		finished.emit()
		queue_free())
