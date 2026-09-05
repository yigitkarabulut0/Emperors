extends VBoxContainer
## The Keep: who you are, what your estate earns while you are away, and the
## Family tree that makes everything else better.

var _estates: Dictionary = {}
var _selected := ""
var _list: VBoxContainer
var _stats: Label
var _tax: Label
var _tax_button: Button
var _action: Button
var _action_sub: Label
var _busy := false
var _kingdom_button: Button
var _body: Control
var _kingdom_screen: Node
var _estate_card: Control


func _ready() -> void:
	add_theme_constant_override("separation", 8)

	_stats = UI.label("", 13, Palette.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER)
	add_child(_stats)

	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", UI.panel_box(Palette.PANEL, Palette.GOLD_DEEP))
	add_child(card)
	_estate_card = card
	var crow := HBoxContainer.new()
	crow.add_theme_constant_override("separation", 10)
	card.add_child(crow)

	var tcol := VBoxContainer.new()
	tcol.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tcol.add_theme_constant_override("separation", 1)
	crow.add_child(tcol)
	tcol.add_child(UI.label("YOUR ESTATES", 12, Palette.TEXT_FAINT))
	_tax = UI.label("", 15, Palette.GOLD)
	_tax.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tcol.add_child(_tax)

	_tax_button = UI.button("COLLECT", 15)
	_tax_button.custom_minimum_size = Vector2(104, 42)
	_tax_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_tax_button.pressed.connect(_claim_tax)
	crow.add_child(_tax_button)

	_kingdom_button = UI.ghost_button("", 15)
	_kingdom_button.custom_minimum_size = Vector2(0, 46)
	_kingdom_button.add_theme_stylebox_override("normal", UI.panel_box(Palette.PANEL, Palette.LINE))
	_kingdom_button.add_theme_stylebox_override("hover", UI.panel_box(Palette.PANEL_HIGH, Palette.GOLD_DEEP))
	_kingdom_button.pressed.connect(_open_kingdom)
	add_child(_kingdom_button)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	_body = scroll
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 6)
	scroll.add_child(_list)

	GameState.changed.connect(_rebuild)
	_reload()
	_refresh_kingdom_button()

	# Dev-only: open the realm screen directly, so a capture run (which disables
	# input) can reach a screen that normally needs a tap.
	if OS.get_cmdline_user_args().has("--dev-open-kingdom"):
		await get_tree().create_timer(1.0).timeout
		_open_kingdom()


func mount_action_bar(host: Control) -> void:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)
	host.add_child(col)
	_action = UI.button("SELECT AN UPGRADE", 19)
	_action.custom_minimum_size = Vector2(0, 54)
	_action.pressed.connect(_buy)
	col.add_child(_action)
	_action_sub = UI.label("", 12, Palette.TEXT_FAINT, HORIZONTAL_ALIGNMENT_CENTER)
	col.add_child(_action_sub)
	_refresh_action()


func _reload() -> void:
	var res: Api.Response = await Api.get_json("/v1/estates")
	if not res.ok:
		_stats.text = res.error
		return
	_estates = res.data
	_rebuild()


func _rebuild() -> void:
	if _estates.is_empty():
		return

	var p := GameState.player()
	_stats.text = "Level %d     %s / %s xp     %d unspent points" % [
		int(p.get("level", 1)), UI.number(int(p.get("xp", 0))),
		UI.number(int(p.get("xp_to_next", 0))), int(p.get("stat_points_unspent", 0))]

	var tax: Dictionary = _estates.get("tax", {})
	var per_hour := float(int(tax.get("per_hour_milli", 0))) / 1000.0
	var pending := int(tax.get("pending", 0))
	# Per hour, never per second: a rate of 0.008 gold a second reads as nothing.
	_tax.text = "%.1f gold/hour   ·   %s waiting" % [per_hour, UI.number(pending)]
	_tax_button.disabled = pending <= 0 or _busy

	var gold := GameState.display_gold()
	var upgrades: Array = _estates.get("upgrades", [])
	if _list.get_child_count() != upgrades.size():
		for c in _list.get_children():
			c.queue_free()
		for u in upgrades:
			var row := EstateRow.new(str(u.get("id", "")))
			row.pressed.connect(_select.bind(str(u.get("id", ""))))
			_list.add_child(row)

	var i := 0
	for u in upgrades:
		var row: EstateRow = _list.get_child(i)
		i += 1
		var lv := int(u.get("level", 0))
		var effect := ""
		if lv > 0:
			effect = _describe(str(u.get("bucket", "")), int(u.get("effect_now", 0)))
		row.refresh(str(u.get("name", "")), str(u.get("blurb", "")),
			lv, int(u.get("max_level", 0)), effect, int(u.get("next_cost", 0)),
			false, "", gold >= int(u.get("next_cost", 0)),
			str(u.get("id", "")) == _selected)

	_refresh_action()


