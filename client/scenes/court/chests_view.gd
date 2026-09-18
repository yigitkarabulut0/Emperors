extends Control
## THE TAX CART -- COURT ▸ CHESTS, cut from art/reference/chests.png
## (art/slices/chests.json, layout client/layout/chests.json).
##
## The crown's cart comes to the gate on a clock the server keeps: one every
## `interval` seconds, up to `cap` of them waiting in the yard, and each lord
## may hold Cart Writs besides, each one more cart opened after the waiting
## ones. OPEN opens one; what it held is fixed before it is opened (the server
## seeds the Nth cart by the lord and N), so there is nothing to reroll.
##
## The page is the painting's: the yard's places lit for the carts waiting and
## grey for the empty ones, the hourglass's plate counting to the next cart,
## OPEN and the (i) that shows the published odds, and the three cards of a
## cart's round -- in the yard, on the road, opened -- each saying its part.
## Every figure is the server's (GET /v1/cart); the countdown only runs down
## from the answer's moment, and a cart that arrives while the page is open is
## asked for again rather than assumed.
##
## No action_seq: the cart pays through the one reward path, outside the
## sequence the queued collects count on, and its snapshot is adopted through
## GameState.adopt_async.

signal back_requested

const SCREEN := "chests"
const CAPTIONS := {"waiting": "caption_waiting", "road": "caption_road", "opened": "caption_opened"}
const CAPTION_SIZE := 26
const CAPTION_MIN := 17
const TIMER_SIZE := 30
const TIMER_MIN := 20
const SUBTITLE_SIZE := 30
const SUBTITLE_MIN := 20
## A plate that cannot be pressed now, as every one is drawn (StorePrice.DIMMED).
const DIMMED := Color(0.55, 0.55, 0.55)
## The painting's three places in the yard: their centres, and the pitch a yard
## of another size is spread at, over the stock panel's inside.
const PLACES := [214.5, 285.5, 356.5]
const PLACE_Y := 1099.5
const PANEL_X := Vector2(168.0, 398.0)
const PITCH := 71.0
const NUMBER_WORDS := ["", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
	"eleven", "twelve"]
## The painted picture a prize is shown with where its reward line's own icon
## is only the currency it pays in: the purses for gold, the scroll for
## experience, the chest for gear not yet rolled (reward_icons.png, cut by
## art/slices/rewards.json). Every other prize -- and one added later -- keeps
## its line's own picture, and rolled gear always shows its own painting.
const PRIZE_ART := {"purse": "rewards/purse_small", "heavy_purse": "rewards/purse_heavy",
	"scroll": "rewards/xp_scroll", "gear": "rewards/gear_chest"}

var _ui: Dictionary = {}
var _cart: Dictionary = {}         ## the last /v1/cart answer, or the snapshot's cart before it comes
var _cart_at_ms := 0               ## when it came: the countdown runs from here
var _places: Array = []            ## the yard's places as built: [{node, parts}]
var _busy := false
var _built := false
var _asked_again := false          ## the countdown ran out and the cart was asked for again


func _ready() -> void:
	_ui = Layout.build(SCREEN, self)
	# The way back, the same plate and word on every Court view.
	_ui["back_hit"] = CourtBack.build(self)
	(_ui["back_hit"] as BaseButton).pressed.connect(func() -> void: back_requested.emit())
	(_ui["open"] as BaseButton).pressed.connect(_open)
	# The guide's cart step points here, after the COURT's Chests card.
	GuideTargets.register("chests.open", _ui["open"])
	(_ui["info"] as BaseButton).pressed.connect(_odds)
	_places = _ui.get("cart", [])
	var tick := Timer.new()
	tick.wait_time = 1.0
	tick.timeout.connect(_tick)
	add_child(tick)
	tick.start()
	_built = true
	# What the snapshot already says, until the cart's own answer comes.
	var snap := GameState.cart()
	if not snap.is_empty():
		paint(snap, GameState.live_age_s())


