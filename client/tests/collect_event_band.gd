extends SceneTree
## The Crown's live event on the Collect tab: a band between the header and the
## quests while one runs (snapshot.live), saying the event, what it is worth to
## this lord and its time left; the quests and the job list stand the band's
## height lower while it shows, and exactly where they were when it does not.
## The server has run events for months and no screen said so.
##
## Run: godot --headless --path client --script tests/collect_event_band.gd
##
## The Collect tab and LiveEvents are loaded at run time, never named as
## classes here: a class named in this script compiles before the autoloads
## exist.

## The plates' insides on the cut band (collect/event_band.png, measured between
## the frame lines): the name and worth block is centred on the name plate, the
## time on the time plate.
const NAME_PLATE := Rect2(364, 57, 188, 58)
const TIME_PLATE := Rect2(604, 84, 103, 31)
const NAME_PLATE_MID := 85.5
const TIME_PLATE_MID := 99.0
const SLACK := 3.0
## The band's ink (the layout's worth colour) and the game's red (UI.RED).
const INK := Color("#F1E9DA")
const UI_RED := Color("#F0524F")

var _fails := 0
var _checked := 0


func _initialize() -> void:
	await process_frame
	root.get_node("Env").set("api_base_url", "http://127.0.0.1:9")
	var spec: Dictionary = (load("res://scripts/ui/layout.gd") as GDScript).call("element", "collect", "event_band")
	if spec.is_empty():
		print("FAIL  the Collect layout has no event band: a live event is never shown")
		quit(1)
		return
	for canvas in [Vector2i(941, 1672), Vector2i(941, 2040)]:
		await _canvas(canvas, spec)
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d checks: the band shows only while an event runs, says it true, and moves the list its own height" % _checked)
	quit()


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)


func _expect(cond: bool, msg: String) -> void:
	_checked += 1
	if not cond:
		_fail(msg)


func _snapshot(live: Dictionary) -> Dictionary:
	return {"player": {"level": 30, "gold": "1", "action_seq": 1}, "jobs": [], "energy": {}, "live": live}


