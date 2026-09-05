extends VBoxContainer
## The Shop: two shops on one screen, side by side.
##
## The Market sells gear for gold and restocks every five minutes. The Diamond
## store sells the two things diamonds are allowed to buy -- convenience and
## protection, never gold and never power. They belong together because they
## answer the same question: "I have currency, what can I get for it."
##
## Offers are re-read rather than predicted. A purchase has a random-ish outcome
## from the player's point of view (which item, what quality), and predicting
## those would mean showing something that might not be what arrives — so this
## sits in the pessimistic lane: tap, wait for the server, then reveal.

var _list: VBoxContainer
var _header: Label
var _cards: Array[ItemCard] = []
var _shop: Dictionary = {}
var _busy := false
var _seconds_left := 0
var _reroll: Button
var _reroll_sub: Label
var _mode: int = Mode.MARKET
var _tabs: HBoxContainer
var _tab_buttons: Array[Button] = []
var _store: Dictionary = {}


enum Mode { MARKET, DIAMONDS }

func _ready() -> void:
	add_theme_constant_override("separation", 8)

	_tabs = HBoxContainer.new()
	_tabs.add_theme_constant_override("separation", 4)
	add_child(_tabs)
	for entry in [[Mode.MARKET, "Market", "currency/coin"], [Mode.DIAMONDS, "Diamonds", "currency/gem"]]:
		var b := UI.ghost_button(str(entry[1]), UI.F_BODY)
		b.custom_minimum_size = Vector2(0, UI.TAP_MIN)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.icon = ArtRegistry.ui_icon(str(entry[2]))
		b.expand_icon = true
		var m: int = int(entry[0])
		b.pressed.connect(func() -> void:
			_mode = m
			_rebuild()
			_reload())
		_tabs.add_child(b)
		_tab_buttons.append(b)

	_header = UI.label("Loading the market…", UI.F_CAPTION, Palette.TEXT_DIM)
	add_child(_header)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)

	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 6)
	scroll.add_child(_list)

	var t := Timer.new()
	t.wait_time = 1.0
	t.autostart = true
	t.timeout.connect(_tick)
	add_child(t)

	GameState.changed.connect(_update_affordability)

	# Dev-only: a capture run disables input, so open a half on request.
	if OS.get_cmdline_user_args().has("--dev-diamonds"):
		_mode = Mode.DIAMONDS
	_reload()


func mount_action_bar(host: Control) -> void:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)
	host.add_child(col)

	# Diamonds had no sink at all: the counter sat at zero and nothing spent it.
	# A reroll is the design's own listed use, and it buys a CHANCE rather than
	# an item -- you still pay gold for whatever it turns up.
	_reroll = UI.button("REROLL", UI.F_BODY)
	_reroll.custom_minimum_size = Vector2(0, UI.TAP_MIN)
	_reroll.pressed.connect(_do_reroll)
	col.add_child(_reroll)

	_reroll_sub = UI.label("", UI.F_MICRO, Palette.TEXT_FAINT, HORIZONTAL_ALIGNMENT_CENTER)
	col.add_child(_reroll_sub)
	_update_reroll()


func _reload() -> void:
	if _mode == Mode.DIAMONDS:
		var sres: Api.Response = await Api.get_json("/v1/store")
		if not sres.ok:
			_header.text = sres.error
			return
		_store = sres.data
		_rebuild()
		return

	var res: Api.Response = await Api.get_json("/v1/shop")
	if not res.ok:
		_header.text = res.error
		return
	_shop = res.data
	_seconds_left = int(_shop.get("seconds_left", 0))
	_rebuild()


func _rebuild() -> void:
	for c in _list.get_children():
		c.queue_free()
	_cards.clear()
	_style_tabs()

	if _mode == Mode.DIAMONDS:
		_build_store()
		_update_reroll()
		return

	for offer in _shop.get("offers", []):
		var item: Dictionary = offer.get("item", {})
		var card := ItemCard.new(item)
		card.pressed.connect(_buy.bind(int(offer.get("slot", 0))))
		card.set_meta("offer", offer)
		_list.add_child(card)
		_cards.append(card)

	_update_header()
	_update_reroll()
	# No frame await needed: add_child runs _ready synchronously, so every card's
	# children are already built by the time this returns.
	_update_affordability()


