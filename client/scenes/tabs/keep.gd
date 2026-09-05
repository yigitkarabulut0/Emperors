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
var _army: Dictionary = {}
var _hero_card: Control
var _vault_card: Control


func _ready() -> void:
	add_theme_constant_override("separation", 8)

	# The Keep is the character sheet before it is an upgrade list: who you are,
	# what you are carrying, and what is safe. The upgrade rows used to open the
	# screen, which made it indistinguishable from Territory.
	var scroll_all := ScrollContainer.new()
	scroll_all.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll_all.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll_all)
	var stack := VBoxContainer.new()
	stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stack.add_theme_constant_override("separation", 8)
	scroll_all.add_child(stack)

	_hero_card = PanelContainer.new()
	(_hero_card as PanelContainer).add_theme_stylebox_override(
		"panel", UI.panel_box(Palette.PANEL, Palette.GOLD_DEEP))
	stack.add_child(_hero_card)

	_vault_card = PanelContainer.new()
	(_vault_card as PanelContainer).add_theme_stylebox_override(
		"panel", UI.panel_box(Palette.PANEL, Palette.LINE))
	stack.add_child(_vault_card)

	_stats = UI.label("", 13, Palette.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER)
	_stats.visible = false
	stack.add_child(_stats)

	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", UI.panel_box(Palette.PANEL, Palette.GOLD_DEEP))
	stack.add_child(card)
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
	stack.add_child(_kingdom_button)

	stack.add_child(UI.label("YOUR KEEP", 12, Palette.TEXT_FAINT))
	_body = scroll_all
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 6)
	stack.add_child(_list)

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
		_stats.visible = true
		_stats.text = res.error
		return
	_estates = res.data
	# The hero card needs Might and worn gear, which only the army view carries.
	var army: Api.Response = await Api.get_json("/v1/army")
	if army.ok:
		_army = army.data
	_rebuild()


func _rebuild() -> void:
	if _estates.is_empty():
		return

	_render_hero()
	_render_vault()

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
			var row := EstateRow.new(str(u.get("id", "")), "upgrades")
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
## The vault. Raiders take a share of what you are CARRYING and never touch what
## is banked, so this is the standing risk decision every session ends on. It had
## no screen at all until now -- the column existed, the steal already spared it,
## and there was no way to put anything in.
func _render_vault() -> void:
	for c in _vault_card.get_children():
		c.queue_free()
	var p := GameState.player()
	var carried := GameState.display_gold()
	var banked := int(str(p.get("treasury", "0")))
	var fee_bp := 1000  # shown, not enforced here; the server is authoritative

	var pad := MarginContainer.new()
	for side in ["left", "right"]:
		pad.add_theme_constant_override("margin_" + side, 12)
	for side in ["top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, 10)
	_vault_card.add_child(pad)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	pad.add_child(col)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	col.add_child(row)
	row.add_child(_money("ON HAND", carried, Palette.GOLD, "raiders can take a share"))
	row.add_child(_money("IN THE VAULT", banked, Palette.SUCCESS, "safe from raids"))

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 6)
	col.add_child(buttons)

	var half := UI.ghost_button("BANK HALF", 13)
	half.custom_minimum_size = Vector2(0, 38)
	half.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	half.disabled = _busy or carried < 2
	half.pressed.connect(_move_gold.bind("deposit", carried / 2))
	buttons.add_child(half)

	var all := UI.ghost_button("BANK ALL", 13)
	all.custom_minimum_size = Vector2(0, 38)
	all.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	all.disabled = _busy or carried <= 0
	all.pressed.connect(_move_gold.bind("deposit", carried))
	buttons.add_child(all)

	var out := UI.ghost_button("TAKE OUT", 13)
	out.custom_minimum_size = Vector2(0, 38)
	out.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	out.disabled = _busy or banked <= 0
	out.pressed.connect(_move_gold.bind("withdraw", banked))
	buttons.add_child(out)

	col.add_child(UI.label(
		"Banking costs %d%%. Taking it out is free." % (fee_bp / 100),
		11, Palette.TEXT_FAINT, HORIZONTAL_ALIGNMENT_CENTER))


func _money(title: String, amount: int, tint: Color, note: String) -> Control:
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 1)
	col.add_child(UI.label(title, 11, Palette.TEXT_FAINT))
	col.add_child(UI.label(UI.number(amount), 20, tint))
	col.add_child(UI.label(note, 10, Palette.TEXT_FAINT))
	return col


func _move_gold(direction: String, amount: int) -> void:
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


