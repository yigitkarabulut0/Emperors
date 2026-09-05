extends VBoxContainer
## Hero: who you are, and the upgrades that make everything else better.
##
## It used to be a grab bag -- your character, the vault, estate income, a link
## into the clan system, and the upgrade tree, all on one screen. The vault and
## the clan are their own sections now, and the estate income moved next to the
## estates that earn it.

var _estates: Dictionary = {}
var _selected := ""
var _list: VBoxContainer
var _stats: Label
var _action: Button
var _action_sub: Label
var _busy := false
var _body: Control
var _army: Dictionary = {}
var _hero_card: Control


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

	_stats = UI.label("", 13, Palette.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER)
	_stats.visible = false
	stack.add_child(_stats)


	stack.add_child(UI.label("PERMANENT UPGRADES", 12, Palette.TEXT_FAINT))
	_body = scroll_all
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 6)
	stack.add_child(_list)

	GameState.changed.connect(_rebuild)
	_reload()



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

	var p := GameState.player()
	_stats.text = "Level %d     %s / %s xp     %d unspent points" % [
		int(p.get("level", 1)), UI.number(int(p.get("xp", 0))),
		UI.number(int(p.get("xp_to_next", 0))), int(p.get("stat_points_unspent", 0))]


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

	# Picking the best of three slots out of a bag of 150 by hand is busywork, and
	# the server already knows what "best" means -- it is the Power number on
	# every card.
	var auto := UI.ghost_button("EQUIP MY BEST GEAR", 13)
	auto.custom_minimum_size = Vector2(0, 38)
	auto.disabled = _busy
	auto.pressed.connect(_auto_equip.bind("hero"))
	col.add_child(auto)

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


func _auto_equip(scope: String) -> void:
	if _busy:
		return
	_busy = true
	_rebuild()
	var res: Api.Response = await Api.post_json("/v1/army/autoequip",
		{"scope": scope, "action_seq": int(GameState.player().get("action_seq", 0)) + 1})
	_busy = false
	if res.ok:
		var n := int(res.data.get("equipped", 0))
		GameState.action_failed.emit(
			"Nothing better to wear" if n == 0 else "Equipped %d item%s" % [n, "" if n == 1 else "s"])
		await GameState.refresh()
		await _reload()
	else:
		GameState.action_failed.emit(res.error)
	_rebuild()


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