func _style_tabs() -> void:
	for i in _tab_buttons.size():
		var b: Button = _tab_buttons[i]
		var active: bool = i == _mode
		b.add_theme_stylebox_override("normal",
			UI.panel_box(Palette.PANEL_HIGH if active else Palette.PANEL,
				Palette.GOLD_DEEP if active else Palette.LINE))
		b.add_theme_color_override("font_color", Palette.GOLD if active else Palette.TEXT_DIM)


## The diamond half. Each good says plainly what it does and, when buying it
## would change nothing, why it is greyed out -- a premium currency you cannot
## waste by accident is one people trust.
func _build_store() -> void:
	_header.text = "You have %s diamonds" % UI.number(int(_store.get("diamonds", 0)))
	var have := int(_store.get("diamonds", 0))

	for g in _store.get("goods", []):
		var affordable: bool = have >= int(g.get("diamonds", 0))
		var useful := bool(g.get("useful", true))

		var b := Button.new()
		b.custom_minimum_size = Vector2(0, UI.TAP_ROW)
		b.focus_mode = Control.FOCUS_NONE
		b.disabled = _busy or not useful or not affordable
		var accent := Palette.DIAMOND if (useful and affordable) else Palette.LINE
		b.add_theme_stylebox_override("normal", UI.panel_box(Palette.PANEL, accent))
		b.add_theme_stylebox_override("hover", UI.panel_box(Palette.PANEL_HIGH, Palette.DIAMOND))
		b.add_theme_stylebox_override("disabled", UI.panel_box(Palette.BG, Palette.LINE))
		b.pressed.connect(_buy_good.bind(str(g.get("id", ""))))

		var pad := MarginContainer.new()
		pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
		pad.set_anchors_preset(Control.PRESET_FULL_RECT)
		for side in ["left", "right"]:
			pad.add_theme_constant_override("margin_" + side, 12)
		b.add_child(pad)

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		pad.add_child(row)

		var icon := TextureRect.new()
		icon.texture = ArtRegistry.ui_icon(str(g.get("icon", "currency/gem")))
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.custom_minimum_size = Vector2(44, 44)
		icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		icon.modulate = Palette.DIAMOND if useful else Palette.EMPTY_SLOT
		row.add_child(icon)

		var col := VBoxContainer.new()
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		col.alignment = BoxContainer.ALIGNMENT_CENTER
		col.add_theme_constant_override("separation", 2)
		col.add_child(UI.label(str(g.get("name", "")), UI.F_BODY, Palette.TEXT if useful else Palette.TEXT_FAINT))
		var blurb := UI.label(str(g.get("blurb", "")), UI.F_MICRO, Palette.TEXT_DIM)
		blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		col.add_child(blurb)
		if not useful:
			col.add_child(UI.label(str(g.get("note", "")), UI.F_MICRO, Palette.SUCCESS))
		elif not affordable:
			col.add_child(UI.label("you need %d more" % (int(g.get("diamonds", 0)) - have),
				UI.F_MICRO, Palette.DANGER))
		row.add_child(col)

		var price := HBoxContainer.new()
		price.add_theme_constant_override("separation", 5)
		price.alignment = BoxContainer.ALIGNMENT_END
		var gem := TextureRect.new()
		gem.texture = ArtRegistry.ui_icon("currency/gem")
		gem.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		gem.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		gem.custom_minimum_size = Vector2(16, 16)
		gem.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		gem.modulate = Palette.DIAMOND
		price.add_child(gem)
		price.add_child(UI.label(str(int(g.get("diamonds", 0))), UI.F_H2, Palette.DIAMOND))
		price.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(price)

		_list.add_child(b)


