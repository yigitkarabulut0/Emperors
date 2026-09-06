extends VBoxContainer
## The Armory: what you own, what you are wearing, and what it is worth.

var _list: VBoxContainer
var _header: Label
var _selected := ""
var _inv: Dictionary = {}
var _action: Button
var _sell: Button
var _reforge: Button
var _donate: Button

## Which tiers are on screen. "" is everything.
##
## A hundred-and-fifty-slot bag with no filter and no bulk action meant clearing
## a run of commons was a hundred tap-confirm-tap cycles, which is the kind of
## chore that makes a player stop opening the screen.
var _filter := ""
var _shown: Array = []
var _chips: HBoxContainer
var _chip_buttons: Array[Button] = []

const FILTERS := [
	["", "All"],
	["common", "Common"],
	["uncommon", "Uncommon"],
	["collection", "Wall"],
]

## The Collection, fetched with the bag.
##
## A locked design decision that never shipped, so selling was the only thing to
## do with gear you were not wearing. Donating one of each design tilts future
## rolls, which is the loop: a broader wall makes better drops, which makes more
## to collect.
var _wall: Dictionary = {}


func _ready() -> void:
	add_theme_constant_override("separation", 8)

	_header = UI.label("Loading the armory…", UI.F_CAPTION, Palette.TEXT_DIM)
	add_child(_header)

	_chips = HBoxContainer.new()
	_chips.add_theme_constant_override("separation", 4)
	add_child(_chips)
	for f in FILTERS:
		var b := UI.ghost_button(str(f[1]), UI.F_CAPTION)
		b.custom_minimum_size = Vector2(0, 36)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var key: String = str(f[0])
		b.pressed.connect(func() -> void:
			_filter = key
			_selected = ""
			_rebuild())
		_chips.add_child(b)
		_chip_buttons.append(b)

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

	# Reforge sits beside Sell because they are the two things you do to an item
	# you are not wearing, and because a player deciding between "this is not
	# good enough" and "make it better" wants both prices in front of them.
	_donate = UI.ghost_button("GIVE", UI.F_BODY)
	_donate.custom_minimum_size = Vector2(96, 54)
	_donate.add_theme_stylebox_override("normal", UI.panel_box(Palette.PANEL, Palette.LINE))
	_donate.add_theme_stylebox_override("hover", UI.panel_box(Palette.PANEL_HIGH, Palette.GOLD_DEEP))
	_donate.pressed.connect(_donate_selected)
	row.add_child(_donate)

	_reforge = UI.ghost_button("REFORGE", UI.F_BODY)
	_reforge.custom_minimum_size = Vector2(120, 54)
	_reforge.add_theme_stylebox_override("normal", UI.panel_box(Palette.PANEL, Palette.LINE))
	_reforge.add_theme_stylebox_override("hover", UI.panel_box(Palette.PANEL_HIGH, Palette.GOLD_DEEP))
	_reforge.pressed.connect(_reforge_selected)
	row.add_child(_reforge)

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
	var w: Api.Response = await Api.get_json("/v1/collection")
	if w.ok:
		_wall = w.data
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

	if _filter == "collection":
		_build_wall()
		_style_chips()
		_refresh_actions()
		return

	if _filter != "":
		var kept: Array = []
		for it in items:
			if str(it.get("tier", "")) == _filter:
				kept.append(it)
		items = kept
		_header.text = "%d %s   ·   %d/%d held" % [items.size(), _filter,
			int(_inv.get("used", 0)), int(_inv.get("cap", 0))]

	# Equipped first, then by power: the thing you are wearing should never be
	# something you have to scroll for.
	items.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if bool(a.get("equipped", false)) != bool(b.get("equipped", false)):
			return bool(a.get("equipped", false))
		return int(a.get("power", 0)) > int(b.get("power", 0)))

	if _selected == "" and not items.is_empty():
		_selected = str(items[0].get("id", ""))

	_shown = items
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

	_style_chips()
	_refresh_actions()


func _style_chips() -> void:
	for i in _chip_buttons.size():
		var b: Button = _chip_buttons[i]
		var active: bool = str(FILTERS[i][0]) == _filter
		b.add_theme_stylebox_override("normal",
			UI.panel_box(Palette.PANEL_HIGH if active else Palette.PANEL,
				Palette.GOLD_DEEP if active else Palette.LINE))
		b.add_theme_color_override("font_color", Palette.GOLD_INK if active else Palette.TEXT_DIM)


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
		_reforge.disabled = true
		_donate.disabled = true
		return
	var equipped := bool(it.get("equipped", false))
	_action.text = "UNEQUIP" if equipped else "EQUIP"
	_action.disabled = false
	# Selling worn gear is blocked server-side too; greying it here just avoids a
	# pointless round trip and a confusing error.
	_sell.disabled = equipped
	_sell.text = "SELL %s" % UI.number(int(it.get("sell_price", 0)))

	# Worn gear can be reforged -- it is the same sword afterwards, just better
	# or worse -- so the only bar is whether they can pay for the gamble.
	var reforge_cost := int(it.get("reforge_price", 0))
	_reforge.text = "REFORGE %s" % UI.number(reforge_cost)
	_reforge.disabled = GameState.display_gold() < reforge_cost

	# With a tier filter on, the useful verb is "clear this pile", not "sell the
	# one I happen to have highlighted".
	# Already on the wall, or worn: either way there is nothing to give.
	_donate.disabled = equipped or _held(str(it.get("def_id", "")))

	if _filter != "":
		_reforge.disabled = true
		_donate.disabled = true
		var n := 0
		var worth := 0
		for x in _shown:
			if not bool(x.get("equipped", false)):
				n += 1
				worth += int(x.get("sell_price", 0))
		_sell.disabled = n == 0
		_sell.text = "SELL %d — %s" % [n, UI.number(worth)]


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
	if _filter != "":
		await _sell_shown()
		return
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


