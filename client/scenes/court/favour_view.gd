extends Node
## THE CROWN'S FAVOUR — Crown Patronage and Royal Favour, cut from
## art/reference/favour.png (art/slices/favour.json, layout client/layout/favour.json).
##
## The painting is a whole page -- its own gold frame, no rail, no pills -- so
## it opens on the painted pages' host (PaintedPage), as the treasury does: it
## fits the phone, closes by its CLOSE, the back gesture or Escape, and ignores
## the tap that opened it. This node lives on the page and keeps what it shows.
##
## Crown Patronage is the monthly subscription. Its perks are the product's
## lines from GET /v1/store/court, one to a painted row; its price is the App
## Store's own (Billing.price), never the balance's dollars. SUBSCRIBE buys
## through Billing and says how long a running patronage has left; MANAGE opens
## the App Store's subscriptions. The plate under them carries what App Review
## 3.1.2 asks of every subscription offer: its title, its length, its price, that
## it renews by itself until cancelled, and the Terms and the Privacy Policy.
##
## Royal Favour is what a lord has spent, in US cents, less refunds: ten levels,
## a shield each. The shields up to the lord's level are lit and the bar runs to
## where their favour stands between two pins. A shield tapped says what its
## level gives; today's gift, when it waits, is claimed on the green plate. The
## wax seal is the one other lords see beside the name: it is dimmed until the
## lord has one (PlayerView.vip_seal).
##
## Nothing here moves action_seq: a purchase arrives on the App Store's
## schedule, and a claim answers with a snapshot adopted through
## GameState.adopt_async.

## The page's layout, and this script (a static `open` cannot name its own).
const PAGE := "favour"
const SELF := "res://scenes/court/favour_view.gd"
const PATRONAGE := "patronage"
const TERMS_URL := "https://91-107-215-32.sslip.io/legal/terms"
const PRIVACY_URL := "https://91-107-215-32.sslip.io/legal/privacy"
const MANAGE_URL := "https://apps.apple.com/account/subscriptions"
## The seal of a lord who has none yet: the painted seal under a veil.
const SEAL_VEIL := Color(0, 0, 0, 0.58)
## The disclosure's type. A design unit is about 0.42 pt on a 393 pt iPhone,
## so 22 is about 9 pt: the least App Review reads as clearly shown. The plate
## is drawn taller than painted to hold it (art/slices/favour.json).
const DISCLOSURE_SIZE := 22
const DISCLOSURE_COLOR := Color("#D8CFBF")
const LINK_COLOR := "#E9C46A"
const LINK_WORDS := ["Terms of Use", "Privacy Policy"]
const LINK_GAP := "   ·   "
## A line of EB Garamond is this many times its size tall.
const GARAMOND_LINE := 1.36
## A thumb: 44 pt, 95 units; and the least room kept round a link's words.
const TAP := 96.0
const LINK_PAD := 16.0
## A face's window in a frame's square, as a share of the square (the
## wardrobe's strip: a 112 face 24 inside a 160 frame).
const FACE_IN_FRAME := Rect2(0.15, 0.15, 0.7, 0.7)
## Today's gift on the painted family's green: its word's size (and the least
## it comes down to), and the diamond after it.
const GIFT_SIZE := 22
const GIFT_MIN := 16
const GIFT_ICON := 26.0
const GIFT_GAP := 6.0
const LEVELS := 10

var _p: PaintedPage
var _rows: Array = []                ## [{node, parts}] -- one per perk line shown
var _pins: Array = []                ## TextureRect per level
var _shields: Array = []             ## TextureRect per level
var _disclosure: Label
var _links: RichTextLabel
var _link_hits: Array = []           ## the Terms' target, then the Privacy Policy's
var _store: Dictionary = {}
var _selected := 0                   ## the level whose gifts the plate shows
var _level_seen := -1                ## the lord's level when the plate was last chosen
var _busy := false


