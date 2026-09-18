extends Control
## SHOP — the Royal Market (six offers on a 5-minute window, reroll for
## diamonds) and the Diamond Goods. Layout: layout/shop.json.

const SCREEN := "shop"
## Each tier's card frame is stitched from the reference pieces without scaling.
const FRAMES := {
	"legendary": [["shop/card_frame_legendary", 0, 0]],
	"epic": [["shop/card_frame_epic_l", 0, 0], ["shop/card_frame_epic_r", 150, 0]],
	"rare": [["shop/card_frame_rare_t", 0, 0], ["shop/card_frame_rare_b", 0, 62]],
	"uncommon": [["shop/card_frame_uncommon_t", 0, 0], ["shop/card_frame_uncommon_b", 0, 56]],
	# Not painted: the uncommon card drained to grey (shop.json), so a common
	# piece's grey velvet is not set in a green card.
	"common": [["shop/card_frame_common_t", 0, 0], ["shop/card_frame_common_b", 0, 56]],
}
const FRAME_FALLBACK := {"mystic": "epic", "special": "legendary"}
## The rarity badge is the same object on every screen, so it is drawn from one
## set. The shop reference paints its own -- a hexagon with a diamond finial and
## a flaming tail, in pink for epic and red for legendary -- and cutting those
## gave the shop four badges of one design and three of another, since common,
## mystic and special were never painted there. A player reading EPIC on a shop
## card and EPIC in their bags saw two different marks for one thing.
const BADGE_PREFIX := "inventory/badge_"
## Not "SWORD": one of the seven weapon designs is a spear.
const TYPE_WORD := {"weapon": "WEAPON", "armor": "ARMOR", "horse": "HORSE"}
## An offer's own stat, the one its slot is for, printed under its painting.
const STAT := {"weapon": ["attack", "ATK"], "armor": ["defense", "DEF"], "horse": ["speed", "SPD"]}
## A phone taller than the design gets its extra height between the rows,
## up to these, rather than all of it as bare ground under the Diamond Goods.
const ROW_GAP_MAX := 34.0
const GOODS_GAP_MAX := 56.0

var _scroll: ScrollContainer
var _content: Control
var _ui: Dictionary = {}
var _cards: Array = []
var _shop: Dictionary = {}
var _store: Dictionary = {}
var _loaded_ms := -100000
var _busy := false
var _titles: Dictionary = {}       ## good id -> its live heading on the panel
var _goods_home := 0.0
## While the hour's Fresh Wares gives free restocks, the REROLL MARKET button
## wears its free face (shop/reroll_button_free: the diamond and the price
## lifted, art/slices/shop.json) and FREE is set centred under its title's words
## (x 738..889 on shop.png).
const REROLL_FREE_FACE := "shop/reroll_button_free"
const REROLL_FACE := "shop/reroll_button"
const REROLL_FREE_WORD := Rect2(763.5, 590, 100, 30)
var _reroll_cost_home := Rect2()
## While a sale (Quartermaster's Sale) has the refill cheaper, the price it had
## stands after the sale's, smaller and struck through, inside the price plate.
const WAS_SIZE := 18
const WAS_GAP := 4.0
const WAS_INK := Color("#C9BFAF")
var _refill_was: Label


