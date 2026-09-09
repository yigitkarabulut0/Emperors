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

## A blow is four beats: pull back, drive in, land, recover. The numbers are
## what the beats are worth -- the wind-up is slow enough to be read as intent,
## the lunge is the fastest thing on the screen, and the recovery is long enough
## that the next blow does not tread on this one.
const WIND_UP := 0.13
const LUNGE := 0.09
const RECOVER := 0.26
const AFTER_BLOW := 0.30       ## quiet between one blow and the next
const ROUND_PAUSE := 0.55      ## the round card holds for this
const DRAIN := 0.30            ## the bar falls
const GHOST_DRAIN := 0.55      ## the pale bar behind it follows, late
const GHOST_DELAY := 0.16

## The design grid, and where the pieces sit on it.
const W := 941.0
## The rival portraits in the paintings are 136 across and the hero's is 480.
## Drawing both at 300 meant blowing a rival up two and a half times and, for
## the small lord portraits the old list also picked from, four times -- which
## is what made the face opposite look like a smear. 236 is 1.7x the rival art
## and a reduction of the hero's, so both are sharp.
const PORTRAIT := Rect2(0, 0, 236, 236)
const LEFT_X := 112.0
const RIGHT_X := 593.0
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
var _ghost: Dictionary = {}
var _hp_text: Dictionary = {}
var _face: Dictionary = {}
var _home: Dictionary = {}      ## where each face rests, to come back to
var _centre: Dictionary = {}    ## the middle of each face, for effects
var _weapon: Dictionary = {}    ## side -> the painted sword it swings
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
	UI.place(_round_label, Rect2(0, 200, W, 44))
	_root.add_child(_round_label)

	_weapon["a"] = _weapon_for(_replay.get("attacker", {}))
	_weapon["d"] = _weapon_for(_replay.get("defender", {}))
	_side(_replay.get("attacker", {}), "a", LEFT_X, "portraits/hero_throne",
		int(_replay.get("attacker_might", 0)))
	_side(_replay.get("defender", {}), "d", RIGHT_X, _portrait_for(_replay.get("defender", {})),
		int(_replay.get("defender_might", 0)))

	var swords := UI.label("⚔", 66, UI.GOLD_DIM, "body", 500, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(swords, Rect2(W / 2.0 - 60, FACE_Y + PORTRAIT.size.y / 2.0 - 45, 120, 90))
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


## Only the painted rival faces, which are 136 square. The lord portraits the
## old list also drew from are 76x68 -- thumbnails for a kingdom roster, four
## times too small for a face the screen is built around.
func _portrait_for(army: Dictionary) -> String:
	var names := ["portraits/rival_darius", "portraits/rival_seraphine",
		"portraits/rival_keldric", "portraits/rival_malric"]
	return names[absi(str(army.get("player_id", army.get("name", ""))).hash()) % names.size()]


## The sword this side fights with, as the replay recorded it.
func _weapon_for(army: Dictionary) -> String:
	for u in army.get("units", []):
		var w := str(u.get("weapon", ""))
		if w != "":
			return "items/painted/" + w
	return "items/painted/weapon_01"


## One champion: face, name, might, and the bar that says how it is going.
func _side(army: Dictionary, side: String, x: float, portrait: String, might: int) -> void:
	var accent := UI.GREEN if side == "a" else UI.RED
	var tex: Texture2D = Art.tex(portrait)
	var frame := Rect2(x, FACE_Y, PORTRAIT.size.x, PORTRAIT.size.y)

	var face := UI.image(portrait, frame)
	face.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	face.clip_contents = true
	face.pivot_offset = PORTRAIT.size / 2.0
	_root.add_child(face)
	_face[side] = face
	_home[side] = frame.position
	_centre[side] = frame.position + PORTRAIT.size / 2.0
	# The rarity frames are hollow, so one of them makes a border for anything.
	var ring := UI.image("inventory/frame_legendary" if side == "a" else "inventory/frame_special",
		frame)
	_root.add_child(ring)

	var name := UI.label(str(army.get("name", "")).to_upper(), 30, UI.INK, "title", 700,
		HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(name, Rect2(x - 30, FACE_Y + PORTRAIT.size.y + 14, PORTRAIT.size.x + 60, 40))
	UI.fit_label(name, 30, 18)
	_root.add_child(name)

	var m := UI.label("⚔ %s" % UI.grouped(might), 26, accent, "body", 600,
		HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(m, Rect2(x, FACE_Y + PORTRAIT.size.y + 58, PORTRAIT.size.x, 34))
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
	# Two fills, one behind the other. The pale one drains late and slower, so a
	# blow leaves a strip showing exactly what it took -- the oldest trick in
	# fighting games and the only one that makes a number and a bar agree.
	var bar := Rect2(x - 15, BAR_Y + 4, PORTRAIT.size.x + 30, 22)
	var ghost := Control.new()
	UI.place(ghost, bar)
	ghost.clip_contents = true
	ghost.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var gtex := UI.image("attack/bar_green" if side == "a" else "attack/bar_red",
		Rect2(0, -4, bar.size.x, 30))
	gtex.modulate = Color(1.0, 0.85, 0.75, 0.55)
	ghost.add_child(gtex)
	ghost.set_meta("full", bar.size)
	_root.add_child(ghost)
	_ghost[side] = ghost

	var wrap := Control.new()
	UI.place(wrap, bar)
	wrap.clip_contents = true
	wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wrap.add_child(UI.image("attack/bar_green" if side == "a" else "attack/bar_red",
		Rect2(0, -4, bar.size.x, 30)))
	wrap.set_meta("full", bar.size)
	_root.add_child(wrap)
	_fill[side] = wrap

	var hp := UI.label("", 24, UI.DIM, "body", 600, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(hp, Rect2(x - 20, BAR_Y + 36, PORTRAIT.size.x + 40, 32))
	_root.add_child(hp)
	_hp_text[side] = hp
	_paint(side)


func _paint(side: String) -> void:
	Layout.set_fill(_fill[side], float(_hp[side]) / float(_max[side]))
	Layout.set_fill(_ghost[side], float(_hp[side]) / float(_max[side]))
	_hp_text[side].text = "%s / %s" % [UI.grouped(_hp[side]), UI.grouped(_max[side])]


func _play() -> void:
	for e in _replay.get("events", []):
		if _done:
			return
		var side := str(e.get("s", ""))
		var dst := str(e.get("dst", ""))
		match str(e.get("k", "")):
			"round":
				await _round_card(int(e.get("r", 0)))
			"hit":
				await _blow(side, int(e.get("dmg", 0)), bool(e.get("crit", false)))
			"dodge", "miss":
				await _dodge(side)
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
					await _fall(s2)
	_finish()


func _wait(seconds: float) -> void:
	if _skip:
		return
	await get_tree().create_timer(seconds).timeout


## The round announces itself and gets out of the way.
func _round_card(round: int) -> void:
	_round_label.text = "ROUND %d" % round
	if _skip:
		return
	_round_label.modulate.a = 0.0
	_round_label.pivot_offset = Vector2(W / 2.0, 22)
	_round_label.scale = Vector2(1.25, 1.25)
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(_round_label, "modulate:a", 1.0, 0.16)
	tw.tween_property(_round_label, "scale", Vector2.ONE, 0.24).set_trans(Tween.TRANS_BACK) \
		.set_ease(Tween.EASE_OUT)
	await _wait(ROUND_PAUSE)


## One blow, in four beats.
##
## Pull back, drive in, land, recover. The old version slid a portrait 34 units
## and put a number in the middle of the screen, which told you a number had
## happened somewhere; none of it said who hit whom or how hard. Every beat here
## is doing one of those two jobs: the lunge is the striker's, the recoil, the
## flash, the burst, the shake and the bar are the struck side's, and the number
## lands on the face it was taken out of.
func _blow(side: String, damage: int, crit: bool) -> void:
	var hit := "d" if side == "a" else "a"
	if _skip:
		return
	var toward := 1.0 if side == "a" else -1.0
	var face: Control = _face[side]
	var home: Vector2 = _home[side]

	# 1. Wind up: back off the target and rise a little. Intent, made visible.
	var wind := create_tween()
	wind.set_parallel(true)
	wind.tween_property(face, "position:x", home.x - toward * 26.0, WIND_UP) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	wind.tween_property(face, "scale", Vector2(1.05, 1.05), WIND_UP)
	await _wait(WIND_UP)

	# 2. Lunge, and the sword goes with it. The portraits are paintings and
	#    cannot move a limb, so the swing has to be carried by something that
	#    can: the player's own weapon, crossing the gap and arriving at the
	#    moment of contact. This is the motion the animation was missing -- a
	#    portrait sliding back and forth reads as a picture being slid.
	_swing(side, toward)
	var drive := create_tween()
	drive.tween_property(face, "position:x", home.x + toward * 104.0, LUNGE) \
		.set_trans(Tween.TRANS_QUINT).set_ease(Tween.EASE_IN)
	await _wait(LUNGE + 0.06)

	# 3. The blow lands on the other side.
	var force := clampf(float(damage) / float(maxi(_max[hit], 1)) * 3.2, 0.25, 1.0)
	_slash_at(hit, toward, crit)
	_burst_at(hit, crit)
	_recoil(hit, toward, force)
	_flash(hit, Color(1.6, 1.1, 1.0) if crit else Color(1.4, 1.4, 1.4))
	_shake(force * (1.8 if crit else 1.0))
	_number_at(hit, damage, crit)
	if crit:
		_say("CRITICAL", UI.GOLD)

	# 4. Recover.
	var back := create_tween()
	back.set_parallel(true)
	back.tween_property(face, "position:x", home.x, RECOVER).set_trans(Tween.TRANS_QUAD) \
		.set_ease(Tween.EASE_OUT)
	back.tween_property(face, "scale", Vector2.ONE, RECOVER)
	await _wait(AFTER_BLOW)


## A dodge is a blow that does not land: the target leaves, and nothing hits.
func _dodge(side: String) -> void:
	var miss := "d" if side == "a" else "a"
	if _skip:
		return
	var toward := 1.0 if side == "a" else -1.0
	var face: Control = _face[side]
	var home: Vector2 = _home[side]
	var target: Control = _face[miss]
	var thome: Vector2 = _home[miss]

	var drive := create_tween()
	drive.tween_property(face, "position:x", home.x + toward * 84.0, LUNGE + 0.04) \
		.set_trans(Tween.TRANS_QUINT).set_ease(Tween.EASE_IN)
	var slip := create_tween()
	slip.tween_property(target, "position:y", thome.y - 34.0, 0.10).set_trans(Tween.TRANS_QUAD)
	slip.tween_property(target, "position:y", thome.y, 0.20).set_trans(Tween.TRANS_QUAD)
	_say("DODGED", UI.DIM)
	await _wait(0.16)
	var back := create_tween()
	back.tween_property(face, "position:x", home.x, RECOVER).set_trans(Tween.TRANS_QUAD)
	await _wait(AFTER_BLOW)


## The sword crosses the gap and arrives as the blow lands.
##
## It starts cocked back over the striker's shoulder, sweeps through a
## hundred-odd degrees on its way over, and ends buried in the other side. The
## blade is the painted item the player equipped, so a raid shows the sword they
## bought doing the work.
func _swing(side: String, toward: float) -> void:
	var from: Vector2 = _centre[side] + Vector2(-toward * 40.0, -40.0)
	var to: Vector2 = _centre["d" if side == "a" else "a"] + Vector2(-toward * 30.0, 10.0)
	var size := 210.0
	var img := UI.image(str(_weapon.get(side, "items/painted/weapon_01")),
		Rect2(from.x - size / 2.0, from.y - size / 2.0, size, size))
	img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	img.pivot_offset = Vector2(size / 2.0, size / 2.0)
	# Cocked back, and mirrored so the defender's blade leads with its edge too.
	img.rotation = deg_to_rad(-70.0 * toward)
	img.scale = Vector2(toward, 1.0) * 0.85
	_floaters.add_child(img)

	var travel := LUNGE + 0.06
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(img, "position", Vector2(to.x - size / 2.0, to.y - size / 2.0), travel) \
		.set_trans(Tween.TRANS_QUINT).set_ease(Tween.EASE_IN)
	tw.tween_property(img, "rotation", deg_to_rad(38.0 * toward), travel) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_property(img, "scale", Vector2(toward, 1.0) * 1.15, travel)
	# It bites, holds a beat, and is gone before the recovery starts.
	tw.chain().set_parallel(true)
	tw.tween_property(img, "rotation", deg_to_rad(56.0 * toward), 0.10)
	tw.tween_property(img, "modulate:a", 0.0, 0.20).set_delay(0.06)
	tw.chain().tween_callback(img.queue_free)


## The arc a blade leaves, swept across the face it landed on.
func _slash_at(side: String, toward: float, crit: bool) -> void:
	var at: Vector2 = _centre[side]
	var size := 300.0 if crit else 250.0
	var img := UI.image("battle/slash", Rect2(at.x - size / 2.0, at.y - size / 2.0, size, size))
	img.pivot_offset = Vector2(size / 2.0, size / 2.0)
	# The crescent faces the way the blow came from, and sweeps through.
	img.rotation = deg_to_rad(-55.0 if toward > 0.0 else 125.0)
	img.scale = Vector2(0.55, 0.9)
	img.modulate = Color(1, 1, 1, 0.0)
	_floaters.add_child(img)
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(img, "modulate:a", 1.0, 0.05)
	tw.tween_property(img, "scale", Vector2(1.25, 1.05), 0.22).set_trans(Tween.TRANS_QUAD) \
		.set_ease(Tween.EASE_OUT)
	tw.tween_property(img, "rotation", img.rotation + deg_to_rad(38.0 * toward), 0.22)
	tw.chain().tween_property(img, "modulate:a", 0.0, 0.14)
	tw.chain().tween_callback(img.queue_free)


## The flash of contact.
func _burst_at(side: String, crit: bool) -> void:
	var at: Vector2 = _centre[side]
	var size := 340.0 if crit else 260.0
	var img := UI.image("battle/impact", Rect2(at.x - size / 2.0, at.y - size / 2.0, size, size))
	img.pivot_offset = Vector2(size / 2.0, size / 2.0)
	img.scale = Vector2(0.25, 0.25)
	img.rotation = randf_range(-0.4, 0.4)
	_floaters.add_child(img)
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(img, "scale", Vector2.ONE, 0.26).set_trans(Tween.TRANS_QUINT) \
		.set_ease(Tween.EASE_OUT)
	tw.tween_property(img, "modulate:a", 0.0, 0.30)
	tw.chain().tween_callback(img.queue_free)


## The struck side is thrown back and comes off its feet a little.
func _recoil(side: String, toward: float, force: float) -> void:
	var face: Control = _face[side]
	var home: Vector2 = _home[side]
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(face, "position:x", home.x + toward * (16.0 + 34.0 * force), 0.08) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(face, "rotation", deg_to_rad(toward * 4.0 * force), 0.08)
	tw.chain().set_parallel(true)
	tw.tween_property(face, "position:x", home.x, 0.34).set_trans(Tween.TRANS_ELASTIC) \
		.set_ease(Tween.EASE_OUT)
	tw.tween_property(face, "rotation", 0.0, 0.34).set_trans(Tween.TRANS_ELASTIC) \
		.set_ease(Tween.EASE_OUT)


func _flash(side: String, col: Color) -> void:
	var face: Control = _face[side]
	face.modulate = col
	var tw := create_tween()
	tw.tween_property(face, "modulate", Color.WHITE, 0.28)


## The number lands on the face it came out of, then drifts off it.
func _number_at(side: String, damage: int, crit: bool) -> void:
	var at: Vector2 = _centre[side]
	var size := 96 if crit else 74
	var l := UI.label(UI.grouped(damage) + ("!" if crit else ""), size,
		UI.GOLD if crit else UI.INK, "title", 800, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(l, Rect2(at.x - 170, at.y - 60, 340, size + 30))
	l.pivot_offset = Vector2(170, (size + 30) / 2.0)
	l.scale = Vector2(0.5, 0.5)
	_floaters.add_child(l)
	var away := 1.0 if side == "d" else -1.0
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(l, "scale", Vector2(1.15, 1.15), 0.12).set_trans(Tween.TRANS_BACK) \
		.set_ease(Tween.EASE_OUT)
	tw.chain().set_parallel(true)
	tw.tween_property(l, "scale", Vector2.ONE, 0.10)
	tw.tween_property(l, "position:y", l.position.y - 96.0, 0.62).set_trans(Tween.TRANS_QUAD) \
		.set_ease(Tween.EASE_OUT)
	tw.tween_property(l, "position:x", l.position.x + away * 26.0, 0.62)
	tw.tween_property(l, "modulate:a", 0.0, 0.62).set_delay(0.18)
	tw.chain().tween_callback(l.queue_free)


## The word for what happened, when a number is not the story.
func _say(text: String, col: Color) -> void:
	if _skip:
		return
	_callout.text = text
	_callout.label_settings.font_color = col
	_callout.label_settings.font_size = 54
	_callout.modulate.a = 1.0
	_callout.pivot_offset = Vector2(W / 2.0, 65)
	_callout.scale = Vector2(0.8, 0.8)
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(_callout, "scale", Vector2.ONE, 0.14).set_trans(Tween.TRANS_BACK) \
		.set_ease(Tween.EASE_OUT)
	tw.chain().tween_interval(0.24)
	tw.chain().tween_property(_callout, "modulate:a", 0.0, 0.22)


func _shake(force: float) -> void:
	if _skip:
		return
	var home := _root.position
	var amp := 4.0 + 12.0 * clampf(force, 0.0, 1.0)
	var tw := create_tween()
	for i in 4:
		tw.tween_property(_root, "position",
			home + Vector2(randf_range(-amp, amp), randf_range(-amp * 0.6, amp * 0.6)), 0.035)
	tw.tween_property(_root, "position", home, 0.06)


## The real bar falls at once; the pale one behind it follows, late and slower,
## so the strip between them is the blow that was just struck.
func _drain(side: String) -> void:
	_hp_text[side].text = "%s / %s" % [UI.grouped(_hp[side]), UI.grouped(_max[side])]
	if _skip:
		Layout.set_fill(_fill[side], float(_hp[side]) / float(_max[side]))
		Layout.set_fill(_ghost[side], float(_hp[side]) / float(_max[side]))
		return
	var frac := clampf(float(_hp[side]) / float(_max[side]), 0.0, 1.0)
	for pair in [[_fill[side], DRAIN, 0.0], [_ghost[side], GHOST_DRAIN, GHOST_DELAY]]:
		var wrap: Control = pair[0]
		var full: Vector2 = wrap.get_meta("full")
		var want: float = maxf(full.x * frac, 1.0)
		wrap.visible = full.x * frac >= 1.0
		var tw := create_tween()
		tw.tween_property(wrap, "size:x", want, float(pair[1])) \
			.set_trans(Tween.TRANS_CUBIC).set_delay(float(pair[2]))


## The loser goes down: the colour leaves them and they slide out of the light.
func _fall(side: String) -> void:
	var face: Control = _face[side]
	if _skip:
		face.modulate = Color(0.35, 0.3, 0.3, 0.6)
		return
	_shake(1.0)
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(face, "modulate", Color(0.34, 0.29, 0.30, 0.55), 0.55)
	tw.tween_property(face, "position:y", _home[side].y + 34.0, 0.55) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_property(face, "rotation", deg_to_rad(7.0 if side == "d" else -7.0), 0.55)
	await _wait(0.75)


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
	UI.place(head, Rect2(130, 1086, 681, 84))
	_root.add_child(head)
	var n := int(_replay.get("rounds", 0))
	var rounds := UI.label("%d %s%s" % [n, "round" if n == 1 else "rounds",
		"  ·  ran out of time" if bool(_replay.get("timed_out", false)) else ""],
		24, UI.DIM, "body", 500, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(rounds, Rect2(130, 1182, 681, 34))
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
		UI.place(l, Rect2(130, 1228 + i * 40, 681, 38))
		_root.add_child(l)

	var go := _plate_button("CONTINUE", "shop/buy_plate" if won else "inventory/btn_sell_plate",
		Color("#F3FBF3") if won else UI.INK, Rect2(W / 2.0 - 170, 1440, 340, 96))
	go.pressed.connect(func() -> void:
		finished.emit()
		queue_free())
	_root.add_child(go)
