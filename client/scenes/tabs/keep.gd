extends VBoxContainer
## Hero: who you are, and the upgrades that make everything else better.
##
## It used to be a grab bag -- your character, the vault, estate income, a link
## into the clan system, and the upgrade tree, all on one screen. The vault and
## the clan are their own sections now, and the estate income moved next to the
## estates that earn it.

var _estates: Dictionary = {}

## The Legacy offer.
##
## Only ever drawn once a player has something to give up: an offer to start over
## shown to somebody at level 12 is a threat, not a reward.
var _legacy: Dictionary = {}
var _legacy_card: Control
var _selected := ""
var _list: VBoxContainer
var _stats: Label
var _action: Button
var _action_sub: Label
var _busy := false
var _body: Control
var _army: Dictionary = {}
var _hero_card: Control

## The portrait on the identity card, and the three equipment plates.
const PORTRAIT := 132
const GEAR_SLOT := 96


func _ready() -> void:
	add_theme_constant_override("separation", 8)

	# The Hero is the character sheet before it is an upgrade list: who you are,
	# what you are carrying, and what you are worth in a fight. The upgrade rows
	# used to open the screen, which made it indistinguishable from Estates.
	var scroll_all := ScrollContainer.new()
	scroll_all.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll_all.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	# Lists follow your finger. Godot's own touch scrolling is gated behind
	# is_touchscreen_available() and is eaten by the buttons the list is made of.
	DragScroll.install(scroll_all)
	add_child(scroll_all)
	var stack := VBoxContainer.new()
	stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stack.add_theme_constant_override("separation", UI.GAP_M)
	scroll_all.add_child(stack)

	# Everything above the upgrade list is rebuilt as one piece, because all of
	# it comes from the same two fetches and none of it is worth diffing.
	_hero_card = VBoxContainer.new()
	(_hero_card as VBoxContainer).add_theme_constant_override("separation", UI.GAP_M)
	_hero_card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stack.add_child(_hero_card)

	_legacy_card = VBoxContainer.new()
	(_legacy_card as VBoxContainer).add_theme_constant_override("separation", UI.GAP_S)
	_legacy_card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stack.add_child(_legacy_card)

	_stats = UI.label("", UI.F_CAPTION, Palette.DANGER, HORIZONTAL_ALIGNMENT_CENTER)
	_stats.visible = false
	stack.add_child(_stats)

	stack.add_child(UI.section_header("Permanent Upgrades"))
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
	_action = UI.button("SELECT AN UPGRADE", UI.F_H2)
	_action.custom_minimum_size = Vector2(0, UI.TAP_PRIMARY)
	_action.pressed.connect(_buy)
	col.add_child(_action)
	_action_sub = UI.label("", UI.F_MICRO, Palette.TEXT_FAINT, HORIZONTAL_ALIGNMENT_CENTER)
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
	var leg: Api.Response = await Api.get_json("/v1/legacy")
	if leg.ok:
		_legacy = leg.data
	_rebuild()


func _rebuild() -> void:
	if _estates.is_empty():
		return

	_render_hero()
	_render_legacy()

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
## Who you are: portrait, name, level, what you are worth, and what you carry.
##
## Laid out the way the reference lays out a screen -- an identity card, a
## quartered panel of figures, then named bands with their own actions -- rather
## than as one card with everything crammed into it, which is what this was.
func _render_hero() -> void:
	for c in _hero_card.get_children():
		c.queue_free()
	if _army.is_empty():
		return
	var p := GameState.player()
	var hero: Dictionary = _army.get("hero", {})
	var totals: Dictionary = _army.get("totals", {})

	_hero_card.add_child(_identity_card(p))
	_hero_card.add_child(UI.stat_grid([
		["stat/sword", "Attack", UI.number(int(totals.get("attack", 0)))],
		["stat/shield", "Defence", UI.number(int(hero.get("defense", 0)))],
		["war_gate", "Might", UI.number(int(totals.get("might", 0)))],
		["barracks", "In the field", str(int(totals.get("units", 1)))],
	]))

	# Picking the best of three slots out of a bag of 150 by hand is busywork, and
	# the server already knows what "best" means -- it is the Power number on
	# every card.
	var auto := UI.button("EQUIP BEST", UI.F_CAPTION)
	auto.custom_minimum_size = Vector2(0, UI.TAP_MIN)
	auto.disabled = _busy
	auto.pressed.connect(_auto_equip.bind("hero"))
	_hero_card.add_child(UI.section_header("Your Gear", auto))

	var gear := HBoxContainer.new()
	gear.add_theme_constant_override("separation", UI.GAP_M)
	gear.alignment = BoxContainer.ALIGNMENT_CENTER
	_hero_card.add_child(gear)
	var worn: Dictionary = hero.get("equipped", {})
	for slot in ["weapon", "armor", "horse"]:
		gear.add_child(_gear_button(slot, worn.get(slot)))

	# Stat points were once displayed with nowhere to spend them. They are the
	# whole reason a player with no soldiers still gets stronger every level.
	var unspent := int(p.get("stat_points_unspent", 0))
	if unspent > 0:
		_hero_card.add_child(UI.section_header(
			"%d Point%s To Spend" % [unspent, "" if unspent == 1 else "s"]))
		var spend := HBoxContainer.new()
		spend.add_theme_constant_override("separation", UI.GAP_S)
		_hero_card.add_child(spend)
		for pair in [["Max Energy", "energy"], ["Attack", "attack"], ["Defence", "defense"]]:
			var b := UI.ghost_button("+ " + str(pair[0]), UI.F_CAPTION)
			b.custom_minimum_size = Vector2(0, UI.TAP_MIN)
			b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			b.disabled = _busy
			b.pressed.connect(_spend_point.bind(str(pair[1])))
			spend.add_child(b)


