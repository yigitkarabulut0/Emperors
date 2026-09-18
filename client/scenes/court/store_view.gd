extends Control
## ROYAL STORE — the Court's shop, cut from art/reference/store.png and
## store_2.png (art/slices/store.json, store_2.json; layout client/layout/store.json).
##
## The two paintings are one page. The header stays; under it the sections
## scroll in the paintings' order, 10 units apart as both paintings space them:
## the live offers, Crown Patronage, the six diamond packs, the Royal Stipend,
## the day's deals, the Comforts (the Steward, the Quartermaster), Herald's
## Tidings, Royal Largesse, and RESTORE PURCHASES / TERMS / PRIVACY. A section
## with nothing to show -- no live offer, Herald's Tidings while the server has
## no adverts -- is left out and the rest close up.
##
## What is on sale, and what each purchase brings, is the server's (GET
## /v1/store/court): the client keeps no catalogue. What it costs is the App
## Store's, in the player's own currency, and only that (Billing.price): the
## balance's usd_cents is Royal Favour's arithmetic, never a price to show. A
## purchase goes through Billing, which finishes it only once the server holds
## it; the Royal Delivery plays when it lands.
##
## A Court view: the shell hosts it over the tabs until the COURT tab exists,
## and its plate (CourtBack, BACK until then) goes back.
##
## The day's deals are sequenced spends (diamonds out of the purse), sent with
## action_seq through GameState.act like every other spend. Purchases and the
## Stipend's daily share are not: money and a daily claim move nothing a queued
## collect reads, and their snapshots are adopted with GameState.adopt_async.

signal back_requested

const SCREEN := "store"
## The advert plugin, when a build has one. Empty of it, WATCH says so rather
## than doing nothing (GodotAdMob's singleton; the plan's Wave 1 plugin).
const ADMOB_SINGLETON := "AdMob"
## How long after an advert to read the purse again: Google's callback reaches
## the server on its own clock, and it is usually there by now.
const ADVERT_SETTLE_SECONDS := 2.0
## Top to bottom, as the paintings stack them.
const ORDER := ["note", "sec_offer", "sec_patron", "sec_head", "sec_packs", "sec_stipend",
	"sec_deals", "sec_comforts", "sec_herald", "sec_largesse", "sec_footer"]
const TERMS_URL := "https://91-107-215-32.sslip.io/legal/terms"
const PRIVACY_URL := "https://91-107-215-32.sslip.io/legal/privacy"
## A deal already taken today: its card reads as spent.
const SPENT := Color(0.45, 0.45, 0.47)
## Under the note, when the plates carry the catalogue's reference prices.
const DOLLARS := "The prices shown are in US dollars."
## The layout's repeated parts, by position.
const TILE_ICONS := ["icon_1", "icon_2", "icon_3"]
const TILE_COUNTS := ["count_1", "count_2", "count_3"]
const PERKS := ["perk_1", "perk_2", "perk_3"]
const DEAL_PRICES := ["", "price_1", "price_2", "price_3"]
const DEAL_WAS := ["", "was_1", "was_2", "was_3"]
const DEAL_CARDS := ["card_0", "card_1", "card_2", "card_3"]
const DEAL_HITS := ["", "hit_1", "hit_2", "hit_3"]
## What a caller may open the Store at (open_at), by the shelf's name.
const SECTIONS := {"comfort": "sec_comforts", "packs": "sec_packs", "deals": "sec_deals",
	"stipend": "sec_stipend", "largesse": "sec_largesse", "offers": "sec_offer"}
## Opened at a section, the list stops this far above it.
const SECTION_MARGIN := 24.0
## The Comforts' two cards: [product id contains, buy button, price, card tap].
const COMFORTS := [["steward", "steward_buy", "steward_price", "steward_hit"],
	["quartermaster", "qm_buy", "qm_price", "qm_hit"]]

var _ui: Dictionary = {}
var _data: Dictionary = {}
var _built := false
var _busy := false
var _nodes: Array = []             ## every section node laid in the list
var _buys: Array = []              ## [{button, label, product, suffix}] -- the plates Billing prices
var _clocks: Array = []            ## [{label, ends: msec, words: Callable}] -- counted down each second
var _painted_at := 0               ## ticks when the server's seconds were read
var _prices_answered := false      ## the App Store has answered since the view asked
var _clock: Timer
var _section_y: Dictionary = {}    ## layout section id -> its top in the list
var _open_at := ""                 ## the section to bring into view once painted


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
	Billing.delivered.connect(_on_delivered)
	Billing.pending.connect(func(_id: String) -> void:
		GameState.toast("Waiting for approval. Your purchase will arrive by itself once it is given."))
	Billing.failed.connect(func(_id: String, message: String) -> void:
		if message != "":
			GameState.toast(message))
	Billing.restored.connect(_on_restored)
	_built = true