## Opens the page over the game and reads the store. `opts` goes to
## PaintedPage.open (a test's inset); "offline" skips the read (a test paints).
static func open(host: Node, opts: Dictionary = {}) -> PaintedPage:
	var p := PaintedPage.open(host, PAGE, opts)
	var v: Node = (load(SELF) as GDScript).new()
	v.name = "FavourView"
	p.add_child(v)
	v.call("_setup", p)
	if not bool(opts.get("offline", false)):
		v.call("refresh")
	return p


## The page's view, for a test or a capture that paints it.
static func of(p: PaintedPage) -> Node:
	return p.get_node_or_null("FavourView")


func _setup(p: PaintedPage) -> void:
	_p = p
	_build_disclosure()
	_build_levels()

	_p.on("subscribe", _subscribe)
	_p.on("manage", func() -> void: OS.shell_open(MANAGE_URL))
	_p.on("gift", _claim_gift)
	var gift := _p.node("gift") as Button
	# The gift's diamonds after its number, as a price is written everywhere.
	gift.icon = Art.tex("icons/diamond")
	gift.icon_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	gift.add_theme_constant_override("icon_max_width", int(GIFT_ICON))
	gift.add_theme_constant_override("h_separation", int(GIFT_GAP))
	# The tap area is taller than the plate (UI.inset_plate), and the words and
	# the diamond keep the painted family's edge in from each side: the diamond
	# goes to the content's right edge, which was the plate's rim.
	for state in ["normal", "hover", "focus", "pressed", "disabled"]:
		var sb := gift.get_theme_stylebox(state)
		if sb != null:
			sb.content_margin_left = Dialog.PLATE_EDGE
			sb.content_margin_right = Dialog.PLATE_EDGE
	gift.visible = false
	# Only the red plate's own words: the dim veil over the seal starts clear.
	_p.node("vip_seal").modulate = Color(1, 1, 1, 0)

	# Methods, not lambdas: an autoload's connection to a freed node's method is
	# dropped with it, and a lambda's is not.
	Billing.products_changed.connect(_paint_patron)
	Billing.busy_changed.connect(_on_busy)
	Billing.delivered.connect(_on_delivered)
	Billing.failed.connect(_on_failed)
	Billing.pending.connect(_on_pending)


func refresh() -> void:
	await _load()


func _load() -> void:
	var res: Api.Response = await Api.get_json("/v1/store/court")
	if not is_inside_tree():
		return
	if not res.ok:
		GameState.action_failed.emit("The Royal Store could not be read. " + res.error)
		return
	paint(res.data)


## Paints a /v1/store/court answer. Public for tests and captures.
func paint(store: Dictionary) -> void:
	_store = store
	var product := patronage_of(store)
	var sid := str(product.get("store_id", ""))
	if sid != "" and not Billing.has_product(sid):
		Billing.load_products(PackedStringArray([sid]))
	_paint_perks(product.get("lines", []))
	_paint_patron()
	_paint_vip(store.get("vip", {}))


# --- Crown Patronage ---------------------------------------------------------------

## The patronage product on the store's shelves, or {}.
static func patronage_of(store: Dictionary) -> Dictionary:
	for p in store.get("products", []):
		if str(p.get("id", "")) == PATRONAGE:
			return p
	return {}


## One painted row per perk, the rows centred in the five painted rows' band.
## A perk that brings its own look (the Patron's Frame) shows it in the crown's
## place, on the row cut with its crown lifted.
func _paint_perks(lines: Array) -> void:
	for r in _rows:
		r["node"].queue_free()
	_rows.clear()
	var tpl := Layout.element(PAGE, "perk_row")
	var cut := Layout.rect_of(tpl)
	var pitch := float(tpl.get("pitch", 56))
	var slots := int(tpl.get("rows", 5))
	var shown := perk_rows(lines, slots)
	var lead := (slots - shown.size()) * pitch / 2.0
	var icon_at := Layout.rect_of({"rect": tpl.get("icon", [9, 2, 50, 50])})
	for i in shown.size():
		var line: Dictionary = shown[i]
		var built := Layout.instantiate(tpl)
		_p.place(built["node"], Rect2(cut.position + Vector2(0, lead + i * pitch), cut.size))
		var pic := perk_picture(line, icon_at)
		if pic != null:
			(built["parts"]["row"] as TextureRect).texture = Art.tex(str(tpl.get("bare", "")))
			built["node"].add_child(pic)
			built["icon"] = pic
		var l: Label = built["parts"]["line"]
		l.text = str(line.get("text", ""))
		UI.fit_line(l, 25, 20)
		_rows.append(built)