## The card at the head of the screen: a large portrait beside the name, the
## level and the experience under it.
##
## The reference puts an illustration hard against the card's edge and sets the
## name against it in large serif. The portrait IS the illustration here, so it
## takes the same place rather than being shrunk to a chip in the corner.
func _identity_card(p: Dictionary) -> Control:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", UI.card_box())

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UI.GAP_M)
	card.add_child(row)

	var face := Button.new()
	face.custom_minimum_size = Vector2(PORTRAIT, PORTRAIT)
	face.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	face.focus_mode = Control.FOCUS_NONE
	face.tooltip_text = "Change your portrait"
	face.add_theme_stylebox_override("normal", UI.panel_box(Color.TRANSPARENT, Color.TRANSPARENT, 0))
	face.add_theme_stylebox_override(
		"hover", UI.panel_box(Palette.PANEL_HIGH, Color.TRANSPARENT, PORTRAIT / 2))
	face.pressed.connect(func() -> void:
		add_child(load("res://scenes/shell/avatar_picker.gd").new(str(p.get("avatar", "knight")))))
	var img := TextureRect.new()
	img.mouse_filter = Control.MOUSE_FILTER_IGNORE
	img.set_anchors_preset(Control.PRESET_FULL_RECT)
	img.offset_left = 6
	img.offset_top = 6
	img.offset_right = -6
	img.offset_bottom = -6
	img.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	img.texture = ArtRegistry.portrait(str(p.get("avatar", "knight")))
	face.add_child(img)
	# The same carved collar the rail's crest wears, so the two read as the same
	# person rather than as two different treatments of one portrait.
	var ring := TextureRect.new()
	ring.texture = ArtRegistry.ui_icon("chrome/portrait_ring")
	ring.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	ring.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	ring.set_anchors_preset(Control.PRESET_FULL_RECT)
	ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	face.add_child(ring)
	row.add_child(face)

	var who := VBoxContainer.new()
	who.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	who.alignment = BoxContainer.ALIGNMENT_CENTER
	who.add_theme_constant_override("separation", UI.GAP_XS)
	row.add_child(who)

	var word := UI.label(str(p.get("username", "")), UI.F_H1, Palette.TEXT)
	word.clip_text = true
	word.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	who.add_child(word)
	who.add_child(UI.rule())

	var xp := int(p.get("xp", 0))
	var need := int(p.get("xp_to_next", 1))
	who.add_child(UI.label("Level %d" % int(p.get("level", 1)), UI.F_BODY, Palette.TEXT_DIM))

	var bar := ProgressBar.new()
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(0, 10)
	bar.max_value = maxf(float(need), 1.0)
	bar.value = float(xp)
	bar.add_theme_stylebox_override("background", UI.panel_box(Palette.RAIL, Palette.LINE, 5))
	bar.add_theme_stylebox_override("fill", UI.panel_box(Palette.GOLD, Color.TRANSPARENT, 5))
	who.add_child(bar)
	who.add_child(UI.number_label("%s / %s xp" % [UI.number(xp), UI.number(need)],
		UI.F_CAPTION, Palette.TEXT_FAINT))
	return card


