extends VBoxContainer
## The War Gate: pick a target, raid it, watch it resolve.
##
## Three targets, not a forced pairing. A perfectly fair matchmaker produces a
## 50% win rate, which players experience as losing half the time; choosing from
## a band makes every raid a decision they own.

enum Mode { RAID, HISTORY }

var _view: Dictionary = {}
var _log: Dictionary = {}
var _selected := ""
var _mode := Mode.RAID
var _tabs: HBoxContainer
var _tab_buttons: Array[Button] = []
var _list: VBoxContainer
var _header: Label
var _action: Button
var _action_sub: Label
var _busy := false


func _ready() -> void:
	add_theme_constant_override("separation", 8)

	# Two views on one screen rather than a tenth rail section: the rail is full
	# at nine and shell_fits.gd measures its column against an iPad, so a new
	# entry there costs height every device has to find.
	_tabs = HBoxContainer.new()
	_tabs.add_theme_constant_override("separation", 4)
	add_child(_tabs)
	for entry in [[Mode.RAID, "Raid"], [Mode.HISTORY, "History"]]:
		var b := UI.ghost_button(str(entry[1]), UI.F_BODY)
		b.custom_minimum_size = Vector2(0, UI.TAP_MIN)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var m: int = int(entry[0])
		b.pressed.connect(func() -> void:
			_mode = m
			_reload())
		_tabs.add_child(b)
		_tab_buttons.append(b)

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
	_style_tabs()
	if _mode == Mode.HISTORY:
		var h: Api.Response = await Api.get_json("/v1/attack/history")
		if not h.ok:
			_header.text = h.error
			return
		_log = h.data
		_build_history()
		return

	var res: Api.Response = await Api.get_json("/v1/attack/targets")
	if not res.ok:
		_header.text = res.error
		return
	_view = res.data
	if _selected == "" and not _view.get("targets", []).is_empty():
		_selected = str(_view["targets"][0].get("player_id", ""))
	_rebuild()


func _style_tabs() -> void:
	for i in _tab_buttons.size():
		var b: Button = _tab_buttons[i]
		var active: bool = i == _mode
		b.add_theme_stylebox_override("normal",
			UI.panel_box(Palette.PANEL_HIGH if active else Palette.PANEL,
				Palette.GOLD_DEEP if active else Palette.LINE))
		b.add_theme_color_override("font_color", Palette.GOLD_INK if active else Palette.TEXT_DIM)


func _rebuild() -> void:
	for c in _list.get_children():
		c.queue_free()

	_header.text = "Your Might %s     %d energy per raid" % [
		UI.number(int(_view.get("might", 0))), int(_view.get("energy_cost", 0))]

	var shield: Variant = _view.get("shield_until")
	if shield != null:
		_list.add_child(_banner("You are under protection — nobody can raid you", Palette.SUCCESS))

	# Scores to settle come first. A raid you did not choose is the one the
	# player came here to answer, and the token expires in a day.
	var revenge: Array = _view.get("revenge", [])
	if not revenge.is_empty():
		_list.add_child(UI.section_header("SCORES TO SETTLE"))
		for rv in revenge:
			_list.add_child(_revenge_row(rv))

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
		risk = Palette.GOLD_INK
		risk_word = "an even match"

	var b := Button.new()
	b.custom_minimum_size = Vector2(0, UI.TAP_ROW)
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(func() -> void:
		_selected = id
		_rebuild())
	var border := risk if selected else Color.TRANSPARENT
	b.add_theme_stylebox_override("normal", UI.card_box(selected))
	b.add_theme_stylebox_override("hover", UI.card_box(true))
	b.add_theme_stylebox_override("pressed", UI.skin("ghost_press", Palette.PANEL, 14, 10))
	b.add_theme_stylebox_override("disabled", UI.card_box(false, true))

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
	right.add_child(UI.label("+%s" % UI.number(int(t.get("estimated_steal", 0))), UI.F_H2, Palette.GOLD_INK,
		HORIZONTAL_ALIGNMENT_RIGHT))
	right.add_child(UI.label("if you win", UI.F_MICRO, Palette.TEXT_FAINT, HORIZONTAL_ALIGNMENT_RIGHT))
	return b


func _selected_target() -> Dictionary:
	for t in _view.get("targets", []):
		if str(t.get("player_id", "")) == _selected:
			return t
	# A score to settle is a target too, and it is deliberately NOT in the
	# shortlist: the matchmaker would never offer somebody who is shielded or on
	# cooldown, which is exactly who you are owed a strike against.
	for rv in _view.get("revenge", []):
		if str(rv.get("target_id", "")) == _selected:
			return {"player_id": _selected, "name": str(rv.get("target_name", "")),
				"level": int(rv.get("target_level", 0))}
	return {}


func _refresh_action() -> void:
	if _action == null:
		return
	if _busy:
		_action.text = "…"
		_action.disabled = true
		return
	# Nothing to commit energy to on the history view; tapping a row watches it.
	if _mode == Mode.HISTORY:
		_action.text = "TAP A FIGHT TO WATCH IT"
		_action.disabled = true
		_action_sub.text = ""
		return
	var t := _selected_target()
	if t.is_empty():
		_action.text = "SELECT A TARGET"
		_action.disabled = true
		_action_sub.text = ""
		return
	var cost := int(_view.get("energy_cost", 0))
	var avenging := _is_revenge(_selected)
	if avenging:
		cost = maxi(cost / 2, 1)
	var can := GameState.display_energy() >= cost
	_action.text = "%s %s  —  %d ⚡" % [
		"AVENGE" if avenging else "RAID", str(t.get("name", "")).to_upper(), cost]
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
		{"target_id": _selected, "action_seq": seq, "revenge": _is_revenge(_selected)})
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


