extends CanvasLayer
## Plays back a battle the server already resolved.
##
## Nothing here decides anything: the server simulated once and sent an event
## log, and this draws it blow by blow.
##
## Two champions, one blow each per round, the attacker first. That is what the
## server sends now -- a side's whole strength lands in one swing rather than
## ten units taking turns -- and it is what this screen is built to show: two
## faces, two health bars, and one damage number at a time, big enough to be the
## event it is. The old screen animated a stream of small numbers over a row of
## portraits with a "4 of 5 standing" line under each, which read as a
## spreadsheet settling rather than a fight.
##
## Assembled from the cut pieces: the banners and castle out of the Attack
## painting for the horizon, the painted portraits, the reference's own bar
## segments, and the plate buttons.

signal finished

const ROUND_PAUSE := 0.40      ## between rounds: long enough to read the blow
const BLOW_PAUSE := 0.55       ## after a hit lands
const DRAIN := 0.32            ## how long a bar takes to fall

## The design grid, and where the pieces sit on it.
const W := 941.0
const PORTRAIT := Rect2(0, 0, 300, 300)
const LEFT_X := 78.0
const RIGHT_X := 563.0
const FACE_Y := 360.0
const BAR_Y := 700.0
const THEATRE_Y := 820.0

var _replay: Dictionary = {}
var _result: Dictionary = {}
var _target: Dictionary = {}

