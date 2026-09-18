extends CanvasLayer
## Plays back a battle the server already resolved.
##
## Nothing here decides anything: the server simulated once and sent an event
## log, and this draws it blow by blow.
##
## Two champions, one blow each per round, the attacker first -- a side's whole
## strength lands in one swing -- on the painted battle screen
## (art/reference/battle.png, cut by art/slices/battle.json, laid out by
## client/layout/battle.json): the armies before the castle, each champion's
## face in a gilded frame (the player's under the golden lion, on the left in
## green; the rival's under the wolf, in red), a name plate, a power plate and
## an HP bar under each, ROUND in its plate, Fortune of War between the two
## rolls, and the results board with CONTINUE at the foot.
##
## The frames are the painting's and stay where it put them, so a blow is told
## inside them: the striker's face presses into its frame, the painted sword
## crosses the gap, and the struck face is thrown back in its own. Every effect
## -- the burst, the blade's arc, the dodge's whoosh, a critical's explosion,
## the spark off a held shield, the dice and the VICTORY / DEFEAT banners -- is
## cut from art/reference/battle_fx.png (art/slices/battle_fx.json). The three
## light effects were painted on navy and are drawn additively, so they light
## what they cross instead of laying a dark square over a face.

signal finished

const SCREEN := "battle"

## A blow is four beats: pull back, drive in, land, recover. The numbers are
## what the beats are worth -- the wind-up is slow enough to be read as intent,
## the lunge is the fastest thing on the screen, and the recovery is long enough
## that the next blow does not tread on this one.
const WIND_UP := 0.13
const LUNGE := 0.09
const RECOVER := 0.26
const AFTER_BLOW := 0.30       ## quiet between one blow and the next
const ROUND_PAUSE := 0.55      ## the round number holds for this
const DRAIN := 0.30            ## the bar falls
const GHOST_DRAIN := 0.55      ## the pale bar behind it follows, late
const GHOST_DELAY := 0.16

## The painting's navy where its two blocks meet (y 1010), and so the ground of
## the gap between them on a phone taller than the painting.
const GROUND := Color("#07131C")
## The painting's height: the results block is anchored this far up from the
## screen's foot, the battlefield block to the top.
const DESIGN_H := 1672.0
## The battlefield block's parts, moved down past the phone's top inset.
const TOP := ["scene_top", "skip", "round_number", "name_you", "name_them", "power_you",
	"power_them", "hp_you", "hp_them", "die_you", "die_them", "fortune_you", "fortune_them", "callout"]
## The HP fill's painted ends, kept whole when it is stretched along its channel.
const BAR_CAP := 10
## How far a face overhangs its window on every side. Every move a blow makes
## inside the window (the recoil, the dodge's slip, the fall) stays within it.
const FACE_BLEED := 16.0
## The largest VICTORY / DEFEAT is drawn in its zone over the battlefield.
const BANNER_MAX := Vector2(620, 240)
## A plate with nothing to do (SKIP once the fight is told, CONTINUE while it
## runs) is its own cut laid over it in this.
const VEIL := Color(0.02, 0.05, 0.08, 0.62)

var _replay: Dictionary = {}
var _result: Dictionary = {}
var _target: Dictionary = {}
## Which of the record's sides is the player watching: "a" when they raided,
## "d" when they were raided. Their side stands on the left in green whichever
## it is. It used to be the attacker's, always, so a defence was played back
## with the player's own face on the lord who robbed them.
var _you := "a"
## How far the phone's notch reaches, in canvas units. Negative: ask the phone
## (UI.safe_top). Tests set it, since a desktop has no notch.
var top_inset := -1.0

