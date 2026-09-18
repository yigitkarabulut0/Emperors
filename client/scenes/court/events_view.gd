extends Control
## EVENTS -- COURT ▸ EVENTS, cut from art/reference/events.png and the
## festivals' own scenes from event_themes.png (art/slices/events.json, layout
## client/layout/events.json).
##
## The realm's calendar on one page, as the painting lays it out:
##
##  - the hero card: the festival running, else the next one announced, else
##    the last to close (dimmed), in its own scene -- its name, what it gives
##    this lord, its time, and VIEW, which opens the festival's page
##    (scenes/pages/festival_page.gd); the Court's count disc on VIEW while
##    something in it waits to be claimed;
##  - the two cards: the festivals after it and before it -- announced ones
##    first, then the last to close -- each in its scene with its time; a card
##    with no festival for it is drawn dim, "None announced";
##  - ROYAL HOURS: the hour's event (its icon and name), its time left, and the
##    next hour's; a tap opens the published odds of every hour
##    (scenes/pages/hourly_odds_page.gd);
##  - UPCOMING: what else the crown has on or announced -- the operator's
##    server-wide events (what the Wave 2 events panel listed: running ones
##    with the hourglass and the time they end, announced ones with the
##    calendar and when they start) and any festival announced beyond the cards.
##
## Every figure is the server's (GET /v1/festivals, and snapshot.live for the
## operator's events); the times only count down from the answer's moment.

signal back_requested

const SCREEN := "events"
## The festivals' scenes (events/scene_<theme>_hero|left|right): the three the
## owner painted. A theme the client has no scene for is drawn in the first.
const THEMES := ["harvest", "blood_moon", "caravan"]
const CARDS := ["l", "r"]
const CARD_SCENE := {"l": "left", "r": "right"}
## Each card's parts, named in full: a layout part is found by its own name
## here and in the layout, never by one the code spells out of pieces.
const CARD_TITLE := {"l": "card_title_l", "r": "card_title_r"}
const CARD_TIMER := {"l": "card_timer_l", "r": "card_timer_r"}
## A festival that has closed, or a card with no festival for it: dimmed as
## the Court dims what cannot be opened (StorePrice.DIMMED).
const DIMMED := Color(0.55, 0.55, 0.55)
const PAST_TINT := Color(0.78, 0.78, 0.78)
const TITLE_FIT := Vector2i(28, 17)
const CARD_TITLE_FIT := Vector2i(24, 15)
const LINE_FIT := Vector2i(26, 16)
const CARD_LINE_FIT := Vector2i(24, 15)
const HOURS_FIT := Vector2i(24, 15)
const NEXT_FIT := Vector2i(21, 13)
const ROW_WHAT_FIT := Vector2i(22, 14)
const ROW_FIT := Vector2i(23, 14)
const ICON_CAL := "court/event_calendar"
const ICON_GLASS := "court/event_hourglass"
## The hourglass is 44 wide to the calendar's 52: stood on the same centre.
const GLASS_SHIFT := 4.0

var _ui: Dictionary = {}
var _ev: Dictionary = {}          ## the last /v1/festivals answer
var _ev_at_ms := 0                ## when it came: its times count down from here
var _rows: Array = []             ## UPCOMING's three rows as built: [{node, parts}]
var _built := false
var _loading := false
var _asked_again := false         ## a time ran out and the page was asked for again


func _ready() -> void:
	_ui = Layout.build(SCREEN, self)
	# The way back, the same plate and word on every Court view.
	_ui["back_hit"] = CourtBack.build(self)
	(_ui["back_hit"] as BaseButton).pressed.connect(func() -> void: back_requested.emit())
	(_ui["view"] as BaseButton).pressed.connect(_view)
	(_ui["hero_hit"] as BaseButton).pressed.connect(_view)
	(_ui["card_hit_l"] as BaseButton).pressed.connect(_card.bind("l"))
	(_ui["card_hit_r"] as BaseButton).pressed.connect(_card.bind("r"))
	(_ui["hours_hit"] as BaseButton).pressed.connect(_hours)
	_rows = _ui.get("up_row", [])
	for id in ["hours_icon"]:
		(_ui[id] as TextureRect).expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		(_ui[id] as TextureRect).stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	GameState.changed.connect(_paint_rows)
	var tick := Timer.new()
	tick.wait_time = 1.0
	tick.timeout.connect(_tick)
	add_child(tick)
	tick.start()
	_built = true
	# What the snapshot already says, until the page's own answer comes.
	paint(snapshot_events(GameState.live()), GameState.live_age_s())