## The raid log, both directions.
##
## The defending half is the reason this screen exists. Every fight was already
## stored with its replay; nothing read it, so a player who was raided overnight
## woke up with less gold and no account of who took it. The ransom rule --
## which pays you for LOSING a defence -- could never be experienced as news.
func _build_history() -> void:
	for c in _list.get_children():
		c.queue_free()
	_selected = ""

	var entries: Array = _log.get("entries", [])
	if entries.is_empty():
		_header.text = "No raids yet, in either direction"
		_list.add_child(_banner("Win or lose, every fight is kept here.", Palette.TEXT_DIM))
		_refresh_action()
		return

	var raids := 0
	var net := 0
	for e in entries:
		if bool(e.get("raided", false)):
			raids += 1
		net += int(e.get("gold", 0))
	_header.text = "%d fights   ·   %d against you   ·   %s gold overall" % [
		entries.size(), raids, UI.number(net)]

	for e in entries:
		_list.add_child(_history_row(e))
	_refresh_action()


func _history_row(e: Dictionary) -> Control:
	var raided := bool(e.get("raided", false))
	var won := bool(e.get("won", false))
	var gold := int(e.get("gold", 0))

	var b := Button.new()
	b.custom_minimum_size = Vector2(0, UI.TAP_ROW)
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_stylebox_override("normal", UI.card_box())
	b.add_theme_stylebox_override("hover", UI.card_box(true))
	b.pressed.connect(_watch.bind(e))

	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 10)
	b.add_child(margin)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	margin.add_child(row)

	var face := TextureRect.new()
	face.custom_minimum_size = Vector2(44, 44)
	face.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	face.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	face.texture = ArtRegistry.portrait(str(e.get("opponent_avatar", "")))
	row.add_child(face)

	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 2)
	row.add_child(col)

	# Told from the player's side, not the record's: "they raided you" is the
	# sentence a defender needs, and the server already resolved which side
	# they were on.
	var who := str(e.get("opponent_name", "someone"))
	var line := ("%s raided you" % who) if raided else ("You raided %s" % who)
	col.add_child(UI.label(line, UI.F_BODY, Palette.TEXT))

	var verdict := "held them off" if won else "took the field"
	if not raided:
		verdict = "you won" if won else "you were driven back"
	col.add_child(UI.label("level %d   ·   %s" % [int(e.get("opponent_level", 0)), verdict],
		UI.F_CAPTION, Palette.TEXT_DIM))

	var amount := UI.number(absi(gold))
	var tint := Palette.TEXT_DIM
	if gold > 0:
		amount = "+" + amount
		tint = Palette.SUCCESS
	elif gold < 0:
		amount = "−" + amount
		tint = Palette.DANGER
	row.add_child(UI.label(amount, UI.F_BODY, tint))
	return b


## Replays a stored fight.
##
## The overlay takes the same payload shape the live raid hands it, so the
## animation path is shared rather than reimplemented -- the client still never
## simulates anything, it only ever animates a log the server produced.
func _watch(e: Dictionary) -> void:
	if _busy:
		return
	_busy = true
	var res: Api.Response = await Api.get_json("/v1/battles/%s" % str(e.get("battle_id", "")))
	_busy = false
	if not res.ok:
		GameState.action_failed.emit(res.error)
		return

	var replay := preload("res://scenes/battle/battle_replay.gd").new()
	replay.setup({
		"won": bool(e.get("won", false)),
		"gold_stolen": maxi(int(e.get("gold", 0)), 0),
		"xp_gained": int(e.get("xp_gained", 0)),
		"replay": res.data,
	}, {
		"name": str(e.get("opponent_name", "")),
		"avatar": str(e.get("opponent_avatar", "")),
		"level": int(e.get("opponent_level", 0)),
	})
	get_tree().root.add_child(replay)
	await replay.finished


## Is the selected target somebody we owe a strike back?
func _is_revenge(target_id: String) -> bool:
	for rv in _view.get("revenge", []):
		if str(rv.get("target_id", "")) == target_id:
			return true
	return false


## One score to settle.
##
## Deliberately louder than a normal target row: this is the thing that makes
## opening the game after a raid worth doing, and it stops mattering in a day.
func _revenge_row(rv: Dictionary) -> Control:
	var id := str(rv.get("target_id", ""))
	var selected := id == _selected

	var b := Button.new()
	b.custom_minimum_size = Vector2(0, UI.TAP_ROW)
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_stylebox_override("normal", UI.panel_box(
		Palette.PANEL_HIGH if selected else Palette.PANEL, Palette.DANGER))
	b.add_theme_stylebox_override("hover", UI.panel_box(Palette.PANEL_HIGH, Palette.DANGER))
	b.pressed.connect(func() -> void:
		_selected = id
		_rebuild())

	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 10)
	b.add_child(margin)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	margin.add_child(row)

	var face := TextureRect.new()
	face.custom_minimum_size = Vector2(44, 44)
	face.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	face.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	face.texture = ArtRegistry.portrait(str(rv.get("target_avatar", "")))
	row.add_child(face)

	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 2)
	row.add_child(col)
	col.add_child(UI.label("%s robbed you" % str(rv.get("target_name", "someone")),
		UI.F_BODY, Palette.TEXT))
	col.add_child(UI.label("half energy   ·   their shield will not save them",
		UI.F_CAPTION, Palette.DANGER))

	row.add_child(UI.label("LEVEL %d" % int(rv.get("target_level", 0)), UI.F_CAPTION, Palette.TEXT_DIM))
	return b