func _buy_good(id: String) -> void:
	if _busy:
		return
	_busy = true
	_rebuild()
	var res: Api.Response = await Api.post_json("/v1/store/buy",
		{"good": id, "action_seq": int(GameState.player().get("action_seq", 0)) + 1})
	_busy = false
	if res.ok:
		GameState.snapshot = res.data
		GameState.changed.emit()
	else:
		GameState.action_failed.emit(res.error)
	await _reload()


func _update_header() -> void:
	if _mode != Mode.MARKET:
		return
	var used := int(_shop.get("inventory_used", 0))
	var cap := int(_shop.get("inventory_cap", 0))
	_header.text = "Restocks in %s   ·   your armory holds %d of %d" % [
		UI.duration(_seconds_left), used, cap]


## The price escalates within a window and resets when the window turns, so it
## has to be read back from the server rather than counted locally.
func _update_reroll() -> void:
	if _reroll == null:
		return
	# The reroll belongs to the Market. On the diamond side every purchase is its
	# own row, so the bar has nothing to say.
	_reroll.visible = _mode == Mode.MARKET
	_reroll_sub.visible = _mode == Mode.MARKET
	if _mode != Mode.MARKET:
		return
	var cost := int(_shop.get("reroll_cost", 0))
	var used := int(_shop.get("rerolls_used", 0))
	var have := int(GameState.player().get("diamonds", 0))
	_reroll.text = "REROLL — %d ◆" % cost
	_reroll.disabled = _busy or have < cost
	if have < cost:
		_reroll_sub.text = "you have %d diamonds — level up to earn more" % have
	elif used > 0:
		_reroll_sub.text = "%d this window · the price rises each time" % used
	else:
		_reroll_sub.text = "a fresh set of offers, same window"


func _do_reroll() -> void:
	if _busy:
		return
	_busy = true
	_update_reroll()
	var res: Api.Response = await Api.post_json("/v1/shop/reroll",
		{"action_seq": int(GameState.player().get("action_seq", 0)) + 1})
	_busy = false
	if res.ok:
		_shop = res.data
		_seconds_left = int(_shop.get("seconds_left", 0))
		await GameState.refresh()
		_rebuild()
	else:
		GameState.action_failed.emit(res.error)
		_update_reroll()


func _update_affordability() -> void:
	var gold := GameState.display_gold()
	for card in _cards:
		if not is_instance_valid(card):
			continue
		var offer: Dictionary = card.get_meta("offer", {})
		var price := int(offer.get("price", 0))
		if bool(offer.get("purchased", false)):
			card.set_footer("SOLD", Palette.TEXT_FAINT)
			card.disabled = true
			card.modulate.a = 0.45
		else:
			var afford := gold >= price
			card.set_footer(UI.number(price), Palette.GOLD if afford else Palette.DANGER)
			card.disabled = not afford or _busy
			card.modulate.a = 1.0 if afford else 0.7


func _tick() -> void:
	if _seconds_left <= 0:
		return
	_seconds_left -= 1
	_update_header()
	if _seconds_left <= 0:
		# The window rolled. Re-read rather than guess: the server owns the shelf.
		_header.text = "Restocking…"
		_reload()


func _buy(slot: int) -> void:
	if _busy:
		return
	_busy = true
	_update_affordability()

	var seq := int(GameState.player().get("action_seq", 0)) + 1
	var res: Api.Response = await Api.post_json("/v1/shop/buy", {"slot": slot, "action_seq": seq})
	_busy = false

	if not res.ok:
		GameState.action_failed.emit(res.error)
		# A stale shop or a lost race both mean the shelf we drew is wrong.
		await GameState.refresh()
		await _reload()
		return

	GameState.action_failed.emit("Bought %s for %s gold" %
		[str(res.data.get("item", {}).get("name", "it")), UI.number(int(res.data.get("paid", 0)))])
	await GameState.refresh()
	await _reload()