## The shell calls this when the view opens.
func refresh() -> void:
	if _built:
		_load()


func _load() -> void:
	if _loading:
		# One already in flight: wait for it. Returning here handed whoever
		# awaited this the page as it stood -- the snapshot's word, without a
		# festival's tasks -- and the festival's page would not open on a tap
		# that came while the page was still reading itself.
		while _loading and is_inside_tree():
			await get_tree().process_frame
		return
	_loading = true
	var res: Api.Response = await Api.get_json("/v1/festivals")
	_loading = false
	if not is_inside_tree():
		return
	if not res.ok:
		GameState.action_failed.emit("The realm's calendar could not be read. " + res.error)
		return
	paint(res.data)


## Paints an events answer (GET /v1/festivals) given `age` seconds ago. Public
## for tests, captures and the festival's page, which hands back what a claim
## answered.
func paint(ev: Dictionary, age: int = 0) -> void:
	_ev = ev
	_ev_at_ms = Time.get_ticks_msec() - age * 1000
	_asked_again = false
	_paint()


func _age() -> int:
	return (Time.get_ticks_msec() - _ev_at_ms) / 1000


func _tick() -> void:
	if not _built:
		return
	_paint_times()
	# A festival began or ended, or the hour turned: ask what the calendar
	# says now, once.
	if not _asked_again and not _loading and turned(_ev, _age()):
		_asked_again = true
		_load()


func _paint() -> void:
	if not _built:
		return
	var age := _age()
	var hero := hero_of(_ev)
	_paint_hero(hero)
	var cards := cards_of(_ev, hero)
	for i in CARDS.size():
		_paint_card(CARDS[i], cards[i], _themes_left(hero, cards)[i])
	_paint_hours(age)
	_paint_rows()
	_paint_times()


# --- the hero card -------------------------------------------------------------------

func _paint_hero(hero: Dictionary) -> void:
	var f: Dictionary = hero.get("festival", {})
	var state := str(hero.get("state", "none"))
	var scene: TextureRect = _ui["hero_scene"]
	scene.texture = Art.tex("events/scene_%s_hero" % theme_of(f if not f.is_empty() else {}))
	scene.modulate = Color.WHITE if state == "running" or state == "coming" else DIMMED
	var title: Label = _ui["hero_title"]
	title.text = str(f.get("name", "")).to_upper() if not f.is_empty() else "NO FESTIVAL NOW"
	title.label_settings.font_color = Color("#F1D48D") if state != "none" else UI.DIM
	UI.fit_line(title, TITLE_FIT.x, TITLE_FIT.y)
	var bonus: Label = _ui["hero_bonus"]
	bonus.text = bonus_words(f, state)
	UI.fit_line(bonus, 24, 15)
	var view: CanvasItem = _ui["view"]
	view.visible = state == "running" or state == "coming"
	(_ui["hero_hit"] as CanvasItem).visible = view.visible
	var n := int(f.get("claimable", 0)) if state == "running" else 0
	(_ui["view_badge"] as CanvasItem).visible = n > 0
	var count: Label = _ui["view_count"]
	count.visible = n > 0
	count.text = str(n) if n < 10 else "9+"


# --- the two cards -------------------------------------------------------------------