## The shell calls this when the view opens.
func refresh() -> void:
	if _built:
		_load()


func _load() -> void:
	var res: Api.Response = await Api.get_json("/v1/cart")
	if not is_inside_tree():
		return
	if not res.ok:
		GameState.action_failed.emit("The Tax Cart could not be read. " + res.error)
		return
	paint(res.data)


## Paints a cart (a /v1/cart answer, or the snapshot's `cart`) given `age`
## seconds ago. Public for tests and captures.
func paint(cart: Dictionary, age: int = 0) -> void:
	_cart = cart
	_cart_at_ms = Time.get_ticks_msec() - age * 1000
	_asked_again = false
	_paint()


func _age() -> int:
	return (Time.get_ticks_msec() - _cart_at_ms) / 1000


func _tick() -> void:
	if _cart.is_empty():
		return
	_paint_clock()
	# The next cart is at the gate: ask what the yard holds now, once.
	var st := int(_cart.get("stock", 0))
	if bool(_cart.get("unlocked", true)) and st < int(_cart.get("cap", 3)) and int(_cart.get("next_in", 0)) > 0 \
			and left_until_next(_cart, _age()) <= 0 and not _asked_again and not _busy:
		_asked_again = true
		_load()


func _paint() -> void:
	if not _built:
		return
	_set_line(_ui["subtitle"], subtitle_for(int(_cart.get("interval", 0))), SUBTITLE_SIZE, SUBTITLE_MIN)
	_paint_places()
	_paint_clock()
	_set_line(_ui[CAPTIONS["waiting"]], waiting_words(_cart), CAPTION_SIZE, CAPTION_MIN)
	_set_line(_ui[CAPTIONS["opened"]], opened_words(_cart), CAPTION_SIZE, CAPTION_MIN)
	(_ui["open"] as CanvasItem).modulate = Color.WHITE if open_state(_cart) == "ok" and not _busy else DIMMED


## The countdown's two lines: the hourglass's plate and the road's card.
func _paint_clock() -> void:
	var age := _age()
	_set_line(_ui["timer"], timer_words(_cart, age), TIMER_SIZE, TIMER_MIN)
	_set_line(_ui[CAPTIONS["road"]], road_words(_cart, age), CAPTION_SIZE, CAPTION_MIN)


## The yard: one painted cart per place, lit for each cart waiting, grey for
## each place empty. The painting's three places stand where they were painted;
## a yard of another size is spread evenly over the panel, drawn down if the
## places would crowd.
func _paint_places() -> void:
	var cap := maxi(0, int(_cart.get("cap", PLACES.size())))
	var stock := clampi(int(_cart.get("stock", 0)), 0, cap)
	var tpl := Layout.element(SCREEN, "cart")
	while _places.size() < cap:
		var built := Layout.instantiate(tpl, [0, 0])
		add_child(built["node"])
		# Under OPEN and the back plate, like the painted ones.
		move_child(built["node"], (_places[0]["node"] as Node).get_index() if not _places.is_empty() else get_child_count() - 1)
		_places.append(built)
	var spots := cart_places(cap)
	var k := minf(1.0, spot_pitch(cap) / PITCH)
	for i in _places.size():
		var p: Dictionary = _places[i]
		var node: Control = p["node"]
		node.visible = i < cap
		if i >= cap:
			continue
		node.scale = Vector2(k, k)
		node.pivot_offset = node.size / 2.0
		node.position = Vector2(float(spots[i]), PLACE_Y) - node.size / 2.0
		(p["parts"]["lit"] as CanvasItem).visible = i < stock
		(p["parts"]["dim"] as CanvasItem).visible = i >= stock


## Where each of `cap` places stands: the painting's own for three, else evenly
## spread over the stock panel's inside around the painting's middle place.
static func cart_places(cap: int) -> Array:
	if cap == PLACES.size():
		return PLACES.duplicate()
	var out: Array = []
	var pitch := spot_pitch(cap)
	var mid := float(PLACES[PLACES.size() / 2])
	for i in cap:
		out.append(mid + (i - (cap - 1) / 2.0) * pitch)
	return out


