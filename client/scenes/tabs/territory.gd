extends VBoxContainer
## The Map Table: the estates that earn while you are away.
##
## Territory is the income engine. Unlike the Family tree — which is deliberately
## bottomless — holdings are priced to pay for themselves in a couple of weeks,
## so building them is a real investment rather than a vanity sink.

var _estates: Dictionary = {}
var _selected := ""
var _list: VBoxContainer
var _header: Label
var _income_card: PanelContainer
var _income: Label
var _waiting: Label
var _rate: Label
var _action: Button
var _action_sub: Label
var _busy := false


func _ready() -> void:
	add_theme_constant_override("separation", 8)
	# The income and the button that claims it belong with the estates that earn
	# it. They used to sit on the Hero screen, one tab away from the thing they
	# were describing.
	_income_card = PanelContainer.new()
	_income_card.add_theme_stylebox_override("panel", UI.panel_box(Palette.PANEL, Palette.GOLD_DEEP))
	add_child(_income_card)

	var pad := MarginContainer.new()
	for side in ["left", "right"]:
		pad.add_theme_constant_override("margin_" + side, 12)
	for side in ["top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, 10)
	_income_card.add_child(pad)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	pad.add_child(row)

	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 1)
	row.add_child(col)
	col.add_child(UI.label("YOUR ESTATES EARN", UI.F_MICRO, Palette.TEXT_FAINT))
	_income = UI.label("", UI.F_BODY, Palette.GOLD)
	col.add_child(_income)
	_waiting = UI.label("", UI.F_MICRO, Palette.TEXT_DIM)
	col.add_child(_waiting)

	# No COLLECT button. Estate income is credited continuously now, so the only
	# thing a button could do is interrupt the player to tell them so.
	_rate = UI.label("", UI.F_H2, Palette.GOLD, HORIZONTAL_ALIGNMENT_RIGHT)
	_rate.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_rate)

	_header = UI.label("Surveying your lands…", UI.F_CAPTION, Palette.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER)
	_header.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
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

	GameState.changed.connect(_rebuild)
	_reload()


func mount_action_bar(host: Control) -> void:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)
	host.add_child(col)
	_action = UI.button("SELECT AN ESTATE", UI.F_H2)
	_action.custom_minimum_size = Vector2(0, UI.TAP_PRIMARY)
	_action.pressed.connect(_buy)
	col.add_child(_action)
	_action_sub = UI.label("", UI.F_MICRO, Palette.TEXT_FAINT, HORIZONTAL_ALIGNMENT_CENTER)
	col.add_child(_action_sub)
	_refresh_action()


func _reload() -> void:
	var res: Api.Response = await Api.get_json("/v1/estates")
	if not res.ok:
		_header.text = res.error
		return
	_estates = res.data
	_rebuild()


func _rebuild() -> void:
	if _estates.is_empty():
		return

	var tax: Dictionary = _estates.get("tax", {})
	# Per hour, never per second: a rate of 0.008 gold a second reads as nothing.
	var per_hour := float(int(tax.get("per_hour_milli", 0))) / 1000.0
	_income.text = "%.1f gold every hour" % per_hour
	_waiting.text = "arriving in your purse as it is earned" if per_hour > 0.0 \
		else "buy an estate and it starts paying at once"
	_rate.text = "+%.1f/h" % per_hour
	_header.text = "Your estates pay you around the clock, whether you are here or not."

	var holdings: Array = _estates.get("holdings", [])
	var gold := GameState.display_gold()

	if _list.get_child_count() != holdings.size():
		for c in _list.get_children():
			c.queue_free()
		for h in holdings:
			var row := EstateRow.new(str(h.get("id", "")), "holdings")
			row.pressed.connect(_select.bind(str(h.get("id", ""))))
			_list.add_child(row)

	var i := 0
	for h in holdings:
		var row: EstateRow = _list.get_child(i)
		i += 1
		var lv := int(h.get("level", 0))
		var yield_hr := float(int(h.get("yield_per_hour_milli", 0))) / 1000.0
		var effect := "" if lv == 0 else "earning %.1f gold/hour" % yield_hr
		var locked := not bool(h.get("unlocked", false))
		row.refresh(str(h.get("name", "")),
			"An estate that pays while you are away.",
			lv, int(h.get("max_level", 0)), effect, int(h.get("next_cost", 0)),
			locked, "unlocks at level %d" % int(h.get("unlock_level", 0)),
			gold >= int(h.get("next_cost", 0)), str(h.get("id", "")) == _selected)
	_refresh_action()


func _select(id: String) -> void:
	_selected = id
	_rebuild()


func _selected_holding() -> Dictionary:
	for h in _estates.get("holdings", []):
		if str(h.get("id", "")) == _selected:
			return h
	return {}


func _refresh_action() -> void:
	if _action == null:
		return
	var h := _selected_holding()
	if h.is_empty() or _busy:
		_action.text = "…" if _busy else "SELECT AN ESTATE"
		_action.disabled = true
		_action_sub.text = ""
		return
	if bool(h.get("maxed", false)):
		_action.text = "%s IS FULLY BUILT" % str(h.get("name", "")).to_upper()
		_action.disabled = true
		_action_sub.text = ""
		return

	var cost := int(h.get("next_cost", 0))
	var can := GameState.display_gold() >= cost and bool(h.get("unlocked", false))
	var verb := "BUILD" if int(h.get("level", 0)) == 0 else "EXPAND"
	_action.text = "%s %s  —  %s" % [verb, str(h.get("name", "")).to_upper(), UI.number(cost)]
	_action.disabled = not can
	if not bool(h.get("unlocked", false)):
		_action_sub.text = "unlocks at level %d" % int(h.get("unlock_level", 0))
	elif not can:
		_action_sub.text = "not enough gold"
	else:
		_action_sub.text = "level %d to %d" % [int(h.get("level", 0)), int(h.get("level", 0)) + 1]


func _buy() -> void:
	var h := _selected_holding()
	if h.is_empty() or _busy:
		return
	if not await Confirm.ask(self, {
			"title": "Buy %s?" % str(h.get("name", "this estate")),
			"body": "Level %d to %d. %s" % [int(h.get("level", 0)),
				int(h.get("level", 0)) + 1, str(h.get("blurb", ""))],
			"cost": {"amount": int(h.get("next_cost", 0)), "currency": "gold"},
			"confirm_text": "Buy"}):
		return
	_busy = true
	_refresh_action()
	var res: Api.Response = await Api.post_json("/v1/estates/holding",
		{"id": _selected, "action_seq": int(GameState.player().get("action_seq", 0)) + 1})
	_busy = false
	if not res.ok:
		GameState.action_failed.emit(res.error)
	else:
		_estates = res.data
	await GameState.refresh()
	_rebuild()