func _paint_card(side: String, card: Dictionary, spare_theme: String) -> void:
	var scene: TextureRect = _ui["card_scene_" + side]
	var empty := card.is_empty()
	scene.texture = Art.tex("events/scene_%s_%s" % [theme_of(card) if not empty else spare_theme, CARD_SCENE[side]])
	var coming := int(card.get("starts_in", 0)) > 0
	scene.modulate = DIMMED if empty else (Color.WHITE if coming else PAST_TINT)
	var title: Label = _ui[CARD_TITLE[side]]
	title.text = str(card.get("name", "")).to_upper() if not empty else "COMING LATER"
	title.label_settings.font_color = Color("#F1D48D") if not empty else UI.DIM
	UI.fit_line(title, CARD_TITLE_FIT.x, CARD_TITLE_FIT.y)


## The spare scenes for cards with no festival: the themes the hero and the
## other card are not showing, so the page shows each of the owner's three.
func _themes_left(hero: Dictionary, cards: Array) -> Array:
	var used: Array = []
	var f: Dictionary = hero.get("festival", {})
	if not f.is_empty():
		used.append(theme_of(f))
	for c in cards:
		if not (c as Dictionary).is_empty():
			used.append(theme_of(c))
	var spare: Array = []
	for t in THEMES:
		if not used.has(t):
			spare.append(t)
	while spare.size() < 2:
		spare.append(THEMES[spare.size() % THEMES.size()])
	return spare


# --- the royal hours -------------------------------------------------------------------

func _paint_hours(age: int) -> void:
	var h: Dictionary = _ev.get("hourly", {}) if _ev.get("hourly") is Dictionary else {}
	var words := hours_words(h, age)
	var icon: TextureRect = _ui["hours_icon"]
	icon.visible = str(words["icon"]) != ""
	if icon.visible:
		icon.texture = Art.tex(str(words["icon"]))
	var name: Label = _ui["hours_name"]
	name.text = str(words["name"])
	name.label_settings.font_color = UI.INK if bool(words["on"]) else UI.DIM
	UI.fit_line(name, HOURS_FIT.x, HOURS_FIT.y)
	var next: Label = _ui["hours_next"]
	next.text = str(words["next"])
	next.label_settings.font_color = UI.INK if str(words["next"]) != "Quiet" else UI.DIM
	UI.fit_line(next, NEXT_FIT.x, NEXT_FIT.y)


# --- upcoming ---------------------------------------------------------------------------

func _paint_rows() -> void:
	if not _built or _rows.is_empty():
		return
	var items := rows_of(_ev, GameState.live(), GameState.live_age_s(), _age())
	for i in _rows.size():
		var r: Dictionary = _rows[i]
		var node: Control = r["node"]
		var parts: Dictionary = r["parts"]
		# The painting's three rows stay where they were painted: a row with
		# nothing for it is its empty plate, as the paintings' empty plates
		# are, and the first says why it is empty.
		var it: Dictionary = {"icon": ICON_CAL, "what": "", "worth": "", "when": "", "dim": true}
		if i < items.size():
			it = items[i]
		elif i == 0:
			it = {"icon": ICON_CAL, "what": "Nothing else is announced", "worth": "", "when": "", "dim": true}
		var icon: TextureRect = parts["icon"]
		var glass := str(it["icon"]) == ICON_GLASS
		icon.texture = Art.tex(str(it["icon"]))
		icon.position.x = 15.0 + (GLASS_SHIFT if glass else 0.0)
		icon.size = Vector2(44 if glass else 52, 56)
		var what: Label = parts["what"]
		what.text = str(it["what"])
		what.label_settings.font_color = UI.DIM if bool(it.get("dim", false)) else Color("#F1D48D")
		# A line alone on its row takes the row's whole plate.
		what.size.x = 268.0 if str(it["worth"]) != "" or str(it["when"]) != "" else 595.0
		what.set_meta("box_w", what.size.x)
		UI.fit_line(what, ROW_WHAT_FIT.x, ROW_WHAT_FIT.y)
		var worth: Label = parts["worth"]
		worth.text = str(it["worth"])
		UI.fit_line(worth, ROW_FIT.x, ROW_FIT.y)
		r["item"] = it


# --- the clocks ---------------------------------------------------------------------------

