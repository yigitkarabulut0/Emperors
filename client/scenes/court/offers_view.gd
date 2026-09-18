extends Control
## ROYAL OFFERS -- the Court's OFFERS card.
##
## Built from the owner's own painting (art/reference/offers.png, slices
## art/slices/offers.json, layout client/layout/offers.json). The offers
## themselves were only ever a section inside the Royal Store; this is the
## screen the painting asks for: the merchant's stand, and under it one wide
## card per offer on sale -- its bundle painted, what is in it on three tiles,
## how long it lasts, and its price.
##
## Nothing here is money of the game's own. What a buyer pays is the App
## Store's, in their own currency (Billing.price / StorePrice), and the
## catalogue's usd_cents is Royal Favour's arithmetic and never a price to show.
## The offers, their order and their seconds are the server's
## (GET /v1/store/court, StoreView.live_offers), and a purchase leaves by the
## one path every purchase leaves by: Billing.buy, delivered by the server's
## own verify.
##
## The painting's value plate -- an empty plate with a gold line struck through
## it -- is not drawn: a strike is a was-price, and this game has none to
## strike. art/slices/offers.json records the rect for the day it does.

signal back_requested

const SCREEN := "offers"
const StoreView := preload("res://scenes/court/store_view.gd")
## The badge the catalogue puts on the offer the painting ribbons.
const BEST := "best_value"

var _ui: Dictionary = {}
var _data: Dictionary = {}
var _built := false
var _cards: Array = []             ## the card nodes laid in the list
var _buys: Array = []              ## [{button, label, product}] -- the plates Billing prices
var _clocks: Array = []            ## [{label, seconds}] -- counted down each second
var _painted_at := 0
var _prices_answered := false
var _clock: Timer


func _ready() -> void:
	_ui = Layout.build(SCREEN, self)
	_ui["back_hit"] = CourtBack.build(self)
	(_ui["back_hit"] as BaseButton).pressed.connect(func() -> void: back_requested.emit())
	_clock = Timer.new()
	_clock.wait_time = 1.0
	_clock.timeout.connect(_count_down)
	add_child(_clock)
	_clock.start()
	Billing.products_changed.connect(func() -> void:
		_prices_answered = true
		_paint_prices())
	Billing.busy_changed.connect(func(_b: bool) -> void: _paint_prices())
	Billing.delivered.connect(func(_d: Dictionary) -> void: _load())
	Billing.pending.connect(func(_id: String) -> void:
		GameState.toast("Waiting for approval. Your purchase will arrive by itself once it is given."))
	Billing.failed.connect(func(_id: String, message: String) -> void:
		if message != "":
			GameState.toast(message))
	_built = true


func refresh() -> void:
	if _built:
		_load()


func _load() -> void:
	var res: Api.Response = await Api.get_json("/v1/store/court")
	if not is_inside_tree():
		return
	if not res.ok:
		GameState.action_failed.emit("The offers could not be opened. " + res.error)
		return
	paint(res.data)


func paint(store: Dictionary) -> void:
	_data = store
	_painted_at = Time.get_ticks_msec()
	var sc: ScrollContainer = _ui["list"]
	var content: Control = sc.get_meta("content")
	for n in _cards:
		n.queue_free()
	_cards.clear()
	_buys.clear()
	_clocks.clear()

	# The offers on sale now, soonest to end first -- the Store's own list, so
	# the two screens can never disagree about what is on sale.
	var offers: Array = StoreView.live_offers(store.get("products", []))
	var ids := PackedStringArray()
	for p in offers:
		ids.append(str((p as Dictionary).get("store_id", "")))
	Billing.load_products(ids)

	var tpl := Layout.element(SCREEN, "card")
	var r := Layout.rect_of(tpl)
	var gap := Layout.rect_of(Layout.element(SCREEN, "stack_gap")).size.y
	var y := Layout.rect_of(Layout.element(SCREEN, "stack_top")).size.y
	for p in offers:
		var built := _card(p)
		built["node"].position = Vector2(r.position.x, y)
		content.add_child(built["node"])
		_cards.append(built["node"])
		y += r.size.y + gap
	content.custom_minimum_size.y = y
	# The painting has three cards and the realm may have none.
	_ui["empty_text"].visible = offers.is_empty()
	# Where the App Store cannot be reached the plates fall back to the
	# catalogue's own figures, and those are dollars: say so, as the Store does.
	_ui["dollars_text"].visible = not Billing.available
	_paint_prices()
	_count_down()


