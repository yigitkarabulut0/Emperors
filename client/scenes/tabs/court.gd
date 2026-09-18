extends Control
## ROYAL COURT: the treasures, tidings and favours of the crown, as court.png
## paints them. Six cards, each the painting's own with its title baked; what
## each holds now is written on its plate, and what waits for the lord is
## counted in its red disc -- the same count the rail's COURT bubble adds up
## (Shell.court_count).
##
##   STORE        the Royal Store; its free thing, else a live offer's time
##   ROYAL MAIL   the letters; how many wait
##   OFFERS       ROYAL OFFERS; the soonest offer's time left
##   EVENTS       the realm's events (EventsPanel); the running one, or the next
##   CHESTS       the Tax Cart (ChestsView); the carts waiting, or the next one's time
##   SEASON PASS is painted and not yet open: dimmed, "Opens soon".
##
## The Court views open over this tab and close back to it, and their back
## plate says COURT (CourtBack). Offers and the free thing come from
## /v1/store/court, asked each time the tab is opened; events from
## snapshot.live through LiveEvents; the cart from snapshot.cart
## (GameState.cart()); counts from the heartbeat's badges.

const SCREEN := "court"
const CARDS := ["store", "pass", "events", "mail", "chests", "offers"]
## Painted, and not yet open.
const SOON: Array = []
const SOON_WORDS := "Opens soon"
## A card that is not open yet, drawn down as the Store draws a plate it
## cannot sell (StorePrice.DIMMED).
const DIMMED := Color(0.55, 0.55, 0.55)
## Each card's live line and count in the layout (court.json), by card.
const STATUS := {"store": "status_store", "pass": "status_pass", "events": "status_events",
	"mail": "status_mail", "chests": "status_chests", "offers": "status_offers"}
const COUNT := {"store": "count_store", "pass": "count_pass", "events": "count_events",
	"mail": "count_mail", "chests": "count_chests", "offers": "count_offers"}
const STATUS_SIZE := 26
const STATUS_MIN := 17
const COUNT_SIZE := 26

var _ui: Dictionary = {}
var _court: Dictionary = {}     ## the last /v1/store/court answer
var _court_at_ms := 0           ## when it came
var _loading := false


func _ready() -> void:
	_ui = Layout.build(SCREEN, self)
	for id in CARDS:
		var hit: BaseButton = _ui["hit_" + id]
		if id in SOON:
			(_ui["card_" + id] as CanvasItem).modulate = DIMMED
			hit.disabled = true
		else:
			hit.pressed.connect(_tap.bind(id))
	GuideTargets.register("court.chests", _ui["hit_chests"])
	GameState.badges_changed.connect(_paint)
	GameState.changed.connect(_paint)
	var tick := Timer.new()
	tick.wait_time = 1.0
	tick.timeout.connect(_paint)
	add_child(tick)
	tick.start()
	_paint()


## The shell calls this when the tab is opened.
func refresh() -> void:
	_paint()
	if _loading:
		return
	_loading = true
	var res: Api.Response = await Api.get_json("/v1/store/court")
	_loading = false
	if not is_inside_tree():
		return
	if res.ok and res.data is Dictionary:
		paint_court(res.data)


## Paints with a /v1/store/court answer. Public for tests and captures.
func paint_court(court: Dictionary) -> void:
	_court = court
	_court_at_ms = Time.get_ticks_msec()
	_paint()


func _paint() -> void:
	if _ui.is_empty():
		return
	var age := (Time.get_ticks_msec() - _court_at_ms) / 1000
	for id in CARDS:
		var status: Label = _ui[STATUS[id]]
		var words := status_for(id, GameState.badges, GameState.live(), GameState.live_age_s(), _court, age,
			GameState.cart())
		if status.text != words:
			status.text = words
			status.label_settings.font_color = UI.DIM if id in SOON or words.begins_with("No ") \
				or words.begins_with("Opens ") else UI.INK
			UI.fit_line(status, STATUS_SIZE, STATUS_MIN)
		var n := count_for(id, GameState.badges)
		(_ui["badge_" + id] as CanvasItem).visible = n > 0
		var count: Label = _ui[COUNT[id]]
		count.visible = n > 0
		count.text = str(n) if n < 10 else "9+"


## What a card's plate says. `live_age` and `court_age` are the seconds since
## snapshot.live and the store's answer were given: their times count down
## from then. `cart` is the snapshot's cart, as old as `live_age`.
static func status_for(id: String, badges: Dictionary, live: Dictionary, live_age: int,
		court: Dictionary, court_age: int, cart: Dictionary = {}) -> String:
	match id:
		"pass":
			return pass_line(live)
		"chests":
			return cart_line(cart, live_age)
		"mail":
			var n := int(badges.get("mail", 0))
			if n <= 0:
				return "No letters"
			return "%d letter%s waiting" % [n, "" if n == 1 else "s"]
		"offers":
			var o := _soonest_offer(court)
			if o.is_empty():
				return "No offer now"
			return "Ends in " + UI.time_left(maxi(0, int(o.get("ends_in", 0)) - court_age))
		"store":
			if bool(badges.get("store_free", false)):
				return free_line(court)
			var o := _soonest_offer(court)
			if not o.is_empty():
				return "An offer ends in " + UI.time_left(maxi(0, int(o.get("ends_in", 0)) - court_age))
			return ""
		"events":
			return events_line(live, live_age)
	return ""