## The rows the band shows: every line while there are rows enough; past that,
## all but the last row's worth and, on it, how many more -- as the Royal
## Store's patronage card says it.
static func perk_rows(lines: Array, slots: int) -> Array:
	if lines.size() <= slots:
		return lines.duplicate()
	var out := lines.slice(0, slots - 1)
	out.append({"text": "and %d more" % (lines.size() - slots + 1)})
	return out


## What a perk shows in the crown's place, or null for the crown: a frame as
## it is worn -- its square (as every reward shows a frame) round the lord's
## own face, as the wardrobe's strip shows it; empty, at the crown's size, it
## read as a box to tick -- or a name colour's chip.
static func perk_picture(line: Dictionary, at: Rect2) -> Control:
	var icon := str(line.get("icon", ""))
	if icon.begins_with("frames/"):
		var box := Control.new()
		box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		UI.place(box, at)
		var side := minf(at.size.x, at.size.y)
		var sq := Rect2(((at.size - Vector2(side, side)) / 2.0).round(), Vector2(side, side))
		var face := UI.image(Art.avatar_small(str(GameState.player().get("avatar", ""))),
			Rect2(sq.position + sq.size * FACE_IN_FRAME.position, sq.size * FACE_IN_FRAME.size))
		face.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		face.clip_contents = true
		box.add_child(face)
		var frame := TextureRect.new()
		frame.texture = Art.reward_icon(icon)
		frame.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		frame.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
		UI.place(frame, sq)
		box.add_child(frame)
		return box
	if str(line.get("color", "")) != "":
		# The enamel chip, drawn down to the crown's height, its face tinted.
		var chip := Art.tex("icons/colour_chip").get_size()
		var s := minf(at.size.x / chip.x, at.size.y / chip.y)
		var box := Control.new()
		box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		UI.place(box, Rect2(at.position + (at.size - chip * s) / 2.0, chip * s))
		box.add_child(UI.image("icons/colour_chip", Rect2(Vector2.ZERO, chip * s)))
		var face := UI.image("icons/colour_chip_face", Rect2(Vector2(11, 11) * s,
			Art.tex("icons/colour_chip_face").get_size() * s))
		face.modulate = Color(str(line["color"]))
		box.add_child(face)
		return box
	return null


func _paint_patron() -> void:
	if _p == null:
		return
	var product := patronage_of(_store)
	var patron: Dictionary = _store.get("patronage", {})
	var sid := str(product.get("store_id", ""))
	var price := Billing.price(sid)
	var st := _p.node("status") as Label
	st.text = status_words(patron, price)
	UI.fit_line(st, 24, 18)
	var b := _p.node("subscribe") as Button
	b.text = subscribe_word(patron)
	# A patron's plate says how long is left and opens the App Store's
	# subscriptions, where it is managed: it stays lit.
	b.disabled = not bool(patron.get("active", false)) and (not Billing.available or price == ""
		or Billing.busy or product.is_empty())
	_paint_disclosure(price)


## The red plate: the App Store's price a month, or that the lord is a patron.
static func status_words(patron: Dictionary, price: String) -> String:
	if bool(patron.get("active", false)):
		return "A PATRON OF THE CROWN"
	if price == "":
		return "ONE MONTH"
	return "%s A MONTH" % price


## SUBSCRIBE, or how long a running patronage has left.
static func subscribe_word(patron: Dictionary) -> String:
	if not bool(patron.get("active", false)):
		return "SUBSCRIBE"
	var s := int(patron.get("seconds", 0))
	if s >= 2 * 86400:
		return "%d DAYS LEFT" % (s / 86400)
	if s >= 86400:
		return "1 DAY LEFT"
	return "%s LEFT" % UI.short_duration(s).to_upper()


