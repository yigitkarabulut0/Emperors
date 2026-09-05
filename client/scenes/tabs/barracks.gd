extends VBoxContainer
## The Barracks: your army, its Might, and the three ways to grow it —
## buy a slot, recruit into it, train the veteran you already have.

const TIER_PIPS := {"common": 1, "uncommon": 2, "rare": 3, "epic": 4, "legendary": 5, "mystic": 6, "special": 7}

var _army: Dictionary = {}
var _selected := -1          # slot index, or -1 for the hero
var _list: VBoxContainer
var _might: Label
var _sub: Label
var _action: Button
var _action_sub: Label
var _busy := false
var _dev_sheet_done := false
var _auto: Button


func _ready() -> void:
	add_theme_constant_override("separation", 8)

	var head := VBoxContainer.new()
	head.add_theme_constant_override("separation", 0)
	add_child(head)
	_might = UI.label("—", UI.F_DISPLAY, Palette.GOLD, HORIZONTAL_ALIGNMENT_CENTER)
	head.add_child(_might)
	_sub = UI.label("", UI.F_CAPTION, Palette.TEXT_FAINT, HORIZONTAL_ALIGNMENT_CENTER)
	head.add_child(_sub)

	# Dressing four units from a bag of 150 by hand is busywork, and the server
	# already knows what "best" means. You first, then the strongest soldier down.
	_auto = UI.ghost_button("EQUIP EVERYONE'S BEST GEAR", UI.F_CAPTION)
	_auto.custom_minimum_size = Vector2(0, UI.TAP_MIN)
	_auto.pressed.connect(_auto_equip)
	head.add_child(UI.spacer(6))
	head.add_child(_auto)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)

	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 6)
	scroll.add_child(_list)

	_reload()


func mount_action_bar(host: Control) -> void:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)
	host.add_child(col)

	_action = UI.button("—", UI.F_H2)
	_action.custom_minimum_size = Vector2(0, UI.TAP_PRIMARY)
	_action.pressed.connect(_do_action)
	col.add_child(_action)

	_action_sub = UI.label("", UI.F_MICRO, Palette.TEXT_FAINT, HORIZONTAL_ALIGNMENT_CENTER)
	col.add_child(_action_sub)
	_refresh_action()


func _reload() -> void:
	var res: Api.Response = await Api.get_json("/v1/army")
	if not res.ok:
		_sub.text = res.error
		return
	_army = res.data
	_rebuild()


func _rebuild() -> void:
	for c in _list.get_children():
		c.queue_free()

	var totals: Dictionary = _army.get("totals", {})
	_might.text = UI.number(int(totals.get("might", 0)))
	_sub.text = "MIGHT     attack %s     defence %s     %d in the field" % [
		UI.number(int(totals.get("attack", 0))),
		UI.number(int(totals.get("ehp", 0)) / 10),
		int(totals.get("units", 0))]

	_list.add_child(_unit_row(_army.get("hero", {}), -1, true))

	for slot in _army.get("slots", []):
		_list.add_child(_unit_row(slot.get("soldier", {}), int(slot.get("index", 0)), false))

	var next: Variant = _army.get("next_slot")
	if next is Dictionary:
		_list.add_child(_next_slot_row(next))

	_refresh_action()
	if not _dev_sheet_done:
		_dev_sheet_done = true
		_dev_open_sheet()