var _hp := {"a": 0, "d": 0}
var _max := {"a": 1, "d": 1}
var _id_side: Dictionary = {}
var _fill: Dictionary = {}
var _ghost: Dictionary = {}
var _hp_text: Dictionary = {}
var _face: Dictionary = {}
var _home: Dictionary = {}      ## where each face rests in its window, to come back to
var _centre: Dictionary = {}    ## the middle of each window, for effects
var _weapon: Dictionary = {}    ## side -> the painted sword it swings
var _ui: Dictionary = {}
var _top_y := 0.0               ## the battlefield block's drop past the top inset
var _root: Control
var _floaters: Control
var _round_label: Label
var _fortune: Array[Control] = []  ## each side's roll and its painted die
var _callout: Label
var _skip_button: BaseButton
var _continue: BaseButton
var _veils: Dictionary = {}     ## button id -> its darkened cut
var _skip := false
var _done := false


## `result` is the /v1/attack response or a stored battle (/v1/battles/{id}),
## both told from the player's side; `target` is the other lord, for their name
## and face when the record lacks them.
func setup(result: Dictionary, target: Dictionary = {}) -> void:
	_result = result
	_target = target
	_replay = result if result.has("events") else result.get("replay", {})
	_you = "d" if str(result.get("perspective", "")) == "defender" else "a"


func _them() -> String:
	return "d" if _you == "a" else "a"


func _ready() -> void:
	layer = 90
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_root)
	var canvas := get_viewport().get_visible_rect().size
	var inset := top_inset if top_inset >= 0.0 else UI.safe_top(canvas)
	# The battlefield moves down past the notch as far as the phone is taller
	# than the painting; the results block keeps the foot either way.
	_top_y = clampf(inset, 0.0, maxf(0.0, canvas.y - DESIGN_H))

	var ground := ColorRect.new()
	ground.color = GROUND
	ground.set_anchors_preset(Control.PRESET_FULL_RECT)
	ground.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(ground)

	var armies := {"a": _replay.get("attacker", {}), "d": _replay.get("defender", {})}
	var mights := {"a": int(_replay.get("attacker_might", 0)), "d": int(_replay.get("defender_might", 0))}
	_weapon["a"] = _weapon_for(armies["a"])
	_weapon["d"] = _weapon_for(armies["d"])
	# The faces go in first: the frames are drawn over them.
	_face_in(_you, armies[_you], "window_you")
	_face_in(_them(), armies[_them()], "window_them")

	_ui = Layout.build(SCREEN, _root)
	for id in TOP:
		(_ui[id] as Control).position.y += _top_y

	_side(armies[_you], _you, "you", mights[_you], "battle/hp_green")
	_side(armies[_them()], _them(), "them", mights[_them()], "battle/hp_red")
	for id in ["hp_you", "hp_them"]:
		# The numbers read over the fills, which are drawn after the layout.
		_root.move_child(_ui[id], -1)

	_round_label = _ui["round_number"]
	_round_label.pivot_offset = _round_label.size / 2.0
	_build_fortune()
	_callout = _ui["callout"]
	_callout.modulate.a = 0.0
	_callout.pivot_offset = _callout.size / 2.0
	var band: Label = _ui["band"]
	band.text = _story(armies[_them()])
	UI.fit_line(band, 30, 20)
	for id in ["row_gold", "row_crown", "row_diamond"]:
		(_ui[id] as Label).text = ""

	_skip_button = _ui["skip"]
	_skip_button.pressed.connect(func() -> void: _skip = true)
	_continue = _ui["continue"]
	_continue.disabled = true
	_continue.pressed.connect(func() -> void:
		finished.emit()
		queue_free())
	_veil("continue", true)

	_floaters = Control.new()
	_floaters.name = "floaters"
	_floaters.set_anchors_preset(Control.PRESET_FULL_RECT)
	_floaters.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_floaters)
	_play.call_deferred()


## A layout measurement, moved with the battlefield block.
func _rect(id: String) -> Rect2:
	var r := Layout.rect_of(Layout.element(SCREEN, id))
	r.position.y += _top_y
	return r


