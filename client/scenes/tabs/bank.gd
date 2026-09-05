extends VBoxContainer
## The Bank: what you are carrying versus what is safe.
##
## Its own section rather than a card inside the Keep. Raiders take a share of
## gold ON HAND and never touch the vault, so this is the standing decision every
## session ends on -- it deserves a place you can find, not a panel you scroll
## past on the way to the upgrade list.

const FEE_BP := 1000  ## shown only; the server is authoritative

var _busy := false
var _body: VBoxContainer
var _action: Button
var _action_sub: Label


func _ready() -> void:
	add_theme_constant_override("separation", 10)

	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 10)
	add_child(_body)

	GameState.changed.connect(_rebuild)
	_rebuild()


func mount_action_bar(host: Control) -> void:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)
	host.add_child(col)
	_action = UI.button("BANK ALL", UI.F_H2)
	_action.custom_minimum_size = Vector2(0, 52)
	_action.pressed.connect(func() -> void: _move("deposit", GameState.display_gold()))
	col.add_child(_action)
	_action_sub = UI.label("", UI.F_MICRO, Palette.TEXT_FAINT, HORIZONTAL_ALIGNMENT_CENTER)
	col.add_child(_action_sub)
	_refresh_action()


func _reload() -> void:
	await GameState.refresh()


func _rebuild() -> void:
	for c in _body.get_children():
		c.queue_free()

	var carried := GameState.display_gold()
	var banked := int(str(GameState.player().get("treasury", "0")))

	_body.add_child(_pile("ON HAND", carried, Palette.GOLD,
		"A raider takes a share of this", "coin"))
	_body.add_child(_pile("IN THE VAULT", banked, Palette.SUCCESS,
		"Nobody can take this", "bank"))

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_body.add_child(row)
	row.add_child(_move_button("Bank half", "deposit", carried / 2, carried >= 2))
	row.add_child(_move_button("Take it all out", "withdraw", banked, banked > 0))

	_body.add_child(UI.label(
		"Putting gold in costs %d%% of what you put in. Taking it out is free." % (FEE_BP / 100),
		UI.F_CAPTION, Palette.TEXT_FAINT, HORIZONTAL_ALIGNMENT_CENTER))
	_refresh_action()


## One big readable number with its own icon, rather than two columns of small
## ones. This screen holds exactly two facts and they should be unmissable.
func _pile(title: String, amount: int, tint: Color, note: String, icon: String) -> Control:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", UI.panel_box(Palette.PANEL, tint))

	var pad := MarginContainer.new()
	for side in ["left", "right"]:
		pad.add_theme_constant_override("margin_" + side, 14)
	for side in ["top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, 12)
	card.add_child(pad)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	pad.add_child(row)

	var glyph := TextureRect.new()
	glyph.texture = ArtRegistry.ui_icon("currency/coin" if icon == "coin" else icon)
	glyph.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	glyph.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	glyph.custom_minimum_size = Vector2(40, 40)
	glyph.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	glyph.modulate = tint
	row.add_child(glyph)

	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 1)
	col.add_child(UI.label(title, UI.F_MICRO, Palette.TEXT_FAINT))
	col.add_child(UI.label(UI.number(amount), 27, tint))
	col.add_child(UI.label(note, UI.F_MICRO, Palette.TEXT_DIM))
	row.add_child(col)
	return card


func _move_button(text: String, direction: String, amount: int, enabled: bool) -> Button:
	var b := UI.ghost_button(text, UI.F_BODY)
	b.custom_minimum_size = Vector2(0, UI.TAP_MIN)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.disabled = _busy or not enabled
	b.pressed.connect(_move.bind(direction, amount))
	return b


func _refresh_action() -> void:
	if _action == null:
		return
	var carried := GameState.display_gold()
	var fee := carried * FEE_BP / 10000
	_action.disabled = _busy or carried <= 0
	_action.text = "…" if _busy else "BANK ALL"
	if carried <= 0:
		_action_sub.text = "you are carrying nothing"
	else:
		_action_sub.text = "%s in, %s fee" % [UI.number(carried - fee), UI.number(fee)]


func _move(direction: String, amount: int) -> void:
	if _busy or amount <= 0:
		return
	_busy = true
	_rebuild()
	var res: Api.Response = await Api.post_json("/v1/treasury/" + direction,
		{"amount": amount, "action_seq": int(GameState.player().get("action_seq", 0)) + 1})
	_busy = false
	if res.ok:
		GameState.snapshot = res.data.get("snapshot", GameState.snapshot)
		GameState.changed.emit()
	else:
		GameState.action_failed.emit(res.error)
	_rebuild()
