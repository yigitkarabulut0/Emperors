extends CanvasLayer
## The hour's event, as it begins: the event's own disc (hourly/<id>) set in
## the kit's blazing gauge (events_kit/gauge_blazing: its twelve cells lit and
## its rim afire -- the hour, burning), its name, what it does, what it is
## worth to this lord, its time left, and a way to it. All of it cut from
## art/reference/events_kit.png (art/slices/events_kit.json) and the game's
## dialog plates; every figure is the server's (snapshot.live.hourly).
##
## It comes to the lord once an hour, when an hour's event begins while they
## are in the game (not one already running when they arrived), at a calm
## moment -- the offer popup's (offer_popup.calm): the session settled, nothing
## on its way, no Court view, page, dialog, battle or ceremony over the game --
## and never during the steward's guide. `--page hourly` shows it for a capture.
##
## The courier's gift is taken from here (CLAIM) as from the Collect band's:
## claim() is the one way, and the Royal Delivery says what it brought.

signal closed

const LAYER := 80
## The emblem: the gauge drawn at 0.9 (286x324 of its 318x360), its hourglass
## -- the crop's (159, 180) -- at the card's centre line, 50 under the plate's
## top edge, so the burning hour stands out of the card; the disc set in its
## well, rim 70 across the radius (the disc's 137 in its 290 square).
const GAUGE := "events_kit/gauge_blazing"
const GAUGE_SCALE := 0.9
const GAUGE_CENTRE := Vector2(159, 180)
const EMBLEM_DOWN := 50.0
const DISC_RIM := 70.0
const DISC_RIM_PAINTED := 137.3
const DISC_SIZE := 290.0
## The card: the dialogs' plate (inventory/card_frame), 660 wide, its content
## 600 across inside its 30 of margin.
const WIDTH := 660.0
const INNER := 600.0
const HEIGHT := 640.0
## What stands on it, top to bottom, from the plate's top edge.
const KICKER_Y := 226.0
const TITLE_Y := 254.0
const BLURB_Y := 322.0
const WORTH_Y := 410.0
const TIME_Y := 456.0
const BUTTONS_Y := 510.0
const BUTTON_H := 96.0
const KICKER_INK := Color("#9DB3C9")
const BUTTON_INK := Color("#F3FBF3")
const QUIET_INK := Color("#E9E2D2")

static var _asking := false

var _hourly: Dictionary = {}
var _host: Node = null
var _ends_at := 0
var _time: Label
var _clock: Timer
var _root: Control
var _primary: Button


## Shows the hour's event if one began since the lord arrived and has not been
## shown this hour, at a calm moment; otherwise does nothing, and the shell's
## next second asks again. `force` (the dev page) shows the hour's event --
## or, in a quiet hour, the next one's -- whatever the moment.
static func maybe_show(host: Node, force: bool = false) -> bool:
	if _asking or host == null or not host.is_inside_tree():
		return false
	var live := GameState.live()
	var age := GameState.live_age_s()
	var h := LiveEvents.hourly_running(live, age)
	if force and h.is_empty():
		h = (live.get("hourly", {}) as Dictionary) if live.get("hourly") is Dictionary else {}
	if h.is_empty() or str(h.get("id", "")) == "":
		return false
	if not force:
		var hour := LiveEvents.hour_index(live, age, int(Time.get_unix_time_from_system()))
		if not due(hour, int(host.get_meta("hourly_arrived", -1)), int(Prefs.get_value("hourly_shown", -1))):
			return false
		if Guide.active() or not load("res://scenes/court/offer_popup.gd").calm(host):
			return false
		Prefs.set_value("hourly_shown", hour)
	_asking = true
	var popup: CanvasLayer = (load("res://scenes/court/hourly_popup.gd") as GDScript).new()
	popup.call("setup", h, host, age)
	Nav.overlay_parent().add_child(popup)
	_asking = false
	Api.track("screen", {"name": "popup:hourly"})
	return true


## Whether an hour's event is due its popup: an hour after the one the lord
## arrived in (an event already running when they came is not "beginning"),
## and not the hour last shown. Pure.
static func due(hour: int, arrived_hour: int, shown_hour: int) -> bool:
	return arrived_hour >= 0 and hour > arrived_hour and hour != shown_hour