## One champion's face in its painted window, under the frame: the portrait
## they chose, square, covering the window and clipped to it.
func _face_in(side: String, army: Dictionary, window: String) -> void:
	var r := _rect(window)
	var clip := Control.new()
	clip.name = "Window_" + side
	UI.place(clip, r)
	clip.clip_contents = true
	clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(clip)
	# A little larger than the window, so a face thrown about inside it never
	# shows the window's edge behind it.
	var s := maxf(r.size.x, r.size.y) + FACE_BLEED * 2.0
	var face := UI.image(Art.avatar(_avatar_of(side, army)), Rect2((r.size.x - s) / 2.0, (r.size.y - s) / 2.0, s, s))
	face.pivot_offset = Vector2(s, s) / 2.0
	clip.add_child(face)
	_face[side] = face
	_home[side] = face.position
	_centre[side] = r.get_center()


## The portrait id a side is drawn with: the one the record froze with the
## battle, or -- for a record from before it carried one -- the rival card's,
## or the player's own.
func _avatar_of(side: String, army: Dictionary) -> String:
	var id := str(army.get("avatar", ""))
	if id != "":
		return id
	if side == _you:
		return str(GameState.snapshot.get("player", {}).get("avatar", ""))
	return str(_target.get("avatar", ""))


## Fortune of War: each side's roll, as the server rolled it, in the window on
## its own side of the plate, the painted die before it.
func _build_fortune() -> void:
	var bp := {"a": int(_replay.get("fortune_a_bp", 10000)), "d": int(_replay.get("fortune_d_bp", 10000))}
	for pair in [["you", _you], ["them", _them()]]:
		var l: Label = _ui["fortune_" + pair[0]]
		l.text = "%d%%" % (int(bp[pair[1]]) / 100)
		UI.fit_line(l, 26, 18)
		_fortune.append(l)
		_fortune.append(_ui["die_" + pair[0]])


## A plate that has nothing to do is drawn darkened: its own cut, laid over it.
func _veil(id: String, on: bool) -> void:
	var b: TextureButton = _ui[id]
	if not _veils.has(id):
		# A child of the button, over its face and wherever the button goes; the
		# taps go through it to the button, which is disabled while it shows.
		var tex := b.texture_normal
		var at := Vector2.ZERO
		if b.stretch_mode == TextureButton.STRETCH_KEEP_CENTERED:
			at = (b.size - tex.get_size()) / 2.0
		var v := UI.image("", Rect2(at, tex.get_size() if b.stretch_mode == TextureButton.STRETCH_KEEP_CENTERED else b.size))
		v.texture = tex
		v.name = "Veil"
		v.self_modulate = VEIL
		v.mouse_filter = Control.MOUSE_FILTER_IGNORE
		b.add_child(v)
		_veils[id] = v
	var veil: TextureRect = _veils[id]
	veil.visible = true
	if _skip or not is_inside_tree():
		veil.modulate.a = 1.0 if on else 0.0
		veil.visible = on
		return
	var tw := create_tween()
	tw.tween_property(veil, "modulate:a", 1.0 if on else 0.0, 0.25)
	if not on:
		tw.tween_callback(func() -> void: veil.visible = false)


## An effect from battle_fx, `width` across at its own proportions, centred on
## `at`. The light ones are added to what is under them.
func _fx(asset: String, at: Vector2, width: float, additive: bool) -> TextureRect:
	var tex: Texture2D = Art.tex(asset)
	var size := Vector2(width, width * float(tex.get_height()) / maxf(float(tex.get_width()), 1.0))
	var img := UI.image(asset, Rect2(at - size / 2.0, size))
	img.pivot_offset = size / 2.0
	img.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if additive:
		var m := CanvasItemMaterial.new()
		m.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
		img.material = m
	_floaters.add_child(img)
	return img


## One line on whose fight this was, in the results board's title band.
func _story(them: Dictionary) -> String:
	var name := str(them.get("name", _target.get("name", "")))
	if _you == "d":
		return "%s raided your city" % name
	if bool(_result.get("revenge", false)):
		return "Your revenge on %s" % name
	return "Your raid on %s" % name