## Which free thing waits in the Store, in the order the Store shows them: the
## Stipend's share, Royal Favour's gift, the day's free deal. Read from the
## Store's own answer; "A free gift waits" only when it has not come yet.
static func free_line(court: Dictionary) -> String:
	var st: Variant = court.get("stipend", {})
	if st is Dictionary and bool(st.get("active", false)) and bool(st.get("claimable_today", false)):
		return "Today's stipend waits"
	var vip: Variant = court.get("vip", {})
	if vip is Dictionary and bool(vip.get("gift_claimable", false)):
		return "Royal Favour's gift waits"
	var deals: Variant = court.get("deals", {})
	if deals is Dictionary:
		for d in deals.get("slots", []):
			if d is Dictionary and int(d.get("slot", -1)) == 0 and not bool(d.get("claimed", true)):
				return "Today's free gift waits"
	return "A free gift waits"


## The CHESTS card's line, from the snapshot's cart `age` seconds on: the carts
## waiting (a writ is one more cart to open), else when the next comes, else
## the level it comes at. Nothing from a server that sends no cart.
static func cart_line(cart: Dictionary, age: int) -> String:
	if cart.is_empty():
		return ""
	if not bool(cart.get("unlocked", true)):
		return "Opens at level %d" % int(cart.get("unlock_level", 2))
	var n := int(cart.get("stock", 0)) + int(cart.get("tokens", 0))
	if n > 0:
		return "%d cart%s waiting" % [n, "" if n == 1 else "s"]
	return "Next cart in " + UI.time_left(maxi(0, int(cart.get("next_in", 0)) - age))


## The EVENTS card's plate, in the order a lord would notice them: the festival
## running, else the hour's event, else an operator's event, else whichever is
## announced soonest. All from the snapshot, so the card says something before
## the Events page has been opened once.
static func events_line(live: Dictionary, live_age: int) -> String:
	var fest := LiveEvents.festival_running(live, live_age)
	if not fest.is_empty():
		return "%s · %s" % [str(fest.get("name", "")), UI.time_left(LiveEvents.left(fest, live_age))]
	var hour := LiveEvents.hourly_running(live, live_age)
	if not hour.is_empty():
		return "%s · %s" % [str(hour.get("name", "")), UI.time_left(LiveEvents.left(hour, live_age))]
	var now_on := LiveEvents.soonest(live)
	if not now_on.is_empty():
		return "%s %s · %s" % [LiveEvents.name(str(now_on.get("bucket", ""))),
			LiveEvents.percent(int(now_on.get("bp", 0))), UI.time_left(LiveEvents.left(now_on, live_age))]
	var coming := LiveEvents.festival_coming(live, live_age)
	if not coming.is_empty():
		return "%s in %s" % [str(coming.get("name", "")), UI.time_left(LiveEvents.left(coming, live_age, "starts_in"))]
	var next: Array = LiveEvents.upcoming(live)
	if not next.is_empty():
		return "Starts in " + UI.time_left(LiveEvents.left(next[0], live_age, "starts_in"))
	var soon := LiveEvents.hourly_next(live)
	if not soon.is_empty():
		return "%s in %s" % [str(soon.get("name", "")), UI.time_left(LiveEvents.hourly_next_in(live, live_age))]
	return "No event now"


## The SEASON PASS card's plate: the tier the lord's Charter stands at and how
## long the season has left, from the snapshot alone (live.season). Before the
## first season, nothing.
static func pass_line(live: Dictionary) -> String:
	var season: Dictionary = live.get("season", {}) if live.get("season") is Dictionary else {}
	if int(season.get("number", 0)) < 1:
		return ""
	var out := "Tier %d of %d" % [int(season.get("tier", 0)), int(season.get("tiers", 0))]
	var left := int(season.get("ends_in", 0))
	if left > 0:
		out += "  ·  " + UI.time_left(left) + " left"
	return out


## What a card's red disc counts: the letters, the offers not yet seen, the
## Store's free thing, the carts waiting, the Charter's tiers and the
## festival's tasks and milestones. Together they are the rail's COURT bubble.
static func count_for(id: String, badges: Dictionary) -> int:
	match id:
		"mail":
			return int(badges.get("mail", 0))
		"offers":
			return int(badges.get("offers_unseen", 0))
		"store":
			return 1 if bool(badges.get("store_free", false)) else 0
		"chests":
			return int(badges.get("cart", 0))
		"pass":
			return int(badges.get("season", 0))
		"events":
			return int(badges.get("events", 0)) + (1 if bool(badges.get("hourly", false)) else 0)
	return 0


static func _soonest_offer(court: Dictionary) -> Dictionary:
	var store_view: GDScript = load("res://scenes/court/store_view.gd")
	var offers: Array = store_view.call("live_offers", court.get("products", []))
	return offers[0] if not offers.is_empty() else {}


func _tap(id: String) -> void:
	var shell := get_tree().get_first_node_in_group("shell")
	match id:
		"store", "mail", "chests", "pass":
			if shell != null:
				shell.call("open_view", id)
		"offers":
			# ROYAL OFFERS, the owner's own painting of them
			# (scenes/court/offers_view.gd). It was the Royal Store scrolled to
			# its offers section until the painting was cut.
			if shell != null:
				shell.call("open_view", "offers")
		"events":
			open_events()


## The realm's events over the COURT: the EVENTS card, and the rail's seal.
func open_events() -> Control:
	var shell := get_tree().get_first_node_in_group("shell")
	if shell == null:
		return null
	var v: Variant = shell.call("open_view", "events")
	return v if v is Control else null