## Opens the Store scrolled so a section is in view: "comfort" (the Steward
## and the Quartermaster -- Armory's MORE ROOM), "offers" (the COURT's OFFERS
## card), "packs", "deals", "stipend", "largesse", or a layout section id. Before the Store has painted, it waits
## for the paint.
func open_at(section: String) -> void:
	_open_at = str(SECTIONS.get(section, section))
	if not _data.is_empty():
		_scroll_to_section.call_deferred()


func _scroll_to_section() -> void:
	if _open_at == "" or not _section_y.has(_open_at):
		return
	var sc: ScrollContainer = _ui["list"]
	# The list takes its content's new height a frame late; set before then,
	# the scroll is clamped to the old one.
	await get_tree().process_frame
	if not is_inside_tree():
		return
	sc.scroll_vertical = int(maxf(0.0, float(_section_y[_open_at]) - SECTION_MARGIN))
	_open_at = ""


## The shell calls this when the view opens.
func refresh() -> void:
	if _built:
		_load()


func _load() -> void:
	var res: Api.Response = await Api.get_json("/v1/store/court")
	if not is_inside_tree():
		return
	if not res.ok:
		GameState.action_failed.emit("The Royal Store could not be opened. " + res.error)
		return
	paint(res.data)


## Paints a CourtStore (a /v1/store/court answer). Public for tests and captures.
func paint(store: Dictionary) -> void:
	_data = store
	_painted_at = Time.get_ticks_msec()
	var sc: ScrollContainer = _ui["list"]
	var content: Control = sc.get_meta("content")
	for n in _nodes:
		n.queue_free()
	_nodes.clear()
	_buys.clear()
	_clocks.clear()
	var ids := PackedStringArray()
	for p in store.get("products", []):
		ids.append(str(p.get("store_id", "")))
	Billing.load_products(ids)

	var gap := Layout.rect_of(Layout.element(SCREEN, "stack_gap")).size.y
	var y := Layout.rect_of(Layout.element(SCREEN, "stack_top")).size.y
	_section_y.clear()
	for id in ORDER:
		for built in _section(id):
			var tpl := Layout.element(SCREEN, id)
			var r := Layout.rect_of(tpl)
			if not _section_y.has(id):
				_section_y[id] = y
			built["node"].position = Vector2(r.position.x, y)
			content.add_child(built["node"])
			_nodes.append(built["node"])
			y += r.size.y + gap
	content.custom_minimum_size.y = maxf(sc.size.y, y)
	# Whether the Quartermaster is owned, fresh for MORE ROOM.
	Armory.learn(store)
	if _open_at != "":
		_scroll_to_section.call_deferred()
	_paint_prices()
	_count_down()


## The nodes one section contributes: none when it has nothing to show, one
## card per live offer.
func _section(id: String) -> Array:
	match id:
		"note":
			if Billing.available:
				return []
			var b := _built_from(id)
			b["parts"]["text"].text = Billing.unavailable_reason() + "\n" + DOLLARS
			return [b]
		"sec_offer":
			var out: Array = []
			for p in live_offers(_data.get("products", [])):
				out.append(_offer_card(p))
			return out
		"sec_patron":
			var p := shelf_one(_data, "passes", "subscription")
			return [] if p.is_empty() else [_patron_card(p)]
		"sec_head":
			return [] if shelf(_data, "diamonds").is_empty() else [_built_from(id)]
		"sec_packs":
			var packs := shelf(_data, "diamonds")
			return [] if packs.is_empty() else [_packs(packs)]
		"sec_stipend":
			var p := stipend_product(_data)
			return [] if p.is_empty() else [_stipend(p)]
		"sec_deals":
			var deals: Dictionary = _data.get("deals", {})
			return [] if (deals.get("slots", []) as Array).is_empty() else [_deals(deals)]
		"sec_comforts":
			return [] if shelf(_data, "comfort").is_empty() else [_comforts()]
		"sec_herald":
			return [_herald()] if bool(_data.get("herald", {}).get("enabled", false)) else []
		"sec_largesse":
			var p := shelf_one(_data, "kingdom", "")
			return [] if p.is_empty() else [_largesse(p)]
		"sec_footer":
			return [_footer()]
	return []


func _built_from(id: String) -> Dictionary:
	return Layout.instantiate(Layout.element(SCREEN, id))


# --- the catalogue, as the server sent it --------------------------------------------

## The offers on sale now, soonest to end first. The server sends an offer only
## while it lasts and until it is bought.
static func live_offers(products: Array) -> Array:
	var out: Array = []
	for p in products:
		if str(p.get("shelf", "")) == "offers" and int(p.get("ends_in", 0)) > 0:
			out.append(p)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.get("ends_in", 0)) < int(b.get("ends_in", 0)))
	return out


