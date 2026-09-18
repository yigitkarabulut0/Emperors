extends CanvasLayer
## The offer popup, cut from art/reference/offers_popup.png (art/slices/
## offers_popup.json, layout client/layout/offer_popup.json).
##
## An offer is a product the server fires once, when its moment comes -- a
## level reached, the day's refills gone, a raid suffered -- and sells for a
## few hours. It is on the Royal Store's first shelf for as long as it lasts;
## this is the one time it comes to the player instead: once a session, at a
## calm moment (never in the first twenty seconds, never over an action, a
## battle, a ceremony, a dialog or a page), and never twice for the same offer
## -- showing it marks every live offer seen (POST /v1/store/offers/seen), which
## clears the badge that asked for it.
##
## Everything on it is the server's except the price, which is the App Store's
## (Billing.price). Its green button buys through Billing; LATER and the close
## button put it away. The Royal Delivery is played by the shell, which hears
## every delivery.

signal closed

const SCREEN := "offer_popup"
## The three tiles' parts, by position.
const ICONS := ["icon_1", "icon_2", "icon_3"]
const WORDS := ["words_1", "words_2", "words_3"]
const LAYER := 80
## Not in the first moments of a session: the game is still arriving.
const QUIET_START_MS := 20000

static var _shown_this_session := false
static var _asking := false

var _ui: Dictionary = {}
var _offer: Dictionary = {}
var _host: Node = null
var _ends_at := 0                  ## ticks when the offer runs out
var _answered := false             ## the App Store has answered since the popup asked
var _framed: Array = []            ## the frame-and-face pictures drawn in the tiles
var _root: Control
var _clock: Timer


## Shows an offer if one waits and the moment is calm; otherwise does nothing,
## and the next heartbeat asks again. `host` is the shell. `force` (the dev
## page) skips the session's once and the calm checks.
static func maybe_show(host: Node, force: bool = false) -> void:
	if _asking or (_shown_this_session and not force):
		return
	if not force and not calm(host):
		return
	_asking = true
	var res: Api.Response = await Api.get_json("/v1/store/court")
	_asking = false
	if not res.ok or not is_instance_valid(host) or not host.is_inside_tree():
		return
	var offer := pick(res.data.get("products", []))
	if offer.is_empty() or (not force and not calm(host)):
		return
	_shown_this_session = true
	var popup: CanvasLayer = (load("res://scenes/court/offer_popup.gd") as GDScript).new()
	popup.call("setup", offer, host)
	Nav.overlay_parent().add_child(popup)
	Api.post_json("/v1/store/offers/seen", {})


## Which offer to show: the one that ends soonest, so the one about to be lost
## is the one seen. {} when none is live.
static func pick(products: Array) -> Dictionary:
	var best: Dictionary = {}
	for p in products:
		if str(p.get("shelf", "")) != "offers" or int(p.get("ends_in", 0)) <= 0:
			continue
		if not bool(p.get("available", true)):
			continue
		if best.is_empty() or int(p.get("ends_in", 0)) < int(best.get("ends_in", 0)):
			best = p
	return best


## A calm moment: the session has settled, nothing the player did is still
## on its way, no Court view is open (the store shows its offers itself), and
## nothing stands over the game -- no page, dialog, battle or ceremony.
static func calm(host: Node) -> bool:
	if Time.get_ticks_msec() < QUIET_START_MS:
		return false
	if GameState.pending_count() > 0:
		return false
	if host != null and host.get("_view") != null:
		return false
	for c in Nav.overlay_parent().get_children():
		if c is CanvasLayer and (c as CanvasLayer).visible and (c as CanvasLayer).layer >= 40:
			return false
	return true


func setup(offer: Dictionary, host: Node = null) -> void:
	_offer = offer
	_host = host
	_ends_at = Time.get_ticks_msec() + int(offer.get("ends_in", 0)) * 1000