## One offer, as the painting draws it.
func _card(p: Dictionary) -> Dictionary:
	var built := Layout.instantiate(Layout.element(SCREEN, "card"))
	var parts: Dictionary = built["parts"]

	(parts["bundle"] as TextureRect).texture = Art.tex(_bundle_of(p))
	(parts["ribbon"] as CanvasItem).visible = str(p.get("badge", "")) == BEST

	var title: Label = parts["title"]
	title.text = str(p.get("title", ""))
	UI.fit_line(title, title.label_settings.font_size, 20)

	var lines: Array = p.get("lines", [])
	for i in 3:
		var icon: TextureRect = parts["icon_%d" % (i + 1)]
		var count: Label = parts["count_%d" % (i + 1)]
		icon.visible = i < lines.size()
		count.text = ""
		if not icon.visible:
			continue
		# A frame or a border is shown as it will be WORN, round the lord's own
		# face -- the same object the Store's card draws, not a bare ring.
		var square := FramedFace.square_of(str(lines[i].get("icon", "")))
		if square != "":
			icon.visible = false
			var framed := FramedFace.build(square, Rect2(icon.position, icon.size), str(GameState.player().get("avatar", "")))
			icon.get_parent().add_child(framed)
			icon.get_parent().move_child(framed, icon.get_index())
		else:
			icon.texture = Art.reward_line_icon(lines[i])
			StoreView.fit_down(icon)
		count.text = StoreView.count_words(lines[i])
	(parts["tiles_hit"] as BaseButton).pressed.connect(func() -> void: _say_lines(p))

	_clocks.append({"label": parts["timer"], "seconds": int(p.get("ends_in", 0))})
	var buy: TextureButton = parts["buy"]
	var price: Label = parts["price"]
	price.set_meta("size", price.label_settings.font_size)
	_buys.append({"button": buy, "label": price, "product": p})
	buy.pressed.connect(func() -> void: _buy(p))
	return built


## Which bundle painting an offer wears. The painting has three, in the order
## it stands them; a fourth offer takes the last, because the catalogue may add
## one and the painting cannot.
func _bundle_of(p: Dictionary) -> String:
	var offers: Array = StoreView.live_offers(_data.get("products", []))
	var i := 0
	for q in offers:
		if str((q as Dictionary).get("id", "")) == str(p.get("id", "")):
			break
		i += 1
	return "offers/bundle_%d" % (mini(i, 2) + 1)


func _say_lines(p: Dictionary) -> void:
	var body := "\n".join(StoreView.line_texts(p))
	var note := str(p.get("note", ""))
	if note != "":
		body += "\n" + StoreView.sentence(note) + "."
	await Dialog.ask(self, {"title": str(p.get("title", "")), "body": body, "confirm_text": "OK"})


func _buy(p: Dictionary) -> void:
	var store_id := str(p.get("store_id", ""))
	if bool(p.get("owned", false)):
		GameState.toast("%s is yours for good." % str(p.get("title", "")))
		return
	if not bool(p.get("available", true)):
		var note := str(p.get("note", ""))
		GameState.toast(StoreView.sentence(note) + "." if note != "" else "Not on sale to you just now.")
		return
	if not Billing.available:
		GameState.toast(Billing.unavailable_reason())
		return
	if Billing.busy:
		return
	Billing.buy(store_id)


func _paint_prices() -> void:
	for e in _buys:
		var p: Dictionary = e["product"]
		var label: Label = e["label"]
		var button: TextureButton = e["button"]
		if not is_instance_valid(button):
			continue
		var sid := str(p.get("store_id", ""))
		var live := StoreView.buyable(p, Billing.available, Billing.price(sid), Billing.busy)
		StorePrice.paint(button, label,
			StorePrice.words(p, Billing.available, Billing.price(sid), _prices_answered, ""), live)
		UI.fit_line(label, int(label.get_meta("size", 30)), 14)


func _count_down() -> void:
	var expired := false
	for c in _clocks:
		var label: Label = c["label"]
		if not is_instance_valid(label):
			continue
		var left: int = maxi(0, int(c["seconds"]) - (Time.get_ticks_msec() - _painted_at) / 1000)
		label.text = UI.time_left(left)
		UI.fit_line(label, label.label_settings.font_size, 14)
		if left == 0 and int(c["seconds"]) > 0:
			expired = true
	if expired:
		# An offer that ran out while the screen was open is gone: the server
		# decides what is on sale, so the list is asked again rather than edited.
		_load()
