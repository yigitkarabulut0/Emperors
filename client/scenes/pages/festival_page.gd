extends RefCounted
## A FESTIVAL — behind the Events page's VIEW: the festival a lord is in, whole.
##
## The Events page shows what is on; this is what it is worth and what is left
## to take in it. In the server's own figures (GET /v1/festivals `current`),
## laid out as the festival is played:
##
##  - its line: how long it has left, the points earned, the place they stand
##    at, and today's points against the day's cap -- a festival is won by
##    coming back, and the cap is what says so;
##  - its five tasks, each on the painted quest tile the day's and the week's
##    quests use, in the server's order; a tap on a finished tile claims it;
##  - its milestones, in points: what each pays, and CLAIM while one waits.
##    The last is the festival's own frame, and wears the crown;
##  - its board, as far as the server sends it, the lord's own row marked --
##    and, when they stand past the last row shown, their row after the rest;
##  - what the places pay when it closes, and how points are earned.
##
## POST /v1/festivals/claim {"kind", "index"} takes one; CLAIM ALL takes
## everything done. Not the player's sequenced action: no action_seq, the
## answer's snapshot goes through GameState.adopt_async, and what a claim paid
## plays as the Royal Delivery. What a festival still owes a lord when it
## closes comes by letter, which the foot says.

const SCREEN := "page:festival"
const CLAIM := "/v1/festivals/claim"
const TILE := "collect/week_tile"
const TILE_SIZE := Vector2(237, 222)
const COL_GAP := 18.0
const ROW_GAP := 18.0
const NAME_H := 34.0
const NAME_FIT := Vector2i(20, 14)
## A milestone's row: its points on the left, what it pays beside them, and
## its state on the right.
const MS_H := 96.0
const MS_ICON := 56.0
const MS_POINTS_W := 132.0
const MS_STATE_W := 156.0
## A board row, and how many of them the page shows before the lord's own.
const BOARD_H := 64.0
const BOARD_SHOWN := 10
const PLACE_W := 74.0
const POINTS_W := 132.0
const ROW_FIT := Vector2i(22, 15)
const LINE_ICON := 40.0
const LINE_H := 46.0
const LINE_FIT := Vector2i(18, 13)
## The lord's own row on the board, in the gold a ready chest wears.
const ME_INK := Color("#F0D27A")
## A milestone reached and taken, and one still out of reach.
const TAKEN := Color(0.62, 0.62, 0.66)
const AHEAD := Color(0.78, 0.78, 0.78)


## `f` is the festival (the answer's `current`); `view` the Events page, which
## is asked to read itself again after a claim so both show the same festival.
static func open(host: Node, f: Dictionary, view: Node = null) -> Sheet:
	var s := Sheet.open(host, str(f.get("name", "A FESTIVAL")).to_upper(), str(f.get("blurb", "")), 62, SCREEN)
	s.set_meta("festival", f)
	s.set_meta("view", view)
	s.set_meta("at_ms", Time.get_ticks_msec())
	_paint(s)
	# Its line counts the festival down while the page is open.
	var timer := Timer.new()
	timer.wait_time = 1.0
	timer.autostart = true
	timer.timeout.connect(func() -> void: _paint_line(s))
	s.add_child(timer)
	return s


static func _festival(s: Sheet) -> Dictionary:
	return s.get_meta("festival", {})


## Seconds since the festival was read: every time it carries counts down from
## then, as the snapshot's do.
static func _age(s: Sheet) -> int:
	return int((Time.get_ticks_msec() - int(s.get_meta("at_ms", 0))) / 1000)