## App Review 3.1.2's words: the title, its length, the App Store's price (or,
## before StoreKit has said it, that the price is the App Store's), who is
## charged, and that it renews until cancelled in Settings. Two lines of the
## plate at DISCLOSURE_SIZE with the longest price; the links are the third.
static func disclosure_words(price: String) -> String:
	var cost := ("for %s" % price) if price != "" else "at the App Store's price"
	return ("Crown Patronage: one month %s, charged to your Apple ID. Renews monthly until cancelled "
		+ "in Settings at least 24 hours before it ends.") % cost


## The plate under SUBSCRIBE: the words, and the Terms of Use and the Privacy
## Policy on the line under them, each link under a thumb-sized target.
func _build_disclosure() -> void:
	var box := Layout.rect_of(Layout.element(PAGE, "disclosure"))
	var line_h := ceilf(DISCLOSURE_SIZE * GARAMOND_LINE)
	_disclosure = UI.label("", DISCLOSURE_SIZE, DISCLOSURE_COLOR, "body", 600)
	_disclosure.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_disclosure.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_p.place(_disclosure, Rect2(box.position, Vector2(box.size.x, box.size.y - line_h)))

	_links = RichTextLabel.new()
	_links.bbcode_enabled = true
	_links.scroll_active = false
	_links.autowrap_mode = TextServer.AUTOWRAP_OFF
	_links.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var f := UI.font("body", 700)
	_links.add_theme_font_override("normal_font", f)
	_links.add_theme_font_size_override("normal_font_size", DISCLOSURE_SIZE)
	_links.add_theme_color_override("default_color", DISCLOSURE_COLOR)
	_links.text = "[url=terms][color=%s]%s[/color][/url]%s[url=privacy][color=%s]%s[/color][/url]" % [
		LINK_COLOR, LINK_WORDS[0], LINK_GAP, LINK_COLOR, LINK_WORDS[1]]
	var at := Vector2(box.position.x, box.end.y - line_h)
	_p.place(_links, Rect2(at, Vector2(box.size.x, line_h)))
	# The words are a line of type, 30 units tall; the thumb needs 95. Each
	# link's target runs from the plate's edge (or halfway across the gap
	# between the two) past its words, the full height of a thumb, centred on
	# the line.
	_link_hits.clear()
	for r in link_targets(f, DISCLOSURE_SIZE, at, line_h):
		var hit := UI.hotspot(Rect2())
		var meta: String = ["terms", "privacy"][_link_hits.size()]
		hit.pressed.connect(_on_link.bind(meta))
		_p.place(hit, r)
		_link_hits.append(hit)


## Where the two links' targets go, in the painting's units: from the words'
## ink, padded to a thumb (TAP units) and split halfway across the gap.
static func link_targets(f: Font, size_pt: int, at: Vector2, line_h: float) -> Array:
	var w0 := f.get_string_size(LINK_WORDS[0], HORIZONTAL_ALIGNMENT_LEFT, -1, size_pt).x
	var gap := f.get_string_size(LINK_GAP, HORIZONTAL_ALIGNMENT_LEFT, -1, size_pt).x
	var w1 := f.get_string_size(LINK_WORDS[1], HORIZONTAL_ALIGNMENT_LEFT, -1, size_pt).x
	var mid := at.x + w0 + gap / 2.0
	var top := at.y + line_h / 2.0 - TAP / 2.0
	var left := minf(at.x - LINK_PAD, mid - TAP)
	var right := maxf(at.x + w0 + gap + w1 + LINK_PAD, mid + TAP)
	return [Rect2(left, top, mid - left, TAP), Rect2(mid, top, right - mid, TAP)]


## The disclosure is set at DISCLOSURE_SIZE and never shrunk: its words are
## sized to two lines of the plate with the longest price, and a test holds
## them there (favour_view_fit.gd).
func _paint_disclosure(price: String) -> void:
	_disclosure.text = disclosure_words(price)


func _on_link(meta: Variant) -> void:
	match str(meta):
		"terms": OS.shell_open(TERMS_URL)
		"privacy": OS.shell_open(PRIVACY_URL)