static func shelf(store: Dictionary, name: String) -> Array:
	var out: Array = []
	for p in store.get("products", []):
		if str(p.get("shelf", "")) == name:
			out.append(p)
	return out


## The one product on a shelf of this kind ("" for any kind).
static func shelf_one(store: Dictionary, name: String, kind: String) -> Dictionary:
	for p in shelf(store, name):
		if kind == "" or str(p.get("kind", "")) == kind:
			return p
	return {}


## The Royal Stipend: the passes shelf's product that is not the subscription.
static func stipend_product(store: Dictionary) -> Dictionary:
	for p in shelf(store, "passes"):
		if str(p.get("kind", "")) != "subscription":
			return p
	return {}


## Which of the painting's six pack arts each diamond pack wears, in the
## catalogue's order. The ribboned arts go to the packs whose badge says so, so
## a MOST POPULAR ribbon is always on the most popular pack.
static func pack_arts(packs: Array) -> Array:
	var spec := Layout.element(SCREEN, "sec_packs")
	var arts: Dictionary = spec.get("pack_arts", {})
	var plain: Array = (arts.get("plain", []) as Array).duplicate()
	var out: Array = []
	for p in packs:
		var badge := str(p.get("badge", ""))
		if badge != "" and arts.has(badge):
			out.append(str(arts[badge]))
		elif not plain.is_empty():
			out.append(str(plain.pop_front()))
		else:
			out.append("store/pack_1")
	return out


# --- sections -----------------------------------------------------------------------

func _offer_card(p: Dictionary) -> Dictionary:
	var b := _built_from("sec_offer")
	var parts: Dictionary = b["parts"]
	var title: Label = parts["title"]
	title.text = str(p.get("title", ""))
	UI.fit_line(title, title.label_settings.font_size, 22)
	var lines: Array = p.get("lines", [])
	for i in 3:
		var icon: TextureRect = parts[TILE_ICONS[i]]
		var count: Label = parts[TILE_COUNTS[i]]
		icon.visible = i < lines.size()
		count.text = ""
		if icon.visible:
			var key := str(lines[i].get("icon", ""))
			var square := FramedFace.square_of(key)
			if square != "":
				# A frame is shown as it will be worn, round the lord's own face.
				icon.visible = false
				var framed := FramedFace.build(square, Rect2(icon.position, icon.size), _avatar())
				icon.get_parent().add_child(framed)
				icon.get_parent().move_child(framed, icon.get_index())
			else:
				icon.texture = Art.reward_line_icon(lines[i])
				fit_down(icon)
			count.text = count_words(lines[i])
	_clock_label(parts["timer"], int(p.get("ends_in", 0)), func(s: int) -> String: return UI.time_left(s))
	(parts["tiles_hit"] as BaseButton).pressed.connect(func() -> void: _say_lines(p))
	_buy_plate(parts["buy"], parts["price"], p, "")
	return b


func _patron_card(p: Dictionary) -> Dictionary:
	var b := _built_from("sec_patron")
	var parts: Dictionary = b["parts"]
	var title: Label = parts["title"]
	title.text = str(p.get("title", ""))
	UI.fit_line(title, title.label_settings.font_size, 20)
	var lines: Array = p.get("lines", [])
	var rows := perk_rows(lines)
	for i in 3:
		var l: Label = parts[PERKS[i]]
		l.text = rows[i]
		# The third row is the painting's short one (the button covers its
		# line): it keeps the others' size and says how many more a tap shows.
		UI.fit_line(l, l.label_settings.font_size, 18)
	(parts["perks_hit"] as BaseButton).pressed.connect(_open_favour)
	var patron: Dictionary = _data.get("patronage", {})
	if bool(patron.get("active", false)):
		# A patron's plate says how long the patronage runs, not a price.
		_clock_label(parts["price"], int(patron.get("seconds", 0)), func(s: int) -> String: return UI.time_left(s) + " left")
	# Sold in one place, THE CROWN'S FAVOUR: the plate says its price a month
	# (or the patron's time left) and opens that page, which carries everything
	# App Review 3.1.2 asks beside its SUBSCRIBE.
	_price_plate(parts["buy"], parts["price"], p, " a month")
	(parts["buy"] as BaseButton).pressed.connect(_open_favour)
	return b