## Who you are: portrait, level, experience, might, and what you are carrying.
func _render_hero() -> void:
	for c in _hero_card.get_children():
		c.queue_free()
	if _army.is_empty():
		return
	var p := GameState.player()
	var hero: Dictionary = _army.get("hero", {})

	var pad := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, 12)
	_hero_card.add_child(pad)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	pad.add_child(col)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	col.add_child(head)

	var face := Button.new()
	face.custom_minimum_size = Vector2(64, 64)
	face.focus_mode = Control.FOCUS_NONE
	face.tooltip_text = "Change your portrait"
	face.add_theme_stylebox_override("normal", UI.panel_box(Color.TRANSPARENT, Color.TRANSPARENT, 0))
	face.add_theme_stylebox_override("hover", UI.panel_box(Palette.PANEL_HIGH, Color.TRANSPARENT, 32))
	face.pressed.connect(func() -> void:
		add_child(load("res://scenes/shell/avatar_picker.gd").new(str(p.get("avatar", "knight")))))
	var img := TextureRect.new()
	img.mouse_filter = Control.MOUSE_FILTER_IGNORE
	img.set_anchors_preset(Control.PRESET_FULL_RECT)
	img.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	img.texture = ArtRegistry.portrait(str(p.get("avatar", "knight")))
	face.add_child(img)
	head.add_child(face)

	var who := VBoxContainer.new()
	who.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	who.alignment = BoxContainer.ALIGNMENT_CENTER
	who.add_theme_constant_override("separation", 3)
	who.add_child(UI.label(str(p.get("username", "")), 19, Palette.TEXT))

	var xp := int(p.get("xp", 0))
	var need := int(p.get("xp_to_next", 1))
	var bar := ProgressBar.new()
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(0, 8)
	bar.max_value = maxf(float(need), 1.0)
	bar.value = float(xp)
	bar.add_theme_stylebox_override("background", UI.panel_box(Palette.PANEL_HIGH, Palette.LINE, 4))
	bar.add_theme_stylebox_override("fill", UI.panel_box(Palette.GOLD, Color.TRANSPARENT, 4))
	who.add_child(bar)
	who.add_child(UI.label("Level %d   ·   %s / %s xp" % [
		int(p.get("level", 1)), UI.number(xp), UI.number(need)], 12, Palette.TEXT_DIM))
	head.add_child(who)

	var might := VBoxContainer.new()
	might.alignment = BoxContainer.ALIGNMENT_CENTER
	might.add_theme_constant_override("separation", 0)
	var totals: Dictionary = _army.get("totals", {})
	might.add_child(UI.label(UI.number(int(totals.get("might", 0))), 26, Palette.GOLD,
		HORIZONTAL_ALIGNMENT_RIGHT))
	might.add_child(UI.label("MIGHT", 11, Palette.TEXT_FAINT, HORIZONTAL_ALIGNMENT_RIGHT))
	head.add_child(might)

	col.add_child(UI.label("ATK %d      DEF %d      HP %d      %d in the field" % [
		int(totals.get("attack", 0)), int(hero.get("defense", 0)),
		int(hero.get("hp", 0)), int(totals.get("units", 1))],
		13, Palette.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER))

	# Your own three slots, gear-able here rather than only in the Barracks.
	var gear := HBoxContainer.new()
	gear.add_theme_constant_override("separation", 8)
	gear.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_child(gear)
	var worn: Dictionary = hero.get("equipped", {})
	for slot in ["weapon", "armor", "horse"]:
		gear.add_child(_gear_button(slot, worn.get(slot)))

	# Stat points were displayed with nowhere to spend them. They are the whole
	# reason a player with no soldiers still gets stronger every level.
	var unspent := int(p.get("stat_points_unspent", 0))
	if unspent > 0:
		col.add_child(UI.label("%d point%s to spend" % [unspent, "" if unspent == 1 else "s"],
			13, Palette.SUCCESS, HORIZONTAL_ALIGNMENT_CENTER))
		var spend := HBoxContainer.new()
		spend.add_theme_constant_override("separation", 6)
		spend.alignment = BoxContainer.ALIGNMENT_CENTER
		col.add_child(spend)
		for pair in [["Max Energy", "energy"], ["Attack", "attack"], ["Defense", "defense"]]:
			var b := UI.ghost_button("+ " + str(pair[0]), 13)
			b.custom_minimum_size = Vector2(0, 36)
			b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			b.disabled = _busy
			b.pressed.connect(_spend_point.bind(str(pair[1])))
			spend.add_child(b)


func _gear_button(slot: String, item: Variant) -> Control:
	var b := Button.new()
	b.custom_minimum_size = Vector2(72, 72)
	b.focus_mode = Control.FOCUS_NONE
	var tier := str(item.get("tier", "")) if item is Dictionary else ""
	b.tooltip_text = str(item.get("name", "")) if item is Dictionary else ("no " + slot)
	b.add_theme_stylebox_override("normal", UI.panel_box(Palette.PANEL_HIGH,
		Palette.tier(tier) if tier != "" else Palette.LINE))
	b.add_theme_stylebox_override("hover", UI.panel_box(Palette.PANEL_HIGH, Palette.GOLD))
	b.pressed.connect(func() -> void:
		var chooser: CanvasLayer = load("res://scenes/shell/item_chooser.gd").new(
			slot, str(_army.get("hero", {}).get("id", "")), true)
		chooser.picked.connect(func() -> void:
			await _reload()
			_rebuild())
		add_child(chooser))

	var img := TextureRect.new()
	img.mouse_filter = Control.MOUSE_FILTER_IGNORE
	img.set_anchors_preset(Control.PRESET_FULL_RECT)
	img.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	if item is Dictionary:
		img.texture = ArtRegistry.item_icon(str(item.get("art", "")), tier)
	else:
		img.texture = ArtRegistry.ui_icon("slots/" + slot)
		img.modulate = Palette.EMPTY_SLOT
	b.add_child(img)
	return b


func _spend_point(stat: String) -> void:
	if _busy:
		return
	_busy = true
	var body := {"energy": 0, "attack": 0, "defense": 0,
		"action_seq": int(GameState.player().get("action_seq", 0)) + 1}
	body[stat] = 1
	var res: Api.Response = await Api.post_json("/v1/stats/spend", body)
	_busy = false
	if res.ok:
		GameState.snapshot = res.data
		GameState.changed.emit()
		await _reload()
		_rebuild()
	else:
		GameState.action_failed.emit(res.error)


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