func _ready() -> void:
	layer = LAYER
	var back := ColorRect.new()
	back.color = Color(0, 0, 0, 0.74)
	back.set_anchors_preset(Control.PRESET_FULL_RECT)
	back.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(back)
	# The canvas the game is laid out on (the shell's), as Dialog measures it.
	var canvas := UI.canvas_size(_host) if _host != null else Vector2(941, 1672)
	if Nav.host != null:
		canvas = Vector2(Nav.host.size)
	_root = Control.new()
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.size = Vector2(941, 1672)
	# The painting's own place on the design canvas; a taller phone gets the
	# popup in the middle of its extra height.
	_root.position = Vector2(0, maxf(0.0, (canvas.y - 1672.0) / 2.0))
	add_child(_root)
	_ui = Layout.build(SCREEN, _root)
	paint(_offer)
	(_ui["buy"] as BaseButton).pressed.connect(_buy)
	(_ui["later"] as BaseButton).pressed.connect(close)
	(_ui["close"] as BaseButton).pressed.connect(close)
	Billing.products_changed.connect(func() -> void:
		_answered = true
		_paint_price())
	Billing.busy_changed.connect(func(_b: bool) -> void: _paint_price())
	Billing.delivered.connect(_on_delivered)
	# The store view says these while it is open; the popup only opens when it
	# is not, so each is said once.
	Billing.pending.connect(func(_id: String) -> void:
		GameState.toast("Waiting for approval. Your purchase will arrive by itself once it is given."))
	Billing.failed.connect(func(_id: String, message: String) -> void:
		if message != "":
			GameState.toast(message))
	Billing.load_products(PackedStringArray([str(_offer.get("store_id", ""))]))
	_clock = Timer.new()
	_clock.wait_time = 1.0
	_clock.timeout.connect(_count_down)
	add_child(_clock)
	_clock.start()
	_count_down()
	Api.track("screen", {"name": "court:offer"})


## Paints an offer (a CourtStore product). Public for tests and captures.
func paint(offer: Dictionary) -> void:
	_offer = offer
	var title: Label = _ui["title"]
	title.text = str(offer.get("title", ""))
	UI.fit_line(title, title.label_settings.font_size, 24)
	var lines: Array = offer.get("lines", [])
	for n in _framed:
		n.queue_free()
	_framed.clear()
	for i in 3:
		var icon: TextureRect = _ui[ICONS[i]]
		var words: Label = _ui[WORDS[i]]
		icon.visible = i < lines.size()
		words.visible = icon.visible
		if not icon.visible:
			continue
		words.text = str(lines[i].get("text", ""))
		UI.fit_wrapped(words, words.label_settings.font_size, 15)
		# Drawn large, as the Royal Delivery draws it when it arrives.
		var framed := RewardArt.dress(icon, lines[i], str(GameState.player().get("avatar", "")))
		if framed != null:
			_framed.append(framed)
	_paint_price()


func _paint_price() -> void:
	if _ui.is_empty():
		return
	var sid := str(_offer.get("store_id", ""))
	var app := Billing.price(sid)
	var price: Label = _ui["price"]
	var live := Billing.available and app != "" and not Billing.busy
	StorePrice.paint(_ui["buy"], price, StorePrice.words(_offer, Billing.available, app, _answered), live)
	UI.fit_line(price, 46, 20)


func _count_down() -> void:
	var left := maxi(0, (_ends_at - Time.get_ticks_msec()) / 1000)
	var t: Label = _ui["timer"]
	t.text = UI.time_left(left)
	t.label_settings.font_color = UI.RED if left < 3600 else UI.INK
	UI.fit_line(t, 30, 18)
	if left == 0:
		close()


func _buy() -> void:
	if not Billing.available:
		GameState.toast(Billing.unavailable_reason())
		return
	if Billing.busy:
		return
	Billing.buy(str(_offer.get("store_id", "")))


## The offer arrived: the shell plays the Royal Delivery; this steps aside.
func _on_delivered(d: Dictionary) -> void:
	if str(d.get("product", "")) == str(_offer.get("id", "")):
		close()


func close() -> void:
	if is_queued_for_deletion():
		return
	closed.emit()
	queue_free()
