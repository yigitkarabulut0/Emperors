extends Control
## COLLECT — the quests (today's and the week's), the Golden Hour and the job
## list. Layout: layout/collect.json.
##
## The screen renders what the server sent: payouts are resolved values, the
## counter is collects / next milestone, and a tap queues an optimistic collect
## through GameState (confirmed + replay(pending) is what the pills show).
##
## Reads: /v1/quests and /v1/weekly for the pager and the week's chest bar;
## snapshot.frenzy for the Golden Hour's wheel; the collect answers'
## frenzy_gold / frenzy_started through GameState.golden_hour.

const SCREEN := "collect"
## Every job wears its own painting, cut for it as collect/job_<id>. Fifteen
## jobs used to share six paintings by their place in the list, so Tend the
## Orchard showed a pile of logs and Fish the River a cart of gold.
const JOB_ART := "collect/job_%s"
## The fifteen, in the list's order: a job the server adds before its painting
## is cut is drawn with one of these by its place, never with nothing.
## tests/job_paintings.gd keeps every job in the balance on its own painting.
const JOB_IDS := ["grapes", "strawberries", "wheat", "orchard", "timber", "fish", "stone", "iron",
	"hunt", "caravan", "silver", "bandits", "deep_mine", "tithe", "dragon_hoard"]
## The frame every row lays over its painting -- the grapes row's own, with its
## window cut out -- and where the painting sits under it, in the frame's own
## coordinates (the row's tile part draws the frame at [2, -2]).
const JOB_FRAME := "collect/job_frame"
const JOB_FRAME_SIZE := Vector2(190, 158)
const JOB_PAINTING_RECT := Rect2(9, 10, 165, 141)
## The part of a painting that shows through the frame's window; the rest runs
## under the frame. Anything showing a painting without that frame (the mastery
## ceremony) shows only this.
const JOB_WINDOW := Rect2(2, 2, 161, 137)

var _ui: Dictionary = {}
var _rows: Array = []            ## [{node, parts, job_id}]
var _quests: Array = []
var _quest_cards: Array = []
var _quests_loaded_ms := -100000

## The quests pager (collect_events.png): one panel, its three painted tiles
## and the two dots, showing today's quests or the week's. Six weekly tasks do
## not fit three tiles and the painting gives the pager two dots, so the week's
## page shows the three that need the lord most (QuestTile.weekly_order) and
## its heading opens the whole week; a third page would be a dot the painting
## does not have.
const PAGE_TODAY := 0
const PAGE_WEEK := 1
const TITLES := ["TODAY'S QUESTS", "THIS WEEK'S QUESTS"]
## A sideways drag this long on the panel turns the page; anything shorter is a tap.
const SWIPE_MIN := 70.0
const TURN_S := 0.12
## The week's badge on its dot: the rail's own bubble, drawn down.
const BUBBLE := "icons/count_bubble"
const DOT_BUBBLE := 30.0
var _page := PAGE_TODAY
## What the tiles show, in tile order: today's quests, or the three of the
## week's the tiles hold.
var _shown: Array = []
var _weekly: Dictionary = {}
var _weekly_loaded_ms := -100000
## When `_weekly` arrived, for counting its ends_in down.
var _weekly_at_ms := 0
var _swipe_from := Vector2.INF
var _dot_bubble: TextureRect

## The week's chest bar (layout week_bar): the fill toward the chests, and a
## chest's plate saying what it needs, OPEN, or OPENED.
var _bar: Dictionary = {}
const CHEST_NAMES := ["BRONZE CHEST", "SILVER CHEST", "GOLDEN CHEST"]
## The bar's parts for each chest, bronze to gold (layout week_bar).
const CHEST_PARTS := ["chest_0", "chest_1", "chest_2"]
const CHEST_NEEDS := ["need_0", "need_1", "need_2"]
const CHEST_TAPS := ["chest_tap_0", "chest_tap_1", "chest_tap_2"]
const CHEST_MARKERS := ["marker_0", "marker_1", "marker_2"]
const CHEST_PLATES := ["plate_0", "plate_1", "plate_2"]
## A chest not yet reached is drawn as painted; one waiting breathes; one opened steps back.
const CHEST_LOCKED := Color.WHITE
const CHEST_OPENED := Color(0.5, 0.5, 0.54)
var _chest_pulses: Dictionary = {}

## The Golden Hour's wheel (layout golden): the painting's dark wheel, its
## cells lit over it as the meter fills and burnt back as the hour runs out, and
## its plate saying what it is doing. It shows only what the last answer
## confirmed (snapshot.frenzy); between answers it only counts down.
var _golden: Control
var _golden_parts: Dictionary = {}
var _wheel: TextureProgressBar
var _golden_said := ""
var _glow_tween: Tween
## The plate's words and how far they shrink.
const GOLDEN_FIT := Vector2i(22, 15)
const GOLDEN_ENERGY_GAP := 10.0
const GOLDEN_BOLT_GAP := 3.0

## A task's reward row centred as a pair (QuestTile.paint_pair); the rising
## figures after a claim; the ready gold.
const READY := Color("#F0D27A")

## Font sizes a row's name and its collect counter are fitted between (max, min):
## the painting's size when the text fits its box, smaller only when it would not.
const NAME_FIT := Vector2i(24, 14)
const COUNTER_FIT := Vector2i(24, 16)
const NAME_CLEAR := 16.0
## Below this a name that will not fit on one line takes two, in this height.
const NAME_ONE_LINE_MIN := 18
## The band (top, bottom) a two-line name's ink stands in: under the row's
## border, over the payout icons.
const NAME_TWO_LINES_INK := Vector2(8.0, 44.0)
## Cinzel's capital height, as a fraction of its size (OS/2 sCapHeight 700/1000).
const TITLE_CAP := 0.70
## A row's payouts -- bolt, coin, crown, each with its figure. The painting
## sets them for one-digit jobs; a late job pays thousands, and at the
## painting's places "1,250" ran into the crown. Each pair stands where the
## painting has it, or this far after the figure before it if that is further,
## and all three figures shrink together (max, min) if they would reach the
## COLLECT button.
const PAYOUT_GAP := 20.0
const PAYOUT_FIT := Vector2i(30, 20)
const PAYOUT_CLEAR := 14.0
## The live band (layout event_band, cut from collect_events.png): the first of
## the hour's event running, an operator's event, the festival running, the
## next hour's event, the festival announced (LiveEvents.band). While it shows,
## the quests panel, everything on it, the chest bar and the job list's top
## stand the band's `shift` lower; with nothing to say the tab is exactly as
## without it.
##
## The hour's event wears its disc (hourly/<id>, events_kit.png) pinned over the
## band's scene against the name plate: its gold rim 110 across, centred at
## (296, 73.5) of the cut band -- 11 left of the plate's frame line at 362, the
## band's middle. The next hour's is the same disc drawn quieter with the kit's
## NEXT plate on its foot; the courier's gift puts a CLAIM plate (the Equip
## button's green, inventory/btn_equip_plate, 43 tall as MORE ROOM's) over the
## time plate (x 604..706, y 84..114), the hourglass left standing beside it.
const BAND_ICON := Rect2(238.0, 15.5, 116.0, 116.0)
const BAND_NEXT := Rect2(250.0, 104.0, 92.0, 34.0)
const BAND_NEXT_DIM := Color(0.78, 0.78, 0.8)
const BAND_CLAIM := Rect2(599.0, 77.5, 113.0, 43.0)
const BAND_CLAIM_PLATE := "inventory/btn_equip_plate"
const BAND_CLAIM_SIZE := 20
const BAND_CLAIM_INK := Color("#EFFCEF")
var _band: Control
var _band_icon: TextureRect
var _band_next: TextureRect
var _band_claim: Button
var _claiming := false
## Busy Hands' multiplier while it runs, which today's heading carries ("×2").
var _quest_x := 1
var _band_parts: Dictionary = {}
var _band_shift := 0.0
var _band_on := false
## Where each moved node stands without the band: the node, and its y (for the
## job list, the top offset its bottom stays anchored under).
var _band_homes: Array = []
## What the band last said: its seconds left and the live block they came from,
## so its words are set once a second, and at once when a new snapshot changes
## the events (a second one starts, a lord reaches their cap) on the same second.
var _band_said := ""
## A band's worth line gives up its "· N more" before it would shrink past this.
const BAND_WORTH_MIN := 15
## The time plate's words shrink to this for a month-long event.
const BAND_TIME_FIT := Vector2i(20, 15)
## Everything between the band and the job list, which the band moves down.
const QUEST_BLOCK := ["quests_panel", "quests_title", "quests_more", "quests_reset", "page_dot_0",
	"page_dot_1", "quests_heading", "quests_flip", "quests_touch", "week_bar"]