static func _paint(s: Sheet) -> void:
	s.clear_body()
	var f := _festival(s)
	var line := s.paragraph("", 24, UI.DIM, HORIZONTAL_ALIGNMENT_CENTER)
	line.name = "FestivalLine"
	s.set_meta("line", line)
	_paint_line(s)
	var today := s.paragraph(day_line(f), 22, UI.DIM, HORIZONTAL_ALIGNMENT_CENTER)
	today.name = "FestivalDay"

	s.heading("THE FESTIVAL'S TASKS")
	_tasks(s, f)
	s.heading("WHAT THE POINTS OPEN")
	_milestones(s, f)
	if int(f.get("claimable", 0)) > 0:
		s.add_button("CLAIM ALL", "green", func() -> void: _claim(s, "", -1))
	s.heading("THE BOARD")
	_board(s, f)
	s.heading("WHAT THE PLACES PAY")
	_ranks(s, f)
	s.heading("HOW POINTS ARE EARNED")
	_sources(s, f)
	s.paragraph("The board is paid when the festival closes, by letter -- and with it anything you have "
		+ "reached here and not taken.", 21, UI.DIM)
	s.add_close()


## "Ends in 2d 04h · 640 points · 3rd of 128 lords" -- and, before it begins,
## when it does.
static func festival_line(f: Dictionary, age_s: int) -> String:
	var parts: Array = []
	if not bool(f.get("running", false)) and int(f.get("starts_in", 0)) > 0:
		parts.append("Begins in " + UI.time_left(maxi(0, int(f.get("starts_in", 0)) - age_s)))
	else:
		parts.append("Ends in " + UI.time_left(maxi(0, int(f.get("ends_in", 0)) - age_s)))
	parts.append("%s point%s" % [UI.grouped(int(f.get("points", 0))), "" if int(f.get("points", 0)) == 1 else "s"])
	var place := int(f.get("place", 0))
	if place > 0:
		var lords := int(f.get("lords", 0))
		parts.append("%s of %s" % [UI.ordinal(place), UI.grouped(maxi(lords, place))])
	return "  ·  ".join(parts)


## "Day 2 of 3 · 320 of today's 600 points": what a day may still earn, so the
## cap is never a surprise.
static func day_line(f: Dictionary) -> String:
	var cap := int(f.get("day_cap", 0))
	var out := "Day %d of %d" % [int(f.get("day", 0)), int(f.get("days", 0))]
	if cap > 0:
		out += "  ·  %s of today's %s points" % [UI.grouped(int(f.get("day_points", 0))), UI.grouped(cap)]
	return out


static func _paint_line(s: Sheet) -> void:
	var line: Variant = s.get_meta("line") if s.has_meta("line") else null
	if line is Label and is_instance_valid(line):
		(line as Label).text = festival_line(_festival(s), _age(s))


## The five tasks, three to a row, each on the quest tile the day's and the
## week's quests use.
static func _tasks(s: Sheet, f: Dictionary) -> void:
	var tasks: Array = f.get("tasks", [])
	var cols := 3
	var rows := int(ceil(tasks.size() / float(cols)))
	var grid := Control.new()
	grid.name = "Tasks"
	grid.mouse_filter = Control.MOUSE_FILTER_PASS
	var cell_h := NAME_H + TILE_SIZE.y
	grid.custom_minimum_size = Vector2(s.inner_w, rows * cell_h + maxi(0, rows - 1) * ROW_GAP)
	s.body.add_child(grid)
	var x0 := (s.inner_w - (cols * TILE_SIZE.x + (cols - 1) * COL_GAP)) / 2.0
	var tpl := Layout.element("collect", "quest_card")
	for i in tasks.size():
		var q: Dictionary = tasks[i] if tasks[i] is Dictionary else {}
		var at := Vector2(x0 + (i % cols) * (TILE_SIZE.x + COL_GAP), (i / cols) * (cell_h + ROW_GAP))
		var name := UI.label(str(q.get("name", "")).to_upper(), NAME_FIT.x, UI.GOLD, "title", 700,
			HORIZONTAL_ALIGNMENT_CENTER)
		UI.place(name, Rect2(at, Vector2(TILE_SIZE.x, NAME_H)))
		name.set_meta("box_w", TILE_SIZE.x)
		grid.add_child(name)
		UI.fit_line(name, NAME_FIT.x, NAME_FIT.y)
		var tile := UI.image(TILE, Rect2(at + Vector2(0, NAME_H), TILE_SIZE))
		tile.name = "Tile%d" % i
		grid.add_child(tile)
		var built := Layout.instantiate(tpl)
		built["node"].position = tile.position
		grid.add_child(built["node"])
		var st := QuestTile.paint_festival(built["parts"], q)
		if st == "claimed":
			tile.modulate = QuestTile.CLAIMED_TINT
			built["node"].modulate = QuestTile.CLAIMED_TINT
		var hit := UI.hotspot(Rect2(tile.position, TILE_SIZE), true)
		hit.pressed.connect(func() -> void: _on_task(s, q))
		grid.add_child(hit)