func _paint_times() -> void:
	var age := _age()
	var hero := hero_of(_ev)
	_say(_ui["hero_timer"], hero_time(hero, age), LINE_FIT)
	var cards := cards_of(_ev, hero)
	for i in CARDS.size():
		_say(_ui[CARD_TIMER[CARDS[i]]], card_time(cards[i], age), CARD_LINE_FIT)
	var h: Dictionary = _ev.get("hourly", {}) if _ev.get("hourly") is Dictionary else {}
	_say(_ui["hours_timer"], str(hours_words(h, age)["timer"]), HOURS_FIT)
	var live_age := GameState.live_age_s()
	for r in _rows:
		var it: Dictionary = r.get("item", {})
		var when: Label = r["parts"]["when"]
		_say(when, row_time(it, live_age, age), ROW_FIT)


## Sets a label's words and fits them, when they have changed.
func _say(l: Label, words: String, fit: Vector2i) -> void:
	if l.text == words:
		return
	l.text = words
	UI.fit_line(l, fit.x, fit.y)


# --- what each part says ----------------------------------------------------------------
# Pure, from the server's answer, so a test reads every case.

## The events answer the snapshot alone can give before /v1/festivals answers:
## its festival (running or announced, without its tasks) and its hour.
static func snapshot_events(live: Dictionary) -> Dictionary:
	var out := {"current": null, "upcoming": [], "past": [], "hourly": live.get("hourly", {}), "hourly_table": []}
	var f: Variant = live.get("festival")
	if f is Dictionary:
		out["current"] = f
	return out


## The hero: {state: running | coming | past | none, festival}. The festival
## running, else the next announced, else the last to close.
static func hero_of(ev: Dictionary) -> Dictionary:
	var cur: Variant = ev.get("current")
	if cur is Dictionary and not (cur as Dictionary).is_empty():
		return {"state": "running" if bool(cur.get("running", false)) else "coming", "festival": cur}
	var past: Array = ev.get("past", []) if ev.get("past") is Array else []
	if not past.is_empty() and past[0] is Dictionary:
		return {"state": "past", "festival": past[0]}
	return {"state": "none", "festival": {}}


## The two cards, left then right: the festivals announced after the hero's,
## then those closed most recently (the hero's own past festival left out);
## {} for a card with none.
static func cards_of(ev: Dictionary, hero: Dictionary) -> Array:
	var out: Array = []
	var hid := int((hero.get("festival", {}) as Dictionary).get("id", 0))
	for key in ["upcoming", "past"]:
		for c in (ev.get(key, []) if ev.get(key) is Array else []):
			if c is Dictionary and int(c.get("id", 0)) != hid and out.size() < 2:
				out.append(c)
	while out.size() < 2:
		out.append({})
	return out


## A festival's scene: its theme when the owner painted one, else the first.
static func theme_of(f: Dictionary) -> String:
	var t := str(f.get("theme", ""))
	return t if THEMES.has(t) else THEMES[0]


## The hero's plate, right of the name: what the festival gives this lord
## (LiveEvents.festival_worth: "+25% for you", "+50% renown", "10% off the
## market"); for one that has closed, the points this lord took in it.
static func bonus_words(f: Dictionary, state: String) -> String:
	match state:
		"running", "coming":
			if state == "coming":
				# Not yet this lord's: what it will give everyone.
				var what := LiveEvents.festival_worth({"bucket": f.get("bucket", ""), "bp": f.get("bp", 0),
					"effective_bp": f.get("bp", 0)})
				return what.replace(" for you", " for all")
			return LiveEvents.festival_worth(f)
		"past":
			var pts := int(f.get("points", 0))
			return "%s points" % UI.grouped(pts) if pts > 0 else ""
	return ""


## The hero's timer plate: "Ends in 2d 14h", "Starts in 1d 03h", "Ended 3d ago",
## "None announced".
static func hero_time(hero: Dictionary, age: int) -> String:
	var f: Dictionary = hero.get("festival", {})
	match str(hero.get("state", "none")):
		"running":
			var left := maxi(0, int(f.get("ends_in", 0)) - age)
			return "Ends in " + UI.time_left(left) if left > 0 else "Closing"
		"coming":
			var left := maxi(0, int(f.get("starts_in", 0)) - age)
			return "Starts in " + UI.time_left(left) if left > 0 else "Beginning"
		"past":
			return "Ended " + UI.ago(int(f.get("ended_ago", 0)) + age)
	return "None announced"