func _packs(packs: Array) -> Dictionary:
	var sec := _built_from("sec_packs")
	var spec := Layout.element(SCREEN, "sec_packs")
	var places: Array = spec.get("places", [])
	var rows: Dictionary = spec.get("pack_art_rows", {})
	var arts := pack_arts(packs)
	for i in mini(packs.size(), places.size()):
		var p: Dictionary = packs[i]
		var art: String = arts[i]
		var row: Array = rows.get(art, ["a", 0])
		var tpl := Layout.element(SCREEN, "pack_a" if str(row[0]) == "a" else "pack_b")
		var card := Layout.instantiate(tpl, {"assets": {"art": art}})
		var parts: Dictionary = card["parts"]
		(parts["art"] as TextureRect).size = Art.tex(art).get_size()
		# The third column's plate and button sit two units right of the others'.
		var dx := float(row[1])
		for k in ["amount", "buy", "price"]:
			(parts[k] as Control).position.x += dx
		var place: Array = places[i]
		card["node"].position = Vector2(float(place[0]), float(place[1]))
		sec["node"].add_child(card["node"])
		parts["seal"].visible = bool(p.get("first_bonus", false))
		var amount: Label = parts["amount"]
		amount.text = UI.grouped(diamonds_of(p))
		UI.fit_line(amount, amount.label_settings.font_size, 18)
		_buy_plate(parts["buy"], parts["price"], p, "")
	return sec


func _stipend(p: Dictionary) -> Dictionary:
	var b := _built_from("sec_stipend")
	var parts: Dictionary = b["parts"]
	var st: Dictionary = _data.get("stipend", {})
	var l1: Label = parts["line_1"]
	var l2: Label = parts["line_2"]
	var claim: TextureButton = parts["claim"]
	if bool(st.get("active", false)):
		var left := int(st.get("days_left", 0))
		l1.text = "%d day%s left\n%d diamonds a day" % [left, "" if left == 1 else "s", int(st.get("daily_diamonds", 0))]
		var waiting := bool(st.get("claimable_today", false))
		l2.text = "Today's diamonds wait" if waiting else "Claimed today"
		_enable(claim, waiting)
	else:
		l1.text = "\n".join(line_texts(p))
		var note := str(p.get("note", ""))
		l2.text = sentence(note) if note != "" else "Each day's share is claimed on its day"
		_enable(claim, false)
	UI.fit_wrapped(l1, l1.label_settings.font_size, 15)
	UI.fit_line(l2, l2.label_settings.font_size, 14)
	claim.pressed.connect(_claim_stipend)
	_buy_plate(parts["buy"], parts["price"], p, "")
	return b


## HERALD'S TIDINGS: the rewarded advert.
##
## Both plates are the server's own words: what one is worth, and either how
## many are left today, when the next may be watched, or the level it opens at.
## WATCH is a TICKET, not a reward -- the diamonds are paid by
## Google's callback to the server, never by this screen saying it watched one.
## The whole section is hidden while the realm has no adverts (`enabled`), so a
## plate that could play nothing is never drawn. A realm that HAS one draws it
## for a young lord too, with the level it opens at, the way every other gate
## on these screens is shown (`unlocked`).
func _herald() -> Dictionary:
	var b := _built_from("sec_herald")
	var parts: Dictionary = b["parts"]
	var h: Dictionary = _data.get("herald", {})
	var unlocked := bool(h.get("unlocked", false))
	var left := int(h.get("left", 0))
	var next_in := int(h.get("next_in", 0))

	# What one is worth is said on both plates, locked or not: a lord who cannot
	# watch one yet is still being told what it will pay.
	var l1: Label = parts["line_1"]
	var lines: Array = h.get("lines", [])
	l1.text = ", ".join(PackedStringArray(lines)) if not lines.is_empty() else ""
	UI.fit_wrapped(l1, l1.label_settings.font_size, 15)

	var l2: Label = parts["line_2"]
	if not unlocked:
		l2.text = "Level %d" % int(h.get("unlock_level", 1))
	elif left <= 0:
		l2.text = "None left today"
	elif next_in > 0:
		l2.text = "In " + UI.time_left(next_in)
	else:
		l2.text = "%d left today" % left
	UI.fit_line(l2, l2.label_settings.font_size, 14)

	var watch: TextureButton = parts["watch"]
	_enable(watch, unlocked and left > 0 and next_in <= 0)
	watch.pressed.connect(_watch_advert)
	return b


## One advert. The server hands back a ticket the advert must carry; what turns
## it into diamonds is Google calling the server afterwards, so there is nothing
## to adopt here -- the store is simply read again once the advert has played.
func _watch_advert() -> void:
	if _busy:
		return
	_busy = true
	var res: Api.Response = await Api.post_json("/v1/ads/watch", {})
	if res.ok:
		var ticket: Dictionary = res.data
		if Engine.has_singleton(ADMOB_SINGLETON):
			var admob: Object = Engine.get_singleton(ADMOB_SINGLETON)
			if admob.has_method("show_rewarded"):
				admob.call("show_rewarded", str(ticket.get("unit", "")),
					str(ticket.get("user_id", "")), str(ticket.get("ticket", "")))
			# The diamonds arrive by Google's callback, which lands on the
			# server's own clock -- while the advert plays, or a moment after
			# it. The purse is read again rather than guessed at.
			await get_tree().create_timer(ADVERT_SETTLE_SECONDS).timeout
			await GameState.refresh()
		else:
			# The realm has an advert to play and this build cannot play one.
			# Said plainly rather than swallowed: a WATCH that does nothing at
			# all is the thing this section was written to avoid.
			GameState.toast("This build cannot play adverts yet.")
	else:
		GameState.action_failed.emit(res.error)
	if is_inside_tree():
		await _load()
	_busy = false