func _unit_row(unit: Variant, slot_index: int, is_hero: bool) -> Control:
	var b := Button.new()
	b.custom_minimum_size = Vector2(0, UI.TAP_ROW)
	b.focus_mode = Control.FOCUS_NONE
	# First tap selects, so the action bar targets it. Tapping the one already
	# selected opens its sheet -- gear and dismissal live there. Two gestures on
	# one row beats a second row of buttons on a phone.
	b.pressed.connect(func() -> void:
		if _selected == slot_index and unit is Dictionary:
			_open_sheet(unit, is_hero)
			return
		_selected = slot_index
		_rebuild())

	var selected := _selected == slot_index
	var tier := ""
	if unit is Dictionary and unit.has("tier"):
		tier = str(unit.get("tier", ""))
	var accent := Palette.tier(tier) if tier != "" else Palette.GOLD_DEEP
	var border := accent if selected else Color.TRANSPARENT
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

	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 2)
	row.add_child(col)

	if not (unit is Dictionary) or unit.is_empty():
		col.add_child(UI.label("Slot %d — empty" % slot_index, UI.F_BODY, Palette.TEXT_DIM))
		col.add_child(UI.label("Recruit someone to fill it", UI.F_MICRO, Palette.TEXT_FAINT))
		return b

	var title := str(unit.get("name", ""))
	if is_hero:
		title += "   (you)"
	col.add_child(UI.label(title, UI.F_BODY, Palette.TEXT))

	var meta := "level %d" % int(unit.get("level", 1))
	if tier != "":
		meta = "%s %s   level %d" % [tier.to_upper(), "*".repeat(TIER_PIPS.get(tier, 1)), int(unit.get("level", 1))]
	var meta_label := UI.label(meta, 12, accent)
	col.add_child(meta_label)

	col.add_child(UI.label("ATK %d   DEF %d   SPD %d   HP %d" % [
		int(unit.get("attack", 0)), int(unit.get("defense", 0)),
		int(unit.get("speed", 0)), int(unit.get("hp", 0))], UI.F_CAPTION, Palette.TEXT_DIM))

	# Three small squares showing which gear slots are filled: the fastest way to
	# see at a glance that a soldier is naked.
	var gear := HBoxContainer.new()
	gear.alignment = BoxContainer.ALIGNMENT_CENTER
	gear.add_theme_constant_override("separation", 4)
	gear.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(gear)

	var equipped: Dictionary = unit.get("equipped", {})
	for slot_name in ["weapon", "armor", "horse"]:
		var cell := TextureRect.new()
		cell.custom_minimum_size = Vector2(30, 30)
		# Without EXPAND_IGNORE_SIZE a TextureRect reports the texture's own size
		# as its minimum, so a 96px icon silently forces a 96px row and overflows
		# the card it sits in.
		cell.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		cell.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		var it: Variant = equipped.get(slot_name)
		if it is Dictionary:
			cell.texture = ArtRegistry.item_icon(str(it.get("art", "")), str(it.get("tier", "common")))
		else:
			# A painterly loot icon ghosted to 18% is mush at 30 px. The flat slot
			# silhouette still says WHICH kind of gear is missing at this size.
			cell.texture = ArtRegistry.ui_icon("slots/" + slot_name)
			cell.modulate = Palette.EMPTY_SLOT
		gear.add_child(cell)

	return b


## Opens the unit sheet: its three equipment slots, and dismissal.
func _dev_open_sheet() -> void:
	# Dev-only: a capture run disables input, so it cannot tap a row itself.
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--dev-sheet" and i + 1 < args.size():
			if args[i + 1] == "hero":
				_open_sheet(_army.get("hero", {}), true)
			else:
				for sl in _army.get("slots", []):
					var u: Variant = sl.get("soldier")
					if u is Dictionary:
						_open_sheet(u, false)
						return


func _open_sheet(unit: Dictionary, is_hero: bool) -> void:
	var sheet: CanvasLayer = load("res://scenes/shell/unit_sheet.gd").new(unit, is_hero)
	sheet.changed.connect(func() -> void:
		await _reload()
		_rebuild())
	add_child(sheet)


func _next_slot_row(next: Dictionary) -> Control:
	var b := Button.new()
	b.custom_minimum_size = Vector2(0, UI.TAP_ROW_TIGHT)
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(func() -> void:
		_selected = int(next.get("index", 0))
		_rebuild())

	var free := bool(next.get("free", false))
	var unlocked := bool(next.get("unlocked", false))
	var accent := Palette.SUCCESS if free else Palette.LINE
	b.add_theme_stylebox_override("normal", UI.panel_box(Palette.BG, accent))
	b.add_theme_stylebox_override("hover", UI.panel_box(Palette.PANEL, accent))
	b.add_theme_stylebox_override("pressed", UI.panel_box(Palette.BG, accent))

	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 12)
	b.add_child(margin)

	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 2)
	margin.add_child(col)

	col.add_child(UI.label("Slot %d" % int(next.get("index", 0)), UI.F_BODY, Palette.TEXT_DIM))
	if free:
		col.add_child(UI.label("FREE — your first barracks slot", UI.F_CAPTION, Palette.SUCCESS))
	elif unlocked:
		col.add_child(UI.label("%s gold" % UI.number(int(next.get("cost", 0))), UI.F_CAPTION, Palette.GOLD))
		# On the row, not just in the action bar: this is where the eye lands, and
		# nobody should grind 500 gold for the slot they are about to be given.
		var free_at := int(next.get("free_at_level", 0))
		if free_at > 0:
			col.add_child(UI.label("free at level %d — you can wait" % free_at,
				UI.F_MICRO, Palette.SUCCESS))
	else:
		col.add_child(UI.label("unlocks at level %d" % int(next.get("level_gate", 0)), UI.F_CAPTION, Palette.TEXT_FAINT))
	return b


