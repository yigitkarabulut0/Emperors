extends VBoxContainer
## The Market: six offers that restock every five minutes.
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


func _ready() -> void:
	add_theme_constant_override("separation", 8)

	_header = UI.label("Loading the market…", 14, Palette.TEXT_DIM)
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
	_reload()


func mount_action_bar(host: Control) -> void:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)
	host.add_child(col)

	# Diamonds had no sink at all: the counter sat at zero and nothing spent it.
	# A reroll is the design's own listed use, and it buys a CHANCE rather than
	# an item -- you still pay gold for whatever it turns up.
	_reroll = UI.button("REROLL", 17)
	_reroll.custom_minimum_size = Vector2(0, 48)
	_reroll.pressed.connect(_do_reroll)
	col.add_child(_reroll)

	_reroll_sub = UI.label("", 12, Palette.TEXT_FAINT, HORIZONTAL_ALIGNMENT_CENTER)
	col.add_child(_reroll_sub)
	_update_reroll()


func _reload() -> void:
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


func _update_header() -> void:
	var used := int(_shop.get("inventory_used", 0))
	var cap := int(_shop.get("inventory_cap", 0))
	_header.text = "Restocks in %s     armory %d/%d" % [UI.duration(_seconds_left), used, cap]


## The price escalates within a window and resets when the window turns, so it
## has to be read back from the server rather than counted locally.
func _update_reroll() -> void:
	if _reroll == null:
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