func _deals(deals: Dictionary) -> Dictionary:
	var b := _built_from("sec_deals")
	var parts: Dictionary = b["parts"]
	_clock_label(parts["timer"], int(deals.get("resets_in", 0)), func(s: int) -> String: return UI.time_left(s))
	var by_slot := {}
	for s in deals.get("slots", []):
		by_slot[int(s.get("slot", -1))] = s
	var have := int(GameState.player().get("diamonds", 0))
	# Slot 0: the gift box, free.
	var gift: Dictionary = by_slot.get(0, {})
	var free: TextureButton = parts["free"]
	var gift_open := not gift.is_empty() and not bool(gift.get("claimed", false))
	_enable(free, gift_open)
	(parts[DEAL_CARDS[0]] as CanvasItem).modulate = Color.WHITE if gift_open else SPENT
	free.pressed.connect(func() -> void: _claim_deal(gift))
	# Slots 1..3: potions, charters, a cosmetic -- for diamonds.
	for i in [1, 2, 3]:
		var s: Dictionary = by_slot.get(i, {})
		var price: Label = parts[DEAL_PRICES[i]]
		var was: Label = parts[DEAL_WAS[i]]
		var card: CanvasItem = parts[DEAL_CARDS[i]]
		var sold_out := s.is_empty()
		var taken := not sold_out and bool(s.get("claimed", false))
		card.modulate = SPENT if sold_out or taken else Color.WHITE
		if sold_out:
			price.text = "SOLD OUT"
		elif taken:
			price.text = "BOUGHT"
		else:
			price.text = UI.grouped(int(s.get("diamonds", 0)))
		var word := sold_out or taken
		price.label_settings.font = UI.font("title", 800) if word else UI.font("body", 800)
		price.label_settings.font_size = 21 if word else 28
		price.label_settings.font_color = UI.RED if not word and int(s.get("diamonds", 0)) > have else Color("#F6F3EE")
		UI.fit_line(price, price.label_settings.font_size, 14)
		var was_n := int(s.get("was", 0))
		was.visible = not word and was_n > int(s.get("diamonds", 0))
		was.text = UI.grouped(was_n)
		_strike(was)
		if i < 3:
			var count: Label = parts[TILE_COUNTS[i - 1]]
			var lines: Array = s.get("lines", [])
			# Always the count, one included: the painting shows two potions
			# whatever the slot holds, and the number is what is sold.
			count.text = "×%d" % int(lines[0].get("amount", 1)) if not lines.is_empty() else ""
			count.visible = not sold_out
		(parts[DEAL_HITS[i]] as BaseButton).pressed.connect(func() -> void:
			if sold_out:
				GameState.toast("Sold out today: you own every piece the Splendour shop sells.")
			elif taken:
				GameState.toast("Bought today. New deals in " + UI.time_left(_left(int(deals.get("resets_in", 0)))) + ".")
			else:
				_claim_deal(s))
	_paint_cosmetic(parts, by_slot.get(3, {}))
	return b


## The fourth slot shows what it sells: the crest itself, the colour on the
## wardrobe's enamel chip, the frame's own picture -- or the painted gilded
## frame, for a frame this build has no picture of.
func _paint_cosmetic(parts: Dictionary, s: Dictionary) -> void:
	var box: TextureRect = parts["cosmetic_box"]
	var name: Label = parts["cosmetic_name"]
	var c: Dictionary = s.get("cosmetic", {}) if not s.is_empty() else {}
	box.visible = not c.is_empty()
	name.visible = false
	for n in box.get_children():
		n.queue_free()
	if c.is_empty():
		return
	box.modulate = SPENT if bool(s.get("claimed", false)) else Color.WHITE
	var art := cosmetic_picture(c)
	box.texture = Art.tex(art)
	fit_down(box)
	var square := FramedFace.square_of(str(c.get("art", ""))) if str(c.get("kind", "")) == "frame" else ""
	if square != "":
		# The frame for sale, shown as it will be worn: round the lord's own face.
		box.texture = null
		box.add_child(FramedFace.build(square, Rect2(Vector2.ZERO, box.size), _avatar()))
	if str(c.get("kind", "")) == "name_color":
		# The chip's face, in the colour it sells, over the chip's gold rim.
		var face := UI.image("icons/colour_chip_face", Rect2(Vector2.ZERO, Art.tex("icons/colour_chip_face").get_size()))
		face.modulate = Color(str(c.get("color", "#FFFFFF")))
		box.add_child(face)
		face.position = (box.size - Art.tex("icons/colour_chip").get_size()) / 2.0 + Vector2(11, 11)
		name.visible = true
		name.text = str(c.get("name", "")).to_upper()
		name.label_settings.font_color = Color(str(c.get("color", "#FFFFFF")))
		UI.fit_line(name, name.label_settings.font_size, 14)
	elif str(c.get("kind", "")) == "title":
		box.texture = null
		name.visible = true
		name.text = str(c.get("text", c.get("name", "")))
		name.label_settings.font_color = UI.GOLD
		UI.fit_line(name, name.label_settings.font_size, 14)


