extends VBoxContainer
## The Collect tab: the game's core loop.
##
## Pick a job, then tap the big button. The button lives in the shell's bottom
## strip because that is the only part of a tall phone a thumb reaches, and this
## is the action a player performs hundreds of times a session.

const ICON_SIZE := UI.ICON_LG

var _selected := ""
var _rows: Dictionary = {}
var _list: VBoxContainer
var _action: Button
var _action_sub: Label

## Today's three tasks.
##
## They live here rather than on a tenth rail entry: most of them are about
## collecting, this is the screen a player already has open while doing it, and
## shell_fits.gd measures the rail's column against an iPad that has no room.
##
## Kept OUTSIDE the job list's container because that list rebuilds by diffing
## row counts, and quests appearing would look like the job set changed.
var _quests: VBoxContainer
var _quest_busy := false
## Throttles the quest refresh. `changed` fires on every settled batch, and a
## request per tap would be a storm; three seconds is fast enough that a counter
## looks live and slow enough to cost nothing.
var _quests_at_ms := 0
const QUEST_REFRESH_MS := 3000


func _ready() -> void:
	add_theme_constant_override("separation", 8)

	_quests = VBoxContainer.new()
	_quests.add_theme_constant_override("separation", 4)
	add_child(_quests)

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

	GameState.changed.connect(_rebuild)
	GameState.changed.connect(_maybe_reload_quests)
	_reload_quests.call_deferred()
	# Energy regenerates without the snapshot changing, so the button has to be
	# re-armed from its own signal or it stays disabled until something else
	# happens to redraw it.
	GameState.energy_changed.connect(func(_v: int) -> void: _refresh_action())
	_rebuild()


## The shell owns the bottom strip, so the tab hands it a button rather than
## drawing one inside its own scroll area.
func mount_action_bar(host: Control) -> void:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)
	host.add_child(col)

	_action = UI.button("SELECT A JOB", UI.F_H2)
	_action.custom_minimum_size = Vector2(0, UI.TAP_PRIMARY)
	_action.pressed.connect(_collect_selected)
	col.add_child(_action)

	_action_sub = UI.label("", UI.F_MICRO, Palette.TEXT_FAINT, HORIZONTAL_ALIGNMENT_CENTER)
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
	b.custom_minimum_size = Vector2(0, UI.TAP_ROW)
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

	# Fifteen rows of near-identical text are hard to scan. The icon is how a
	# player finds the job they were on without reading every name.
	var icon := TextureRect.new()
	icon.texture = ArtRegistry.ui_icon("jobs/" + str(job.get("id", "")))
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.custom_minimum_size = Vector2(ICON_SIZE, ICON_SIZE)
	row.add_child(icon)

	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.alignment = BoxContainer.ALIGNMENT_CENTER
	left.add_theme_constant_override("separation", 2)
	left.add_child(UI.label("", UI.F_H2, Palette.TEXT))     # 0 name
	left.add_child(UI.label("", UI.F_MICRO, Palette.TEXT_FAINT)) # 1 mastery / unlock
	row.add_child(left)

	var right := VBoxContainer.new()
	right.alignment = BoxContainer.ALIGNMENT_CENTER
	right.add_theme_constant_override("separation", 2)
	right.add_child(UI.label("", UI.F_H2, Palette.GOLD_INK, HORIZONTAL_ALIGNMENT_RIGHT))   # 0 gold
	right.add_child(UI.label("", UI.F_CAPTION, Palette.ENERGY, HORIZONTAL_ALIGNMENT_RIGHT)) # 1 cost
	row.add_child(right)

	return b


func _update_row(row: Control, job: Dictionary) -> void:
	var id := str(job.get("id", ""))
	var unlocked := bool(job.get("unlocked", false))
	var selected := id == _selected
	var affordable := unlocked and GameState.display_energy() >= int(job.get("energy_cost", 0))

	var box := row.get_child(0).get_child(0)
	var icon: TextureRect = box.get_child(0)
	var left: VBoxContainer = box.get_child(1)
	var right: VBoxContainer = box.get_child(2)

	# Gold when it is the job you are about to run, plain when available, faint
	# when still locked -- the same three states the row's text already uses.
	if selected:
		icon.modulate = Palette.GOLD
	else:
		icon.modulate = Palette.TEXT if unlocked else Palette.TEXT_FAINT

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
		Palette.GOLD_INK if unlocked else Palette.TEXT_FAINT)
	(right.get_child(1) as Label).text = "%d energy" % int(job.get("energy_cost", 0))

	# The same lit surfaces every other card in the game uses. These were still
	# flat boxes, which is why the jobs list -- the screen the game is mostly
	# played on -- looked plainer than everything around it. A locked job is
	# sunken, the selected one is raised with a gold edge.
	row.add_theme_stylebox_override("normal", UI.card_box(selected, not unlocked))
	row.add_theme_stylebox_override("hover", UI.card_box(true, not unlocked))
	row.add_theme_stylebox_override("pressed", UI.skin("ghost_press", Palette.PANEL, 14, 10))
	# A locked row is disabled, and with no box of its own it would fall back to
	# the engine default and disappear.
	row.add_theme_stylebox_override("disabled", UI.card_box(false, true))
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
		# Refused locally, so there is no round trip and no flicker. Re-running
		# the whole refresh rather than only writing the message: the message was
		# the half that never got cleared, because the only thing that rewrites it
		# is the call that was not happening.
		_refresh_action()