func _ready() -> void:
	_scroll = ScrollContainer.new()
	_scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	_scroll.scroll_deadzone = 14
	add_child(_scroll)
	_content = Control.new()
	_content.custom_minimum_size = Vector2(941, 1694)
	_content.mouse_filter = Control.MOUSE_FILTER_PASS
	_scroll.add_child(_content)
	# The page is at least as tall as the screen, so on a phone taller than the
	# design the bottom-anchored pieces sit at the screen's foot rather than at
	# the design's, with ground under them.
	# The scroll took its size when its anchors were set, above, so the hook is
	# applied once by hand as well as on every later resize.
	_scroll.resized.connect(_fit_page)
	_ui = Layout.build(SCREEN, _content)
	_cards = _ui["offer_card"]
	for i in _cards.size():
		var parts: Dictionary = _cards[i]["parts"]
		parts["buy"].pressed.connect(_buy.bind(i))
		GuideTargets.register("shop.offer.%d" % i, parts["buy"])
		# The frame is stitched per tier; the template's single frame image is replaced.
		parts["frame"].visible = false
		_cards[i]["frame_pieces"] = []
		# What the item is worth, under its painting: the card showed a name and
		# a price and nothing to weigh the price against. It ends short of the
		# BUY plate, which starts at 184.
		var stat := UI.label("", 21, Color("#E6DFD2"), "body", 600, HORIZONTAL_ALIGNMENT_CENTER)
		UI.place(stat, Rect2(12, 207, 164, 34))
		_cards[i]["node"].add_child(stat)
		_cards[i]["stat"] = stat
		_cards[i]["home"] = _cards[i]["node"].position
	_ui["reroll"].pressed.connect(_reroll)
	var cost: Label = _ui["reroll_cost"]
	_reroll_cost_home = Rect2(cost.position, cost.size)
	_goods_home = _ui["diamond_panel"].position.y
	_fit_page()
	var dp: Dictionary = _ui["diamond_panel"].get_meta("parts")
	dp["energy_buy"].pressed.connect(_buy_good.bind("energy_refill"))
	dp["shield_buy"].pressed.connect(_buy_good.bind("shield"))
	# The goods' headings were painted -- "30M SHIELD" over a server that sells
	# hours -- and are painted out now, so the server's title is the one shown.
	# The painting sets each heading at the left edge of its caption, a size
	# under the caption's own weight of line.
	var panel: Control = _ui["diamond_panel"]
	for pair in [["energy_refill", Rect2(159, 68, 196, 34)], ["shield", Rect2(532, 68, 186, 34)]]:
		var t := UI.label("", 21, Color("#F4EFE6"), "title", 600)
		UI.place(t, pair[1])
		panel.add_child(t)
		_titles[pair[0]] = t
	_refill_was = UI.label("", WAS_SIZE, WAS_INK, "body", 600)
	_refill_was.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var strike := ColorRect.new()
	strike.name = "strike"
	strike.color = UI.RED
	strike.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_refill_was.add_child(strike)
	_refill_was.visible = false
	panel.add_child(_refill_was)
	set_process(true)


## The page is at least as tall as the screen, so the bottom-anchored footer
## sits at the screen's foot. What a taller phone adds is shared out: some
## between the three rows of offers, some above the Diamond Goods, the rest
## under them -- rather than all of it as one band of bare ground.
func _fit_page() -> void:
	var h := maxf(1694.0, _scroll.size.y)
	_content.custom_minimum_size.y = h
	if _cards.is_empty():
		return
	var extra := h - 1694.0
	var row_gap := minf(ROW_GAP_MAX, extra / 5.0)
	var goods_gap := minf(GOODS_GAP_MAX, maxf(0.0, extra - row_gap * 3.0) / 2.0)
	for i in _cards.size():
		var home: Vector2 = _cards[i]["home"]
		_cards[i]["node"].position.y = home.y + row_gap * float(i / 2 + 1)
	_ui["diamond_panel"].position.y = _goods_home + row_gap * 3.0 + goods_gap


func refresh() -> void:
	if Time.get_ticks_msec() - _loaded_ms > 3000:
		_load()
	else:
		_paint()


func _process(_dt: float) -> void:
	if not visible or _shop.is_empty():
		return
	var gone := (Time.get_ticks_msec() - _loaded_ms) / 1000
	var left := int(_shop.get("seconds_left", 0)) - gone
	# The window turned, or the hour's free restock ran out: ask again.
	if left < 0 or (int(_shop.get("free_rerolls", 0)) > 0 and int(_shop.get("free_ends_in", 0)) - gone < 0):
		_load()
		return
	_ui["refresh_time"].text = "%02d:%02d" % [left / 60, left % 60]


func _load() -> void:
	_loaded_ms = Time.get_ticks_msec()
	var res: Api.Response = await Api.get_json("/v1/shop")
	if res.ok:
		_shop = res.data
	var st: Api.Response = await Api.get_json("/v1/store")
	if st.ok:
		_store = st.data
	_paint()