static func _on_task(s: Sheet, q: Dictionary) -> void:
	match QuestTile.state(q):
		"done":
			await _claim(s, "task", int(q.get("index", 0)))
		"claimed":
			GameState.toast("Taken already.")
		_:
			GameState.toast("%s: %s of %s" % [str(q.get("short", q.get("name", ""))),
				UI.grouped(int(q.get("progress", 0))), UI.grouped(int(q.get("target", 0)))])


## The milestones, in the points they open at: what each pays, and its state.
static func _milestones(s: Sheet, f: Dictionary) -> void:
	var points := int(f.get("points", 0))
	for m in f.get("milestones", []):
		if not (m is Dictionary):
			continue
		var reached := bool(m.get("reached", false))
		var claimed := bool(m.get("claimed", false))
		var row := s.slot(MS_H)
		var at := UI.label("%s points" % UI.grouped(int(m.get("at", 0))), ROW_FIT.x,
			UI.GOLD if reached else AHEAD, "title", 800)
		UI.place(at, Rect2(16, (MS_H - 34.0) / 2.0, MS_POINTS_W, 34))
		at.set_meta("box_w", MS_POINTS_W)
		row.add_child(at)
		UI.fit_line(at, ROW_FIT.x, ROW_FIT.y)
		if bool(m.get("crown", false)):
			var crown := UI.image("icons/reward_crown", Rect2(16, 8, 26, 26))
			crown.modulate = UI.GOLD if reached else AHEAD
			row.add_child(crown)
		var x := 16.0 + MS_POINTS_W + 12.0
		var w := s.inner_w - x - MS_STATE_W - 16.0
		_lines(row, Vector2(x, (MS_H - LINE_H * maxi(1, (m.get("lines", []) as Array).size())) / 2.0), w,
			m.get("lines", []), TAKEN if claimed else (Color.WHITE if reached else AHEAD))
		var state := UI.label(_ms_state(reached, claimed), ROW_FIT.x,
			ME_INK if (reached and not claimed) else (TAKEN if claimed else AHEAD), "title", 700,
			HORIZONTAL_ALIGNMENT_RIGHT)
		UI.place(state, Rect2(s.inner_w - MS_STATE_W - 16.0, (MS_H - 34.0) / 2.0, MS_STATE_W, 34))
		state.set_meta("box_w", MS_STATE_W)
		row.add_child(state)
		UI.fit_line(state, ROW_FIT.x, ROW_FIT.y)
		if reached and not claimed:
			var hit := UI.hotspot(Rect2(0, 0, s.inner_w, MS_H), true)
			hit.pressed.connect(func() -> void: _claim(s, "milestone", int(m.get("index", 0))))
			row.add_child(hit)


static func _ms_state(reached: bool, claimed: bool) -> String:
	if claimed:
		return "TAKEN"
	return "CLAIM" if reached else "NOT YET"


## The board: the places the server sends, the lord's own marked -- and their
## own row after the rest when they stand past the last one shown.
static func _board(s: Sheet, f: Dictionary) -> void:
	var board: Array = f.get("board", [])
	if board.is_empty():
		s.paragraph("Nobody has earned a point yet. The first to work at the festival takes the first place.",
			22, UI.DIM)
		return
	var mine := -1
	for i in board.size():
		if board[i] is Dictionary and bool((board[i] as Dictionary).get("me", false)):
			mine = i
	var shown := mini(board.size(), BOARD_SHOWN)
	for i in shown:
		_board_row(s, board[i])
	if mine >= shown:
		s.paragraph("…", 20, UI.DIM, HORIZONTAL_ALIGNMENT_CENTER)
		_board_row(s, board[mine])