## The shell calls this on every re-entry to a cached section. Collect renders
## straight from GameState so it has nothing to re-fetch, but re-arming the
## button here kills the stale-disabled bug from a second direction.
func _reload() -> void:
	_rebuild()


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

	# No "N queued" any more. The gold and the experience have ALREADY moved on
	# screen by the time this runs -- the queue is an implementation detail of
	# getting the server to agree, and announcing it was the single thing making
	# a tap that already happened feel like it had not.
	if not can:
		_action_sub.text = "Not enough energy"
	else:
		_action_sub.text = "+%s gold   +%d xp" % [
			UI.number(int(job.get("gold_payout", 0))), int(job.get("xp_payout", 0))]


## Draws today's tasks, and refreshes them after anything that could advance one.
func _reload_quests() -> void:
	var res: Api.Response = await Api.get_json("/v1/quests")
	if not res.ok:
		return
	for c in _quests.get_children():
		c.queue_free()

	var list: Array = res.data.get("quests", [])
	if list.is_empty():
		return
	_quests.add_child(UI.label("TODAY", UI.F_MICRO, Palette.TEXT_FAINT))
	for qv in list:
		_quests.add_child(_quest_row(qv))


func _quest_row(qv: Dictionary) -> Control:
	var done := bool(qv.get("done", false))
	var claimed := bool(qv.get("claimed", false))

	var b := Button.new()
	b.custom_minimum_size = Vector2(0, 44)
	b.focus_mode = Control.FOCUS_NONE
	b.disabled = claimed or not done
	b.add_theme_stylebox_override("normal", UI.panel_box(
		Palette.PANEL_HIGH if (done and not claimed) else Palette.PANEL,
		Palette.GOLD_DEEP if (done and not claimed) else Palette.LINE))
	b.add_theme_stylebox_override("disabled", UI.panel_box(Palette.PANEL, Palette.LINE))
	b.pressed.connect(_claim_quest.bind(int(qv.get("slot", 0))))

	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 10)
	b.add_child(margin)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	margin.add_child(row)

	var name_col := VBoxContainer.new()
	name_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_col.alignment = BoxContainer.ALIGNMENT_CENTER
	name_col.add_theme_constant_override("separation", 0)
	row.add_child(name_col)
	name_col.add_child(UI.label(str(qv.get("name", "")), UI.F_CAPTION,
		Palette.TEXT_DIM if claimed else Palette.TEXT))
	name_col.add_child(UI.label("%d / %d" % [int(qv.get("progress", 0)), int(qv.get("target", 0))],
		UI.F_MICRO, Palette.TEXT_FAINT))

	var right := "TAKEN"
	var tint := Palette.TEXT_FAINT
	if not claimed:
		right = "CLAIM" if done else "%s g  ·  %s xp" % [
			UI.number(int(qv.get("gold", 0))), UI.number(int(qv.get("xp", 0)))]
		tint = Palette.GOLD_INK if done else Palette.TEXT_DIM
	row.add_child(UI.label(right, UI.F_CAPTION, tint))
	return b


func _claim_quest(slot: int) -> void:
	if _quest_busy:
		return
	_quest_busy = true
	var seq := int(GameState.player().get("action_seq", 0)) + 1
	var res: Api.Response = await Api.post_json("/v1/quests/claim",
		{"slot": slot, "action_seq": seq})
	_quest_busy = false
	if not res.ok:
		GameState.action_failed.emit(res.error)
	await GameState.refresh()
	await _reload_quests()


func _maybe_reload_quests() -> void:
	var now := Time.get_ticks_msec()
	if now - _quests_at_ms < QUEST_REFRESH_MS:
		return
	_quests_at_ms = now
	await _reload_quests()