## A card's timer plate: an announced festival's start, a closed one's end.
static func card_time(c: Dictionary, age: int) -> String:
	if c.is_empty():
		return "None announced"
	var starts := int(c.get("starts_in", 0))
	if starts > 0:
		var left := maxi(0, starts - age)
		return "Starts in " + UI.time_left(left) if left > 0 else "Beginning"
	return "Ended " + UI.ago(int(c.get("ended_ago", 0)) + age)


## ROYAL HOURS' words: {icon, name, on (the event is running), timer, next}.
## Running: the event's icon and name, and its time left. Its minutes over, or
## a quiet hour: "A quiet hour" and the time until the next hour turns.
static func hours_words(h: Dictionary, age: int) -> Dictionary:
	var out := {"icon": "", "name": "A quiet hour", "on": false, "timer": "", "next": "Quiet"}
	if h.is_empty():
		out["next"] = ""
		return out
	var running := LiveEvents.hourly_running({"hourly": h}, age)
	var next_in := maxi(0, int(h.get("next_in", 0)) - age)
	if not running.is_empty():
		out["icon"] = str(running.get("icon", ""))
		out["name"] = str(running.get("name", ""))
		out["on"] = true
		out["timer"] = UI.time_left(maxi(0, int(running.get("ends_in", 0)) - age))
	elif str(h.get("id", "")) != "":
		# Its minutes are over: the hour is quiet until the next begins.
		out["name"] = "%s is over" % str(h.get("name", ""))
		out["timer"] = UI.time_left(next_in)
	else:
		out["timer"] = UI.time_left(next_in)
	var n: Variant = h.get("next")
	out["next"] = str(n.get("name", "")) if n is Dictionary and str(n.get("name", "")) != "" else "Quiet"
	return out


## UPCOMING's rows, soonest first: the operator's server-wide events running
## now (the hourglass, what they give and what they are worth to this lord,
## the time they end), those announced (the calendar, when they start), and
## any festival announced beyond the two cards. `live_age` is the snapshot's
## age, `age` the events answer's.
static func rows_of(ev: Dictionary, live: Dictionary, live_age: int, age: int) -> Array:
	var out: Array = []
	for e in LiveEvents.running(live):
		if LiveEvents.left(e, live_age) <= 0:
			continue
		out.append({"icon": ICON_GLASS, "what": "%s %s" % [LiveEvents.name(str(e.get("bucket", ""))),
			LiveEvents.percent(int(e.get("bp", 0)))], "worth": LiveEvents.worth(e), "when_key": "ends_in",
			"src": "live", "event": e})
	for e in LiveEvents.upcoming(live):
		out.append({"icon": ICON_CAL, "what": "%s %s" % [LiveEvents.name(str(e.get("bucket", ""))),
			LiveEvents.percent(int(e.get("bp", 0)))], "worth": LiveEvents.worth(e), "when_key": "starts_in",
			"src": "live", "event": e})
	var ups: Array = ev.get("upcoming", []) if ev.get("upcoming") is Array else []
	var hero := hero_of(ev)
	var on_cards := cards_of(ev, hero)
	for c in ups:
		if not (c is Dictionary) or on_cards.has(c):
			continue
		out.append({"icon": ICON_CAL, "what": str(c.get("name", "")), "worth": LiveEvents.festival_worth(
			{"bucket": c.get("bucket", ""), "bp": c.get("bp", 0), "effective_bp": c.get("bp", 0)}).replace(" for you", " for all"),
			"when_key": "starts_in", "src": "ev", "event": c})
	return out.slice(0, 3)


