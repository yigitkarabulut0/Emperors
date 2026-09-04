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

var _hp: Dictionary = {}        # unit id -> current hp
var _max_hp: Dictionary = {}
var _bars: Dictionary = {}      # unit id -> ProgressBar
var _rows: Dictionary = {}      # unit id -> Control

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

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.anchor_right = 1.0
	margin.anchor_bottom = 1.0
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	_root.add_child(margin)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	# Centred rather than top-aligned: the two armies should face each other in
	# the middle of the screen, which is where the eye goes.
	col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	margin.add_child(col)

	_round_label = UI.label("", 15, Palette.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER)
	col.add_child(_round_label)

	# The Fortune roll is shown BEFORE anything moves. A visible die the player
	# watches is dramatic; the identical maths applied silently reads as a bug.
	_fortune = UI.label("", 15, Palette.GOLD, HORIZONTAL_ALIGNMENT_CENTER)
	_fortune.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(_fortune)

	col.add_child(UI.spacer(6))
	col.add_child(_side_block(_replay.get("defender", {}), "d", Palette.DANGER))
	col.add_child(UI.label("versus", 13, Palette.TEXT_FAINT, HORIZONTAL_ALIGNMENT_CENTER))
	col.add_child(_side_block(_replay.get("attacker", {}), "a", Palette.SUCCESS))
	col.add_child(UI.spacer(10))

	_floaters = Control.new()
	_floaters.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_floaters.set_anchors_preset(Control.PRESET_FULL_RECT)
	_floaters.anchor_right = 1.0
	_floaters.anchor_bottom = 1.0
	_root.add_child(_floaters)

	var skip := UI.ghost_button("SKIP", 16)
	skip.custom_minimum_size = Vector2(0, 44)
	skip.add_theme_stylebox_override("normal", UI.panel_box(Palette.PANEL, Palette.LINE))
	skip.pressed.connect(func() -> void: _skip = true)
	col.add_child(skip)

	_play()


func _side_block(army: Dictionary, side: String, accent: Color) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 3)

	var might := int(_replay.get("attacker_might", 0)) if side == "a" \
		else int(_replay.get("defender_might", 0))
	var title := "%s  ·  Might %s" % [str(army.get("name", "")), UI.number(might)]
	box.add_child(UI.label(title, 15, accent))

	for u in army.get("units", []):
		var id := str(u.get("id", ""))
		_hp[id] = int(u.get("hp", 1))
		_max_hp[id] = maxi(int(u.get("hp", 1)), 1)

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		box.add_child(row)
		_rows[id] = row

		var name := UI.label(str(u.get("name", "")), 13, Palette.TEXT_DIM)
		name.custom_minimum_size = Vector2(110, 0)
		row.add_child(name)

		var bar := ProgressBar.new()
		bar.show_percentage = false
		bar.max_value = _max_hp[id]
		bar.value = _hp[id]
		bar.custom_minimum_size = Vector2(0, 14)
		bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bar.add_theme_stylebox_override("background", UI.panel_box(Palette.PANEL, Color.TRANSPARENT, 4))
		bar.add_theme_stylebox_override("fill", UI.panel_box(accent, Color.TRANSPARENT, 4))
		row.add_child(bar)
		_bars[id] = bar
	return box


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


func _set_hp(id: String, hp: int) -> void:
	if not _bars.has(id):
		return
	_hp[id] = hp
	var bar: ProgressBar = _bars[id]
	if _skip:
		bar.value = hp
		return
	var tw := create_tween()
	tw.tween_property(bar, "value", float(hp), minf(0.12, _interval * 2.0))


func _kill(id: String) -> void:
	if _rows.has(id):
		var row: Control = _rows[id]
		row.modulate = Color(0.45, 0.4, 0.38, 0.55)


func _show_damage(id: String, dmg: int, crit: bool) -> void:
	_show_text(id, ("%d!" % dmg) if crit else str(dmg),
		Palette.GOLD if crit else Palette.DANGER, crit)


func _show_text(id: String, text: String, colour: Color, big: bool = false) -> void:
	if _skip or not _rows.has(id):
		return
	var row: Control = _rows[id]
	var l := UI.label(text, 20 if big else 15, colour)
	l.position = row.global_position + Vector2(row.size.x * 0.62, 0)
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
		UI.panel_box(Palette.PANEL, Palette.SUCCESS if won else Palette.DANGER))
	panel.custom_minimum_size = Vector2(300, 0)
	_root.add_child(panel)
	panel.position = _root.size / 2.0 - Vector2(150, 90)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	panel.add_child(col)

	col.add_child(UI.label("VICTORY" if won else "DEFEAT", 30,
		Palette.SUCCESS if won else Palette.DANGER, HORIZONTAL_ALIGNMENT_CENTER))

	if won:
		col.add_child(UI.label("+%s gold" % UI.number(int(_result.get("gold_stolen", 0))),
			20, Palette.GOLD, HORIZONTAL_ALIGNMENT_CENTER))
	else:
		col.add_child(UI.label("They kept their coin", 15, Palette.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER))
	col.add_child(UI.label("+%d experience" % int(_result.get("xp_gained", 0)),
		15, Palette.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER))

	var close := UI.button("CONTINUE", 18)
	close.custom_minimum_size = Vector2(0, 48)
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
