extends VBoxContainer
## The Armory: what you own, what you are wearing, and what it is worth.

var _list: VBoxContainer
var _header: Label
var _selected := ""
var _inv: Dictionary = {}
var _action: Button
var _sell: Button


func _ready() -> void:
	add_theme_constant_override("separation", 8)

	_header = UI.label("Loading the armory…", UI.F_CAPTION, Palette.TEXT_DIM)
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

	_reload()


func mount_action_bar(host: Control) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	host.add_child(row)

	_action = UI.button("EQUIP", UI.F_H2)
	_action.custom_minimum_size = Vector2(0, UI.TAP_PRIMARY)
	_action.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_action.pressed.connect(_toggle_equip)
	row.add_child(_action)

	_sell = UI.ghost_button("SELL", UI.F_BODY)
	_sell.custom_minimum_size = Vector2(120, 54)
	_sell.add_theme_stylebox_override("normal", UI.panel_box(Palette.PANEL, Palette.LINE))
	_sell.add_theme_stylebox_override("hover", UI.panel_box(Palette.PANEL_HIGH, Palette.DANGER))
	_sell.pressed.connect(_sell_selected)
	row.add_child(_sell)

	_refresh_actions()


func _reload() -> void:
	var res: Api.Response = await Api.get_json("/v1/inventory")
	if not res.ok:
		_header.text = res.error
		return
	_inv = res.data
	_rebuild()


func _rebuild() -> void:
	for c in _list.get_children():
		c.queue_free()

	var items: Array = _inv.get("items", [])
	if items.is_empty():
		_header.text = "Your armory is empty. Visit the Market."
	else:
		var hero: Dictionary = _inv.get("hero", {})
		_header.text = "%d/%d held     ATK %d   DEF %d   SPD %d   POWER %d" % [
			int(_inv.get("used", 0)), int(_inv.get("cap", 0)),
			int(hero.get("attack", 0)), int(hero.get("defense", 0)),
			int(hero.get("speed", 0)), int(hero.get("power", 0))]

	# Equipped first, then by power: the thing you are wearing should never be
	# something you have to scroll for.
	items.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if bool(a.get("equipped", false)) != bool(b.get("equipped", false)):
			return bool(a.get("equipped", false))
		return int(a.get("power", 0)) > int(b.get("power", 0)))

	if _selected == "" and not items.is_empty():
		_selected = str(items[0].get("id", ""))

	for it in items:
		var card := ItemCard.new(it)
		card.pressed.connect(_select.bind(str(it.get("id", ""))))
		# add_child runs _ready synchronously while the parent is in the tree, so
		# the card's children exist immediately. Awaiting a frame per item here
		# would cost ~2.5s of stutter at the 150-item inventory cap.
		_list.add_child(card)
		var equipped := bool(it.get("equipped", false))
		card.set_footer("WORN" if equipped else UI.number(int(it.get("sell_price", 0))),
			Palette.SUCCESS if equipped else Palette.TEXT_DIM)
		if str(it.get("id", "")) == _selected:
			card.modulate = Color(1.15, 1.15, 1.15)

	_refresh_actions()


func _select(id: String) -> void:
	_selected = id
	_rebuild()


func _selected_item() -> Dictionary:
	for it in _inv.get("items", []):
		if str(it.get("id", "")) == _selected:
			return it
	return {}


func _refresh_actions() -> void:
	if _action == null:
		return
	var it := _selected_item()
	if it.is_empty():
		_action.text = "EQUIP"
		_action.disabled = true
		_sell.disabled = true
		return
	var equipped := bool(it.get("equipped", false))
	_action.text = "UNEQUIP" if equipped else "EQUIP"
	_action.disabled = false
	# Selling worn gear is blocked server-side too; greying it here just avoids a
	# pointless round trip and a confusing error.
	_sell.disabled = equipped
	_sell.text = "SELL %s" % UI.number(int(it.get("sell_price", 0)))


func _toggle_equip() -> void:
	var it := _selected_item()
	if it.is_empty():
		return
	var path := "/v1/inventory/unequip" if bool(it.get("equipped", false)) else "/v1/inventory/equip"
	var res: Api.Response = await Api.post_json(path, {"item_id": _selected})
	if not res.ok:
		GameState.action_failed.emit(res.error)
		return
	_inv = res.data
	_rebuild()


func _sell_selected() -> void:
	var it := _selected_item()
	if it.is_empty():
		return
	if not await Confirm.ask(self, {
			"title": "Sell this?",
			"body": "%s (%s) is gone for good." % [
				str(it.get("name", "")), str(it.get("tier", "")).to_upper()],
			"cost": {"amount": int(it.get("sell_price", 0)), "currency": "gold"},
			"confirm_text": "Sell", "danger": true}):
		return
	var seq := int(GameState.player().get("action_seq", 0)) + 1
	var res: Api.Response = await Api.post_json("/v1/inventory/sell",
		{"item_id": _selected, "action_seq": seq})
	if not res.ok:
		GameState.action_failed.emit(res.error)
		await GameState.refresh()
		await _reload()
		return
	GameState.action_failed.emit("Sold for %s gold" % UI.number(int(res.data.get("gained", 0))))
	_selected = ""
	await GameState.refresh()
	await _reload()