static func _board_row(s: Sheet, r: Variant) -> void:
	if not (r is Dictionary):
		return
	var row: Dictionary = r
	var me := bool(row.get("me", false))
	var slot := s.slot(BOARD_H)
	var ink := ME_INK if me else UI.INK
	var place := UI.label(UI.ordinal(int(row.get("place", 0))), ROW_FIT.x, ink, "title", 800,
		HORIZONTAL_ALIGNMENT_RIGHT)
	UI.place(place, Rect2(8, (BOARD_H - 30.0) / 2.0, PLACE_W, 30))
	place.set_meta("box_w", PLACE_W)
	slot.add_child(place)
	UI.fit_line(place, ROW_FIT.x, ROW_FIT.y)
	var x := 8.0 + PLACE_W + 14.0
	var w := s.inner_w - x - POINTS_W - 16.0
	var name := UI.label(str(row.get("name", "")), ROW_FIT.x, ink, "body", 700)
	UI.place(name, Rect2(x, (BOARD_H - 30.0) / 2.0, w, 30))
	name.set_meta("box_w", w)
	slot.add_child(name)
	UI.fit_line(name, ROW_FIT.x, ROW_FIT.y)
	var pts := UI.label(UI.grouped(int(row.get("points", 0))), ROW_FIT.x, ink, "title", 700,
		HORIZONTAL_ALIGNMENT_RIGHT)
	UI.place(pts, Rect2(s.inner_w - POINTS_W - 16.0, (BOARD_H - 30.0) / 2.0, POINTS_W, 30))
	pts.set_meta("box_w", POINTS_W)
	slot.add_child(pts)
	UI.fit_line(pts, ROW_FIT.x, ROW_FIT.y)


## What each run of places pays when the festival closes.
static func _ranks(s: Sheet, f: Dictionary) -> void:
	for r in f.get("ranks", []):
		if not (r is Dictionary):
			continue
		var lines: Array = r.get("lines", [])
		var h := maxf(BOARD_H, LINE_H * lines.size() + 18.0)
		var row := s.slot(h)
		var where := UI.label(places_words(int(r.get("from", 0)), int(r.get("to", 0))), ROW_FIT.x, UI.GOLD,
			"title", 700)
		UI.place(where, Rect2(16, (h - 30.0) / 2.0, MS_POINTS_W + 40.0, 30))
		where.set_meta("box_w", MS_POINTS_W + 40.0)
		row.add_child(where)
		UI.fit_line(where, ROW_FIT.x, ROW_FIT.y)
		var x := 16.0 + MS_POINTS_W + 52.0
		_lines(row, Vector2(x, (h - LINE_H * maxi(1, lines.size())) / 2.0), s.inner_w - x - 16.0, lines, Color.WHITE)


## "1st", "2nd to 3rd", "11th to 50th".
static func places_words(from: int, to: int) -> String:
	if from >= to:
		return UI.ordinal(from)
	return "%s to %s" % [UI.ordinal(from), UI.ordinal(to)]


## How points are earned, in the server's own words.
static func _sources(s: Sheet, f: Dictionary) -> void:
	for src in f.get("sources", []):
		if not (src is Dictionary):
			continue
		var row := s.slot(BOARD_H)
		var mark := str(QuestTile.WEEKLY_ICON.get(str(src.get("icon", "")), "icons/quest_scroll_lg"))
		var pic := UI.image(mark, Rect2(14, (BOARD_H - 44.0) / 2.0, 44, 44))
		row.add_child(pic)
		var x := 14.0 + 44.0 + 14.0
		var w := s.inner_w - x - POINTS_W - 16.0
		var what := UI.label(str(src.get("text", "")), ROW_FIT.x, UI.INK, "body", 600)
		UI.place(what, Rect2(x, (BOARD_H - 30.0) / 2.0, w, 30))
		what.set_meta("box_w", w)
		row.add_child(what)
		UI.fit_line(what, ROW_FIT.x, ROW_FIT.y)
		var pts := UI.label("+%s" % UI.grouped(int(src.get("points", 0))), ROW_FIT.x, UI.GOLD, "title", 800,
			HORIZONTAL_ALIGNMENT_RIGHT)
		UI.place(pts, Rect2(s.inner_w - POINTS_W - 16.0, (BOARD_H - 30.0) / 2.0, POINTS_W, 30))
		pts.set_meta("box_w", POINTS_W)
		row.add_child(pts)
		UI.fit_line(pts, ROW_FIT.x, ROW_FIT.y)