func _canvas(canvas: Vector2i, spec: Dictionary) -> void:
	var vp := SubViewport.new()
	vp.size = canvas
	root.add_child(vp)
	root.get_node("Nav").set("host", vp)
	var gs: Node = root.get_node("GameState")
	gs.call("adopt", _snapshot({}))
	var tab: Control = (load("res://scenes/tabs/collect.gd") as GDScript).new()
	tab.size = Vector2(canvas)
	vp.add_child(tab)
	await process_frame
	var tag := "%dx%d" % [canvas.x, canvas.y]
	if not tab.has_method("paint_band"):
		_fail("%s: the Collect tab has no event band" % tag)
		vp.queue_free()
		return
	var ui: Dictionary = tab.get("_ui")
	var band: Control = ui["event_band"]
	var parts: Dictionary = band.get_meta("parts")
	var panel: Control = ui["quests_panel"]
	var reset: Control = ui["quests_reset"]
	var cards: Array = ui["quest_card"]
	var list: Control = ui["job_list"]
	var shift := float(spec.get("shift", 0))
	var home_panel := panel.position.y
	var home_card := (cards[0]["node"] as Control).position.y
	# Everything collect_events.png paints between the band and the jobs moves
	# with the panel: the heading, its line, the dots, the touch over the tiles
	# and the week's chest bar.
	var block := {}
	for id in ["quests_title", "page_dot_0", "page_dot_1", "quests_touch", "week_bar"]:
		if ui.has(id):
			block[id] = (ui[id] as Control).position.y
	var home_top := list.offset_top
	await process_frame
	var home_bottom := list.position.y + list.size.y

	# Nothing running: no band, and everything where the layout has it.
	tab.call("paint_band")
	_expect(not band.visible, "%s: a band shows with nothing running" % tag)
	_expect(panel.position.y == home_panel and list.offset_top == home_top,
		"%s: with nothing running the quests or the list moved" % tag)

	# One event: the band, its words, and the rest moved exactly its shift.
	gs.call("adopt", _snapshot({"boosts": [{"bucket": "xp_bp", "bp": 5000, "effective_bp": 5000, "ends_in": 8040}]}))
	tab.call("paint_band")
	await process_frame
	_expect(band.visible, "%s: a running event shows no band" % tag)
	_expect((parts["name"] as Label).text == "EXPERIENCE", "%s: the band names %s, not EXPERIENCE" % [tag, (parts["name"] as Label).text])
	_expect((parts["worth"] as Label).text == "+50% for you", "%s: the band says %s, not +50%% for you" % [tag, (parts["worth"] as Label).text])
	_expect((parts["time"] as Label).text == "2h 14m", "%s: the band's time is %s, not 2h 14m" % [tag, (parts["time"] as Label).text])
	_expect(absf(panel.position.y - home_panel - shift) < 0.01 and absf(reset.position.y - _layout_y("quests_reset") - shift) < 0.01,
		"%s: the quests panel moved %.0f, not the band's %.0f" % [tag, panel.position.y - home_panel, shift])
	_expect(absf((cards[0]["node"] as Control).position.y - home_card - shift) < 0.01, "%s: the quest cards did not move with their panel" % tag)
	for id in block:
		_expect(absf((ui[id] as Control).position.y - float(block[id]) - shift) < 0.01, "%s: the %s did not move with the panel" % [tag, id])
	_expect(block.size() == 5, "%s: the Collect tab has no week's chest bar or quests pager" % tag)
	_expect(absf(list.offset_top - home_top - shift) < 0.01, "%s: the job list's top moved %.0f, not %.0f" % [tag, list.offset_top - home_top, shift])
	await process_frame
	_expect(absf(list.position.y + list.size.y - home_bottom) < 0.5, "%s: the job list's bottom left the screen's foot" % tag)
	# The band stands between the header and the quests, clear of both.
	_expect(band.position.y >= 280.0 and band.position.y + band.size.y + 8.0 <= panel.position.y + 5.0,
		"%s: the band (%.0f..%.0f) runs into the quests panel's rim at %.0f" % [tag, band.position.y, band.position.y + band.size.y, panel.position.y + 5.0])
	_centred(parts, tag)

	# A second event starts: the next snapshot says so at once, though the one
	# shown has the same seconds left as a moment ago.
	gs.call("adopt", _snapshot({"boosts": [
		{"bucket": "xp_bp", "bp": 5000, "effective_bp": 5000, "ends_in": 8040},
		{"bucket": "luck_bp", "bp": 2000, "effective_bp": 2000, "ends_in": 90000}]}))
	tab.call("paint_band")
	_expect((parts["name"] as Label).text == "EXPERIENCE" and (parts["more"] as Label).text == " · 1 more",
		"%s: a new snapshot's second event went unsaid (%s)" % [tag, (parts["more"] as Label).text])

	# Two running: the one that ends first, and the other said when it fits.
	gs.call("adopt", _snapshot({"boosts": [
		{"bucket": "collect_income_bp", "bp": 5000, "effective_bp": 5000, "ends_in": 90000},
		{"bucket": "luck_bp", "bp": 2000, "effective_bp": 2000, "ends_in": 1200}]}))
	tab.call("paint_band")
	_expect((parts["name"] as Label).text == "FORTUNE", "%s: of two, the band shows %s, not the one ending first" % [tag, (parts["name"] as Label).text])
	_expect((parts["worth"] as Label).text + (parts["more"] as Label).text == "+20% for you · 1 more",
		"%s: the second event is not said (%s%s)" % [tag, (parts["worth"] as Label).text, (parts["more"] as Label).text])
	_fits(parts, tag + " two events")
	_centred(parts, tag + " two events")
	# The longest worth the band can be asked for gives up its "more", not its figure.
	gs.call("adopt", _snapshot({"boosts": [
		{"bucket": "collect_income_bp", "bp": -1250, "effective_bp": -1250, "ends_in": 600},
		{"bucket": "xp_bp", "bp": 5000, "effective_bp": 5000, "ends_in": 900},
		{"bucket": "luck_bp", "bp": 5000, "effective_bp": 5000, "ends_in": 900}]}))
	tab.call("paint_band")
	_expect((parts["worth"] as Label).text == "-12.5% for you", "%s: a long worth lost its figure (%s)" % [tag, (parts["worth"] as Label).text])
	# The loss in red, the others' count in the band's ink: they are not losses.
	var tail := parts["more"] as Label
	_expect((parts["worth"] as Label).label_settings.font_color == UI_RED and tail.visible and tail.text == " · 2 more"
		and tail.label_settings.font_color == INK,
		"%s: beside a red loss the other events read \"%s\" in %s" % [tag, tail.text, tail.label_settings.font_color])
	_fits(parts, tag + " a long worth")
	_centred(parts, tag + " a long worth")
	gs.call("adopt", _snapshot({"boosts": [
		{"bucket": "collect_income_bp", "bp": 5000, "effective_bp": 5000, "ends_in": 90000},
		{"bucket": "luck_bp", "bp": 2000, "effective_bp": 2000, "ends_in": 1200}]}))
	tab.call("paint_band")
	# A tap lists both, each saying what it moves: Fortune is not a collect's.
	var body: String = tab.call("events_body", gs.call("live"), 0)
	_expect(body == "Fortune +20% · 20m 00s left\n+20% for you, on the shop's stock and your recruits."
		+ "\n\nJob payout +50% · 1d 01h left\n+50% for you, on the gold of every collect.",
		"%s: the events dialog reads:\n%s" % [tag, body])

	# The lord's figure, never the event's own: another timed bonus lifts it,
	# and one cancelled by a nerf in its bucket promises nothing it does not pay.
	gs.call("adopt", _snapshot({"boosts": [{"bucket": "xp_bp", "bp": 5000, "effective_bp": 7000, "ends_in": 600}]}))
	tab.call("paint_band")
	_expect((parts["worth"] as Label).text == "+70% for you", "%s: the band says %s, not the lord's +70%%" % [tag, (parts["worth"] as Label).text])
	gs.call("adopt", _snapshot({"boosts": [{"bucket": "xp_bp", "bp": 5000, "effective_bp": 0, "ends_in": 600}]}))
	tab.call("paint_band")
	_expect((parts["worth"] as Label).text == "+0% for you", "%s: an event worth nothing to this lord says %s" % [tag, (parts["worth"] as Label).text])
	_fits(parts, tag + " cancelled")

	# A nerf, in red; a month-long event's time in its plate.
	gs.call("adopt", _snapshot({"boosts": [{"bucket": "collect_income_bp", "bp": -2500, "effective_bp": -2500, "ends_in": 30 * 86400}]}))
	tab.call("paint_band")
	var worth := parts["worth"] as Label
	_expect(worth.text == "-25% for you" and worth.label_settings.font_color == UI_RED and not (parts["more"] as Label).visible,
		"%s: a nerf reads %s, not -25%% for you in red" % [tag, worth.text])
	_expect((parts["time"] as Label).text == "30d 00h", "%s: a month-long event says %s" % [tag, (parts["time"] as Label).text])
	_fits(parts, tag + " a month")
	# The nerf over, the next event's worth is in the band's own ink again.
	gs.call("adopt", _snapshot({"boosts": [{"bucket": "luck_bp", "bp": 1000, "effective_bp": 1000, "ends_in": 600}]}))
	tab.call("paint_band")
	_expect(worth.label_settings.font_color == INK, "%s: after a nerf the worth stays red" % tag)

	# Only announced: no band (the painting has no quieter state), everything home.
	gs.call("adopt", _snapshot({"boosts": [], "upcoming": [{"bucket": "xp_bp", "bp": 5000, "effective_bp": 5000, "starts_in": 3600, "ends_in": 10800}]}))
	tab.call("paint_band")
	_expect(not band.visible and panel.position.y == home_panel and list.offset_top == home_top,
		"%s: an event only announced shows a band, or left the list moved" % tag)
	body = tab.call("events_body", gs.call("live"), 0)
	_expect(body == "Coming in 1h 00m: Experience +50%.", "%s: an announced event reads: %s" % [tag, body])
	_expect(tab.call("events_body", {}, 0) == "", "%s: with nothing live the dialog has words" % tag)

	vp.queue_free()
	await process_frame