## The sword this side fights with, as the replay recorded it.
func _weapon_for(army: Dictionary) -> String:
	for u in army.get("units", []):
		var w := str(u.get("weapon", ""))
		if w != "":
			return "items/painted/" + w
	return "items/painted/weapon_01"


## One champion's plates and bar: the name, the power, and the HP fill in its
## painted channel.
func _side(army: Dictionary, side: String, slot: String, might: int, fill: String) -> void:
	var name: Label = _ui["name_" + slot]
	# Named as every screen names a lord (Look.paint_name): the colour they
	# wear and Royal Favour's seal. The player's own look is their snapshot's;
	# the other lord's comes with them: a raid card is itself a look (its worn
	# and vip_seal), a replay from the history passes the entry's opponent_look
	# as `look`; plain when neither says.
	var look: Variant = Look.mine() if side == _you else _target.get("look", _target)
	var box := Layout.rect_of(Layout.element(SCREEN, "name_" + slot))
	box.position.y += _top_y
	# Sixteen of the widest letter fit the plate at 16, and beside a seal at 14.
	Look.paint_name(name, look if look is Dictionary else {}, str(army.get("name", "")).to_upper(), box, 28, 14)
	var power: Label = _ui["power_" + slot]
	power.text = UI.grouped(might)
	UI.fit_line(power, 26, 18)

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

	# Two fills, one behind the other. The pale one drains late and slower, so a
	# blow leaves a strip showing exactly what it took -- the oldest trick in
	# fighting games and the only one that makes a number and a bar agree. Each
	# is the painted fill stretched the whole channel long and clipped at the
	# fraction: a partial bar ends square, as the painting's does, and a full one
	# closes on the channel's own chamfer.
	var channel := _rect("channel_" + slot)
	for ghost in [true, false]:
		var wrap := Control.new()
		wrap.name = ("Ghost_" if ghost else "Fill_") + slot
		UI.place(wrap, channel)
		wrap.clip_contents = true
		wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var np := NinePatchRect.new()
		np.texture = Art.tex(fill)
		np.patch_margin_left = BAR_CAP
		np.patch_margin_right = BAR_CAP
		np.size = channel.size
		np.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if ghost:
			np.modulate = Color(1.0, 0.85, 0.75, 0.55)
		wrap.add_child(np)
		wrap.set_meta("full", channel.size)
		_root.add_child(wrap)
		if ghost:
			_ghost[side] = wrap
		else:
			_fill[side] = wrap
	_hp_text[side] = _ui["hp_" + slot]
	_paint(side)


func _paint(side: String) -> void:
	Layout.set_fill(_fill[side], float(_hp[side]) / float(_max[side]))
	Layout.set_fill(_ghost[side], float(_hp[side]) / float(_max[side]))
	_set_hp_text(side)


func _set_hp_text(side: String) -> void:
	var l: Label = _hp_text[side]
	l.text = "%s / %s" % [UI.grouped(_hp[side]), UI.grouped(_max[side])]
	UI.fit_line(l, 18, 14)


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


## The round announces itself in the painted plate's window and gets out of
## the way.
func _round_card(round: int) -> void:
	_round_label.text = str(round)
	UI.fit_line(_round_label, 40, 26)
	if _skip:
		_round_label.modulate.a = 1.0
		return
	_round_label.modulate.a = 0.0
	_round_label.scale = Vector2(1.35, 1.35)
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(_round_label, "modulate:a", 1.0, 0.16)
	tw.tween_property(_round_label, "scale", Vector2.ONE, 0.24).set_trans(Tween.TRANS_BACK) \
		.set_ease(Tween.EASE_OUT)
	await _wait(ROUND_PAUSE)


