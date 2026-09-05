extends VBoxContainer
## The War Gate: pick a target, raid it, watch it resolve.
##
## Three targets, not a forced pairing. A perfectly fair matchmaker produces a
## 50% win rate, which players experience as losing half the time; choosing from
## a band makes every raid a decision they own.

var _view: Dictionary = {}
var _selected := ""
var _list: VBoxContainer
var _header: Label
var _action: Button
var _action_sub: Label
var _busy := false


func _ready() -> void:
	add_theme_constant_override("separation", 8)
	_header = UI.label("Scouting…", UI.F_CAPTION, Palette.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER)
	add_child(_header)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

	# Lists follow your finger. Godot's own touch scrolling is gated behind

	# is_touchscreen_available() and is eaten by the buttons the list is made of.

	DragScroll.install(scroll)
	add_child(scroll)

	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 6)
	scroll.add_child(_list)

	# Raiding is gated on energy the same way collecting is, and regeneration
	# never touches the snapshot, so the button needs its own signal to re-arm.
	GameState.energy_changed.connect(func(_v: int) -> void: _refresh_action())

	_reload()


func mount_action_bar(host: Control) -> void:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)
	host.add_child(col)
	_action = UI.button("SELECT A TARGET", UI.F_H2)
	_action.custom_minimum_size = Vector2(0, UI.TAP_PRIMARY)
	_action.pressed.connect(_raid)
	col.add_child(_action)
	_action_sub = UI.label("", UI.F_MICRO, Palette.TEXT_FAINT, HORIZONTAL_ALIGNMENT_CENTER)
	col.add_child(_action_sub)
	_refresh_action()


func _reload() -> void:
	var res: Api.Response = await Api.get_json("/v1/attack/targets")
	if not res.ok:
		_header.text = res.error
		return
	_view = res.data
	if _selected == "" and not _view.get("targets", []).is_empty():
		_selected = str(_view["targets"][0].get("player_id", ""))
	_rebuild()


func _rebuild() -> void:
	for c in _list.get_children():
		c.queue_free()

	_header.text = "Your Might %s     %d energy per raid" % [
		UI.number(int(_view.get("might", 0))), int(_view.get("energy_cost", 0))]

	var shield: Variant = _view.get("shield_until")
	if shield != null:
		_list.add_child(_banner("You are under protection — nobody can raid you", Palette.SUCCESS))

	var targets: Array = _view.get("targets", [])
	if targets.is_empty():
		_list.add_child(_banner("No lords within reach. Try again shortly.", Palette.TEXT_DIM))

	for t in targets:
		_list.add_child(_target_row(t))
	_refresh_action()


func _banner(text: String, colour: Color) -> Control:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", UI.panel_box(Palette.PANEL, colour))
	var l := UI.label(text, 14, colour, HORIZONTAL_ALIGNMENT_CENTER)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	p.add_child(l)
	return p


func _target_row(t: Dictionary) -> Control:
	var id := str(t.get("player_id", ""))
	var selected := id == _selected
	var mine := maxi(int(_view.get("might", 1)), 1)
	var ratio := float(int(t.get("might", 0))) / float(mine)

	# Colour by relative strength, not by outcome: the player should be able to
	# read the risk before committing energy, and never be told a win chance.
	var risk := Palette.SUCCESS
	var risk_word := "weaker"
	if ratio > 1.15:
		risk = Palette.DANGER
		risk_word = "stronger"
	elif ratio > 0.85:
		risk = Palette.GOLD
		risk_word = "an even match"

	var b := Button.new()
	b.custom_minimum_size = Vector2(0, UI.TAP_ROW)
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(func() -> void:
		_selected = id
		_rebuild())
	var border := risk if selected else Color.TRANSPARENT
	b.add_theme_stylebox_override("normal", UI.panel_box(Palette.PANEL_HIGH if selected else Palette.PANEL, border))
	b.add_theme_stylebox_override("hover", UI.panel_box(Palette.PANEL_HIGH, border))
	b.add_theme_stylebox_override("pressed", UI.panel_box(Palette.PANEL, border))

	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 12)
	b.add_child(margin)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	margin.add_child(row)

	# The face is the point of portraits. In asynchronous PvP an opponent is a row
	# on a list and never a person you meet, so without it every raid target reads
	# as the same anonymous stranger.
	var face := TextureRect.new()
	face.texture = ArtRegistry.portrait(str(t.get("avatar", "knight")))
	face.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	face.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	face.custom_minimum_size = Vector2(52, 52)
	face.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(face)

	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 2)
	row.add_child(col)
	col.add_child(UI.label(str(t.get("name", "")), UI.F_BODY, Palette.TEXT))
	col.add_child(UI.label("level %d   ·   %s" % [int(t.get("level", 1)), risk_word], 12, risk))
	col.add_child(UI.label("Might %s" % UI.number(int(t.get("might", 0))), UI.F_CAPTION, Palette.TEXT_DIM))

	var right := VBoxContainer.new()
	right.alignment = BoxContainer.ALIGNMENT_CENTER
	right.add_theme_constant_override("separation", 2)
	row.add_child(right)
	right.add_child(UI.label("+%s" % UI.number(int(t.get("estimated_steal", 0))), UI.F_H2, Palette.GOLD,
		HORIZONTAL_ALIGNMENT_RIGHT))
	right.add_child(UI.label("if you win", UI.F_MICRO, Palette.TEXT_FAINT, HORIZONTAL_ALIGNMENT_RIGHT))
	return b


func _selected_target() -> Dictionary:
	for t in _view.get("targets", []):
		if str(t.get("player_id", "")) == _selected:
			return t
	return {}


func _refresh_action() -> void:
	if _action == null:
		return
	if _busy:
		_action.text = "…"
		_action.disabled = true
		return
	var t := _selected_target()
	if t.is_empty():
		_action.text = "SELECT A TARGET"
		_action.disabled = true
		_action_sub.text = ""
		return
	var cost := int(_view.get("energy_cost", 0))
	var can := GameState.display_energy() >= cost
	_action.text = "RAID %s  —  %d ⚡" % [str(t.get("name", "")).to_upper(), cost]
	_action.disabled = not can
	_action_sub.text = "" if can else "not enough energy"


func _raid() -> void:
	var t := _selected_target()
	if t.is_empty() or _busy:
		return
	_busy = true
	_refresh_action()

	var seq := int(GameState.player().get("action_seq", 0)) + 1
	var res: Api.Response = await Api.post_json("/v1/attack",
		{"target_id": _selected, "action_seq": seq})
	_busy = false

	if not res.ok:
		GameState.action_failed.emit(res.error)
		await GameState.refresh()
		await _reload()
		return

	# The client NEVER simulates. It animates the log the server produced, which
	# keeps cross-platform float determinism off the correctness path entirely.
	var replay := preload("res://scenes/battle/battle_replay.gd").new()
	replay.setup(res.data, t)
	get_tree().root.add_child(replay)

	await replay.finished
	_selected = ""
	await GameState.refresh()
	await _reload()