## A layout element's y, for the reset line's home.
func _layout_y(id: String) -> float:
	var e: Dictionary = (load("res://scripts/ui/layout.gd") as GDScript).call("element", "collect", id)
	return float((e.get("rect", [0, 0]) as Array)[1])


## Every word inside its box at its fitted size: nothing cut by an ellipsis.
func _fits(parts: Dictionary, tag: String) -> void:
	for id in ["name", "worth", "time"]:
		var l := parts[id] as Label
		var s := l.label_settings
		var w := s.font.get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, s.font_size).x
		_expect(w <= float(l.get_meta("box_w", l.size.x)) + 0.5 and s.font_size >= 13,
			"%s: %s \"%s\" is %.0f wide at %d in a %.0f box" % [tag, id, l.text, w, s.font_size, float(l.get_meta("box_w", l.size.x))])


## The name and worth, one block, centred on the name plate; the time on its own.
func _centred(parts: Dictionary, tag: String) -> void:
	var name := parts["name"] as Label
	var worth := parts["worth"] as Label
	var time := parts["time"] as Label
	var block_mid := (name.position.y + worth.position.y + worth.get_minimum_size().y) / 2.0
	_expect(absf(block_mid - NAME_PLATE_MID) <= SLACK, "%s: the name and worth sit %.1f off the name plate's middle" % [tag, block_mid - NAME_PLATE_MID])
	var time_mid := time.position.y + time.get_minimum_size().y / 2.0
	_expect(absf(time_mid - TIME_PLATE_MID) <= SLACK, "%s: the time sits %.1f off its plate's middle" % [tag, time_mid - TIME_PLATE_MID])
	# Across: the name's box centred on its plate's inside and clear of its
	# frame; the worth line's ink -- the figure and the tail as one -- centred
	# the same, the tail standing right after the figure.
	var box := Rect2(name.position, Vector2(float(name.get_meta("box_w", name.size.x)), name.size.y))
	_expect(absf(box.get_center().x - NAME_PLATE.get_center().x) <= 1.0
		and box.position.x >= NAME_PLATE.position.x + 8.0 and box.end.x <= NAME_PLATE.end.x - 8.0,
		"%s: the name box (x %.0f..%.0f) is off the name plate's inside or on its frame" % [tag, box.position.x, box.end.x])
	var tail := parts["more"] as Label
	var f := worth.label_settings.font
	var w_base := f.get_string_size(worth.text, HORIZONTAL_ALIGNMENT_LEFT, -1, worth.label_settings.font_size).x
	var w_rest := f.get_string_size(tail.text, HORIZONTAL_ALIGNMENT_LEFT, -1, tail.label_settings.font_size).x if tail.visible else 0.0
	var line := Rect2(worth.position.x, worth.position.y, w_base + w_rest, worth.size.y)
	_expect(absf(line.get_center().x - NAME_PLATE.get_center().x) <= 1.0
		and line.position.x >= NAME_PLATE.position.x + 8.0 and line.end.x <= NAME_PLATE.end.x - 8.0,
		"%s: the worth line (x %.1f..%.1f) is off the name plate's middle or on its frame" % [tag, line.position.x, line.end.x])
	if tail.visible:
		_expect(absf(tail.position.x - (worth.position.x + w_base)) <= 0.5 and tail.position.y == worth.position.y
			and tail.label_settings.font_size == worth.label_settings.font_size,
			"%s: the tail stands at %.1f, not right after the figure at %.1f" % [tag, tail.position.x, worth.position.x + w_base])
	var tbox := Rect2(time.position, Vector2(float(time.get_meta("box_w", time.size.x)), time.size.y))
	_expect(absf(tbox.get_center().x - TIME_PLATE.get_center().x) <= 1.0,
		"%s: the time box (x %.0f..%.0f) is off its plate's middle" % [tag, tbox.position.x, tbox.end.x])