func _gear_button(slot: String, item: Variant) -> Control:
	var b := Button.new()
	b.custom_minimum_size = Vector2(GEAR_SLOT, GEAR_SLOT)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.focus_mode = Control.FOCUS_NONE
	var tier := str(item.get("tier", "")) if item is Dictionary else ""
	b.tooltip_text = str(item.get("name", "")) if item is Dictionary else ("no " + slot)
	# A filled slot is a raised plate and an empty one is cut into the stone,
	# which is the same pair the job list uses for available and locked.
	b.add_theme_stylebox_override("normal",
		UI.skin("nav" if item is Dictionary else "panel_sunk", Palette.RAIL, 8, 8))
	b.add_theme_stylebox_override("hover", UI.skin("panel_gold", Palette.PANEL_HIGH, 8, 8))
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
	# There is no respec. A mis-tap here is permanent, which is exactly the case
	# the design called out for a confirmation.
	if not await Confirm.ask(self, {
			"title": "Spend a point on %s?" % stat.capitalize(),
			"body": "Stat points cannot be moved once they are spent.",
			"confirm_text": "Spend"}):
		return
	_busy = true
	var body := {"energy": 0, "attack": 0, "defense": 0,
		"action_seq": int(GameState.player().get("action_seq", 0)) + 1}
	body[stat] = 1
	var res: Api.Response = await Api.post_json("/v1/stats/spend", body)
	_busy = false
	if res.ok:
		GameState.adopt(res.data)
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
	if not await Confirm.ask(self, {
			"title": "Upgrade %s?" % str(u.get("name", "this")),
			"body": "Level %d to %d. %s" % [int(u.get("level", 0)),
				int(u.get("level", 0)) + 1, str(u.get("blurb", ""))],
			"cost": {"amount": int(u.get("next_cost", 0)), "currency": "gold"},
			"confirm_text": "Upgrade"}):
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


## The Legacy offer.
##
## Drawn only once there is something to give up. At the cap the job ladder has
## stopped, the holdings have stopped, the last barracks slot was level 37, and
## the only verb left is raid-then-bank; this is what comes after.
##
## Also drawn once a run has been taken, because a player carrying stacks should
## be able to see what they bought with the last one.
func _render_legacy() -> void:
	for c in _legacy_card.get_children():
		c.queue_free()
	if _legacy.is_empty():
		return
	var stacks := int(_legacy.get("stacks", 0))
	var available := bool(_legacy.get("available", false))
	if stacks == 0 and not available:
		return

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel",
		UI.panel_box(Palette.PANEL, Palette.GOLD_DEEP if available else Palette.LINE))
	_legacy_card.add_child(panel)

	var pad := MarginContainer.new()
	for side in ["left", "right"]:
		pad.add_theme_constant_override("margin_" + side, UI.GAP_M)
	for side in ["top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, UI.GAP_S)
	panel.add_child(pad)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)
	pad.add_child(col)

	col.add_child(UI.label("YOUR LINE", UI.F_CAPTION, Palette.GOLD_INK,
		HORIZONTAL_ALIGNMENT_CENTER))
	col.add_child(UI.label("%d of %d generations   ·   +%d%% to everything you earn" % [
		stacks, int(_legacy.get("max_stacks", 0)), int(_legacy.get("income_bp", 0)) / 100],
		UI.F_CAPTION, Palette.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER))

	if not available:
		return
	var b := UI.button("BEGIN AGAIN", UI.F_BODY)
	b.custom_minimum_size = Vector2(0, UI.TAP_MIN)
	b.pressed.connect(_begin_legacy)
	col.add_child(b)


func _begin_legacy() -> void:
	if not await Confirm.ask(self, {
			"title": "Pass the crown?",
			"body": "You return to level one. Your gold, your gear, your soldiers and your estates all stay — only the levels go, and everything they unlocked with them. Your line keeps +%d%% to all income, forever." % (int(_legacy.get("next_bp", 0)) / 100),
			"confirm_text": "Begin again", "danger": true}):
		return

	var seq := int(GameState.player().get("action_seq", 0)) + 1
	var res: Api.Response = await Api.post_json("/v1/legacy/begin", {"action_seq": seq})
	if not res.ok:
		GameState.action_failed.emit(res.error)
		return
	_legacy = res.data
	GameState.action_failed.emit("Generation %d   ·   +%d%% forever" % [
		int(_legacy.get("stacks", 0)), int(_legacy.get("income_bp", 0)) / 100])
	await GameState.refresh()
	await _reload()