## The picture a cosmetic is drawn with in the deals' fourth slot.
static func cosmetic_picture(c: Dictionary) -> String:
	var art := str(c.get("art", ""))
	match str(c.get("kind", "")):
		"frame":
			var square := art + "_square"
			return square if art != "" and Art.has(square) else "store/deal_frame_art"
		"crest":
			return art if art != "" and Art.has(art) else "icons/reward_crown"
		"name_color":
			return "icons/colour_chip"
	return "store/deal_frame_art"


func _comforts() -> Dictionary:
	var b := _built_from("sec_comforts")
	var parts: Dictionary = b["parts"]
	var goods := shelf(_data, "comfort")
	# The painting names its two cards; each takes the product it names.
	for i in COMFORTS.size():
		var names: Array = COMFORTS[i]
		var p := _named(goods, str(names[0]), i)
		var buy: TextureButton = parts[names[1]]
		var price: Label = parts[names[2]]
		buy.visible = not p.is_empty()
		price.visible = not p.is_empty()
		if p.is_empty():
			continue
		(parts[names[3]] as BaseButton).pressed.connect(func() -> void: _say_lines(p))
		_buy_plate(buy, price, p, "")
	return b


## The lord's own portrait id, for a frame shown round their face.
static func _avatar() -> String:
	return str(GameState.player().get("avatar", ""))


static func _named(goods: Array, id_part: String, fallback: int) -> Dictionary:
	for p in goods:
		if str(p.get("id", "")).contains(id_part):
			return p
	return goods[fallback] if fallback < goods.size() else {}


func _largesse(p: Dictionary) -> Dictionary:
	var b := _built_from("sec_largesse")
	var parts: Dictionary = b["parts"]
	var l: Label = parts["line_1"]
	l.text = sentence(str(p.get("note", ""))) if not bool(p.get("available", true)) else largesse_words(p)
	UI.fit_wrapped(l, l.label_settings.font_size, 16)
	(parts["art_hit"] as BaseButton).pressed.connect(func() -> void: _say_lines(p))
	_buy_plate(parts["buy"], parts["price"], p, "")
	return b


func _footer() -> Dictionary:
	var b := _built_from("sec_footer")
	var parts: Dictionary = b["parts"]
	(parts["restore"] as BaseButton).pressed.connect(func() -> void:
		if not Billing.available:
			GameState.toast(Billing.unavailable_reason())
			return
		Billing.restore())
	(parts["terms"] as BaseButton).pressed.connect(func() -> void: OS.shell_open(TERMS_URL))
	(parts["privacy"] as BaseButton).pressed.connect(func() -> void: OS.shell_open(PRIVACY_URL))
	return b


# --- prices and buying ------------------------------------------------------------

## Registers a painted green plate as a product's buy button. Its price (the App
## Store's, with `suffix` -- " a month") is set by _paint_prices whenever Billing
## learns one.
func _buy_plate(button: TextureButton, label: Label, p: Dictionary, suffix: String) -> void:
	_price_plate(button, label, p, suffix)
	button.pressed.connect(func() -> void: _buy(p))


## Registers a plate for its price without making it a buy button.
func _price_plate(button: TextureButton, label: Label, p: Dictionary, suffix: String) -> void:
	label.set_meta("size", label.label_settings.font_size)
	_buys.append({"button": button, "label": label, "product": p, "suffix": suffix})


## Crown Patronage's page, THE CROWN'S FAVOUR, opened over the store through the
## shell (a painted page, it closes back to exactly here). The subscription is
## sold there and only there: its title, length, price, that it renews until
## cancelled, and the Terms and Privacy Policy sit beside its SUBSCRIBE, as App
## Review 3.1.2 asks of every subscription offer.
func _open_favour() -> void:
	var shell := get_tree().get_first_node_in_group("shell") if is_inside_tree() else null
	if shell != null and shell.has_method("open_view"):
		shell.call("open_view", "favour")