## Takes the courier's gift (POST /v1/hourly/claim, asynchronous like a
## letter: its snapshot is adopted with adopt_async) and plays the Royal
## Delivery of what it brought. True when it was taken.
static func claim(host: Node) -> bool:
	var res: Api.Response = await Api.post_json("/v1/hourly/claim", {})
	if res.ok:
		if res.data.get("snapshot", null) is Dictionary:
			GameState.adopt_async(res.data["snapshot"])
		var g: Variant = res.data.get("granted", {})
		var lines: Array = (g as Dictionary).get("lines", []) if g is Dictionary else []
		var shell: Node = host.get_tree().get_first_node_in_group("shell") if host != null and host.is_inside_tree() else null
		load("res://scenes/pages/ceremony.gd").delivery(shell if shell != null else host,
			{"title": "ROYAL COURIER", "lines": lines})
		return true
	match res.code:
		"already_claimed":
			GameState.toast("You have already taken this hour's gift")
			GameState.refresh()
		"hourly_over":
			GameState.toast("The courier has left the realm")
			GameState.refresh()
		_:
			GameState.action_failed.emit(res.error)
	return false


## The way from the popup to where the hour matters: [word, where]. Where is a
## tab to open, "energy" (the energy pill's refill) or "claim" (the gift).
static func action(h: Dictionary) -> Array:
	match str(h.get("kind", "")):
		"gift":
			return ["CLAIM", "claim"] if LiveEvents.gift_waiting(h) else ["SPLENDID", ""]
		"refill_discount":
			return ["REFILL", "energy"]
		"free_reroll":
			return ["TO THE MARKET", "shop"]
		"boost":
			return ["TO THE MARKET", "shop"] if str(h.get("bucket", "")) == "luck_bp" else ["TO WORK", "collect"]
	return ["TO WORK", "collect"]


func setup(h: Dictionary, host: Node, age_s: int = 0) -> void:
	_hourly = h
	_host = host
	var key := "ends_in" if bool(h.get("active", false)) else "next_in"
	_ends_at = Time.get_ticks_msec() + LiveEvents.left(h, age_s, key) * 1000


func _ready() -> void:
	layer = LAYER
	var back := ColorRect.new()
	back.color = Color(0, 0, 0, 0.74)
	back.set_anchors_preset(Control.PRESET_FULL_RECT)
	back.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(back)
	var canvas := Vector2(941, 1672)
	if Nav.host != null:
		canvas = Vector2(Nav.host.size)
	_root = Control.new()
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.size = canvas
	add_child(_root)
	_build(canvas)
	_clock = Timer.new()
	_clock.wait_time = 1.0
	_clock.timeout.connect(_count_down)
	add_child(_clock)
	_clock.start()