func _subscribe() -> void:
	if bool(_store.get("patronage", {}).get("active", false)):
		OS.shell_open(MANAGE_URL)
		return
	var sid := str(patronage_of(_store).get("store_id", ""))
	if sid == "":
		return
	Billing.buy(sid)


func _on_busy(_busy_now: bool) -> void:
	_paint_patron()


func _on_failed(_store_id: String, message: String) -> void:
	GameState.toast(message)


func _on_pending(_store_id: String) -> void:
	GameState.toast("Waiting for approval. Crown Patronage begins as soon as it is given.")


func _on_delivered(_delivery: Dictionary) -> void:
	# Billing has adopted the snapshot; the page reads the new store.
	if is_inside_tree():
		await _load()


# --- Royal Favour --------------------------------------------------------------------

func _build_levels() -> void:
	var pin := Layout.element(PAGE, "pin")
	var shield := Layout.element(PAGE, "shield")
	var pitch := float(pin.get("pitch", 78))
	var pr := Layout.rect_of(pin)
	var sr := Layout.rect_of(shield)
	for k in LEVELS:
		var dx := Vector2(pitch * k, 0)
		var s := UI.image(str(shield.get("dim", "")), Rect2())
		_p.place(s, Rect2(sr.position + dx, sr.size))
		_shields.append(s)
		var p := UI.image(str(pin.get("asset", "")), Rect2())
		p.visible = false
		_p.place(p, Rect2(pr.position + dx, pr.size))
		_pins.append(p)
		# A thumb's target: the shield and the pin above it, half a pitch each side.
		var hit := UI.hotspot(Rect2())
		hit.pressed.connect(_select_level.bind(k + 1))
		_p.place(hit, Rect2(sr.position.x + sr.size.x / 2.0 - pitch / 2.0 + dx.x, pr.position.y,
			pitch, sr.end.y - pr.position.y))


func _paint_vip(vip: Dictionary) -> void:
	var level := int(vip.get("level", 0))
	var lit: String = str(Layout.element(PAGE, "shield").get("lit", ""))
	var dim: String = str(Layout.element(PAGE, "shield").get("dim", ""))
	for k in LEVELS:
		var on := k < level
		(_shields[k] as TextureRect).texture = Art.tex(lit if on else dim)
		(_pins[k] as TextureRect).visible = on
	Layout.set_fill(_p.node("bar_fill"), fill_ratio(vip))
	# The seal other lords see: dimmed until the lord carries one.
	var sealed := bool(GameState.player().get("vip_seal", level > 0))
	_p.node("vip_seal").modulate = Color(1, 1, 1, 0) if sealed else SEAL_VEIL
	var gift := _p.node("gift") as Button
	gift.visible = bool(vip.get("gift_claimable", false)) and int(vip.get("gift_diamonds", 0)) > 0
	gift.text = "CLAIM +%d" % int(vip.get("gift_diamonds", 0))
	gift.disabled = _busy
	# The words and their diamond inside the plate's flat middle, clear of its
	# rim and chamfers: the painted family's edge on each side.
	var pr: Array = Layout.element(PAGE, "gift").get("paint_rect", [0, 0, 200, 66])
	var room := float(pr[2]) - 2.0 * Dialog.PLATE_EDGE
	var f := gift.get_theme_font("font")
	var size_pt := GIFT_SIZE
	while size_pt > GIFT_MIN and f.get_string_size(gift.text, HORIZONTAL_ALIGNMENT_LEFT, -1, size_pt).x \
			+ GIFT_ICON + GIFT_GAP > room:
		size_pt -= 1
	gift.add_theme_font_size_override("font_size", size_pt)
	# The plate opens on the level to come (the top one at the top); a lord whose
	# level has changed since is shown their new one to come.
	if _selected == 0 or level != _level_seen:
		_selected = mini(level + 1, LEVELS)
	_level_seen = level
	_select_level(_selected)