func _paint_prices() -> void:
	var patron_active := bool(_data.get("patronage", {}).get("active", false))
	for e in _buys:
		var p: Dictionary = e["product"]
		var label: Label = e["label"]
		var button: TextureButton = e["button"]
		if not is_instance_valid(button):
			continue
		var sid := str(p.get("store_id", ""))
		var live := buyable(p, Billing.available, Billing.price(sid), Billing.busy)
		if str(p.get("kind", "")) == "subscription" and patron_active:
			# A patron's plate says how long the patronage runs (a clock sets it).
			button.modulate = StorePrice.DIMMED
			continue
		StorePrice.paint(button, label,
			StorePrice.words(p, Billing.available, Billing.price(sid), _prices_answered, str(e["suffix"])), live)
		UI.fit_line(label, int(label.get_meta("size", 28)), 14)


## Whether a buy plate leads anywhere now: the product can be bought, StoreKit
## is here, the App Store has named its price, and no purchase is in flight.
static func buyable(p: Dictionary, available: bool, app_price: String, busy: bool) -> bool:
	return available and app_price != "" and not busy and bool(p.get("available", true)) \
		and not bool(p.get("owned", false))


func _buy(p: Dictionary) -> void:
	if str(p.get("kind", "")) == "subscription":
		# A subscription is sold on its own page, not from a plate: _open_favour.
		_open_favour()
		return
	var store_id := str(p.get("store_id", ""))
	if bool(p.get("owned", false)):
		GameState.toast("%s is yours for good." % str(p.get("title", "")))
		return
	if not bool(p.get("available", true)):
		var note := str(p.get("note", ""))
		GameState.toast(sentence(note) if note != "" else "Not on sale to you just now.")
		return
	if not Billing.available:
		GameState.toast(Billing.unavailable_reason())
		return
	if Billing.busy:
		return
	Billing.buy(store_id)


## A purchase landed. The shell plays the Royal Delivery (it hears every
## delivery, this view's or not); what was bought changes the shelves -- a
## first purchase no longer doubles, an offer is gone -- so they are read again.
func _on_delivered(_d: Dictionary) -> void:
	if is_inside_tree():
		await _load()


func _on_restored(r: Dictionary) -> void:
	var back: Array = r.get("restored", [])
	var names: Array[String] = []
	for d in back:
		var t := str(d.get("title", ""))
		if t != "" and not names.has(t):
			names.append(t)
	if names.is_empty():
		GameState.toast("Nothing to restore: this Apple ID owns nothing that lasts.")
	else:
		GameState.toast("Restored: " + ", ".join(names))
	if is_inside_tree():
		await _load()


# --- claims ------------------------------------------------------------------------

func _claim_stipend() -> void:
	if _busy:
		return
	_busy = true
	var res: Api.Response = await Api.post_json("/v1/stipend/claim", {})
	if res.ok:
		if res.data.get("snapshot", null) is Dictionary:
			GameState.adopt_async(res.data["snapshot"])
		GameState.toast("The Crown's stipend: %s diamonds" % UI.grouped(int(res.data.get("diamonds", 0))))
	else:
		GameState.action_failed.emit(res.error)
	if is_inside_tree():
		await _load()
	_busy = false


## Takes one of the day's deals. The gift is free; the rest ask first, as every
## spend of diamonds does (Goods), and say plainly when the purse is short.
func _claim_deal(s: Dictionary) -> void:
	if _busy or s.is_empty() or bool(s.get("claimed", false)):
		return
	var price := int(s.get("diamonds", 0))
	var have := int(GameState.player().get("diamonds", 0))
	var title := str(s.get("title", ""))
	var what := "\n".join(line_texts(s))
	if price > 0:
		if have < price:
			await Dialog.ask(self, {"title": title,
				"body": "%s\nCosts %s diamonds, and you have %s.\n%s" % [
					what, UI.grouped(price), UI.grouped(have), Goods.WHERE_DIAMONDS], "confirm_text": "OK"})
			return
		if not await Dialog.ask(self, {"title": title,
				"body": "%s\n%s diamonds. You have %s." % [what, UI.grouped(price), UI.grouped(have)],
				"confirm_text": "Buy"}):
			return
	_busy = true
	var res: Api.Response = await GameState.act("/v1/store/deals/claim", {"slot": int(s.get("slot", 0))})
	if res.ok:
		GameState.toast(claimed_words(res.data.get("lines", [])))
	if is_inside_tree():
		await _load()
	_busy = false


# --- words -------------------------------------------------------------------------

## A tile's count: how many, for a stack of something; nothing for a single
## thing (a frame, a title) whose picture says it all.
static func count_words(line: Dictionary) -> String:
	var n := int(line.get("amount", 0))
	return UI.grouped(n) if n > 1 else ""