var _hp := {"a": 0, "d": 0}
var _max := {"a": 1, "d": 1}
var _id_side: Dictionary = {}
var _fill: Dictionary = {}
var _hp_text: Dictionary = {}
var _face: Dictionary = {}
var _root: Control
var _floaters: Control
var _round_label: Label
var _callout: Label
var _skip_button: Button
var _skip := false
var _done := false


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

	var ground := ColorRect.new()
	ground.color = Color(UI.GROUND.r, UI.GROUND.g, UI.GROUND.b, 0.985)
	ground.set_anchors_preset(Control.PRESET_FULL_RECT)
	ground.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(ground)

	# The champions stand in front of the army the Attack painting shows.
	var horizon := UI.image("battle/horizon", Rect2(0, 236, W, 190))
	horizon.modulate = Color(1, 1, 1, 0.5)
	_root.add_child(horizon)
	var veil := TextureRect.new()
	veil.texture = _fade()
	UI.place(veil, Rect2(0, 306, W, 120))
	veil.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(veil)

	var title := UI.label("BATTLE", 72, UI.GOLD, "title", 700, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(title, Rect2(0, 96, W, 96))
	_root.add_child(title)
	_round_label = UI.label("", 30, UI.DIM, "title", 500, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(_round_label, Rect2(0, 190, W, 44))
	_root.add_child(_round_label)

	_side(_replay.get("attacker", {}), "a", LEFT_X, "portraits/hero_throne",
		int(_replay.get("attacker_might", 0)))
	_side(_replay.get("defender", {}), "d", RIGHT_X, _portrait_for(_replay.get("defender", {})),
		int(_replay.get("defender_might", 0)))

	var swords := UI.label("⚔", 66, UI.GOLD_DIM, "body", 500, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(swords, Rect2(W / 2.0 - 60, FACE_Y + 96, 120, 90))
	_root.add_child(swords)

	# Where the blow is announced: one number at a time, in the middle, big.
	_callout = UI.label("", 96, UI.INK, "title", 800, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(_callout, Rect2(0, THEATRE_Y, W, 130))
	_callout.modulate.a = 0.0
	_root.add_child(_callout)

	_floaters = Control.new()
	_floaters.set_anchors_preset(Control.PRESET_FULL_RECT)
	_floaters.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_floaters)

	var fa := int(_replay.get("fortune_a_bp", 10000)) / 100
	var fd := int(_replay.get("fortune_d_bp", 10000)) / 100
	var fortune := UI.label("Fortune of War   %d%%  ·  %d%%" % [fa, fd], 24, UI.GOLD_DIM,
		"body", 500, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(fortune, Rect2(0, 1000, W, 34))
	_root.add_child(fortune)

	_skip_button = _plate_button("SKIP", "inventory/btn_sell_plate", UI.DIM,
		Rect2(W / 2.0 - 170, 1440, 340, 96))
	_skip_button.pressed.connect(func() -> void: _skip = true)
	_root.add_child(_skip_button)
	_play.call_deferred()


func _fade() -> Texture2D:
	var g := Gradient.new()
	g.set_color(0, Color(UI.GROUND, 0.0))
	g.set_color(1, Color(UI.GROUND, 1.0))
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill_from = Vector2(0, 0)
	t.fill_to = Vector2(0, 1)
	t.width = 8
	t.height = 128
	return t


func _plate_button(word: String, plate: String, col: Color, rect: Rect2) -> Button:
	var b := UI.plate_face(plate, 16)
	b.text = word
	b.add_theme_font_override("font", UI.font("title", 700))
	b.add_theme_font_size_override("font_size", 30)
	for c in ["font_color", "font_hover_color", "font_pressed_color"]:
		b.add_theme_color_override(c, col)
	b.add_theme_constant_override("outline_size", 0)
	UI.place(b, rect)
	return b


func _portrait_for(army: Dictionary) -> String:
	var names := ["portraits/rival_darius", "portraits/lord_aldric",
		"portraits/lord_seraphine", "portraits/lord_darian"]
	return names[absi(str(army.get("player_id", army.get("name", ""))).hash()) % names.size()]


## One champion: face, name, might, and the bar that says how it is going.
func _side(army: Dictionary, side: String, x: float, portrait: String, might: int) -> void:
	var accent := UI.GREEN if side == "a" else UI.RED
	var tex: Texture2D = Art.tex(portrait)
	var frame := Rect2(x, FACE_Y, PORTRAIT.size.x, PORTRAIT.size.y)

	var face := UI.image(portrait, frame)
	face.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	face.clip_contents = true
	_root.add_child(face)
	_face[side] = face
	# The rarity frames are hollow, so one of them makes a border for anything.
	var ring := UI.image("inventory/frame_legendary" if side == "a" else "inventory/frame_special",
		frame)
	_root.add_child(ring)

	var name := UI.label(str(army.get("name", "")).to_upper(), 30, UI.INK, "title", 700,
		HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(name, Rect2(x - 20, FACE_Y + 312, PORTRAIT.size.x + 40, 40))
	UI.fit_label(name, 30, 18)
	_root.add_child(name)

	var m := UI.label("⚔ %s" % UI.grouped(might), 26, accent, "body", 600,
		HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(m, Rect2(x, FACE_Y + 352, PORTRAIT.size.x, 34))
	_root.add_child(m)

	var pool := 0
	for u in army.get("units", []):
		pool += maxi(int(u.get("hp", 0)), 0)
	# The server fights one champion a side; its id is the army's, and its hit
	# points are the roster's added up.
	_id_side[str(army.get("player_id", ""))] = side
	for u in army.get("units", []):
		_id_side[str(u.get("id", ""))] = side
	_max[side] = maxi(pool, 1)
	_hp[side] = _max[side]

	var track := UI.image("family/xp_track", Rect2(x - 20, BAR_Y, PORTRAIT.size.x + 40, 30))
	_root.add_child(track)
	var wrap := Control.new()
	UI.place(wrap, Rect2(x - 15, BAR_Y + 4, PORTRAIT.size.x + 30, 22))
	wrap.clip_contents = true
	wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wrap.add_child(UI.image("attack/bar_green" if side == "a" else "attack/bar_red",
		Rect2(0, -4, PORTRAIT.size.x + 30, 30)))
	wrap.set_meta("full", Vector2(PORTRAIT.size.x + 30, 22))
	_root.add_child(wrap)
	_fill[side] = wrap

	var hp := UI.label("", 24, UI.DIM, "body", 600, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(hp, Rect2(x - 20, BAR_Y + 36, PORTRAIT.size.x + 40, 32))
	_root.add_child(hp)
	_hp_text[side] = hp
	_paint(side)


func _paint(side: String) -> void:
	Layout.set_fill(_fill[side], float(_hp[side]) / float(_max[side]))
	_hp_text[side].text = "%s / %s" % [UI.grouped(_hp[side]), UI.grouped(_max[side])]


func _play() -> void:
	for e in _replay.get("events", []):
		if _done:
			return
		var side := str(e.get("s", ""))
		var dst := str(e.get("dst", ""))
		match str(e.get("k", "")):
			"round":
				_round_label.text = "ROUND %d" % int(e.get("r", 0))
				await _wait(ROUND_PAUSE)
			"hit":
				var crit := bool(e.get("crit", false))
				_strike(side, int(e.get("dmg", 0)), crit)
				await _wait(BLOW_PAUSE)
			"dodge", "miss":
				_say("DODGED", UI.DIM)
				_lunge(side)
				await _wait(BLOW_PAUSE * 0.7)
			"hp":
				var s := str(_id_side.get(dst, ""))
				if s != "":
					_hp[s] = maxi(int(e.get("hp", 0)), 0)
					_drain(s)
			"death", "dead", "kill":
				var s2 := str(_id_side.get(dst, ""))
				if s2 != "":
					_hp[s2] = 0
					_drain(s2)
					_fall(s2)
					await _wait(0.5)
	_finish()


func _wait(seconds: float) -> void:
	if _skip:
		return
	await get_tree().create_timer(seconds).timeout


## One blow: the striker lunges, the struck side flashes and the number lands.
func _strike(side: String, damage: int, crit: bool) -> void:
	var hit := "d" if side == "a" else "a"
	_lunge(side)
	_flash(hit, UI.RED if crit else Color(1, 1, 1))
	_say(("%s%s" % [UI.grouped(damage), "!" if crit else ""]), UI.GOLD if crit else UI.INK,
		112 if crit else 92)
	if crit:
		_shake()


## The number is the event, so it arrives in the middle at full size and leaves.
func _say(text: String, col: Color, size: int = 92) -> void:
	if _skip:
		return
	_callout.text = text
	_callout.label_settings.font_color = col
	_callout.label_settings.font_size = size
	_callout.modulate.a = 1.0
	_callout.scale = Vector2(0.7, 0.7)
	_callout.pivot_offset = Vector2(W / 2.0, 65)
	var tw := create_tween()
	tw.tween_property(_callout, "scale", Vector2.ONE, 0.14).set_trans(Tween.TRANS_BACK) \
		.set_ease(Tween.EASE_OUT)
	tw.tween_interval(0.22)
	tw.tween_property(_callout, "modulate:a", 0.0, 0.2)


func _lunge(side: String) -> void:
	if _skip or not _face.has(side):
		return
	var face: Control = _face[side]
	var home := face.position
	var tw := create_tween()
	tw.tween_property(face, "position:x", home.x + (34.0 if side == "a" else -34.0), 0.1) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(face, "position:x", home.x, 0.22).set_trans(Tween.TRANS_QUAD)


func _flash(side: String, col: Color) -> void:
	if _skip or not _face.has(side):
		return
	var face: Control = _face[side]
	face.modulate = col
	var tw := create_tween()
	tw.tween_property(face, "modulate", Color.WHITE, 0.3)


func _shake() -> void:
	if _skip:
		return
	var home := _root.position
	var tw := create_tween()
	for i in 3:
		tw.tween_property(_root, "position", home + Vector2(randf_range(-9, 9), randf_range(-6, 6)), 0.04)
	tw.tween_property(_root, "position", home, 0.05)


func _drain(side: String) -> void:
	if _skip:
		_paint(side)
		return
	var wrap: Control = _fill[side]
	var full: Vector2 = wrap.get_meta("full")
	var want := full.x * clampf(float(_hp[side]) / float(_max[side]), 0.0, 1.0)
	_hp_text[side].text = "%s / %s" % [UI.grouped(_hp[side]), UI.grouped(_max[side])]
	wrap.visible = want >= 1.0
	var tw := create_tween()
	tw.tween_property(wrap, "size:x", maxf(want, 1.0), DRAIN).set_trans(Tween.TRANS_CUBIC)


func _fall(side: String) -> void:
	if not _face.has(side):
		return
	var face: Control = _face[side]
	var tw := create_tween()
	tw.tween_property(face, "modulate", Color(0.35, 0.3, 0.3, 0.65), 0.45)


func _finish() -> void:
	if _done:
		return
	_done = true
	for side in ["a", "d"]:
		_paint(side)
	_skip_button.visible = false
	var won: bool = bool(_result.get("won", str(_replay.get("winner", "")) == "a"))

	var plate := NinePatchRect.new()
	plate.texture = Art.tex("inventory/card_frame")
	for m in ["left", "top", "right", "bottom"]:
		plate.set("patch_margin_" + m, 26)
	UI.place(plate, Rect2(130, 1060, 681, 330))
	_root.add_child(plate)

	var head := UI.label("VICTORY" if won else "DEFEAT", 62, UI.GOLD if won else UI.RED,
		"title", 800, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(head, Rect2(130, 1090, 681, 80))
	_root.add_child(head)
	var rounds := UI.label("%d rounds%s" % [int(_replay.get("rounds", 0)),
		"  ·  ran out of time" if bool(_replay.get("timed_out", false)) else ""],
		24, UI.DIM, "body", 500, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(rounds, Rect2(130, 1170, 681, 34))
	_root.add_child(rounds)

	var spoils: Array = []
	var gold := int(str(_result.get("gold_stolen", _result.get("gold", "0"))))
	if gold > 0:
		spoils.append(["+%s gold" % UI.grouped(gold), UI.GOLD])
	var xp := int(_result.get("xp_gained", 0))
	if xp > 0:
		spoils.append(["+%s experience" % UI.grouped(xp), UI.INK])
	var ransom := int(str(_result.get("ransom_paid", "0")))
	if ransom > 0:
		spoils.append(["+%s ransom" % UI.grouped(ransom), UI.GOLD_DIM])
	if spoils.is_empty():
		spoils.append(["No spoils" if not won else "The field is yours", UI.DIM])
	for i in spoils.size():
		var row: Array = spoils[i]
		var l := UI.label(str(row[0]), 30, row[1], "body", 700, HORIZONTAL_ALIGNMENT_CENTER)
		UI.place(l, Rect2(130, 1216 + i * 40, 681, 38))
		_root.add_child(l)

	var go := _plate_button("CONTINUE", "shop/buy_plate" if won else "inventory/btn_sell_plate",
		Color("#F3FBF3") if won else UI.INK, Rect2(W / 2.0 - 170, 1440, 340, 96))
	go.pressed.connect(func() -> void:
		finished.emit()
		queue_free())
	_root.add_child(go)