## The card, centred on the canvas: the emblem standing out of its top.
func _build(canvas: Vector2) -> void:
	var h := _hourly
	var gauge_tex: Texture2D = Art.tex(GAUGE)
	var gauge_size := gauge_tex.get_size() * GAUGE_SCALE
	var above := GAUGE_CENTRE.y * GAUGE_SCALE - EMBLEM_DOWN
	var top := roundf((canvas.y - (HEIGHT + above)) / 2.0 + above)
	var left := roundf((canvas.x - WIDTH) / 2.0)
	var plate := NinePatchRect.new()
	plate.texture = Art.tex(Dialog.PLATE)
	for m in ["left", "top", "right", "bottom"]:
		plate.set("patch_margin_" + m, Dialog.PLATE_MARGIN)
	UI.place(plate, Rect2(left, top, WIDTH, HEIGHT))
	plate.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(plate)

	var centre := Vector2(left + WIDTH / 2.0, top + EMBLEM_DOWN)
	var gauge := UI.image(GAUGE, Rect2((centre - GAUGE_CENTRE * GAUGE_SCALE).round(), gauge_size.round()))
	gauge.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	gauge.name = "gauge"
	_root.add_child(gauge)
	var disc_w := roundf(DISC_SIZE * DISC_RIM / DISC_RIM_PAINTED)
	var disc := UI.image(str(h.get("icon", "")), Rect2((centre - Vector2(disc_w, disc_w) / 2.0).round(), Vector2(disc_w, disc_w)))
	disc.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	disc.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	disc.name = "disc"
	_root.add_child(disc)
	_breathe(gauge)

	var x := left + (WIDTH - INNER) / 2.0
	var running := bool(h.get("active", false))
	var kicker := UI.label("THE HOUR BEGINS" if running else "THE NEXT HOUR", 20, KICKER_INK, "title", 600,
		HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(kicker, Rect2(x, top + KICKER_Y, INNER, 26))
	kicker.name = "kicker"
	_root.add_child(kicker)
	var title := UI.label(str(h.get("name", "")).to_upper(), 44, UI.GOLD, "title", 700, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(title, Rect2(x, top + TITLE_Y, INNER, 60))
	UI.fit_line(title, 44, 30)
	title.name = "title"
	_root.add_child(title)
	var blurb := UI.label(str(h.get("blurb", "")), 28, UI.INK, "body", 500, HORIZONTAL_ALIGNMENT_CENTER)
	blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	blurb.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	UI.place(blurb, Rect2(x, top + BLURB_Y, INNER, 80))
	blurb.name = "blurb"
	_root.add_child(blurb)
	var worth := UI.label(LiveEvents.hourly_worth(h) if running else "", 30, UI.GOLD, "body", 700,
		HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(worth, Rect2(x, top + WORTH_Y, INNER, 40))
	worth.name = "worth"
	_root.add_child(worth)
	# The time, beside events.png's hourglass, the pair centred.
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 10)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UI.place(row, Rect2(x, top + TIME_Y, INNER, 40))
	_root.add_child(row)
	var glass := TextureRect.new()
	glass.texture = Art.tex("court/event_hourglass")
	glass.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	glass.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	glass.custom_minimum_size = Vector2(28, 40)
	row.add_child(glass)
	_time = UI.label("", 27, UI.INK, "body", 600)
	_time.name = "time"
	row.add_child(_time)
	_count_down()

	var act := action(h)
	var primary_w := 300.0
	var quiet_w := 220.0
	var gap := 24.0
	var bx := left + (WIDTH - primary_w - gap - quiet_w) / 2.0
	_primary = UI.plate_button(Dialog.CONFIRM_PLATE, str(act[0]), Rect2(bx, top + BUTTONS_Y, primary_w, BUTTON_H),
		30, BUTTON_INK, 700, Dialog.PLATE_EDGE)
	_primary.name = "primary"
	_primary.pressed.connect(_go.bind(str(act[1])))
	_root.add_child(_primary)
	var later := UI.plate_button(Dialog.QUIET_PLATE, "LATER", Rect2(bx + primary_w + gap, top + BUTTONS_Y, quiet_w, BUTTON_H),
		30, QUIET_INK, 700, Dialog.PLATE_EDGE)
	later.name = "later"
	later.pressed.connect(close)
	_root.add_child(later)


## The burning hour breathes, gently, about its own middle.
func _breathe(gauge: Control) -> void:
	if Env.args.has("capture"):
		return
	gauge.pivot_offset = GAUGE_CENTRE * GAUGE_SCALE
	var t := gauge.create_tween().set_loops()
	t.tween_property(gauge, "scale", Vector2(1.035, 1.035), 1.4).set_trans(Tween.TRANS_SINE)
	t.tween_property(gauge, "scale", Vector2.ONE, 1.4).set_trans(Tween.TRANS_SINE)


func _count_down() -> void:
	if _time == null:
		return
	# Whole seconds, rounded up: a moment into a second is still that second.
	var left := maxi(0, ceili(float(_ends_at - Time.get_ticks_msec()) / 1000.0))
	var running := bool(_hourly.get("active", false))
	_time.text = (UI.time_left(left) + " left") if running else ("begins in " + UI.time_left(left))
	if running and left <= 0:
		close()


func _go(where: String) -> void:
	match where:
		"claim":
			_primary.disabled = true
			if await claim(self):
				close()
			else:
				_primary.disabled = false
			return
		"energy":
			close()
			# The energy pill's "+": the refill at the sale's price, beside any flask.
			if _host != null and is_instance_valid(_host) and _host.has_method("_energy_popup"):
				_host.call("_energy_popup")
			return
		"":
			close()
			return
	close()
	if _host != null and is_instance_valid(_host) and _host.has_method("open"):
		_host.call("open", where)


func close() -> void:
	if _clock != null:
		_clock.stop()
	closed.emit()
	queue_free()