func _paint() -> void:
	if _shop.is_empty():
		return
	_paint_reroll_face()
	# The server says whether the reroll can be paid for and whether the day's
	# allowance has any left; the button says so before the tap, not after it.
	_ui["reroll"].modulate = reroll_look(_shop)
	# The diamonds figure is its own label over the plate: it dims with the
	# plate, or a spent reroll still showed its price in full white.
	_ui["reroll_cost"].modulate = reroll_look(_shop)
	var offers: Array = _shop.get("offers", [])
	for i in _cards.size():
		var c: Dictionary = _cards[i]
		var p: Dictionary = c["parts"]
		if i >= offers.size():
			c["node"].visible = false
			continue
		c["node"].visible = true
		var offer: Dictionary = offers[i]
		var item: Dictionary = offer.get("item", {})
		var tier := str(item.get("tier", "common"))
		_set_frame(c, tier)
		p["painting"].texture = Art.item(str(item.get("art", "")))
		# The piece on its rarity's velvet: the soft cut, as the card's picture
		# has no ring of its own and the card's own ground runs under it.
		ItemGround.under(p["painting"], tier, SHOP_GROUND, true)
		p["badge"].texture = Art.tex(BADGE_PREFIX + tier)
		p["badge"].size = p["badge"].texture.get_size()
		p["name"].text = str(item.get("name", ""))
		UI.fit_wrapped(p["name"], 24, 16)
		var slot := str(item.get("slot", "weapon"))
		p["type_icon"].texture = Art.tex("shop/type_" + ("sword" if slot == "weapon" else slot))
		p["type"].text = TYPE_WORD.get(slot, slot.to_upper())
		p["price"].text = UI.short_number(int(offer.get("price", 0)))
		UI.fit_label(p["type"], int(p["type"].label_settings.font_size), 14)
		var st: Array = STAT.get(slot, ["attack", "ATK"])
		c["stat"].text = "%s %s  ·  PWR %s" % [st[1], UI.grouped(int(item.get(st[0], 0))), UI.grouped(int(offer.get("power", 0)))]
		UI.fit_label(c["stat"], 21, 15)
		var sold := bool(offer.get("purchased", false))
		c["node"].modulate = Color(0.45, 0.45, 0.45) if sold else Color.WHITE
		p["buy"].disabled = sold
	var dp: Dictionary = _ui["diamond_panel"].get_meta("parts")
	var goods: Array = _store.get("goods", [])
	for g in goods:
		var id := str(g.get("id", ""))
		var buyable := Goods.buyable(g)
		if _titles.has(id):
			_titles[id].text = str(g.get("title", g.get("name", ""))).to_upper()
			UI.fit_label(_titles[id], 21, 16)
		if id == "energy_refill":
			dp["energy_desc"].text = str(g.get("caption", ""))
			UI.fit_label(dp["energy_desc"], 20, 15)
			dp["energy_amount"].text = UI.grouped(int(g.get("amount", 0)))
			dp["energy_price"].text = str(int(g.get("diamonds", 0)))
			_paint_was(dp["energy_price"], Goods.on_sale(g))
			dp["energy_buy"].modulate = Color.WHITE if buyable else Color(0.5, 0.5, 0.5)
		elif id == "shield":
			dp["shield_desc"].text = str(g.get("caption", ""))
			dp["shield_price"].text = str(int(g.get("diamonds", 0)))
			dp["shield_buy"].modulate = Color.WHITE if buyable else Color(0.5, 0.5, 0.5)


## The card's picture area the velvet glows across: the painting's own item
## region on the card (shop.json's item crops, 192 x 216 from the card's corner),
## wider than the drawn picture so the cloth shows round it.
const SHOP_GROUND := Rect2(5, 22, 192, 208)


func _set_frame(c: Dictionary, tier: String) -> void:
	for n in c["frame_pieces"]:
		n.queue_free()
	c["frame_pieces"] = []
	var key: String = tier if FRAMES.has(tier) else FRAME_FALLBACK.get(tier, "uncommon")
	var root: Control = c["node"]
	for piece in FRAMES[key]:
		var tex: Texture2D = Art.tex(piece[0])
		var img := UI.image(piece[0], Rect2(piece[1], piece[2], tex.get_width(), tex.get_height()))
		root.add_child(img)
		root.move_child(img, 0)
		c["frame_pieces"].append(img)


func _buy(i: int) -> void:
	if _busy:
		return
	var offers: Array = _shop.get("offers", [])
	if i >= offers.size():
		return
	var offer: Dictionary = offers[i]
	var item: Dictionary = offer.get("item", {})
	if not await Dialog.ask(self, {"title": "Buy %s?" % str(item.get("name", "")),
			"body": "%s %s for %s gold." % [str(item.get("tier", "")).capitalize(), str(item.get("slot", "")), UI.grouped(int(offer.get("price", 0)))],
			"confirm_text": "Buy"}):
		return
	_busy = true
	var res: Api.Response = await GameState.act("/v1/shop/buy", {"slot": int(offer.get("slot", i))})
	if res.ok:
		GameState.toast("Bought %s" % str(item.get("name", "")))
	if res.ok or res.code == "shop_stale":
		await _load()
	_busy = false


## Whether the market can be rerolled now: "free" (the hour's Fresh Wares
## gives it for nothing, whatever the purse and the day's allowance), "ok",
## "poor" (the purse is short) or "spent" (the day's allowance is used,
## whatever the purse holds). A shop from a server that sends no allowance is
## never "spent".
static func reroll_state(shop: Dictionary) -> String:
	if int(shop.get("free_rerolls", 0)) > 0:
		return "free"
	if shop.has("rerolls_left") and int(shop.get("rerolls_left", 0)) <= 0:
		return "spent"
	if not bool(shop.get("can_afford_reroll", true)):
		return "poor"
	return "ok"