## The distance between two places for a yard of `cap`: the painting's, or less
## when that many would run out of the panel.
static func spot_pitch(cap: int) -> float:
	if cap <= 1:
		return PITCH
	# The outer places' centres stay half a painted cart inside the panel.
	var room := (PANEL_X.y - PANEL_X.x) - PITCH
	return minf(PITCH, room / float(cap - 1))


func _set_line(l: Label, words: String, size: int, least: int) -> void:
	if l.text == words:
		return
	l.text = words
	UI.fit_line(l, size, least)


# --- what each part says ----------------------------------------------------------
# Pure, from the cart as the server described it, so a test reads every case.

## Whether OPEN can open a cart now: "ok", "locked" (below the level the cart
## comes to) or "empty" (nothing waits and no writ is held).
static func open_state(cart: Dictionary) -> String:
	if cart.is_empty():
		return "empty"
	if not bool(cart.get("unlocked", true)):
		return "locked"
	if cart.has("can_open"):
		return "ok" if bool(cart["can_open"]) else "empty"
	return "ok" if int(cart.get("stock", 0)) + int(cart.get("tokens", 0)) > 0 else "empty"


## How long until the next cart comes, counted down `age` seconds from the
## answer; 0 when the yard is full, and the clock waits for a place.
static func left_until_next(cart: Dictionary, age: int) -> int:
	if int(cart.get("stock", 0)) >= int(cart.get("cap", 3)):
		return 0
	return maxi(0, int(cart.get("next_in", 0)) - age)


## The header's line: how often the cart comes, from the server's interval.
static func subtitle_for(interval: int) -> String:
	if interval <= 0:
		return "The crown's cart returns to the gate."
	return "The crown's cart returns %s." % every(interval)


## "every four hours", "every hour", "every 90 minutes", "every 3h 30m".
static func every(seconds: int) -> String:
	if seconds % 3600 == 0:
		var h := seconds / 3600
		if h == 1:
			return "every hour"
		if h < NUMBER_WORDS.size():
			return "every %s hours" % NUMBER_WORDS[h]
		return "every %d hours" % h
	if seconds < 3600 and seconds % 60 == 0:
		return "every %d minutes" % (seconds / 60)
	return "every " + UI.time_left(seconds)


## The hourglass's plate: the time to the next cart, "Full" while the yard is,
## the level the cart comes at below it.
static func timer_words(cart: Dictionary, age: int) -> String:
	if cart.is_empty():
		return ""
	if not bool(cart.get("unlocked", true)):
		return "Level %d" % int(cart.get("unlock_level", 2))
	if int(cart.get("stock", 0)) >= int(cart.get("cap", 3)):
		return "Full"
	return UI.time_left(left_until_next(cart, age))


## The first card, a loaded cart in the yard: what waits to be opened.
static func waiting_words(cart: Dictionary) -> String:
	if cart.is_empty():
		return ""
	var stock := int(cart.get("stock", 0))
	var writs := int(cart.get("tokens", 0))
	if stock > 0 and writs > 0:
		return "%d waiting · %d writ%s" % [stock, writs, "" if writs == 1 else "s"]
	if stock > 0:
		return "%d cart%s waiting" % [stock, "" if stock == 1 else "s"]
	if writs > 0:
		return "%d writ%s held" % [writs, "" if writs == 1 else "s"]
	return "None waiting"


## The second card, the cart on the road: when the next one comes.
static func road_words(cart: Dictionary, age: int) -> String:
	if cart.is_empty():
		return ""
	if not bool(cart.get("unlocked", true)):
		return "Opens at level %d" % int(cart.get("unlock_level", 2))
	if int(cart.get("stock", 0)) >= int(cart.get("cap", 3)):
		return "The yard is full"
	return "Next in " + UI.time_left(left_until_next(cart, age))


