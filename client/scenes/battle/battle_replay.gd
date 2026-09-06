extends CanvasLayer
## Plays back a battle the server already resolved.
##
## A CanvasLayer, not a Control: an overlay parented straight to the scene root
## does not reliably inherit the window rect, and a layer also guarantees it
## draws above the tab underneath regardless of tree order.
##
## Nothing here decides anything. The server simulated once and sent an event
## log; this only draws it. That is what keeps float determinism off the
## correctness path — and it also means a replay can be re-watched later, or
## inspected in the admin panel, and show exactly the same fight.

signal finished

## Playback is paced to a TARGET DURATION, not a fixed per-event delay. A level-60
## fight produces several hundred events and a fixed interval would run past
## fifteen seconds — far too long for something a player does dozens of times a
## session. Short fights still get room to breathe because the interval is clamped.
const TARGET_SECONDS := 6.0
const MIN_INTERVAL := 0.012
const MAX_INTERVAL := 0.09
const ROUND_PAUSE := 0.15

var _result: Dictionary = {}
var _target: Dictionary = {}
var _replay: Dictionary = {}

# Per-unit health is still tracked, because that is what the server's events
# carry, but nothing per-unit is DRAWN. The screen shows one champion a side and
# one pooled bar: the warband is the champion's strength, not a queue of
# separate duels.
var _hp: Dictionary = {}        # unit id -> current hp
var _max_hp: Dictionary = {}
var _side_of: Dictionary = {}   # unit id -> "a" | "d"
var _bars: Dictionary = {}      # side -> ProgressBar
var _pool_max: Dictionary = {}  # side -> summed starting hp
var _anchors: Dictionary = {}   # side -> the portrait, for floaters
var _tokens: Dictionary = {}    # unit id -> its pip under the portrait
var _standing: Dictionary = {}  # side -> Label, "4 of 5 still standing"

var _skip := false
var _interval := MAX_INTERVAL
var _fortune: Label
var _round_label: Label
var _floaters: Control


func setup(result: Dictionary, target: Dictionary) -> void:
	_result = result
	_target = target
	_replay = result.get("replay", {})


var _root: Control


func _ready() -> void:
	layer = 100

	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.anchor_right = 1.0
	_root.anchor_bottom = 1.0
	add_child(_root)

	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.015, 0.01, 0.97)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.anchor_right = 1.0
	dim.anchor_bottom = 1.0
	_root.add_child(dim)

	# SKIP at the top and CONTINUE at the bottom were both inside the home
	# indicator's gesture zone, which is the classic "that button does not work"
	# report on iOS.
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.anchor_right = 1.0
	margin.anchor_bottom = 1.0
	SafeArea.apply(margin, Vector4(16, 16, 16, 16))
	_root.add_child(margin)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	# Centred rather than top-aligned: the two armies should face each other in
	# the middle of the screen, which is where the eye goes.
	col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	margin.add_child(col)

	_round_label = UI.label("", UI.F_CAPTION, Palette.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER)
	col.add_child(_round_label)

	# The Fortune roll is shown BEFORE anything moves. A visible die the player
	# watches is dramatic; the identical maths applied silently reads as a bug.
	_fortune = UI.label("", UI.F_CAPTION, Palette.GOLD, HORIZONTAL_ALIGNMENT_CENTER)
	_fortune.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(_fortune)

	col.add_child(UI.spacer(6))
	# Side by side, because that is what a duel looks like. Stacked, the two
	# champions read as a list of two things rather than as one facing the other.
	var lists := HBoxContainer.new()
	lists.add_theme_constant_override("separation", 6)
	lists.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_child(lists)

	lists.add_child(_side_block(_replay.get("attacker", {}), "a", Palette.SUCCESS))
	var vs := UI.label("VS", UI.F_CAPTION, Palette.GOLD_DEEP, HORIZONTAL_ALIGNMENT_CENTER)
	vs.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	vs.custom_minimum_size = Vector2(26, 0)
	lists.add_child(vs)
	lists.add_child(_side_block(_replay.get("defender", {}), "d", Palette.DANGER))
	_scale_bars()
	col.add_child(UI.spacer(10))

	_floaters = Control.new()
	_floaters.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_floaters.set_anchors_preset(Control.PRESET_FULL_RECT)
	_floaters.anchor_right = 1.0
	_floaters.anchor_bottom = 1.0
	_root.add_child(_floaters)

	var skip := UI.ghost_button("SKIP", UI.F_BODY)
	skip.custom_minimum_size = Vector2(0, UI.TAP_MIN)
	skip.add_theme_stylebox_override("normal", UI.skin("ghost", Palette.PANEL, 14, 10))
	skip.pressed.connect(func() -> void: _skip = true)
	col.add_child(skip)

	_play()