## A row's time: an operator's event counted from the snapshot, a festival
## from the events answer.
static func row_time(it: Dictionary, live_age: int, age: int) -> String:
	if it.is_empty() or not it.has("event"):
		return ""
	var a := live_age if str(it.get("src", "")) == "live" else age
	var key := str(it.get("when_key", "ends_in"))
	var s := LiveEvents.left(it["event"], a, key)
	return ("in " if key == "starts_in" else "") + UI.time_left(s)


## Whether a clock on the page has run out -- a festival begun or closed, the
## hour turned -- so the calendar should be asked again.
static func turned(ev: Dictionary, age: int) -> bool:
	if ev.is_empty():
		return false
	var cur: Variant = ev.get("current")
	if cur is Dictionary and not (cur as Dictionary).is_empty():
		var key := "ends_in" if bool(cur.get("running", false)) else "starts_in"
		if int(cur.get(key, 0)) > 0 and int(cur.get(key, 0)) - age <= 0:
			return true
	var h: Variant = ev.get("hourly")
	if h is Dictionary and int(h.get("next_in", 0)) > 0 and int(h.get("next_in", 0)) - age <= 0:
		return true
	return false


# --- taps ------------------------------------------------------------------------------------

## The festival's page and the hours' odds, as a capture and a test open them
## (--page festival, --page hours): the taps' own work, named.
func open_festival() -> void:
	# Opened the moment the view is built, the calendar may not have answered
	# yet: without it there is no festival to open.
	if _ev.is_empty():
		await _load()
	await _view()


func open_hours() -> void:
	if _ev.is_empty():
		await _load()
	await _hours()


## VIEW: the festival's page -- the one running, or the one announced.
func _view() -> void:
	var hero := hero_of(_ev)
	var f: Dictionary = hero.get("festival", {})
	var state := str(hero.get("state", ""))
	if f.is_empty() or (state != "running" and state != "coming"):
		return
	if not f.has("tasks"):
		# Only the snapshot's word so far: the page needs the festival whole.
		await _load()
		f = (hero_of(_ev).get("festival", {}) as Dictionary)
		if not f.has("tasks"):
			return
	load("res://scenes/pages/festival_page.gd").call("open", self, f, self)


## A card: an announced festival's promise, or a closed one's reckoning.
func _card(side: String) -> void:
	var cards := cards_of(_ev, hero_of(_ev))
	var c: Dictionary = cards[CARDS.find(side)]
	if c.is_empty():
		return
	var name := str(c.get("name", ""))
	var starts := maxi(0, int(c.get("starts_in", 0)) - _age())
	if int(c.get("starts_in", 0)) > 0:
		await Dialog.ask(self, {"title": name.to_upper(), "body": "%s\n\nIt begins in %s." % [str(c.get("blurb", "")),
			UI.time_left(starts)], "confirm_text": "OK"})
		return
	var pts := int(c.get("points", 0))
	var took := "You took no part in it."
	if pts > 0:
		took = "You took %s points in it. Your place's prize, and anything you left unclaimed, came to you by letter." % \
			UI.grouped(pts)
	var cfg := {"title": name.to_upper(), "body": "It closed %s. %s" % [UI.ago(int(c.get("ended_ago", 0)) + _age()), took],
		"confirm_text": "OK"}
	if pts > 0:
		# Its prize is in the letters: the way there, or not now.
		cfg["confirm_text"] = "LETTERS"
		cfg["cancel_text"] = "CLOSE"
	var go := await Dialog.ask(self, cfg)
	if go and pts > 0:
		var shell := get_tree().get_first_node_in_group("shell")
		if shell != null:
			shell.call("open_view", "mail")


## ROYAL HOURS: what every hour may bring, and how often.
func _hours() -> void:
	var table: Array = _ev.get("hourly_table", []) if _ev.get("hourly_table") is Array else []
	if table.is_empty():
		await _load()
		table = _ev.get("hourly_table", []) if _ev.get("hourly_table") is Array else []
	load("res://scenes/pages/hourly_odds_page.gd").call("open", self, table,
		_ev.get("hourly", {}) if _ev.get("hourly") is Dictionary else {})