var _built := false
var _busy := false
## The gentle pulse on a tile whose reward is waiting, one per tile.
var _pulses: Dictionary = {}


func _ready() -> void:
	_ui = Layout.build(SCREEN, self)
	_quest_cards = _ui.get("quest_card", [])
	# One touch area over the heading and the three tiles: a sideways drag turns
	# the page, a tap acts on what is under it. A button per tile could not tell
	# the two apart (a drag that began on a tile claimed it when the finger
	# lifted), and buttons side by side in a row 58 tall could not reach 44 pt.
	var touch: BaseButton = _ui["quests_touch"]
	touch.button_down.connect(func() -> void: _swipe_from = touch.get_local_mouse_position())
	touch.button_up.connect(func() -> void: _on_touch(touch.get_local_mouse_position(), touch.size))
	var sc: ScrollContainer = _ui["job_list"]
	sc.scroll_deadzone = 14
	_build_dots()
	_build_bar()
	_build_golden()
	_build_band()
	_built = true
	GameState.energy_changed.connect(func(_v: int) -> void: _paint_rows())
	GameState.golden_hour.connect(_on_golden_hour)
	GameState.badges_changed.connect(_paint_dots)
	set_process(true)


func refresh() -> void:
	if not _built:
		return
	paint_band()
	paint_golden()
	_ensure_rows()
	_paint_rows()
	_paint_tiles()
	paint_bar()
	var now := Time.get_ticks_msec()
	if now - _quests_loaded_ms > 3000:
		_load_quests()
	if now - _weekly_loaded_ms > 3000:
		_load_weekly()


func _process(_dt: float) -> void:
	if not visible:
		return
	if _band_on or not GameState.live().is_empty():
		paint_band()
	paint_golden()
	var l: Label = _ui.get("quests_reset")
	if l != null:
		l.text = reset_words(_page, _seconds_to_local_midnight(), weekly_ends_in())


## The line right of the heading: when today's quests reset, or when the week ends.
static func reset_words(page: int, to_midnight: int, week_left: int) -> String:
	if page == PAGE_WEEK:
		return "Ends in " + UI.time_left(maxi(0, week_left)) if week_left >= 0 else ""
	return "Resets in " + UI.duration(to_midnight)


# --- the live event ---------------------------------------------------------------

func _build_band() -> void:
	_band = _ui.get("event_band")
	if _band == null:
		return
	_band_parts = _band.get_meta("parts", {})
	_band_shift = float(Layout.element(SCREEN, "event_band").get("shift", 0))
	for id in ["name", "worth", "time"]:
		var l: Label = _band_parts.get(id)
		if l == null:
			continue
		if not l.has_meta("box_w"):
			l.set_meta("box_w", l.size.x)
		# Each label's own settings, so a fit on one never shrinks another.
		l.label_settings = l.label_settings.duplicate()
		l.set_meta("max_size", l.label_settings.font_size)
		l.set_meta("ink", l.label_settings.font_color)
	# The worth line is two labels set as one: this lord's figure, and after it
	# "· N more" in the band's ink, so a nerf's red never colours the others.
	var worth: Label = _band_parts.get("worth")
	if worth != null:
		worth.set_meta("box_x", worth.position.x)
		worth.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		var more := worth.duplicate() as Label
		more.name = "more"
		more.label_settings = worth.label_settings.duplicate()
		more.text = ""
		worth.add_sibling(more)
		_band_parts["more"] = more
	var tap: BaseButton = _band_parts.get("tap")
	if tap != null:
		tap.pressed.connect(_show_events)
	# The hour's disc, its NEXT plate and the gift's CLAIM, over the band's
	# picture and under nothing: the CLAIM takes its own taps before the band's.
	_band_icon = UI.image("hourly/gold_rush", BAND_ICON)
	_band_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_band_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_band_icon.visible = false
	_band.add_child(_band_icon)
	_band_next = UI.image("events_kit/next_plate", BAND_NEXT)
	_band_next.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_band_next.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_band_next.visible = false
	_band.add_child(_band_next)
	_band_claim = UI.plate_button(BAND_CLAIM_PLATE, "CLAIM", BAND_CLAIM, BAND_CLAIM_SIZE, BAND_CLAIM_INK, 700)
	_band_claim.visible = false
	_band_claim.pressed.connect(_claim_gift)
	_band.add_child(_band_claim)
	var homes: Array = []
	for id in QUEST_BLOCK:
		homes.append(_ui.get(id))
	for c in _quest_cards:
		homes.append(c["node"])
	for n in homes:
		if n is Control:
			_band_homes.append({"node": n, "y": (n as Control).position.y})
	var sc: ScrollContainer = _ui["job_list"]
	_band_homes.append({"node": sc, "top": sc.offset_top})
	_band.visible = false


## Shows or hides the band from the snapshot's live block, and says what it
## shows (LiveEvents.band): the name on the plate, what it is worth to this lord
## or does for them, and its time -- left, or "in ..." to its start -- counted
## down from the snapshot; the hour's disc, NEXT for the next hour's, and CLAIM
## while the courier's gift waits.
func paint_band() -> void:
	if _band == null:
		return
	var live := GameState.live()
	var age := GameState.live_age_s()
	_paint_quest_x(live, age)
	var b := LiveEvents.band(live, age)
	_set_band(not b.is_empty())
	if b.is_empty():
		_band_said = ""
		return
	var said := "%d|%d" % [int(b["left"]), live.hash()]
	if said == _band_said:
		return
	_band_said = said
	var kind := str(b["kind"])
	_fit_name(_band_parts["name"], str(b["name"]))
	_paint_worth(str(b["worth"]), bool(b["red"]), int(b["more"]))
	var time: Label = _band_parts["time"]
	var t := UI.time_left(int(b["left"]))
	time.text = "in " + t if kind == "next" or kind == "coming" else t
	UI.fit_line(time, BAND_TIME_FIT.x, BAND_TIME_FIT.y)
	var icon := str(b["icon"])
	_band_icon.visible = icon != ""
	if icon != "":
		_band_icon.texture = Art.tex(icon)
	_band_icon.modulate = BAND_NEXT_DIM if kind == "next" else Color.WHITE
	_band_next.visible = kind == "next"
	var claim := bool(b["claim"])
	_band_claim.visible = claim
	_band_claim.disabled = _claiming
	time.visible = not claim


## The name on the plate, in capitals -- or, where the capitals would have to
## shrink under NAME_CAPS_MIN (QUARTERMASTER'S SALE, MERCHANT CARAVAN), in
## Cinzel's own small capitals, the name as the server writes it, which the
## face draws a third narrower -- fitted to the plate's box.
const NAME_CAPS_MIN := 15
func _fit_name(label: Label, text: String) -> void:
	var max_size := int(label.get_meta("max_size", 19))
	var box_w := float(label.get_meta("box_w", label.size.x))
	var f := label.label_settings.font
	var caps := text.to_upper()
	if f.get_string_size(caps, HORIZONTAL_ALIGNMENT_LEFT, -1, NAME_CAPS_MIN).x <= box_w:
		label.text = caps
		UI.fit_line(label, max_size, NAME_CAPS_MIN)
	else:
		label.text = text
		UI.fit_line(label, max_size, 13)