## One champion, as a column: portrait, name, Might, a single health pool, and
## the warband as pips beneath rather than as a stack of separate fighters.
func _side_block(army: Dictionary, side: String, accent: Color) -> Control:
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(148, 0)
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.add_theme_stylebox_override("panel", UI.skin("panel_gold", Palette.PANEL, 16, 14))

	var pad := MarginContainer.new()
	for edge in ["left", "right"]:
		pad.add_theme_constant_override("margin_" + edge, 8)
	for edge in ["top", "bottom"]:
		pad.add_theme_constant_override("margin_" + edge, 10)
	card.add_child(pad)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 5)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	pad.add_child(box)

	var face := TextureRect.new()
	face.texture = ArtRegistry.portrait(str(army.get("avatar", "knight")))
	face.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	face.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	face.custom_minimum_size = Vector2(0, 72)
	box.add_child(face)

	box.add_child(UI.label(str(army.get("name", "")), 15, accent, HORIZONTAL_ALIGNMENT_CENTER))

	var might := int(_replay.get("attacker_might", 0)) if side == "a" \
		else int(_replay.get("defender_might", 0))
	box.add_child(UI.label("Might %s" % UI.number(might), UI.F_MICRO, Palette.TEXT_DIM,
		HORIZONTAL_ALIGNMENT_CENTER))

	# One bar for the whole side. Every unit's health flows into it, so damage
	# reads as pressure on one champion instead of a queue of separate duels.
	var total := 0
	var units: Array = army.get("units", [])
	for u in units:
		var id := str(u.get("id", ""))
		var hp := maxi(int(u.get("hp", 1)), 1)
		_hp[id] = hp
		_max_hp[id] = hp
		_side_of[id] = side
		total += hp
	_pool_max[side] = maxi(total, 1)

	var bar := ProgressBar.new()
	bar.show_percentage = false
	bar.max_value = 1.0   # set once both sides are known, in _scale_bars()
	bar.value = float(total)
	bar.custom_minimum_size = Vector2(0, 16)
	bar.add_theme_stylebox_override("background", UI.panel_box(Palette.BG, Palette.LINE, 5))
	bar.add_theme_stylebox_override("fill", UI.panel_box(accent, Color.TRANSPARENT, 5))
	box.add_child(bar)
	_bars[side] = bar

	# Wrapped, because a wide warband will not fit across a narrow column.
	var pips := HFlowContainer.new()
	pips.alignment = FlowContainer.ALIGNMENT_CENTER
	pips.add_theme_constant_override("h_separation", 3)
	pips.add_theme_constant_override("v_separation", 3)
	box.add_child(pips)
	for u in units:
		var pip := _pip(str(u.get("tier", "")), bool(u.get("is_hero", false)))
		pips.add_child(pip)
		_tokens[str(u.get("id", ""))] = pip

	var standing := UI.label("", UI.F_MICRO, Palette.TEXT_FAINT, HORIZONTAL_ALIGNMENT_CENTER)
	box.add_child(standing)
	_standing[side] = standing
	_refresh_standing(side)
	_anchors[side] = card
	return card


## One warband member, as a tier-coloured chip. Greys out when they fall.
## Both health bars share one scale, so the longer bar is the bigger army.
##
## Normalised per side, a 450-Might warband's bar was exactly as long as a
## 2,438-Might one and the mismatch was invisible until the numbers were read.
func _scale_bars() -> void:
	var biggest := 1
	for side in _pool_max:
		biggest = maxi(biggest, int(_pool_max[side]))
	for side in _bars:
		var bar: ProgressBar = _bars[side]
		bar.max_value = float(biggest)
		bar.value = float(_pool_max[side])


func _pip(tier: String, is_hero: bool) -> Control:
	var p := PanelContainer.new()
	p.custom_minimum_size = Vector2(20, 20)
	var tint := Palette.GOLD if is_hero else (Palette.tier(tier) if tier != "" else Palette.TEXT_DIM)
	p.add_theme_stylebox_override("panel", UI.panel_box(tint, Color.TRANSPARENT, 4))
	return p


func _refresh_standing(side: String) -> void:
	var alive := 0
	var total := 0
	for id in _side_of:
		if str(_side_of[id]) != side:
			continue
		total += 1
		if int(_hp[id]) > 0:
			alive += 1
	var label: Label = _standing[side]
	label.text = "%d of %d  ·  still standing" % [alive, total]


