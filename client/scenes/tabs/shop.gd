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
}
const FRAME_FALLBACK := {"common": "uncommon", "mystic": "epic", "special": "legendary"}
const BADGES := {"legendary": "shop/badge_legendary", "epic": "shop/badge_epic", "rare": "shop/badge_rare",
	"uncommon": "shop/badge_uncommon", "common": "inventory/badge_common", "mystic": "inventory/badge_mystic",
	"special": "inventory/badge_special"}
const TIER_NUMBER := {"common": 1, "uncommon": 2, "rare": 3, "epic": 4, "legendary": 5, "mystic": 6, "special": 7}
const TYPE_WORD := {"weapon": "SWORD", "armor": "ARMOR", "horse": "HORSE"}

var _scroll: ScrollContainer
var _content: Control
var _ui: Dictionary = {}
var _cards: Array = []
var _shop: Dictionary = {}
var _store: Dictionary = {}
var _loaded_ms := -100000
var _busy := false


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
	_ui = Layout.build(SCREEN, _content)
	_cards = _ui["offer_card"]
	for i in _cards.size():
		var parts: Dictionary = _cards[i]["parts"]
		parts["buy"].pressed.connect(_buy.bind(i))
		# The frame is stitched per tier; the template's single frame image is replaced.
		parts["frame"].visible = false
		_cards[i]["frame_pieces"] = []
	_ui["reroll"].pressed.connect(_reroll)
	var dp: Dictionary = _ui["diamond_panel"].get_meta("parts")
	dp["energy_buy"].pressed.connect(_buy_good.bind("energy_refill"))
	dp["shield_buy"].pressed.connect(_buy_good.bind("shield"))
	set_process(true)


func refresh() -> void:
	if Time.get_ticks_msec() - _loaded_ms > 3000:
		_load()
	else:
		_paint()


func _process(_dt: float) -> void:
	if not visible or _shop.is_empty():
		return
	var left := int(_shop.get("seconds_left", 0)) - (Time.get_ticks_msec() - _loaded_ms) / 1000
	if left < 0:
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
	_ui["reroll_cost"].text = str(int(_shop.get("reroll_cost", 0)))
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
		p["badge"].texture = Art.tex(BADGES.get(tier, "shop/badge_uncommon"))
		p["badge"].size = p["badge"].texture.get_size()
		p["name"].text = str(item.get("name", ""))
		UI.fit_label(p["name"], 26, 15)
		var slot := str(item.get("slot", "weapon"))
		p["type_icon"].texture = Art.tex("shop/type_" + ("sword" if slot == "weapon" else slot))
		p["type"].text = TYPE_WORD.get(slot, slot.to_upper())
		p["tier"].text = "TIER %d" % int(TIER_NUMBER.get(tier, 1))
		p["price"].text = UI.short_number(int(offer.get("price", 0)))
		var sold := bool(offer.get("purchased", false))
		c["node"].modulate = Color(0.45, 0.45, 0.45) if sold else Color.WHITE
		p["buy"].disabled = sold
	var dp: Dictionary = _ui["diamond_panel"].get_meta("parts")
	var goods: Array = _store.get("goods", [])
	for g in goods:
		var id := str(g.get("id", ""))
		if id == "energy_refill":
			dp["energy_desc"].text = "Restore %d Energy" % GameState.max_energy()
			dp["energy_amount"].text = str(GameState.max_energy())
			dp["energy_price"].text = str(int(g.get("diamonds", 0)))
			dp["energy_buy"].modulate = Color.WHITE if bool(g.get("useful", true)) else Color(0.5, 0.5, 0.5)
		elif id == "shield":
			dp["shield_desc"].text = _shield_blurb(str(g.get("blurb", "")))
			dp["shield_price"].text = str(int(g.get("diamonds", 0)))
			dp["shield_buy"].modulate = Color.WHITE if bool(g.get("useful", true)) else Color(0.5, 0.5, 0.5)


## "No one can raid you for 8 hours." -> "Protects your city\nfor 8 hours"
func _shield_blurb(blurb: String) -> String:
	var m := RegEx.new()
	m.compile("for ([0-9]+ [a-z]+)")
	var hit := m.search(blurb)
	if hit:
		return "Protects your city\nfor " + hit.get_string(1)
	return "Protects your city\nfor a while"


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
	_busy = false
	if res.ok:
		GameState.action_failed.emit("Bought %s" % str(item.get("name", "")))
		await _load()
	elif res.code == "shop_stale":
		await _load()


func _reroll() -> void:
	if _busy or _shop.is_empty():
		return
	var cost := int(_shop.get("reroll_cost", 0))
	if not await Dialog.ask(self, {"title": "Reroll the market?", "body": "New offers for %d diamonds." % cost, "confirm_text": "Reroll"}):
		return
	_busy = true
	var res: Api.Response = await GameState.act("/v1/shop/reroll", {})
	_busy = false
	if res.ok:
		await _load()


func _buy_good(id: String) -> void:
	if _busy:
		return
	var good: Dictionary = {}
	for g in _store.get("goods", []):
		if str(g.get("id", "")) == id:
			good = g
	if good.is_empty():
		return
	if not bool(good.get("useful", true)):
		GameState.action_failed.emit("Nothing to gain from that right now")
		return
	if not await Dialog.ask(self, {"title": str(good.get("name", "")), "body": "%s\n%d diamonds." % [str(good.get("blurb", "")), int(good.get("diamonds", 0))], "confirm_text": "Buy"}):
		return
	_busy = true
	var res: Api.Response = await GameState.act("/v1/store/buy", {"good": id})
	_busy = false
	if res.ok:
		await _load()