## The third card, a chest opened: how many this lord has opened.
static func opened_words(cart: Dictionary) -> String:
	if cart.is_empty() or not cart.has("opened"):
		return ""
	var n := int(cart.get("opened", 0))
	if n <= 0:
		return "None opened yet"
	return "%s opened" % UI.grouped(n)


## A prize's reward lines as the page and the opening show them: gold and
## experience in the prize's own painting (PRIZE_ART), gear not yet rolled in
## the gear chest. The words and amounts are the server's, untouched.
static func dressed_lines(prize: String, lines: Array) -> Array:
	var art := str(PRIZE_ART.get(prize, ""))
	var out: Array = []
	for l in lines:
		if not (l is Dictionary):
			continue
		var c: Dictionary = (l as Dictionary).duplicate()
		var kind := str(c.get("kind", ""))
		if art != "" and (kind == "gold" or kind == "xp" or (kind == "item" and str(c.get("icon", "")).begins_with("item:"))):
			c["icon"] = art
		out.append(c)
	return out


## Why OPEN cannot open a cart, in the page's words.
static func refusal(cart: Dictionary, age: int) -> Dictionary:
	match open_state(cart):
		"locked":
			return {"title": "The Tax Cart", "body": "The crown's cart comes to lords of level %d and above. Work the realm's tasks to reach it." % int(cart.get("unlock_level", 2))}
		"empty":
			var left := left_until_next(cart, age)
			var when := "The next arrives in %s." % UI.time_left(left) if left > 0 else "The next is on the road."
			return {"title": "No cart in the yard", "body": "Every cart has been opened. %s" % when}
	return {}


# --- opening -------------------------------------------------------------------------

func _open() -> void:
	if _busy:
		return
	var why := refusal(_cart, _age())
	if not why.is_empty():
		await Dialog.ask(self, {"title": why["title"], "body": why["body"], "confirm_text": "OK"})
		return
	_busy = true
	_paint()
	var res: Api.Response = await Api.post_json("/v1/cart/open", {})
	if res.ok:
		if res.data.get("snapshot", null) is Dictionary:
			GameState.adopt_async(res.data["snapshot"])
		var after: Variant = res.data.get("cart", null)
		if after is Dictionary:
			paint(after)
			_set_badge(after)
		# Over the shell, so going back to the COURT does not take the moment
		# with the page.
		var shell := get_tree().get_first_node_in_group("shell")
		var shown: Dictionary = res.data.duplicate()
		shown["lines"] = dressed_lines(str(res.data.get("prize", "")), res.data.get("lines", []))
		Ceremony.cart(shell if shell != null else self, shown)
	elif res.code == "inventory_full":
		# Nothing was spent: the cart waits until there is room for what it holds.
		await Armory.refused(self, res.error, Armory.sentence(res.error)
			+ " The cart waits; sell or wear something, then open it.")
	elif res.code == "cart_empty" or res.code == "locked":
		var why_now := refusal({"unlocked": res.code != "locked", "stock": 0, "tokens": 0,
			"cap": _cart.get("cap", 3), "next_in": 0, "unlock_level": _cart.get("unlock_level", 2)}, 0)
		await Dialog.ask(self, {"title": why_now.get("title", "The Tax Cart"),
			"body": res.error if res.error != "" else why_now.get("body", ""), "confirm_text": "OK"})
	else:
		GameState.action_failed.emit(res.error)
	if not res.ok and is_inside_tree():
		await _load()
	_busy = false
	_paint()


## The cart's disc on the COURT and the rail, set now rather than at the next
## heartbeat: what waits after this one was opened.
static func _set_badge(cart: Dictionary) -> void:
	var b := GameState.badges.duplicate()
	b["cart"] = int(cart.get("stock", 0)) + int(cart.get("tokens", 0))
	GameState.set_badges(b)


## The (i): what a cart may carry, and how often.
func _odds() -> void:
	load("res://scenes/pages/cart_odds_page.gd").call("open", self, _cart)