## One blow, in four beats.
##
## Pull back, drive in, land, recover. The frames are the painting's and do not
## move, so the beats are told inside them: the striker's face draws back and
## then presses into its frame as the painted sword crosses the gap, and the
## struck face is thrown back in its own, flashing, while the burst, the arc,
## the shake and the bar say how hard. The number lands on the face it was
## taken out of.
func _blow(side: String, damage: int, crit: bool) -> void:
	var hit := "d" if side == "a" else "a"
	if _skip:
		return
	var toward := 1.0 if side == _you else -1.0
	var face: Control = _face[side]
	var home: Vector2 = _home[side]

	# 1. Wind up: back from the target, and up a little. Intent, made visible.
	var wind := create_tween()
	wind.set_parallel(true)
	wind.tween_property(face, "position", home + Vector2(-toward * 12.0, -6.0), WIND_UP) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	wind.tween_property(face, "scale", Vector2(1.05, 1.05), WIND_UP)
	await _wait(WIND_UP)

	# 2. Lunge: the face presses into its frame, and the sword goes across. The
	#    portraits are paintings and cannot move a limb, so the swing is carried
	#    by something that can: the player's own weapon, crossing the gap and
	#    arriving at the moment of contact.
	_swing(side, toward)
	var drive := create_tween()
	drive.set_parallel(true)
	drive.tween_property(face, "position", home + Vector2(toward * 16.0, 0.0), LUNGE) \
		.set_trans(Tween.TRANS_QUINT).set_ease(Tween.EASE_IN)
	drive.tween_property(face, "scale", Vector2(1.13, 1.13), LUNGE)
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
	back.tween_property(face, "position", home, RECOVER).set_trans(Tween.TRANS_QUAD) \
		.set_ease(Tween.EASE_OUT)
	back.tween_property(face, "scale", Vector2.ONE, RECOVER)
	await _wait(AFTER_BLOW)


## A dodge is a blow that does not land: the target slips aside in its frame,
## and nothing hits.
func _dodge(side: String) -> void:
	var miss := "d" if side == "a" else "a"
	if _skip:
		return
	var toward := 1.0 if side == _you else -1.0
	var face: Control = _face[side]
	var home: Vector2 = _home[side]
	var target: Control = _face[miss]
	var thome: Vector2 = _home[miss]

	var drive := create_tween()
	drive.set_parallel(true)
	drive.tween_property(face, "position", home + Vector2(toward * 14.0, 0.0), LUNGE + 0.04) \
		.set_trans(Tween.TRANS_QUINT).set_ease(Tween.EASE_IN)
	drive.tween_property(face, "scale", Vector2(1.1, 1.1), LUNGE + 0.04)
	var slip := create_tween()
	slip.tween_property(target, "position", thome + Vector2(toward * 22.0, -14.0), 0.10) \
		.set_trans(Tween.TRANS_QUAD)
	slip.tween_property(target, "position", thome, 0.20).set_trans(Tween.TRANS_QUAD)
	_whoosh_at(miss, toward)
	_say("DODGED", UI.DIM)
	await _wait(0.16)
	var back := create_tween()
	back.set_parallel(true)
	back.tween_property(face, "position", home, RECOVER).set_trans(Tween.TRANS_QUAD)
	back.tween_property(face, "scale", Vector2.ONE, RECOVER)
	await _wait(AFTER_BLOW)


## The sword crosses the gap and arrives as the blow lands.
##
## It starts cocked back over the striker's frame, sweeps through a hundred-odd
## degrees on its way over, and ends buried in the other side. The blade is the
## painted item the player equipped, so a raid shows the sword they bought
## doing the work.
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
	var img := _fx("battle/slash", _centre[side], 330.0 if crit else 280.0, true)
	# The painted crescent opens to the right; mirrored, it opens toward the
	# striker, and it sweeps on through the way the blow came.
	img.scale = Vector2(-0.55 * toward, 0.9)
	img.rotation = deg_to_rad(-20.0 * toward)
	img.modulate = Color(1, 1, 1, 0.0)
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(img, "modulate:a", 1.0, 0.05)
	tw.tween_property(img, "scale", Vector2(-1.2 * toward, 1.05), 0.22).set_trans(Tween.TRANS_QUAD) \
		.set_ease(Tween.EASE_OUT)
	tw.tween_property(img, "rotation", img.rotation + deg_to_rad(30.0 * toward), 0.22)
	tw.chain().tween_property(img, "modulate:a", 0.0, 0.14)
	tw.chain().tween_callback(img.queue_free)