## Turns a bucket and a raw amount into something a player can read.
func _describe(bucket: String, amount: int) -> String:
	match bucket:
		"max_energy_flat":
			return "now +%d max energy" % amount
		_:
			return "now +%.0f%%" % (amount / 100.0)


func _select(id: String) -> void:
	_selected = id
	_rebuild()


func _selected_upgrade() -> Dictionary:
	for u in _estates.get("upgrades", []):
		if str(u.get("id", "")) == _selected:
			return u
	return {}


func _refresh_action() -> void:
	if _action == null:
		return
	var u := _selected_upgrade()
	if u.is_empty() or _busy:
		_action.text = "…" if _busy else "SELECT AN UPGRADE"
		_action.disabled = true
		_action_sub.text = ""
		return
	if bool(u.get("maxed", false)):
		_action.text = "%s IS MAXED" % str(u.get("name", "")).to_upper()
		_action.disabled = true
		_action_sub.text = ""
		return
	var cost := int(u.get("next_cost", 0))
	var can := GameState.display_gold() >= cost
	_action.text = "%s  —  %s" % [str(u.get("name", "")).to_upper(), UI.number(cost)]
	_action.disabled = not can
	_action_sub.text = "level %d to %d" % [int(u.get("level", 0)), int(u.get("level", 0)) + 1] if can \
		else "not enough gold"


func _buy() -> void:
	var u := _selected_upgrade()
	if u.is_empty() or _busy:
		return
	_busy = true
	_refresh_action()
	var res: Api.Response = await Api.post_json("/v1/estates/upgrade",
		{"id": _selected, "action_seq": int(GameState.player().get("action_seq", 0)) + 1})
	_busy = false
	if not res.ok:
		GameState.action_failed.emit(res.error)
	else:
		_estates = res.data
	await GameState.refresh()
	_rebuild()


func _claim_tax() -> void:
	if _busy:
		return
	_busy = true
	var res: Api.Response = await Api.post_json("/v1/estates/tax/claim",
		{"action_seq": int(GameState.player().get("action_seq", 0)) + 1})
	_busy = false
	if not res.ok:
		GameState.action_failed.emit(res.error)
	else:
		GameState.action_failed.emit("Collected %s gold from your estates" %
			UI.number(int(res.data.get("collected", 0))))
	await GameState.refresh()
	await _reload()


## The kingdom lives behind a card here rather than in its own rail slot: a
## player has no kingdom for the first twelve levels, and a permanently empty
## icon teaches the wrong thing about the game.
func _refresh_kingdom_button() -> void:
	if _kingdom_button == null:
		return
	var res: Api.Response = await Api.get_json("/v1/kingdom")
	if not res.ok:
		return
	if bool(res.data.get("in_kingdom", false)):
		var k: Dictionary = res.data.get("kingdom", {})
		_kingdom_button.text = "%s [%s]   ·   renown %s   >" % [
			str(k.get("name", "")), str(k.get("tag", "")),
			UI.number(int(k.get("reputation", 0)))]
		_kingdom_button.add_theme_color_override("font_color", Palette.GOLD)
	else:
		var invites: Array = res.data.get("invites", [])
		_kingdom_button.text = "You hold no banner   >" if invites.is_empty() \
			else "%d kingdom invitation(s)   >" % invites.size()
		_kingdom_button.add_theme_color_override("font_color",
			Palette.SUCCESS if not invites.is_empty() else Palette.TEXT_DIM)


func _open_kingdom() -> void:
	if _kingdom_screen != null:
		return
	# Everything the Keep owns steps aside, or the estate card and the family tree
	# bleed through behind the realm screen.
	for node in [_body, _kingdom_button, _stats, _estate_card]:
		if node != null:
			node.visible = false

	_kingdom_screen = preload("res://scenes/tabs/kingdom.gd").new()
	_kingdom_screen.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_kingdom_screen.closed.connect(_close_kingdom)
	add_child(_kingdom_screen)
	move_child(_kingdom_screen, 1)


func _close_kingdom() -> void:
	if _kingdom_screen == null:
		return
	_kingdom_screen.queue_free()
	_kingdom_screen = null
	for node in [_body, _kingdom_button, _stats, _estate_card]:
		if node != null:
			node.visible = true
	_refresh_kingdom_button()