func _play() -> void:
	var events: Array = _replay.get("events", [])
	_interval = clampf(TARGET_SECONDS / maxf(float(events.size()), 1.0), MIN_INTERVAL, MAX_INTERVAL)

	var fa := float(int(_replay.get("fortune_a_bp", 10000))) / 100.0
	var fd := float(int(_replay.get("fortune_d_bp", 10000))) / 100.0
	_fortune.text = "Fortune of War — your levies fight at %d%%, theirs at %d%%" % [int(fa), int(fd)]
	await _wait(0.9)

	var last_round := 0
	for e in events:
		var r := int(e.get("r", 0))
		if r != last_round:
			last_round = r
			_round_label.text = "Round %d" % r
			await _wait(ROUND_PAUSE)

		match str(e.get("k", "")):
			"hit":
				_show_damage(str(e.get("dst", "")), int(e.get("dmg", 0)), bool(e.get("crit", false)))
			"dodge":
				_show_text(str(e.get("dst", "")), "miss", Palette.TEXT_FAINT)
			"hp":
				_set_hp(str(e.get("dst", "")), int(e.get("hp", 0)))
			"death":
				_kill(str(e.get("dst", "")))
		await _wait(_interval)

	await _wait(0.4)
	_show_outcome()


## Waits, but collapses to nothing once the player has hit skip.
func _wait(seconds: float) -> void:
	if _skip:
		return
	await get_tree().create_timer(seconds).timeout


## The server reports health per unit; the screen shows it per side. Summing the
## living is what turns a line of separate fighters into one champion under
## pressure.
func _set_hp(id: String, hp: int) -> void:
	if not _side_of.has(id):
		return
	_hp[id] = hp
	var side := str(_side_of[id])
	var pool := 0
	for other_id in _side_of:
		if str(_side_of[other_id]) == side:
			pool += int(_hp[other_id])
	_refresh_standing(side)

	var bar: ProgressBar = _bars[side]
	if _skip:
		bar.value = pool
		return
	var tw := create_tween()
	tw.tween_property(bar, "value", float(pool), minf(0.12, _interval * 2.0))


func _kill(id: String) -> void:
	if _tokens.has(id):
		var pip: Control = _tokens[id]
		pip.modulate = Color(0.35, 0.32, 0.3, 0.9)


func _show_damage(id: String, dmg: int, crit: bool) -> void:
	_show_text(id, ("%d!" % dmg) if crit else str(dmg),
		Palette.GOLD if crit else Palette.DANGER, crit)


## Damage floats off the champion taking it, not off a row, because there are no
## rows any more.
func _show_text(id: String, text: String, colour: Color, big: bool = false) -> void:
	if _skip or not _side_of.has(id):
		return
	var side := str(_side_of[id])
	if not _anchors.has(side):
		return
	var card: Control = _anchors[side]
	var l := UI.label(text, 20 if big else 15, colour)
	# Down the right-hand edge of the card: over the portrait it landed on the
	# name, which is the one thing on the card you always want readable.
	l.position = card.global_position + Vector2(card.size.x * 0.5 - 14.0, 6.0)
	_floaters.add_child(l)

	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(l, "position:y", l.position.y - 26.0, 0.6)
	tw.tween_property(l, "modulate:a", 0.0, 0.6)
	tw.chain().tween_callback(l.queue_free)


func _show_outcome() -> void:
	var won := bool(_result.get("won", false))
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel",
		UI.skin("panel_gold", Palette.PANEL, 22, 20))
	panel.custom_minimum_size = Vector2(300, 0)
	_root.add_child(panel)
	panel.position = _root.size / 2.0 - Vector2(150, 90)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	panel.add_child(col)

	col.add_child(UI.label("VICTORY" if won else "DEFEAT", UI.F_H1,
		Palette.SUCCESS if won else Palette.DANGER, HORIZONTAL_ALIGNMENT_CENTER))

	if won:
		col.add_child(UI.label("+%s gold" % UI.number(int(_result.get("gold_stolen", 0))),
			UI.F_H2, Palette.GOLD, HORIZONTAL_ALIGNMENT_CENTER))
	else:
		col.add_child(UI.label("They kept their coin", UI.F_CAPTION, Palette.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER))
	col.add_child(UI.label("+%d experience" % int(_result.get("xp_gained", 0)),
		UI.F_CAPTION, Palette.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER))

	var close := UI.button("CONTINUE", UI.F_H2)
	close.custom_minimum_size = Vector2(0, UI.TAP_PRIMARY)
	close.pressed.connect(func() -> void:
		finished.emit()
		queue_free())
	col.add_child(close)

	# A capture run disables input, so the panel would sit forever. Nothing else
	# ever sets this.
	if _root.get_viewport().is_input_disabled():
		await get_tree().create_timer(2.5).timeout
		finished.emit()
		queue_free()