## Where the bar runs to, as a share of its track: to the pin of the lord's
## level, and on toward the next as far as their favour has come between them.
## Level 0 runs from the tube's end toward the first pin; level 10 fills it.
static func fill_ratio(vip: Dictionary) -> float:
	var ends := Layout.rect_of(Layout.element(PAGE, "track_ends"))
	var fill := Layout.element(PAGE, "bar_fill")
	var track: Array = fill.get("track", [98, 1291, 748, 24])
	var pin := Layout.element(PAGE, "pin")
	var first := Layout.rect_of(pin).get_center().x
	return bar_ratio(vip, ends.position.x, ends.end.x, first, float(pin.get("pitch", 78)),
		float(track[0]), float(track[2]))


## Pure, so the rule is tested without a page: `start` and `end` are the tube's
## inner ends, `first` the first pin's centre, `pitch` the pins' spacing, and the
## ratio is of the fill's own track (`track_x`, `track_w`).
static func bar_ratio(vip: Dictionary, start: float, end: float, first: float, pitch: float,
		track_x: float, track_w: float) -> float:
	var level := clampi(int(vip.get("level", 0)), 0, LEVELS)
	var tiers: Array = vip.get("tiers", [])
	var points := float(vip.get("points", 0))
	var x := end
	if level < LEVELS:
		var from_pts := 0.0
		var from_x := start
		if level > 0:
			from_x = first + pitch * (level - 1)
			from_pts = float(_tier_points(tiers, level))
		var to_x := first + pitch * level
		var to_pts := float(_tier_points(tiers, level + 1))
		var t := 0.0 if to_pts <= from_pts else clampf((points - from_pts) / (to_pts - from_pts), 0.0, 1.0)
		x = from_x + (to_x - from_x) * t
	return clampf((x - track_x) / track_w, 0.0, 1.0)


static func _tier_points(tiers: Array, level: int) -> int:
	for t in tiers:
		if int(t.get("level", 0)) == level:
			return int(t.get("points", 0))
	return 0


func _select_level(level: int) -> void:
	_selected = clampi(level, 1, LEVELS)
	var words := level_words(_store.get("vip", {}), _selected)
	var t := _p.node("level_title") as Label
	t.text = words[0]
	UI.fit_line(t, 20, 16)
	var l := _p.node("level_text") as Label
	l.text = words[1]
	UI.fit_line(l, 20, 15)


## What a level's plate says: its name and threshold, and what it gives.
static func level_words(vip: Dictionary, level: int) -> Array:
	var tier := {}
	for t in vip.get("tiers", []):
		if int(t.get("level", 0)) == level:
			tier = t
	var mine := int(vip.get("level", 0))
	var head := "LEVEL %d  ·  %s FAVOUR" % [level, UI.grouped(int(tier.get("points", 0)))]
	if level == mine:
		head += "  ·  YOURS"
	elif level == mine + 1:
		head += "  ·  %s TO GO" % UI.grouped(maxi(0, int(tier.get("points", 0)) - int(vip.get("points", 0))))
	var gifts: Array[String] = []
	var daily := int(tier.get("daily_diamonds", 0))
	if daily > 0:
		gifts.append("%d diamonds each day" % daily)
	var bag := int(tier.get("bag_bonus", 0))
	if bag > 0:
		gifts.append("+%d bag slots" % bag)
	for c in tier.get("cosmetics", []):
		gifts.append(str(c.get("text", "")))
	if gifts.is_empty():
		gifts.append("Favour grows with every purchase")
	return [head, " · ".join(gifts)]


func _claim_gift() -> void:
	if _busy:
		return
	_busy = true
	(_p.node("gift") as Button).disabled = true
	var res: Api.Response = await Api.post_json("/v1/vip/gift", {})
	if res.ok:
		if res.data.get("snapshot", null) is Dictionary:
			GameState.adopt_async(res.data["snapshot"])
		GameState.toast("Royal Favour's gift: %d diamonds" % int(res.data.get("diamonds", 0)))
	else:
		GameState.action_failed.emit(res.error)
	if is_inside_tree():
		await _load()
	_busy = false
	if is_inside_tree():
		(_p.node("gift") as Button).disabled = false