## Today's heading carries Busy Hands' "×2" while it runs.
func _paint_quest_x(live: Dictionary, age: int) -> void:
	var h := LiveEvents.hourly_running(live, age)
	var x := maxi(1, int(h.get("x", 1))) if str(h.get("kind", "")) == "quest_multiplier" else 1
	if x == _quest_x:
		return
	_quest_x = x
	_paint_title()


## The courier's gift, from the band's CLAIM.
func _claim_gift() -> void:
	if _claiming:
		return
	_claiming = true
	_band_claim.disabled = true
	await load("res://scenes/court/hourly_popup.gd").claim(self)
	_claiming = false
	_band_said = ""
	paint_band()


## The worth line: what the event is worth to this lord (or does for them), in
## the game's red when it is a loss, then "· N more" for the other events
## running, in the band's ink. One line, one size, centred on the plate: shrunk
## to fit its box, and the "more" given up before the line would shrink past
## BAND_WORTH_MIN.
func _paint_worth(base: String, red: bool, more: int) -> void:
	var worth: Label = _band_parts["worth"]
	var tail: Label = _band_parts["more"]
	var f := worth.label_settings.font
	var box_x := float(worth.get_meta("box_x"))
	var box_w := float(worth.get_meta("box_w"))
	var max_size := int(worth.get_meta("max_size", 19))
	var rest := " · %d more" % more if more > 0 else ""
	var size := _fit_size(f, base + rest, box_w, max_size, BAND_WORTH_MIN if rest != "" else 13)
	if rest != "" and f.get_string_size(base + rest, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x > box_w:
		rest = ""
		size = _fit_size(f, base, box_w, max_size, 13)
	var w_base := f.get_string_size(base, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var w_rest := f.get_string_size(rest, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x if rest != "" else 0.0
	var x := box_x + maxf(0.0, (box_w - w_base - w_rest) / 2.0)
	worth.text = base
	worth.label_settings.font_size = size
	worth.position.x = x
	worth.size.x = ceilf(w_base)
	worth.label_settings.font_color = UI.RED if red else (worth.get_meta("ink") as Color)
	tail.text = rest
	tail.visible = rest != ""
	tail.label_settings.font_size = size
	tail.position.x = x + w_base
	tail.size.x = ceilf(w_rest)


## The largest size from max_size down to min_size at which text fits width.
static func _fit_size(f: Font, text: String, width: float, max_size: int, min_size: int) -> int:
	var size := max_size
	while size > min_size and f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x > width:
		size -= 1
	return size


func _set_band(on: bool) -> void:
	if on == _band_on and _band.visible == on:
		return
	_band_on = on
	_band.visible = on
	var dy := _band_shift if on else 0.0
	for h in _band_homes:
		var n: Control = h["node"]
		if h.has("top"):
			n.offset_top = float(h["top"]) + dy
		else:
			n.position.y = float(h["y"]) + dy


## What is running and what is coming, in full: the band has room for one.
## A tap on the band: the Court's EVENTS view, which says it all -- the hour,
## the festival, what is coming. Without the shell (a test), the list in words.
func _show_events() -> void:
	var shell := get_tree().get_first_node_in_group("shell") if is_inside_tree() else null
	if shell != null and shell.has_method("open_events"):
		shell.call("open_events")
		return
	var body := events_body(GameState.live(), GameState.live_age_s())
	if body == "":
		return
	await Dialog.ask(self, {"title": "The Crown's events", "body": body, "confirm_text": "OK"})


## The events dialog's words, a paragraph for each running event -- its name,
## its own figure and its time left; then what it is worth to this lord and
## what it moves -- and one for those announced.
static func events_body(live: Dictionary, age_s: int) -> String:
	var paras: Array[String] = []
	for e in LiveEvents.running(live):
		var bucket := str(e.get("bucket", ""))
		var what := LiveEvents.what(bucket)
		paras.append("%s %s · %s left\n%s%s." % [LiveEvents.name(bucket),
			LiveEvents.percent(int(e.get("bp", 0))), UI.time_left(LiveEvents.left(e, age_s)),
			LiveEvents.worth(e), ", " + what if what != "" else ""])
	var coming: Array[String] = []
	for e in LiveEvents.upcoming(live):
		coming.append("Coming in %s: %s %s." % [UI.time_left(LiveEvents.left(e, age_s, "starts_in")),
			LiveEvents.name(str(e.get("bucket", ""))), LiveEvents.percent(int(e.get("bp", 0)))])
	if not coming.is_empty():
		paras.append("\n".join(coming))
	return "\n\n".join(paras)


# --- jobs -------------------------------------------------------------------------

func _ensure_rows() -> void:
	var jobs: Array = GameState.jobs().duplicate()
	jobs.sort_custom(func(a, b): return int(a.get("order", 0)) < int(b.get("order", 0)))
	if _rows.size() == jobs.size():
		return
	var sc: ScrollContainer = _ui["job_list"]
	var content: Control = sc.get_meta("content")
	for r in _rows:
		r["node"].queue_free()
	_rows.clear()
	var tpl := Layout.element(SCREEN, "job_row")
	var origin := Layout.rect_of(tpl).position - Layout.rect_of(Layout.element(SCREEN, "job_list")).position
	var pitch := float(tpl.get("pitch", 168))
	for i in jobs.size():
		var job: Dictionary = jobs[i]
		var built := Layout.instantiate(tpl, {"assets": {"painting": painting_for(job, i)}})
		built["node"].position = origin + Vector2(0, i * pitch)
		content.add_child(built["node"])
		built["job_id"] = str(job.get("id", ""))
		var btn: TextureButton = built["parts"]["collect"]
		if i == 0: GuideTargets.register("collect.job0", btn)
		btn.pressed.connect(_on_collect.bind(str(job.get("id", ""))))
		built["empty"] = _build_empty_face(btn)
		_rows.append(built)
	content.custom_minimum_size = Vector2(sc.size.x, origin.y + jobs.size() * pitch + 8)


## The "no energy" face of a Collect button.
##
## The painted NO ENERGY plate (art/reference/plates_sheet.png, cut as
## collect/no_energy_plate), laid over the painted COLLECT at that plate's whole
## extent -- the button's picture is cut four units inside its left rim, and the
## row's painting carries the rest of it -- nine-patched to it corner on corner,
## with NO ENERGY set on it. It was the COLLECT picture with its word inpainted
## and its hue rotated to crimson; the plate is the painter's own now.
##
## Returns the face, which _set_empty() shows or hides; the green button under
## it stays as it is.
const NO_ENERGY_PLATE := "collect/no_energy_plate"
## The painted COLLECT's plate, in its button picture's space (x 728..911,
## y 530..600 on the painting; the picture starts at 732, 530).
const COLLECT_PLATE := Rect2(-4, 0, 184, 71)


func _build_empty_face(btn: TextureButton) -> Control:
	var face := NinePatchRect.new()
	face.texture = Art.tex(NO_ENERGY_PLATE)
	for m in ["left", "top", "right", "bottom"]:
		face.set("patch_margin_" + m, 14)
	var picture := btn.texture_normal.get_size() if btn.texture_normal != null else btn.size
	UI.place(face, Rect2((btn.size - picture) / 2.0 + COLLECT_PLATE.position, COLLECT_PLATE.size))
	face.mouse_filter = Control.MOUSE_FILTER_IGNORE
	face.visible = false
	var l := UI.label("NO ENERGY", 24, Color("#F7E7DA"), "body", 700, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(l, Rect2(Vector2.ZERO, COLLECT_PLATE.size))
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	face.add_child(l)
	btn.add_child(face)
	return face


## Puts a Collect button on its green or its red face.
func _set_empty(row: Dictionary, empty: bool) -> void:
	var face: Control = row.get("empty")
	if face == null:
		return
	face.visible = empty


## The painting for a job: its own, by its id. Static: the mastery ceremony
## draws the same painting.
static func painting_for(job: Dictionary, index: int) -> String:
	var own := JOB_ART % str(job.get("id", ""))
	if Art.has(own):
		return own
	return JOB_ART % JOB_IDS[index % JOB_IDS.size()]


func _job(id: String) -> Dictionary:
	for j in GameState.jobs():
		if str(j.get("id", "")) == id:
			return j
	return {}


func _paint_rows() -> void:
	for r in _rows:
		var job := _job(r["job_id"])
		if job.is_empty():
			continue
		var p: Dictionary = r["parts"]
		p["name"].text = str(job.get("name", "")).to_upper()
		p["energy"].text = str(int(job.get("energy_cost", 0)))
		p["gold"].text = UI.short_number(int(job.get("gold_payout", 0)))
		p["xp"].text = UI.short_number(int(job.get("xp_payout", 0)))
		flow_payouts(p)
		var unlocked := bool(job.get("unlocked", false))
		var next := int(job.get("next_milestone", 0))
		# Confirmed plus the taps still in flight, the same sum the pills show.
		var collects := int(job.get("collects", 0)) + GameState.pending_collects(r["job_id"])
		if not unlocked:
			p["counter"].text = "LV %d" % int(job.get("unlock_level", 1))
		elif next <= 0:
			p["counter"].text = "%d / MAX" % collects
		else:
			p["counter"].text = "%d / %d" % [collects, next]
		fit_top_line(p)
		_paint_mastery(p, job.get("mastery", {}), collects)
		r["node"].modulate = Color.WHITE if unlocked else Color(0.55, 0.55, 0.55)

		# Energy is projected between polls rather than polled, so this is driven
		# by GameState.energy_changed as well as by a state refresh -- the button
		# has to go back to green the moment the bar ticks over the cost.
		var short_of_energy := unlocked \
			and GameState.display_energy() < int(job.get("energy_cost", 0))
		_set_empty(r, short_of_energy)


## A row's top line: the job's name on the left, the collect count on the right.
##
## The painting's counter reads "0 / 25"; "1500 / MAX" is twice as wide. Its box
## ends where the painted figure does, 36 units clear of the button, and a long
## count shrinks to stay inside it -- a Label grows to its text, so without this
## the count walked right until it sat on the COLLECT button. The name then
## stops NAME_CLEAR short of the count's first figure rather than of its box,
## which is empty on its left: "ROYAL TAX PICKUP" ran straight into "0 / MAX".
static func fit_top_line(p: Dictionary) -> void:
	var counter: Label = p["counter"]
	var name: Label = p["name"]
	UI.fit_label(counter, COUNTER_FIT.x, COUNTER_FIT.y)
	var s := counter.label_settings
	var count_left := counter.position.x + float(counter.get_meta("box_w")) \
		- s.font.get_string_size(counter.text, HORIZONTAL_ALIGNMENT_LEFT, -1, s.font_size).x
	if not name.has_meta("home"):
		name.set_meta("home", Rect2(name.position, name.size))
		name.set_meta("layout_w", name.get_meta("box_w", name.size.x))
	var home: Rect2 = name.get_meta("home")
	var room := minf(float(name.get_meta("layout_w")), count_left - NAME_CLEAR - name.position.x)
	name.set_meta("box_w", room)
	name.label_settings.line_spacing = 0.0
	name.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name.position = home.position
	name.size = home.size
	UI.fit_label(name, NAME_FIT.x, NAME_FIT.y)
	var words := name.text.split(" ")
	if name.label_settings.font_size >= NAME_ONE_LINE_MIN or words.size() < 2:
		return
	# Two lines at a size a person can read beat one at a size nobody can:
	# "PLUNDER THE DRAGON'S HOARD" beside "999 / 1000" was 14 units on one line,
	# six and a half points on the phone. The break goes where the two lines
	# come out most even, and the type is the largest at which both fit.
	var f := name.label_settings.font
	var lines := PackedStringArray()
	var widest := INF
	for i in range(1, words.size()):
		var a := " ".join(words.slice(0, i))
		var b := " ".join(words.slice(i))
		var w := maxf(f.get_string_size(a, HORIZONTAL_ALIGNMENT_LEFT, -1, NAME_FIT.x).x,
			f.get_string_size(b, HORIZONTAL_ALIGNMENT_LEFT, -1, NAME_FIT.x).x)
		if w < widest:
			widest = w
			lines = PackedStringArray([a, b])
	# The two lines' ink -- the first line's capitals to the second's baseline,
	# 0.7 + 1.0 of the size in Cinzel -- stands in the band between the row's
	# border and the payout icons.
	var size := NAME_FIT.x
	while size > NAME_FIT.y:
		var w := maxf(f.get_string_size(lines[0], HORIZONTAL_ALIGNMENT_LEFT, -1, size).x,
			f.get_string_size(lines[1], HORIZONTAL_ALIGNMENT_LEFT, -1, size).x)
		if w <= room and size * (TITLE_CAP + 1.0) <= NAME_TWO_LINES_INK.y - NAME_TWO_LINES_INK.x:
			break
		size -= 1
	name.text = "\n".join(lines)
	var ls := name.label_settings
	ls.font_size = size
	ls.line_spacing = 0.0
	ls.line_spacing = size - f.get_height(size)
	name.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	var ink_h := size * (TITLE_CAP + 1.0)
	var ink_top := (NAME_TWO_LINES_INK.x + NAME_TWO_LINES_INK.y - ink_h) / 2.0
	name.position.y = ink_top - (f.get_ascent(size) - size * TITLE_CAP)
	name.size = Vector2(room, f.get_height(size) + size)


## Lays the payout pairs along the row (see PAYOUT_GAP). Every place is the
## layout's: a pair's painted spot and its icon-to-figure offset are read off
## the parts the first time, and the limit is the COLLECT button's left edge.
static func flow_payouts(p: Dictionary) -> void:
	var pairs := [[p["energy_icon"], p["energy"]], [p["gold_icon"], p["gold"]], [p["xp_icon"], p["xp"]]]
	for pair in pairs:
		for n in pair:
			if not (n as Control).has_meta("home_x"):
				(n as Control).set_meta("home_x", (n as Control).position.x)
	var limit: float = (p["collect"] as Control).position.x - PAYOUT_CLEAR
	var size := PAYOUT_FIT.x
	while true:
		var end := _place_payouts(pairs, size)
		if end <= limit or size <= PAYOUT_FIT.y:
			break
		size -= 1


## Places the pairs at one type size and returns where the last figure ends.
static func _place_payouts(pairs: Array, size: int) -> float:
	var end := -INF
	for pair in pairs:
		var icon: Control = pair[0]
		var label: Label = pair[1]
		var home: float = icon.get_meta("home_x")
		var x := maxf(home, end + PAYOUT_GAP)
		icon.position.x = x
		label.label_settings.font_size = size
		label.position.x = x + float(label.get_meta("home_x")) - home
		var w := label.label_settings.font.get_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
		label.size.x = w + 2.0
		end = label.position.x + w
	return end


## The mastery track under a row: three painted markers labelled with the
## stretch of the ladder the player is on -- the threshold reached (its bonus is
## the one in force), the next, and the one after -- and a fill that runs from
## the first marker toward the second as the count climbs. The server resolves
## the stretch (JobView.mastery); this only places it. Zero thresholds mean
## none: a fresh row reads "0  +0%  |  25  +5%  |  50  +10%", a finished one
## carries MAX on the last marker and a full track.
func _paint_mastery(p: Dictionary, m: Dictionary, collects: int) -> void:
	var reached := int(m.get("reached", 0))
	var next := int(m.get("next", 0))
	var after := int(m.get("after", 0))
	p["mastery_1"].text = _milestone_label(reached, int(m.get("reached_bp", 0)))
	p["mastery_2"].text = _milestone_label(next, int(m.get("next_bp", 0))) if next > 0 else "MAX"
	p["mastery_3"].text = _milestone_label(after, int(m.get("after_bp", 0))) if after > 0 else ("MAX" if next > 0 else "")
	Layout.set_fill(p["mastery_fill"], mastery_fill_fraction(p, reached, next, collects))
	# The marker the fill has reached is lit; the ones ahead wait.
	var lit := [true, next == 0, false]
	for i in 3:
		p["mastery_marker_%d" % (i + 1)].modulate = Color.WHITE if lit[i] else Color(0.55, 0.55, 0.55)


static func _milestone_label(collects: int, bp: int) -> String:
	return "%d  +%d%%" % [collects, bp / 100]


## How much of the track to fill: the first marker stands for the threshold
## reached, the second for the next one, and the count's place between them is
## the fill's place between the two markers. A finished ladder fills the track.
## Geometry comes from the layout parts, never from numbers held here.
static func mastery_fill_fraction(p: Dictionary, reached: int, next: int, collects: int) -> float:
	var fill: Control = p["mastery_fill"]
	var track_x: float = fill.position.x
	var track_w: float = float(fill.get_meta("full", fill.size).x)
	if next <= 0:
		return 1.0
	var m1: Control = p["mastery_marker_1"]
	var m2: Control = p["mastery_marker_2"]
	var x1 := m1.position.x + m1.size.x / 2.0
	var x2 := m2.position.x + m2.size.x / 2.0
	var t := clampf(float(collects - reached) / float(next - reached), 0.0, 1.0)
	return clampf((x1 + t * (x2 - x1) - track_x) / track_w, 0.0, 1.0)


func _on_collect(job_id: String) -> void:
	var job := _job(job_id)
	if job.is_empty():
		return
	if not bool(job.get("unlocked", false)):
		GameState.action_failed.emit("Unlocks at level %d" % int(job.get("unlock_level", 1)))
		return
	if not GameState.collect(job):
		GameState.action_failed.emit("Not enough energy")


# --- the quests pager --------------------------------------------------------------

func _load_quests() -> void:
	_quests_loaded_ms = Time.get_ticks_msec()
	var res: Api.Response = await Api.get_json("/v1/quests")
	if res.ok:
		_quests = res.data.get("quests", [])
		_paint_tiles()


func _load_weekly() -> void:
	_weekly_loaded_ms = Time.get_ticks_msec()
	var res: Api.Response = await Api.get_json("/v1/weekly")
	if res.ok and res.data is Dictionary:
		set_weekly(res.data)


## The week as the server last said it; the tiles and the chest bar follow.
func set_weekly(w: Dictionary) -> void:
	_weekly = w
	_weekly_at_ms = Time.get_ticks_msec()
	_paint_tiles()
	paint_bar()


## Seconds until the week turns, counted down from the answer; -1 before one.
func weekly_ends_in() -> int:
	if _weekly.is_empty():
		return -1
	return maxi(0, int(_weekly.get("ends_in", 0)) - (Time.get_ticks_msec() - _weekly_at_ms) / 1000)


## Turns the pager to `page`: the heading, its line, the dots and the three
## tiles change, the painted tiles stay. The tiles' marks and words go out and
## come back in the direction of the turn.
func turn_page(page: int, animate: bool = true) -> void:
	page = clampi(page, PAGE_TODAY, PAGE_WEEK)
	if page == _page:
		return
	var dir := 1.0 if page > _page else -1.0
	_page = page
	if not animate or not is_inside_tree():
		_paint_tiles()
		_paint_dots()
		return
	for c in _quest_cards:
		var n: Control = c["node"]
		n.set_meta("home_x", n.get_meta("home_x", n.position.x))
		var t := create_tween().set_parallel()
		t.tween_property(n, "modulate:a", 0.0, TURN_S)
		t.tween_property(n, "position:x", float(n.get_meta("home_x")) - dir * 24.0, TURN_S)
	await get_tree().create_timer(TURN_S).timeout
	_paint_tiles()
	_paint_dots()
	for c in _quest_cards:
		var n: Control = c["node"]
		n.position.x = float(n.get_meta("home_x")) + dir * 24.0
		var t := create_tween().set_parallel()
		t.tween_property(n, "modulate:a", 1.0, TURN_S + 0.04)
		t.tween_property(n, "position:x", float(n.get_meta("home_x")), TURN_S + 0.04).set_ease(Tween.EASE_OUT)


## The tasks the three tiles show on `page`: today's, in their order, or the
## week's three that most need the lord.
static func shown_on(page: int, quests: Array, weekly: Dictionary) -> Array:
	if page == PAGE_WEEK:
		return QuestTile.weekly_order(weekly.get("tasks", [])).slice(0, 3)
	return quests.slice(0, 3)


func _paint_tiles() -> void:
	if not _built:
		return
	_paint_title()
	_shown = shown_on(_page, _quests, _weekly)
	for i in _quest_cards.size():
		var card: Dictionary = _quest_cards[i]
		var n: Control = card["node"]
		if i >= _shown.size():
			n.visible = false
			_pulse(i, false)
			continue
		n.visible = true
		var q: Dictionary = _shown[i]
		var st: String
		if _page == PAGE_WEEK:
			st = QuestTile.paint_weekly(card["parts"], q)
		else:
			st = QuestTile.paint_daily(card["parts"], q)
		# A claimed task steps back; one waiting breathes, so the eye finds it.
		n.modulate = Color(QuestTile.CLAIMED_TINT, n.modulate.a) if st == "claimed" else Color(1, 1, 1, n.modulate.a)
		_pulse(i, st == "done")


## The pager's heading: TODAY'S QUESTS or THIS WEEK'S QUESTS -- today's with
## Busy Hands' "×2" after it while the hour's event makes them count double.
func _paint_title() -> void:
	if not _built and _ui.is_empty():
		return
	var title: Label = _ui.get("quests_title")
	if title == null:
		return
	title.text = heading(_page, _quest_x)
	UI.fit_line(title, 27, 20)
	_place_more()


## The heading's words for a page, with the quests' multiplier on today's.
static func heading(page: int, x: int) -> String:
	if page == PAGE_TODAY and x > 1:
		return "%s  ×%d" % [TITLES[PAGE_TODAY], x]
	return TITLES[page]


## The event band's gold chevron after THIS WEEK'S QUESTS: the heading opens
## the whole week. Today's page has no more to show.
func _place_more() -> void:
	var more: Control = _ui.get("quests_more")
	if more == null:
		return
	var title: Label = _ui["quests_title"]
	var s := title.label_settings
	var w := s.font.get_string_size(title.text, HORIZONTAL_ALIGNMENT_LEFT, -1, s.font_size).x
	more.position.x = title.position.x + minf(w, float(title.get_meta("box_w", title.size.x))) + 12.0
	more.visible = _page == PAGE_WEEK and not _weekly.is_empty()


## The two dots: the lit one is the page shown. The week's carries what waits
## in it (tasks to claim, chests to open) in the rail's bubble.
func _build_dots() -> void:
	var dot: Control = _ui.get("page_dot_1")
	if dot == null:
		return
	# Up and to the right of the dot, as the rail's stand on their entries'
	# corners, so the lit dot under it still shows.
	_dot_bubble = UI.image(BUBBLE, Rect2(dot.size.x - 6.0, -DOT_BUBBLE * 0.7, DOT_BUBBLE, DOT_BUBBLE))
	var n := UI.label("", 18, Color("#FFF4EC"), "title", 800, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(n, Rect2(0, 0, DOT_BUBBLE, DOT_BUBBLE - 2))
	_dot_bubble.add_child(n)
	_dot_bubble.set_meta("count", n)
	_dot_bubble.visible = false
	dot.add_child(_dot_bubble)
	_paint_dots()


func _paint_dots() -> void:
	var on := Art.tex("collect/page_dot_on")
	var off := Art.tex("collect/page_dot_off")
	(_ui["page_dot_0"] as TextureRect).texture = on if _page == PAGE_TODAY else off
	(_ui["page_dot_1"] as TextureRect).texture = on if _page == PAGE_WEEK else off
	if _dot_bubble != null:
		var n := weekly_waiting(_weekly, GameState.badges)
		_dot_bubble.visible = n > 0
		(_dot_bubble.get_meta("count") as Label).text = str(n) if n < 10 else "9+"


## What waits in the week: the heartbeat's count, or, fresher, the week's own
## answer (a task finished since the last beat).
static func weekly_waiting(weekly: Dictionary, badges: Dictionary) -> int:
	if weekly.is_empty():
		return int(badges.get("weekly", 0))
	var n := 0
	for t in weekly.get("tasks", []):
		if t is Dictionary and QuestTile.state(t) == "done":
			n += 1
	for c in weekly.get("chests", []):
		if c is Dictionary and bool(c.get("ready", false)) and not bool(c.get("claimed", false)):
			n += 1
	return n


func _on_heading() -> void:
	if _page == PAGE_WEEK and not _weekly.is_empty():
		open_week()


## The whole week, over the tab.
func open_week() -> void:
	if _weekly.is_empty():
		await _load_weekly()
		if _weekly.is_empty():
			return
	var page: GDScript = load("res://scenes/pages/weekly_page.gd")
	page.open(self, _weekly, self)


## The touch over the tiles let go at `at` (in the touch area's space): a
## sideways drag of SWIPE_MIN turns the page toward it, anything shorter is a
## tap on the tile under the finger.
func _on_touch(at: Vector2, area: Vector2) -> void:
	var from := _swipe_from
	_swipe_from = Vector2.INF
	if from == Vector2.INF:
		return
	var d := at - from
	if absf(d.x) >= SWIPE_MIN and absf(d.x) > absf(d.y) * 1.5:
		turn_page(PAGE_WEEK if d.x < 0.0 else PAGE_TODAY)
		return
	if not Rect2(Vector2.ZERO, area).has_point(at):
		return
	var touch: Control = _ui["quests_touch"]
	var p := touch.position + at
	if _region(_ui["quests_flip"]).has_point(p):
		turn_page(1 - _page)
		return
	if _region(_ui["quests_heading"]).has_point(p):
		_on_heading()
		return
	var i := tile_at(_quest_cards, p)
	if i >= 0:
		_on_tile(i)


static func _region(n: Control) -> Rect2:
	return Rect2(n.position, n.size)


## The tile under a point in the tab's space, or -1.
static func tile_at(cards: Array, p: Vector2) -> int:
	for i in cards.size():
		var n: Control = cards[i]["node"]
		if n.visible and Rect2(n.position, n.size).has_point(p):
			return i
	return -1


func _on_tile(i: int) -> void:
	if _busy or i >= _shown.size():
		return
	var q: Dictionary = _shown[i]
	var st := QuestTile.state(q)
	if _page == PAGE_TODAY:
		if st == "done":
			_claim_quest(i)
		return
	if st == "done":
		_claim_weekly(i)
	else:
		open_week()


func _claim_quest(i: int) -> void:
	if _busy or i >= _shown.size():
		return
	var q: Dictionary = _shown[i]
	if QuestTile.state(q) != "done":
		return
	_busy = true
	var res: Api.Response = await GameState.act("/v1/quests/claim", {"slot": int(q.get("slot", i))})
	if res.ok:
		var xp := int(q.get("xp", 0))
		var gold := int(q.get("gold", 0))
		_float_reward(i, "+%s XP   +%s gold" % [UI.grouped(xp), UI.grouped(gold)])
		GameState.toast("Task done: +%s XP and +%s gold" % [UI.grouped(xp), UI.grouped(gold)])
		# The server's answer is the day's board, already claimed.
		var got: Array = res.data.get("quests", [])
		if not got.is_empty():
			_quests = got
			_paint_tiles()
		else:
			await _load_quests()
		# A day's task finished is a week's task counted.
		_load_weekly()
	_busy = false


## A week's task claimed: no action_seq -- it is paid like a letter, and its
## snapshot adopted the same way.
func _claim_weekly(i: int) -> void:
	if _busy or i >= _shown.size():
		return
	var q: Dictionary = _shown[i]
	_busy = true
	var res := await claim_weekly_task(int(q.get("slot", 0)))
	if res.ok:
		var lines: Array = res.data.get("lines", [])
		_float_reward(i, lines_words(lines, int(q.get("points", 0))))
		GameState.toast("Task done: " + lines_words(lines, int(q.get("points", 0))))
	_busy = false


## POST /v1/weekly/claim: adopts the answer's week and snapshot. Shared with the
## weekly page.
func claim_weekly_task(slot: int) -> Api.Response:
	var res: Api.Response = await Api.post_json("/v1/weekly/claim", {"slot": slot})
	_after_weekly(res)
	return res


## POST /v1/weekly/chest: the chest opened with its ceremony. Shared with the
## weekly page.
func open_chest(tier: int) -> Api.Response:
	var res: Api.Response = await Api.post_json("/v1/weekly/chest", {"tier": tier})
	_after_weekly(res)
	if res.ok:
		Ceremony.chest(self, CHEST_NAMES[clampi(tier, 0, 2)], tier, res.data.get("lines", []))
	return res


func _after_weekly(res: Api.Response) -> void:
	if res.ok:
		if res.data.get("snapshot", null) is Dictionary:
			GameState.adopt_async(res.data["snapshot"])
		if res.data.get("weekly", null) is Dictionary:
			set_weekly(res.data["weekly"])
			# The rail's count moves with the claim rather than on the next beat.
			var b := GameState.badges.duplicate()
			b["weekly"] = weekly_waiting(_weekly, {})
			GameState.set_badges(b)
		else:
			_load_weekly()
		_paint_dots()
	elif res.code == "inventory_full":
		GameState.armory_full.emit(res.error)
	else:
		GameState.action_failed.emit(res.error)
		_load_weekly()


## What a reward brought, in a few words: the server's lines, and the points.
static func lines_words(lines: Array, points: int) -> String:
	var words: Array[String] = []
	for l in lines:
		if l is Dictionary and words.size() < 2:
			words.append(str(l.get("text", "")))
	if points > 0:
		words.append("+%d points" % points)
	return ", ".join(words)


## Starts or stops the breathing of a tile whose reward is waiting.
func _pulse(i: int, on: bool) -> void:
	var icon: CanvasItem = _quest_cards[i]["parts"]["icon"]
	var running: Tween = _pulses.get(i, null)
	if on == (running != null and running.is_valid()):
		return
	if running != null:
		running.kill()
		_pulses.erase(i)
	icon.modulate = Color.WHITE
	if not on:
		return
	var t := create_tween().set_loops()
	t.tween_property(icon, "modulate", Color(1.35, 1.28, 1.05), 0.7) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	t.tween_property(icon, "modulate", Color.WHITE, 0.7) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_pulses[i] = t


## The reward rises off the tile and fades, so the tap is answered where the
## thumb is rather than only in a toast at the foot of the screen.
func _float_reward(i: int, text: String) -> void:
	var card: Control = _quest_cards[i]["node"]
	var l := UI.label(text, 26, READY, "body", 700, HORIZONTAL_ALIGNMENT_CENTER)
	l.label_settings.outline_size = 6
	l.label_settings.outline_color = Color(0.03, 0.06, 0.09, 0.9)
	UI.place(l, Rect2(card.position.x - 60.0, card.position.y + 120.0, card.size.x + 120.0, 40))
	add_child(l)
	var t := create_tween().set_parallel()
	t.tween_property(l, "position:y", l.position.y - 100.0, 1.3).set_ease(Tween.EASE_OUT)
	t.tween_property(l, "modulate:a", 0.0, 1.3).set_ease(Tween.EASE_IN)
	t.chain().tween_callback(l.queue_free)


func _seconds_to_local_midnight() -> int:
	var now := Time.get_datetime_dict_from_system()
	var passed := int(now.get("hour", 0)) * 3600 + int(now.get("minute", 0)) * 60 + int(now.get("second", 0))
	return 86400 - passed


# --- the week's chest bar -------------------------------------------------------------

func _build_bar() -> void:
	var g: Control = _ui.get("week_bar")
	if g == null:
		return
	_bar = g.get_meta("parts", {})
	for i in 3:
		var tap: BaseButton = _bar.get(CHEST_TAPS[i])
		if tap != null:
			tap.pressed.connect(_on_chest.bind(i))
		var need: Label = _bar.get(CHEST_NEEDS[i])
		if need != null:
			need.label_settings = need.label_settings.duplicate()


## How far the fill runs for `points`: to each painted marker as the points
## reach its chest, in proportion between them, and to the channel's end once
## every chest is reached. Geometry is the layout's markers and track; the
## chests' thresholds (`at`) are the server's.
static func bar_fraction(bar: Dictionary, chests: Array, points: int, points_max: int) -> float:
	var fill: Control = bar.get("fill")
	if fill == null:
		return 0.0
	var x0 := fill.position.x
	var full: float = float((fill.get_meta("full", fill.size) as Vector2).x)
	if points <= 0 or full <= 0.0:
		return 0.0
	var top := points_max
	for c in chests:
		top = maxi(top, int(c.get("at", 0)))
	if points >= top:
		return 1.0
	var prev_at := 0
	var prev_x := x0
	for i in mini(chests.size(), 3):
		var m: Control = bar.get(CHEST_MARKERS[i])
		if m == null:
			continue
		var at := int(chests[i].get("at", 0))
		var mx := m.position.x + m.size.x / 2.0
		if points <= at:
			var t := float(points - prev_at) / maxf(1.0, float(at - prev_at))
			return clampf((prev_x + t * (mx - prev_x) - x0) / full, 0.0, 1.0)
		prev_at = at
		prev_x = mx
	return clampf((prev_x - x0) / full, 0.0, 1.0)


## What a chest's plate says: what it needs, OPEN, or OPENED.
static func chest_words(c: Dictionary) -> String:
	if bool(c.get("claimed", false)):
		return "OPENED"
	if bool(c.get("ready", false)):
		return "OPEN"
	return "%s POINTS" % UI.grouped(int(c.get("at", 0)))


func paint_bar() -> void:
	if _bar.is_empty():
		return
	var chests: Array = _weekly.get("chests", [])
	Layout.set_fill(_bar["fill"], bar_fraction(_bar, chests, int(_weekly.get("points", 0)),
		int(_weekly.get("points_max", 0))))
	for i in 3:
		var c: Dictionary = chests[i] if i < chests.size() and chests[i] is Dictionary else {}
		var chest: CanvasItem = _bar.get(CHEST_PARTS[i])
		var need: Label = _bar.get(CHEST_NEEDS[i])
		var ready := bool(c.get("ready", false)) and not bool(c.get("claimed", false))
		if need != null:
			need.text = chest_words(c) if not c.is_empty() else ""
			need.label_settings.font = UI.font("title" if ready else "body", 800 if ready else 700)
			need.label_settings.font_color = READY if ready else (UI.DIM if bool(c.get("claimed", false)) else QuestTile.INK)
			UI.fit_line(need, 20, 14)
		if chest != null:
			chest.modulate = CHEST_OPENED if bool(c.get("claimed", false)) else (Color.WHITE if ready else CHEST_LOCKED)
		_chest_pulse(i, ready)


func _chest_pulse(i: int, on: bool) -> void:
	var chest: CanvasItem = _bar.get(CHEST_PARTS[i])
	if chest == null:
		return
	var running: Tween = _chest_pulses.get(i, null)
	if on == (running != null and running.is_valid()):
		return
	if running != null:
		running.kill()
		_chest_pulses.erase(i)
	if not on:
		return
	var t := create_tween().set_loops()
	t.tween_property(chest, "modulate", Color(1.3, 1.22, 1.0), 0.7).set_trans(Tween.TRANS_SINE)
	t.tween_property(chest, "modulate", Color.WHITE, 0.7).set_trans(Tween.TRANS_SINE)
	_chest_pulses[i] = t


func _on_chest(i: int) -> void:
	if _busy or _weekly.is_empty():
		return
	var chests: Array = _weekly.get("chests", [])
	if i >= chests.size():
		return
	var c: Dictionary = chests[i]
	if bool(c.get("ready", false)) and not bool(c.get("claimed", false)):
		_busy = true
		await open_chest(int(c.get("tier", i)))
		_busy = false
	else:
		open_week()


# --- the Golden Hour --------------------------------------------------------------------

func _build_golden() -> void:
	_golden = _ui.get("golden")
	if _golden == null:
		return
	_golden_parts = _golden.get_meta("parts", {})
	var under: TextureRect = _golden_parts["under"]
	var lit: TextureRect = _golden_parts["lit"]
	# The cells light over the dark wheel counter-clockwise from the top -- the
	# painting's half-lit wheel is its left half -- and burn back the other way.
	# The fill turns about the ring's centre, which is not the crop's.
	_wheel = TextureProgressBar.new()
	_wheel.texture_under = under.texture
	_wheel.texture_progress = lit.texture
	_wheel.fill_mode = TextureProgressBar.FILL_COUNTER_CLOCKWISE
	_wheel.radial_initial_angle = 0.0
	_wheel.radial_fill_degrees = 360.0
	var centre: Array = Layout.find(SCREEN, "lit").get("centre", [under.size.x / 2.0, under.size.y / 2.0])
	_wheel.radial_center_offset = Vector2(float(centre[0]), float(centre[1])) - under.size / 2.0
	_wheel.min_value = 0.0
	_wheel.max_value = 1.0
	_wheel.step = 0.0
	_wheel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UI.place(_wheel, Rect2(under.position, under.size))
	under.add_sibling(_wheel)
	under.visible = false
	lit.visible = false
	for id in ["state", "energy", "gain", "flare"]:
		var l: Label = _golden_parts.get(id)
		if l != null:
			l.label_settings = l.label_settings.duplicate()
	for id in ["gain", "flare"]:
		var l: Label = _golden_parts[id]
		l.label_settings.outline_size = 8
		l.label_settings.outline_color = Color(0.1, 0.05, 0.0, 0.92)
		l.visible = false
	for id in ["glow", "coins"]:
		var light: Control = _golden_parts[id]
		light.visible = false
		# The lights swell about their own middles, which is the wheel's.
		light.pivot_offset = light.size / 2.0
	_add_glow_blend(_golden_parts["glow"])
	_add_glow_blend(_golden_parts["coins"])
	(_golden_parts["tap"] as BaseButton).pressed.connect(_explain_golden)
	_golden.visible = false


## The ceremonies' lights are painted on navy and drawn additively.
static func _add_glow_blend(n: CanvasItem) -> void:
	var m := CanvasItemMaterial.new()
	m.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	n.material = m


## The snapshot's Golden Hour, its clocks counted down from when it was adopted.
static func golden_now(f: Dictionary, age_s: int) -> Dictionary:
	var out := f.duplicate()
	for k in ["ends_in", "ready_in", "drains_in"]:
		out[k] = maxi(0, int(f.get(k, 0)) - age_s)
	var active := bool(f.get("active", false)) and int(out["ends_in"]) > 0
	out["active"] = active
	# A meter left alone empties when its window runs out (drains_in); the
	# server's next answer says so too.
	if not active and f.has("drains_in") and int(f.get("drains_in", 0)) - age_s <= 0 and float(f.get("meter", 0.0)) > 0.0:
		out["meter"] = 0.0
	return out


## How much of the wheel is lit: the meter filling, or, while the hour burns,
## the time it has left of its whole length.
static func wheel_value(g: Dictionary) -> float:
	if bool(g.get("active", false)):
		var whole := maxi(1, int(g.get("duration", 60)))
		return clampf(float(g.get("ends_in", 0)) / float(whole), 0.0, 1.0)
	return clampf(float(g.get("meter", 0.0)), 0.0, 1.0)


## What the plate says when the hour is not burning: resting until its next
## hour, every hour of the day used, or its name while the wheel fills.
static func golden_words(g: Dictionary) -> String:
	var per_day := int(g.get("per_day", 0))
	if per_day > 0 and int(g.get("used", 0)) >= per_day:
		return "%d of %d used" % [int(g.get("used", 0)), per_day]
	if int(g.get("ready_in", 0)) > 0:
		return "Ready in " + UI.time_left(int(g.get("ready_in", 0)))
	return "Golden Hour"


## "0:42" for the hour's time left.
static func clock(seconds: int) -> String:
	return "%d:%02d" % [seconds / 60, seconds % 60]


func paint_golden() -> void:
	if _golden == null:
		return
	var f := GameState.frenzy()
	var show := not f.is_empty() and bool(f.get("unlocked", false))
	_golden.visible = show
	if not show:
		_golden_said = ""
		return
	var g := golden_now(f, GameState.live_age_s())
	var active := bool(g["active"])
	var said := "%s|%d|%d|%d|%.3f|%d" % [active, int(g["ends_in"]), int(g["ready_in"]), int(g.get("energy_left", 0)),
		float(g.get("meter", 0.0)), f.hash()]
	if said == _golden_said:
		return
	_golden_said = said
	_wheel.value = wheel_value(g)
	var resting := not active and (int(g["ready_in"]) > 0 or (int(g.get("per_day", 0)) > 0 and int(g.get("used", 0)) >= int(g.get("per_day", 0))))
	_wheel.modulate = Color(0.72, 0.72, 0.76) if resting else Color.WHITE
	_set_glow(active)
	var state: Label = _golden_parts["state"]
	var energy: Label = _golden_parts["energy"]
	var bolt: Control = _golden_parts["bolt"]
	if not active:
		state.position.x = float(state.get_meta("home_x", state.position.x))
		state.set_meta("home_x", state.position.x)
		state.size.x = float(state.get_meta("box_w", state.size.x))
		state.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		state.text = golden_words(g)
		state.label_settings.font_color = QuestTile.INK if not resting else UI.DIM
		UI.fit_line(state, GOLDEN_FIT.x, GOLDEN_FIT.y)
		energy.visible = false
		bolt.visible = false
		return
	# Burning: its time left, then the energy it still doubles, as one line
	# centred on the plate.
	state.set_meta("home_x", state.get_meta("home_x", state.position.x))
	var box_x := float(state.get_meta("home_x"))
	var box_w := float(state.get_meta("box_w", state.size.x))
	var t_text := clock(int(g["ends_in"]))
	var e_text := UI.grouped(int(g.get("energy_left", 0)))
	var font := state.label_settings.font
	var size := GOLDEN_FIT.x
	var wt := 0.0
	var we := 0.0
	var total := 0.0
	while true:
		wt = font.get_string_size(t_text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
		we = font.get_string_size(e_text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
		total = wt + GOLDEN_ENERGY_GAP + bolt.size.x + GOLDEN_BOLT_GAP + we
		if total <= box_w or size <= GOLDEN_FIT.y:
			break
		size -= 1
	var x := box_x + (box_w - total) / 2.0
	state.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	state.text = t_text
	state.label_settings.font_size = size
	state.label_settings.font_color = READY
	state.position.x = x
	state.size.x = wt + 2.0
	x += wt + GOLDEN_ENERGY_GAP
	bolt.visible = true
	bolt.position.x = x
	x += bolt.size.x + GOLDEN_BOLT_GAP
	energy.visible = true
	energy.text = e_text
	energy.label_settings.font_size = size
	energy.label_settings.font_color = READY
	energy.position.x = x
	energy.size.x = we + 2.0


## The sunburst behind the wheel while the hour burns, breathing.
func _set_glow(on: bool) -> void:
	var glow: CanvasItem = _golden_parts["glow"]
	if on == glow.visible:
		return
	glow.visible = on
	if _glow_tween != null and _glow_tween.is_valid():
		_glow_tween.kill()
	if on:
		glow.modulate.a = 0.85
		_glow_tween = create_tween().set_loops()
		_glow_tween.tween_property(glow, "modulate:a", 0.55, 0.8).set_trans(Tween.TRANS_SINE)
		_glow_tween.tween_property(glow, "modulate:a", 0.95, 0.8).set_trans(Tween.TRANS_SINE)


## A collect answer the Golden Hour touched: the words when it lights, and the
## gold it added rising from the wheel.
func _on_golden_hour(gold: int, started: bool) -> void:
	if _golden == null or not visible:
		return
	_golden_said = ""
	paint_golden()
	if started:
		_flare()
	if gold > 0:
		_burst(gold)


func _flare() -> void:
	var flare: Label = _golden_parts["flare"]
	flare.text = "GOLDEN HOUR"
	UI.fit_line(flare, 40, 26)
	flare.visible = true
	flare.modulate.a = 0.0
	var home_y := float(flare.get_meta("home_y", flare.position.y))
	flare.set_meta("home_y", home_y)
	flare.position.y = home_y + 16.0
	var glow: CanvasItem = _golden_parts["glow"]
	glow.visible = true
	var t := create_tween()
	t.set_parallel()
	t.tween_property(flare, "modulate:a", 1.0, 0.25)
	t.tween_property(flare, "position:y", home_y, 0.35).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
	t.tween_property(glow, "scale", Vector2(1.25, 1.25), 0.35).from(Vector2(0.6, 0.6))
	t.chain().tween_interval(1.8)
	t.chain().tween_property(flare, "modulate:a", 0.0, 0.5)
	t.chain().tween_callback(func() -> void:
		flare.visible = false
		glow.scale = Vector2.ONE)


func _burst(gold: int) -> void:
	var gain: Label = _golden_parts["gain"]
	var coins: CanvasItem = _golden_parts["coins"]
	gain.text = "+" + UI.grouped(gold)
	UI.fit_line(gain, 30, 20)
	gain.visible = true
	var home_y := float(gain.get_meta("home_y", gain.position.y))
	gain.set_meta("home_y", home_y)
	gain.position.y = home_y
	gain.modulate.a = 1.0
	coins.visible = true
	coins.modulate.a = 0.0
	var t := create_tween().set_parallel()
	t.tween_property(gain, "position:y", home_y - 110.0, 1.4).set_ease(Tween.EASE_OUT)
	t.tween_property(gain, "modulate:a", 0.0, 1.4).set_ease(Tween.EASE_IN)
	t.tween_property(coins, "modulate:a", 0.9, 0.15)
	t.chain().tween_property(coins, "modulate:a", 0.0, 0.6)
	t.chain().tween_callback(func() -> void:
		gain.visible = false
		coins.visible = false)


## What the wheel is, in the server's own numbers.
func _explain_golden() -> void:
	var f := GameState.frenzy()
	if f.is_empty():
		return
	await Dialog.ask(self, {"title": "The Golden Hour", "body": golden_rules(f), "confirm_text": "OK"})


static func golden_rules(f: Dictionary) -> String:
	var pct := int(f.get("bp", 0)) / 100
	var per_day := int(f.get("per_day", 0))
	var words := "Keep collecting, never more than %d seconds between one and the next, and the wheel fills. Full, it lights the Golden Hour: for %d seconds every collect pays %d%% more gold%s." % [
		int(f.get("window", 20)), int(f.get("duration", 60)), pct,
		", on up to %s energy of them" % UI.grouped(int(f.get("energy_left", 0))) if bool(f.get("active", false)) else ""]
	if per_day > 0:
		words += "\n\n%d a day" % per_day
		if int(f.get("cooldown", 0)) > 0:
			words += ", with %s of rest after each" % spoken_span(int(f.get("cooldown", 0)))
		words += ". Used today: %d." % int(f.get("used", 0))
	return words


## A span as a sentence says it: "30 minutes", "1 hour", "90 seconds".
static func spoken_span(seconds: int) -> String:
	if seconds >= 3600 and seconds % 3600 == 0:
		return "%d hour%s" % [seconds / 3600, "" if seconds == 3600 else "s"]
	if seconds >= 60 and seconds % 60 == 0:
		return "%d minute%s" % [seconds / 60, "" if seconds == 60 else "s"]
	return "%d seconds" % seconds