## The flash of contact: the painted burst, or for a critical blow the painted
## explosion, which is laid over the face rather than added to it -- it carries
## stones and embers that must stay dark.
func _burst_at(side: String, crit: bool) -> void:
	var img := _fx("battle/crit" if crit else "battle/impact", _centre[side], 360.0 if crit else 290.0, not crit)
	img.scale = Vector2(0.25, 0.25)
	img.rotation = randf_range(-0.4, 0.4)
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(img, "scale", Vector2.ONE, 0.26).set_trans(Tween.TRANS_QUINT) \
		.set_ease(Tween.EASE_OUT)
	tw.tween_property(img, "modulate:a", 0.0, 0.34 if crit else 0.30).set_delay(0.06 if crit else 0.0)
	tw.chain().tween_callback(img.queue_free)


## The whoosh of a blow that found nothing: swept across the space the target
## just left, in the direction the blow was going.
func _whoosh_at(side: String, toward: float) -> void:
	var img := _fx("battle/dodge", _centre[side] + Vector2(-toward * 30.0, 0.0), 320.0, true)
	img.scale = Vector2(toward * 0.8, 0.8)
	img.modulate = Color(1, 1, 1, 0.0)
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(img, "modulate:a", 1.0, 0.06)
	tw.tween_property(img, "position:x", img.position.x + toward * 60.0, 0.34).set_trans(Tween.TRANS_QUAD) \
		.set_ease(Tween.EASE_OUT)
	tw.tween_property(img, "scale", Vector2(toward * 1.05, 1.0), 0.34)
	tw.chain().tween_property(img, "modulate:a", 0.0, 0.18)
	tw.chain().tween_callback(img.queue_free)


## A defence that held: the painted spark off the shield, on the defender's
## own face. Only ever the player's -- the shield bears the golden lion, the
## player's arms (the crest on their frame), and a rival's defence is not drawn
## with them.
func _shield_spark_at(side: String) -> void:
	var img := _fx("battle/shield_spark", _centre[side], 240.0, false)
	img.scale = Vector2(0.4, 0.4)
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(img, "scale", Vector2.ONE, 0.24).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(img, "modulate:a", 0.0, 0.5).set_delay(0.55)
	tw.chain().tween_callback(img.queue_free)


## The struck face is thrown back in its frame and comes off its feet a little.
func _recoil(side: String, toward: float, force: float) -> void:
	var face: Control = _face[side]
	var home: Vector2 = _home[side]
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(face, "position", home + Vector2(toward * (8.0 + 18.0 * force), -4.0 * force), 0.08) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(face, "rotation", deg_to_rad(toward * 3.0 * force), 0.08)
	tw.chain().set_parallel(true)
	tw.tween_property(face, "position", home, 0.34).set_trans(Tween.TRANS_ELASTIC) \
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
	var away := -1.0 if side == _you else 1.0
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


## The word for what happened, when a number is not the story: over the
## crossed swords, between the frames.
func _say(text: String, col: Color) -> void:
	if _skip:
		return
	_callout.text = text
	_callout.label_settings.font_color = col
	UI.fit_line(_callout, 44, 30)
	_callout.modulate.a = 1.0
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
	_set_hp_text(side)
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


## The loser goes down: the colour leaves them and they sink in their frame --
## no further than the face overhangs it.
func _fall(side: String) -> void:
	var face: Control = _face[side]
	var down := Vector2(_home[side].x, _home[side].y + FACE_BLEED - 2.0)
	if _skip:
		face.modulate = Color(0.35, 0.3, 0.3, 0.6)
		face.position = down
		return
	_shake(1.0)
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(face, "modulate", Color(0.34, 0.29, 0.30, 0.55), 0.55)
	tw.tween_property(face, "position", down, 0.55).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	await _wait(0.75)