## A reward's lines, one under another: the picture, and the server's words.
static func _lines(row: Control, at: Vector2, width: float, lines: Array, tint: Color) -> void:
	for i in lines.size():
		var l: Dictionary = lines[i] if lines[i] is Dictionary else {}
		var y := at.y + i * LINE_H
		var icon := TextureRect.new()
		icon.texture = Art.reward_line_icon(l)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		icon.modulate = tint
		UI.place(icon, Rect2(at.x, y + (LINE_H - LINE_ICON) / 2.0, LINE_ICON, LINE_ICON))
		row.add_child(icon)
		ItemGround.for_line(icon, l, Rect2(icon.position, icon.size))
		var words := UI.label(str(l.get("text", "")), LINE_FIT.x, UI.INK, "body", 600)
		words.modulate = tint
		UI.place(words, Rect2(at.x + LINE_ICON + 8.0, y, width - LINE_ICON - 8.0, LINE_H))
		words.set_meta("box_w", width - LINE_ICON - 8.0)
		row.add_child(words)
		UI.fit_line(words, LINE_FIT.x, LINE_FIT.y)


## Claims one task or milestone, or (index below zero) everything done.
##
## Asynchronous, as every claim of this wave is: no action_seq, the snapshot is
## adopted, and the page and the Events under it are read again from the
## answer so both show the same festival.
static func _claim(s: Sheet, kind: String, index: int) -> void:
	if bool(s.get_meta("busy", false)):
		return
	s.set_meta("busy", true)
	var body := {} if index < 0 else {"kind": kind, "index": index}
	var res: Api.Response = await Api.post_json(CLAIM, body)
	s.set_meta("busy", false)
	if not is_instance_valid(s):
		return
	if res.ok:
		if res.data.get("snapshot", null) is Dictionary:
			GameState.adopt_async(res.data["snapshot"])
		var ev: Variant = res.data.get("events", null)
		if ev is Dictionary:
			_adopt(s, ev)
		var lines: Array = res.data.get("lines", [])
		if not lines.is_empty():
			var shell := s.get_tree().get_first_node_in_group("shell")
			Ceremony.delivery(shell if shell != null else s, {"title": str(_festival(s).get("name", "")).to_upper(),
				"lines": lines})
		return
	match res.code:
		"inventory_full":
			await Armory.refused(s, res.error, Armory.sentence(res.error)
				+ " The festival's gear waits; sell or wear something, then claim it.")
		"nothing_to_claim", "already_claimed", "no_festival":
			GameState.toast(res.error)
		_:
			GameState.action_failed.emit(res.error)
	# A refusal may mean the page is behind the server: read it again.
	var again: Api.Response = await Api.get_json("/v1/festivals")
	if again.ok and is_instance_valid(s):
		_adopt(s, again.data)


## Takes a fresh /v1/festivals answer: this page's festival, and the Events
## page under it, so one answer paints both.
static func _adopt(s: Sheet, ev: Dictionary) -> void:
	var view: Variant = s.get_meta("view") if s.has_meta("view") else null
	if view is Node and is_instance_valid(view) and (view as Node).has_method("paint"):
		(view as Node).call("paint", ev)
	var cur: Variant = ev.get("current", null)
	if cur is Dictionary:
		s.set_meta("festival", cur)
		s.set_meta("at_ms", Time.get_ticks_msec())
		_paint(s)
	else:
		s.close()