## Clears every unequipped item currently on screen.
##
## One request and one confirmation for one decision the player made — which is
## also why the server credits it as a single gold movement and a single ledger
## row rather than fifty.
func _sell_shown() -> void:
	var ids: Array[String] = []
	var worth := 0
	for it in _shown:
		if bool(it.get("equipped", false)):
			continue
		ids.append(str(it.get("id", "")))
		worth += int(it.get("sell_price", 0))
	if ids.is_empty():
		return

	if not await Confirm.ask(self, {
			"title": "Sell %d %s items?" % [ids.size(), _filter],
			"body": "They are gone for good. Anything you are wearing is left alone.",
			"cost": {"amount": worth, "currency": "gold"},
			"confirm_text": "Sell them", "danger": true}):
		return

	var seq := int(GameState.player().get("action_seq", 0)) + 1
	var res: Api.Response = await Api.post_json("/v1/inventory/sell/batch",
		{"item_ids": ids, "action_seq": seq})
	if not res.ok:
		GameState.action_failed.emit(res.error)
		await GameState.refresh()
		await _reload()
		return

	GameState.action_failed.emit("Sold %d for %s gold" % [
		int(res.data.get("sold", 0)), UI.number(int(res.data.get("gained", 0)))])
	_selected = ""
	await GameState.refresh()
	await _reload()


## Re-rolls the selected item's quality.
##
## The confirmation says outright that it can go the wrong way. A gamble the
## player did not know they were taking is the one they resent.
func _reforge_selected() -> void:
	var it := _selected_item()
	if it.is_empty():
		return
	var cost := int(it.get("reforge_price", 0))
	if not await Confirm.ask(self, {
			"title": "Reforge %s?" % str(it.get("name", "this")),
			"body": "The smith re-rolls its quality. It can come back worse — that is the wager.",
			"cost": {"amount": cost, "currency": "gold"},
			"confirm_text": "To the forge"}):
		return

	var seq := int(GameState.player().get("action_seq", 0)) + 1
	var res: Api.Response = await Api.post_json("/v1/inventory/reforge",
		{"item_id": _selected, "action_seq": seq})
	if not res.ok:
		GameState.action_failed.emit(res.error)
		await GameState.refresh()
		await _reload()
		return

	var item: Dictionary = res.data.get("item", {})
	var better := bool(res.data.get("improved", false))
	GameState.action_failed.emit("%s — power %d  (%s)" % [
		str(item.get("name", "")), int(item.get("power", 0)),
		"better" if better else "no better"])
	await GameState.refresh()
	await _reload()


## Is this design already on the wall?
func _held(def_id: String) -> bool:
	for set_ in _wall.get("sets", []):
		for e in set_.get("entries", []):
			if str(e.get("def_id", "")) == def_id:
				return bool(e.get("held", false))
	return false


## The wall: every design in the game, and whether it is yours.
##
## Shown as sets of three because that is the shape of the reward — completing a
## slot at a tier is worth more than three loose pieces, which is what turns
## "sell the spare falchion" into "hold it".
func _build_wall() -> void:
	for c in _list.get_children():
		c.queue_free()

	_header.text = "%d of %d designs   ·   +%d%% fortune" % [
		int(_wall.get("held", 0)), int(_wall.get("total", 0)),
		int(_wall.get("luck_bp", 0)) / 100]

	for set_ in _wall.get("sets", []):
		var p := PanelContainer.new()
		p.add_theme_stylebox_override("panel", UI.card_box(bool(set_.get("complete", false))))

		var margin := MarginContainer.new()
		for side in ["left", "right"]:
			margin.add_theme_constant_override("margin_" + side, 10)
		for side in ["top", "bottom"]:
			margin.add_theme_constant_override("margin_" + side, 6)
		p.add_child(margin)

		var col := VBoxContainer.new()
		col.add_theme_constant_override("separation", 2)
		margin.add_child(col)

		var tier := str(set_.get("tier", ""))
		var title := "%s   %s" % [str(set_.get("slot", "")).to_upper(), tier.to_upper()]
		if bool(set_.get("complete", false)):
			title += "   ✓"
		col.add_child(UI.label(title, UI.F_CAPTION, Palette.tier(tier)))

		for e in set_.get("entries", []):
			var got := bool(e.get("held", false))
			col.add_child(UI.label(
				("● " if got else "○ ") + str(e.get("name", "")),
				UI.F_MICRO, Palette.TEXT if got else Palette.TEXT_FAINT))
		_list.add_child(p)


## Gives the selected item to the collection. It is destroyed either way.
func _donate_selected() -> void:
	var it := _selected_item()
	if it.is_empty():
		return
	if not await Confirm.ask(self, {
			"title": "Give %s to the collection?" % str(it.get("name", "this")),
			"body": "It is gone from your armory for good, and its design is yours forever. Fortune favours a broad collection.",
			"confirm_text": "Give it", "danger": true}):
		return

	var seq := int(GameState.player().get("action_seq", 0)) + 1
	var res: Api.Response = await Api.post_json("/v1/collection/donate",
		{"item_id": _selected, "action_seq": seq})
	if not res.ok:
		GameState.action_failed.emit(res.error)
		await GameState.refresh()
		await _reload()
		return

	_wall = res.data
	GameState.action_failed.emit("%d of %d designs   ·   +%d%% fortune" % [
		int(_wall.get("held", 0)), int(_wall.get("total", 0)),
		int(_wall.get("luck_bp", 0)) / 100])
	_selected = ""
	await GameState.refresh()
	await _reload()