func _finish() -> void:
	if _done:
		return
	_done = true
	for side in ["a", "d"]:
		_paint(side)
	var won: bool = bool(_result.get("won", str(_replay.get("winner", "")) == _you))

	# SKIP has nothing left to do; CONTINUE is the way on.
	_skip_button.disabled = true
	_veil("skip", true)
	_continue.disabled = false
	_veil("continue", false)

	_banner(won)
	var band: Label = _ui["band"]
	if _you == "d":
		# The banner says who came out ahead; for a defence, the band says what
		# happened to the city.
		band.text = "Your defence held" if won else "Your city was raided"
	if bool(_replay.get("timed_out", false)):
		band.text += "  ·  time ran out"
	UI.fit_line(band, 30, 20)
	if _you == "d" and won:
		_shield_spark_at(_you)

	var rows := _rows(won)
	for i in rows.size():
		var l: Label = _ui[["row_gold", "row_crown", "row_diamond"][i]]
		l.text = str(rows[i][0])
		l.label_settings.font_color = rows[i][1]
		UI.fit_line(l, 30, 20)


## The painted VICTORY or DEFEAT banner, dropped over the battlefield between
## the round plate and the crests on the frames, as large as that room allows
## at its own proportions.
func _banner(won: bool) -> void:
	var asset := "battle/victory" if won else "battle/defeat"
	var tex: Texture2D = Art.tex(asset)
	var zone := _rect("banner_zone")
	var aspect := float(tex.get_width()) / maxf(float(tex.get_height()), 1.0)
	var box := Vector2(minf(BANNER_MAX.x, zone.size.x), minf(BANNER_MAX.y, zone.size.y))
	var size := Vector2(box.x, box.x / aspect)
	if size.y > box.y:
		size = Vector2(box.y * aspect, box.y)
	var img := UI.image(asset, Rect2(zone.get_center() - size / 2.0, size))
	img.name = "Banner"
	img.set_meta("asset", asset)
	img.pivot_offset = size / 2.0
	_root.add_child(img)
	if _skip:
		return
	img.scale = Vector2(0.7, 0.7)
	img.modulate.a = 0.0
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(img, "modulate:a", 1.0, 0.18)
	tw.tween_property(img, "scale", Vector2.ONE, 0.36).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


## What the fight did to this player, on the board's three painted rows, from
## their side: gold (coins), experience (the crown), diamonds (the diamond).
##
## Gold is the server's signed figure for the reader. A ransom is the defender's:
## a failed raid is told as what it paid the other side, not counted as the
## raider's own spoils -- which is how the result screen used to read it. A row
## with nothing in it says so quietly rather than showing a zero.
func _rows(won: bool) -> Array:
	var gold := int(str(_result.get("gold", _result.get("gold_stolen", "0"))))
	var ransom := int(str(_result.get("ransom_paid", "0")))
	var xp := int(_result.get("xp_gained", 0))
	var gems := int(_result.get("diamonds_gained", 0))
	var row_gold: Array = ["No gold changed hands", UI.DIM]
	if _you == "a":
		if gold > 0:
			row_gold = ["+%s gold" % UI.grouped(gold), UI.GOLD]
		elif not won and ransom > 0:
			row_gold = ["Their defence earned them %s ransom" % UI.grouped(ransom), UI.DIM]
	else:
		if gold > 0:
			row_gold = ["+%s ransom for holding" % UI.grouped(gold), UI.GOLD]
		elif gold < 0:
			row_gold = ["%s gold stolen" % UI.grouped(gold), UI.RED]
	var row_crown: Array = ["+%s experience" % UI.grouped(xp), UI.INK] if xp > 0 else ["No experience", UI.DIM]
	var row_gems: Array = ["+%s diamonds for the level" % UI.grouped(gems), Color("#9FD8FF")] if gems > 0 \
		else ["No diamonds", UI.DIM]
	return [row_gold, row_crown, row_gems]