## How the REROLL plate and everything on it is drawn: lit while a reroll can
## be had, and otherwise dimmed the way every plate that cannot be pressed is
## (StorePrice.DIMMED, UI.plate_face's disabled look).
static func reroll_look(shop: Dictionary) -> Color:
	return Color.WHITE if reroll_state(shop) in ["ok", "free"] else StorePrice.DIMMED


## The REROLL MARKET button's face: its price over the painted diamond, or --
## while the hour gives a restock for nothing -- the free face with FREE under
## its title.
func _paint_reroll_face() -> void:
	var b: TextureButton = _ui["reroll"]
	var cost: Label = _ui["reroll_cost"]
	var free := reroll_state(_shop) == "free"
	b.texture_normal = Art.tex(REROLL_FREE_FACE if free else REROLL_FACE)
	if free:
		cost.text = "FREE"
		UI.place(cost, REROLL_FREE_WORD)
		cost.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	else:
		cost.text = str(int(_shop.get("reroll_cost", 0)))
		UI.place(cost, _reroll_cost_home)
		cost.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT


## The refill's price before the sale, small and struck through, after the
## sale's price in its plate; hidden with no sale on.
func _paint_was(price: Label, was: int) -> void:
	_refill_was.visible = was > 0
	if was <= 0:
		return
	var f := price.label_settings.font
	var w_price := f.get_string_size(price.text, HORIZONTAL_ALIGNMENT_LEFT, -1, price.label_settings.font_size).x
	_refill_was.text = str(was)
	var s := _refill_was.label_settings
	var w_was := s.font.get_string_size(_refill_was.text, HORIZONTAL_ALIGNMENT_LEFT, -1, WAS_SIZE).x
	UI.place(_refill_was, Rect2(price.position.x + w_price + WAS_GAP, price.position.y, ceilf(w_was) + 1.0, price.size.y))
	# The rule through the figures' middle: Garamond's figures stand 0.65 of the
	# size above the baseline, which sits at the line's middle plus a third of it.
	var strike: ColorRect = _refill_was.get_node("strike")
	strike.size = Vector2(ceilf(w_was) + 2.0, 2.0)
	strike.position = Vector2(-1.0, roundf(price.size.y / 2.0 - 1.0))


## The day's allowance as the confirm dialog says it: "" when the server sends
## none.
static func rerolls_left_line(shop: Dictionary) -> String:
	if not shop.has("rerolls_left"):
		return ""
	var left := int(shop.get("rerolls_left", 0))
	return "%d of today's %d rerolls left." % [left, int(shop.get("rerolls_per_day", left))]


func _reroll() -> void:
	if _busy or _shop.is_empty():
		return
	var cost := int(_shop.get("reroll_cost", 0))
	var have := int(GameState.player().get("diamonds", 0))
	var state := reroll_state(_shop)
	# What cannot be done is said and nothing is sent.
	if state == "spent":
		await Dialog.ask(self, {"title": "Reroll the market",
			"body": "You have rerolled the market %d times today, the most a day allows. It can be rerolled again after midnight." % int(_shop.get("rerolls_per_day", 0)),
			"confirm_text": "OK"})
		return
	if state == "poor":
		await Dialog.ask(self, {"title": "Reroll the market",
			"body": "New offers cost %d diamonds, and you have %d.\n%s" % [cost, have, Goods.WHERE_DIAMONDS],
			"confirm_text": "OK"})
		return
	# The free hour and the bought reroll ask in their own words and are sent
	# the same way, through the one guard below.
	var body := "Fresh Wares: new offers for nothing this hour. Your rerolls for today are not touched."
	if state != "free":
		body = "New offers for %d diamonds. You have %d." % [cost, have]
		var left := rerolls_left_line(_shop)
		if left != "":
			body += "\n" + left
	if not await Dialog.ask(self, {"title": "Reroll the market?", "body": body, "confirm_text": "Reroll"}):
		return
	_busy = true
	var res: Api.Response = await GameState.act("/v1/shop/reroll", {})
	if res.ok:
		await _load()
	_busy = false


func _buy_good(id: String) -> void:
	if _busy:
		return
	var good := Goods.find(_store, id)
	if good.is_empty():
		return
	_busy = true
	if await Goods.buy(self, good):
		await _load()
	_busy = false