func _selected_soldier() -> Dictionary:
	for slot in _army.get("slots", []):
		if int(slot.get("index", 0)) == _selected:
			var s: Variant = slot.get("soldier")
			return s if s is Dictionary else {}
	return {}


func _is_next_slot_selected() -> bool:
	var next: Variant = _army.get("next_slot")
	return next is Dictionary and int(next.get("index", 0)) == _selected \
		and _selected > _army.get("slots", []).size()


func _refresh_action() -> void:
	if _action == null:
		return
	if _busy:
		_action.text = "…"
		_action.disabled = true
		return

	if _is_next_slot_selected():
		var next: Dictionary = _army.get("next_slot")
		var free := bool(next.get("free", false))
		_action.disabled = not bool(next.get("unlocked", false))
		_action.text = "CLAIM FREE SLOT" if free else "BUY SLOT — %s" % UI.number(int(next.get("cost", 0)))
		var free_at := int(next.get("free_at_level", 0))
		if not bool(next.get("unlocked", false)):
			_action_sub.text = "reach level %d first" % int(next.get("level_gate", 0))
		elif free_at > 0:
			# Never let someone grind for a thing they are about to be given.
			_action_sub.text = "or wait — your first slot is free at level %d" % free_at
		else:
			_action_sub.text = ""
		return

	if _selected >= 1:
		var sold := _selected_soldier()
		if sold.is_empty():
			_action.text = "RECRUIT"
			_action.disabled = false
			var cheapest := _cheapest_recruit()
			_action_sub.text = "" if cheapest.is_empty() else \
				("free first recruit" if bool(cheapest.get("free", false))
					else "%s from %s gold" % [str(cheapest.get("name", "")), UI.number(int(cheapest.get("cost", 0)))])
			return
		if bool(sold.get("can_train", false)):
			_action.text = "TRAIN — %s" % UI.number(int(sold.get("train_cost", 0)))
			_action.disabled = GameState.display_gold() < int(sold.get("train_cost", 0))
			_action_sub.text = "level %d to %d   ·   tap again to gear or dismiss" % [
				int(sold.get("level", 1)), int(sold.get("level", 1)) + 1]
			return
		_action.text = "AT YOUR LEVEL"
		_action.disabled = true
		_action_sub.text = "tap again to gear or dismiss"
		return

	_action.text = "SELECT A SLOT"
	_action.disabled = true
	_action_sub.text = ""


func _cheapest_recruit() -> Dictionary:
	var best := {}
	for r in _army.get("recruits", []):
		if best.is_empty() or int(r.get("cost", 0)) < int(best.get("cost", 0)):
			best = r
	return best


func _do_action() -> void:
	if _busy:
		return
	_busy = true
	_refresh_action()

	if _is_next_slot_selected():
		await _post("/v1/army/slot", {"action_seq": _next_seq()})
	elif _selected >= 1:
		var sold := _selected_soldier()
		if sold.is_empty():
			var pick := _cheapest_recruit()
			await _post("/v1/army/recruit", {
				"slot": _selected, "type_id": str(pick.get("type_id", "peasant")),
				"action_seq": _next_seq()})
		else:
			await _post("/v1/army/train", {"soldier_id": str(sold.get("id", "")), "action_seq": _next_seq()})

	_busy = false
	await GameState.refresh()
	await _reload()


func _auto_equip() -> void:
	if _busy:
		return
	_busy = true
	_auto.disabled = true
	_refresh_action()
	var res: Api.Response = await Api.post_json("/v1/army/autoequip",
		{"scope": "army", "action_seq": _next_seq()})
	_busy = false
	_auto.disabled = false
	if res.ok:
		var n := int(res.data.get("equipped", 0))
		GameState.action_failed.emit(
			"Nothing better to wear" if n == 0 else "Equipped %d item%s" % [n, "" if n == 1 else "s"])
	else:
		GameState.action_failed.emit(res.error)
	await GameState.refresh()
	await _reload()


func _next_seq() -> int:
	return int(GameState.player().get("action_seq", 0)) + 1


func _post(path: String, body: Dictionary) -> void:
	var res: Api.Response = await Api.post_json(path, body)
	if not res.ok:
		GameState.action_failed.emit(res.error)