## The patronage card's three perk rows: the first two perks, and the third
## -- or, when more wait than the painting's short third row can hold, how many
## more a tap on the card shows.
static func perk_rows(lines: Array) -> Array[String]:
	var out: Array[String] = ["", "", ""]
	for i in mini(2, lines.size()):
		out[i] = str(lines[i].get("text", ""))
	if lines.size() == 3:
		out[2] = str(lines[2].get("text", ""))
	elif lines.size() > 3:
		out[2] = "and %d more" % (lines.size() - 2)
	return out


## What the Largesse plate says, in two short lines from the server's own
## amounts: what the giver gets, and what each lord of the kingdom gets. The
## plate holds two lines; the server's full words (and the title it also
## brings) are on the card's tap.
static func largesse_words(p: Dictionary) -> String:
	var mine := 0
	var each := 0
	for l in p.get("lines", []):
		match str(l.get("kind", "")):
			"diamonds": mine = int(l.get("amount", 0))
			"largesse": each = int(l.get("amount", 0))
	if mine > 0 and each > 0:
		return "%s diamonds for you\n%s for every lord of your kingdom" % [UI.grouped(mine), UI.grouped(each)]
	var t := line_texts(p)
	return "\n".join(t.slice(0, 2))


## The diamonds a pack brings, its first-purchase double included.
static func diamonds_of(p: Dictionary) -> int:
	for l in p.get("lines", []):
		if str(l.get("kind", "")) == "diamonds":
			return int(l.get("amount", 0))
	return 0


## A server note as a sentence: its first letter raised, nothing else touched
## (capitalize() would raise every word).
static func sentence(t: String) -> String:
	return t.left(1).to_upper() + t.substr(1) if t != "" else t


static func line_texts(p: Dictionary) -> Array[String]:
	var out: Array[String] = []
	for l in p.get("lines", []):
		var t := str(l.get("text", ""))
		if t != "":
			out.append(t)
	return out


static func claimed_words(lines: Array) -> String:
	if lines.is_empty():
		return "Claimed"
	var words: Array[String] = []
	for l in lines:
		words.append(str(l.get("text", "")))
	return "Claimed " + ", ".join(words)


## Says everything a product brings, and why it cannot be bought if it cannot.
func _say_lines(p: Dictionary) -> void:
	var body := "\n".join(line_texts(p))
	var note := str(p.get("note", ""))
	if note != "":
		body += "\n" + sentence(note) + "."
	await Dialog.ask(self, {"title": str(p.get("title", "")), "body": body, "confirm_text": "OK"})


# --- clocks ------------------------------------------------------------------------

## A label that counts the server's seconds down, a second at a time.
func _clock_label(label: Label, seconds: int, words: Callable) -> void:
	_clocks.append({"label": label, "seconds": seconds, "words": words})


func _left(seconds: int) -> int:
	return maxi(0, seconds - (Time.get_ticks_msec() - _painted_at) / 1000)


func _count_down() -> void:
	var expired := false
	for c in _clocks:
		var label: Label = c["label"]
		if not is_instance_valid(label):
			continue
		var left := _left(int(c["seconds"]))
		label.text = (c["words"] as Callable).call(left)
		UI.fit_line(label, label.label_settings.font_size, 14)
		if left == 0 and int(c["seconds"]) > 0:
			expired = true
	# An offer ran out, or the day's deals turned over: ask the server again.
	if expired and not _busy and is_inside_tree() and _built:
		_clocks.clear()
		_load()


# --- small parts -------------------------------------------------------------------

## A picture in a box: at its own size, centred, and drawn down only when it is
## bigger than the box -- never up, which is how a crop goes soft.
static func fit_down(t: TextureRect) -> void:
	if t.texture == null:
		return
	var sz := t.texture.get_size()
	var fits := sz.x <= t.size.x and sz.y <= t.size.y
	t.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED if fits else TextureRect.STRETCH_KEEP_ASPECT_CENTERED


func _enable(b: BaseButton, on: bool) -> void:
	b.disabled = not on
	b.modulate = Color.WHITE if on else StorePrice.DIMMED


## Strikes a label through: what the same goods cost at the store's own prices,
## beside what the deal asks.
static func _strike(l: Label) -> void:
	var line: ColorRect = l.get_node_or_null("strike")
	if line == null:
		line = ColorRect.new()
		line.name = "strike"
		line.mouse_filter = Control.MOUSE_FILTER_IGNORE
		l.add_child(line)
	var s := l.label_settings
	var w := s.font.get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, s.font_size).x
	var box := float(l.get_meta("box_w", l.size.x))
	var x := box - w if l.horizontal_alignment == HORIZONTAL_ALIGNMENT_RIGHT else 0.0
	line.color = s.font_color
	line.position = Vector2(x - 2.0, l.size.y / 2.0)
	line.size = Vector2(w + 4.0, 2.0)
