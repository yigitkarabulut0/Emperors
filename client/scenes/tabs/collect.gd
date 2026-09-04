extends VBoxContainer
## The Collect tab: the game's core loop.
##
## Pick a job, then tap the big button. The button lives in the shell's bottom
## strip because that is the only part of a tall phone a thumb reaches, and this
## is the action a player performs hundreds of times a session.

var _selected := ""
var _rows: Dictionary = {}
var _list: VBoxContainer
var _action: Button
var _action_sub: Label


func _ready() -> void:
	add_theme_constant_override("separation", 8)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)

	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 6)
	scroll.add_child(_list)

	GameState.changed.connect(_rebuild)
	_rebuild()


## The shell owns the bottom strip, so the tab hands it a button rather than
## drawing one inside its own scroll area.
func mount_action_bar(host: Control) -> void:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)
	host.add_child(col)

	_action = UI.button("SELECT A JOB", 21)
	_action.custom_minimum_size = Vector2(0, 54)
	_action.pressed.connect(_collect_selected)
	col.add_child(_action)

	_action_sub = UI.label("", 12, Palette.TEXT_FAINT, HORIZONTAL_ALIGNMENT_CENTER)
	col.add_child(_action_sub)

	_refresh_action()


func _rebuild() -> void:
	if not GameState.has_state():
		return

	var jobs := GameState.jobs()
	# Auto-select the best job the player can currently afford, so a new player's
	# first tap needs no decision and a returning player's default is not stale.
	if _selected == "":
		for j in jobs:
			if bool(j.get("unlocked", false)):
				_selected = str(j.get("id", ""))

	# Rebuild only when the row set changed; otherwise update in place so tapping
	# does not rebuild 15 rows and lose scroll position.
	if _rows.size() != jobs.size():
		for c in _list.get_children():
			c.queue_free()
		_rows.clear()
		for j in jobs:
			var row := _build_row(j)
			_list.add_child(row)
			_rows[str(j.get("id", ""))] = row

	for j in jobs:
		var row: Control = _rows.get(str(j.get("id", "")))
		if row:
			_update_row(row, j)

	_refresh_action()


func _build_row(job: Dictionary) -> Control:
	var b := Button.new()
	b.custom_minimum_size = Vector2(0, 76)
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(_select.bind(str(job.get("id", ""))))
	b.set_meta("job_id", str(job.get("id", "")))

	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 14)
	b.add_child(margin)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	margin.add_child(row)

	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.alignment = BoxContainer.ALIGNMENT_CENTER
	left.add_theme_constant_override("separation", 2)
	left.add_child(UI.label("", 18, Palette.TEXT))     # 0 name
	left.add_child(UI.label("", 12, Palette.TEXT_FAINT)) # 1 mastery / unlock
	row.add_child(left)

	var right := VBoxContainer.new()
	right.alignment = BoxContainer.ALIGNMENT_CENTER
	right.add_theme_constant_override("separation", 2)
	right.add_child(UI.label("", 18, Palette.GOLD, HORIZONTAL_ALIGNMENT_RIGHT))   # 0 gold
	right.add_child(UI.label("", 13, Palette.ENERGY, HORIZONTAL_ALIGNMENT_RIGHT)) # 1 cost
	row.add_child(right)

	return b


func _update_row(row: Control, job: Dictionary) -> void:
	var id := str(job.get("id", ""))
	var unlocked := bool(job.get("unlocked", false))
	var selected := id == _selected
	var affordable := unlocked and GameState.display_energy() >= int(job.get("energy_cost", 0))

	var box := row.get_child(0).get_child(0)
	var left: VBoxContainer = box.get_child(0)
	var right: VBoxContainer = box.get_child(1)

	(left.get_child(0) as Label).text = str(job.get("name", ""))
	(left.get_child(0) as Label).add_theme_color_override("font_color",
		Palette.TEXT if unlocked else Palette.TEXT_FAINT)

	var sub := ""
	if not unlocked:
		sub = "unlocks at level %d" % int(job.get("unlock_level", 0))
	else:
		var done := int(job.get("collects", 0))
		var bonus := int(job.get("mastery_bonus_bp", 0))
		var next := int(job.get("next_milestone", 0))
		sub = "%d done" % done
		if bonus > 0:
			sub += "   +%d%% mastery" % (bonus / 100)
		if next > 0:
			sub += "   next at %d" % next
	(left.get_child(1) as Label).text = sub

	(right.get_child(0) as Label).text = "+" + UI.number(int(job.get("gold_payout", 0)))
	(right.get_child(0) as Label).add_theme_color_override("font_color",
		Palette.GOLD if unlocked else Palette.TEXT_FAINT)
	(right.get_child(1) as Label).text = "%d energy" % int(job.get("energy_cost", 0))

	var bg := Palette.PANEL
	if selected:
		bg = Palette.PANEL_HIGH
	elif not unlocked:
		bg = Palette.BG
	var border := Palette.GOLD_DEEP if selected else Color.TRANSPARENT
	row.add_theme_stylebox_override("normal", UI.panel_box(bg, border))
	row.add_theme_stylebox_override("hover", UI.panel_box(Palette.PANEL_HIGH, border))
	row.add_theme_stylebox_override("pressed", UI.panel_box(Palette.PANEL, border))
	row.disabled = not unlocked
	row.modulate.a = 1.0 if affordable or not unlocked else 0.75


func _select(id: String) -> void:
	_selected = id
	_rebuild()


func _selected_job() -> Dictionary:
	for j in GameState.jobs():
		if str(j.get("id", "")) == _selected:
			return j
	return {}


func _collect_selected() -> void:
	var job := _selected_job()
	if job.is_empty():
		return
	if not GameState.collect(job):
		# Refused locally, so there is no round trip and no flicker.
		_action_sub.text = "Not enough energy"


func _refresh_action() -> void:
	if _action == null:
		return
	var job := _selected_job()
	if job.is_empty():
		_action.text = "SELECT A JOB"
		_action.disabled = true
		_action_sub.text = ""
		return

	var cost := int(job.get("energy_cost", 0))
	var can := GameState.display_energy() >= cost
	_action.text = "%s  —  %d ⚡" % [str(job.get("name", "")).to_upper(), cost]
	_action.disabled = not can

	var queued := GameState.pending_count()
	if queued > 0:
		_action_sub.text = "%d queued" % queued
	elif not can:
		_action_sub.text = "Not enough energy"
	else:
		_action_sub.text = "+%s gold   +%d xp" % [
			UI.number(int(job.get("gold_payout", 0))), int(job.get("xp_payout", 0))]
