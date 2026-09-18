extends RefCounted
## RANKINGS — the lords of the realm, for all time and over the week and the
## season. Painted: art/reference/rankings.png, cut by art/slices/rankings.json
## and laid out by layout/rankings.json on the painted pages' host (PaintedPage).
##
## The painting gives the boards a hall: two rows of the game's tab plates
## (TabStrip), the first three on a podium of silver, gold and bronze rings, the
## rest of the hundred as rows in the list panel, and the asker's own place in
## YOUR RANK.
##
## The second row is the period: THIS WEEK / SEASON / ALL TIME. The first row
## is the boards the server keeps for that period (GET /v1/leaderboards/{board}
## lists them all in `boards`, each with its name and period): MIGHT / LEVEL /
## WEALTH for all time, RAIDS / EXPERIENCE for the week, RENOWN / RAIDS /
## EXPERIENCE / MIGHT for the season -- each chip the board name's first word.
## The week's and the season's words have no painted plates yet, so their strip
## sets them in type on the plates with no word (TabStrip).
##
## A board that closes (the week's and the season's) heads its list with a
## prize row: its name, how long it has left (`ends_in`, counted down from the
## answer's moment), and what its places pay (`rewards`), paid by letter when it
## closes. Lords level on such a board share a place: the answer's `rank` says
## so, and a row shows the place it is given, podium included.
##
## Every lord looks as they look everywhere (scripts/ui/look.gd): their face
## (Art.avatar) in the frame they wear -- the season's nobles in theirs -- their
## name in their colour with the seal at the plate's right end when they have
## one, the title they wear under it. The server sends each lord's look on every
## row (`worn`, `vip_seal`).
##
## Opened from the profile page; `opts.board` opens on a board (the dev pages
## ranks_week and ranks_season).

const PAGE := "rankings"
## The periods as the painted row names them, and the server's word for each.
const PERIODS := ["this_week", "season", "all_time"]
const PERIOD_OF := {"week": "this_week", "season": "season", "all": "all_time"}
## The boards kept for all time, before an answer has listed them all: the
## page opens on these.
const STANDING := [{"id": "might", "name": "Might", "period": "all"}, {"id": "level", "name": "Level", "period": "all"},
	{"id": "wealth", "name": "Wealth", "period": "all"}]

## The podium's round windows: centre and diameter, measured off the painting.
const PODIUM := [[Vector2(470, 529), 132.0], [Vector2(221, 557), 114.0], [Vector2(718.5, 575.5), 111.0]]
## A face inside a worn frame fills the frame's own window: three quarters of
## the band the frame covers.
const FACE_IN_FRAME := 0.78
## The painted rings round a row's face and YOUR RANK's, outer size: a worn
## ring's band covers them.
const ROW_RING := 79.0
const YOU_RING := 87.0
## A row of the list: the painted row, its pitch, and its parts in its own space.
const ROW := "rankings/row"
const ROW_PITCH := 95.0
const ROW_TOP := 4.0
const ROW_X := 2.0
const ROW_SIZE := Vector2(850, 89)
const ROW_RANK := Rect2(34, 18, 76, 53)
const ROW_FACE := [Vector2(175.5, 44), 68.0]
const ROW_NAME := Rect2(246, 16, 262, 32)
const ROW_SUB := Rect2(247, 54, 158, 24)
const ROW_VALUE := Rect2(604, 16, 213, 58)
## YOUR RANK's round window.
const YOU_FACE := [Vector2(242, 1427), 76.0]

## The prize row: the painted row with its plates lifted (rankings/row_plain),
## its name and time on the left, and a cell per run of places on the right --
## the places above, the prize's picture and figure below.
const PRIZE_ROW := "rankings/row_plain"
const PRIZE_NAME := Rect2(30, 13, 290, 34)
const PRIZE_TIME := Rect2(31, 49, 290, 27)
const PRIZE_CELLS := Rect2(330, 8, 500, 73)
const PRIZE_PLACE_H := 30.0
const PRIZE_ICON := 34.0


## `opts` go to the host (a test's "inset"); `opts.board` opens on a board.
static func open(host: Node, opts: Dictionary = {}) -> Control:
	var p := PaintedPage.open(host, PAGE, opts)
	var board := str(opts.get("board", "might"))
	p.set_meta("board", board)
	p.set_meta("chips", STANDING.duplicate(true))
	p.set_meta("period", _guess_period(board))
	var periods := TabStrip.make(PERIODS, Layout.rect_of(Layout.find(PAGE, "periods")), str(p.get_meta("period")))
	p.place(periods, Layout.rect_of(Layout.find(PAGE, "periods")))
	periods.changed.connect(func(id: String) -> void: _choose_period(p, id))
	p.set_meta("periods", periods)
	_open_periods(p)
	_build_boards(p)
	_load(p)
	return p


static func _load(p: PaintedPage) -> void:
	var board := str(p.get_meta("board"))
	_clear(p)
	_notice(p, "Reading the rolls...", UI.DIM, ROW_TOP + 36.0)
	var res: Api.Response = await Api.get_json("/v1/leaderboards/%s" % board)
	if not is_instance_valid(p) or str(p.get_meta("board")) != board:
		return
	_clear(p)
	if not res.ok:
		_notice(p, "The rankings could not be read. " + res.error, UI.RED, ROW_TOP + 36.0)
		_you(p, {}, board)
		return
	paint(p, res.data, board)


## Fills the page from one board's answer. Separate from the load so a test can
## hand it the hard cases.
static func paint(p: PaintedPage, d: Dictionary, board: String) -> void:
	_clear(p)
	# The boards the server keeps, when the answer lists them: the chips follow.
	var listed: Variant = d.get("boards", null)
	if listed is Array and not (listed as Array).is_empty() and listed != p.get_meta("chips"):
		p.set_meta("chips", (listed as Array).duplicate(true))
		_open_periods(p)
		_build_boards(p)
	var rows: Array = d.get("rows", [])
	# The podium holds the first three rows as the server orders them: lords
	# level with each other share a place, so the third ring may hold a second.
	var podium := [null, null, null]
	for i in mini(3, rows.size()):
		podium[i] = rows[i]
	for i in 3:
		_podium(p, i, podium[i], board)
	var list := p.content("list")
	var y := ROW_TOP
	if _closes(d):
		_prizes(list, d, Vector2(ROW_X, y))
		y += ROW_PITCH
	for i in range(3, rows.size()):
		_row(list, rows[i], board, Vector2(ROW_X, y))
		y += ROW_PITCH
	if rows.is_empty():
		_notice(p, _empty_words(str(p.get_meta("period"))), UI.DIM, y + 36.0)
		y += 130.0
	list.custom_minimum_size.y = y
	_you(p, d, board)


# --- the periods and the boards ------------------------------------------------------------

## The period a board belongs to before an answer has said: by its id.
static func _guess_period(board: String) -> String:
	if board.begins_with("week_"):
		return "this_week"
	if board.begins_with("season_"):
		return "season"
	return "all_time"


## The boards of one period, in the server's order.
static func _chips_in(p: PaintedPage, period: String) -> Array:
	var out: Array = []
	for c in p.get_meta("chips"):
		if c is Dictionary and str(PERIOD_OF.get(str(c.get("period", "all")), "all_time")) == period:
			out.append(c)
	return out


## A board's chip word: its name's first word ("Raids this week" -> raids).
static func word_of(chip: Dictionary) -> String:
	var name := str(chip.get("name", chip.get("id", ""))).strip_edges()
	var first := name.split(" ", false)[0] if name != "" else str(chip.get("id", ""))
	return first.to_lower()


## Each period answers when the server keeps a board for it -- and the one
## chosen always does, while the answer that lists them is on its way.
static func _open_periods(p: PaintedPage) -> void:
	var periods: TabStrip = p.get_meta("periods")
	for id in PERIODS:
		periods.set_enabled(id, id == str(p.get_meta("period")) or not _chips_in(p, id).is_empty())


## The first row: the chosen period's boards, the chosen board lit. A row of
## three stands on the painted row; two stand at the same size and spacing,
## centred on it; four take the short plates across it.
static func _build_boards(p: PaintedPage) -> void:
	var old: Node = p.get_meta("boards") if p.has_meta("boards") else null
	if old != null and is_instance_valid(old):
		old.queue_free()
	var chips := _chips_in(p, str(p.get_meta("period")))
	var words: Array = []
	var board_of := {}
	var lit := ""
	for c in chips:
		var w := word_of(c)
		words.append(w)
		board_of[w] = str(c.get("id", ""))
		if str(c.get("id", "")) == str(p.get_meta("board")):
			lit = w
	if words.is_empty():
		p.set_meta("boards", null)
		return
	var rect := board_rect(words)
	var strip := TabStrip.make(words, rect, lit if lit != "" else str(words[0]))
	p.place(strip, rect)
	strip.changed.connect(func(w: String) -> void:
		p.set_meta("board", str(board_of.get(w, "")))
		_load(p))
	p.set_meta("boards", strip)
	p.set_meta("board_of", board_of)


## Where the first row's plates stand: the painted row, or -- for two -- two of
## the row of three's plates at its spacing, centred on it, so a strip of two
## is not two plates at the row's far ends.
static func board_rect(words: Array) -> Rect2:
	var row := Layout.rect_of(Layout.find(PAGE, "boards"))
	if words.size() != 2:
		return row
	var three := TabStrip.layout(["might", "level", "wealth"], row.size)
	var rects: Array = three["rects"]
	var w := (rects[1] as Rect2).end.x - (rects[0] as Rect2).position.x
	return Rect2(row.position.x + (row.size.x - w) / 2.0, row.position.y, w, row.size.y)


## A period chosen: its first board, or the one of its boards already chosen.
static func _choose_period(p: PaintedPage, period: String) -> void:
	p.set_meta("period", period)
	var chips := _chips_in(p, period)
	if chips.is_empty():
		return
	var keep := false
	for c in chips:
		keep = keep or str(c.get("id", "")) == str(p.get_meta("board"))
	if not keep:
		p.set_meta("board", str((chips[0] as Dictionary).get("id", "")))
	_build_boards(p)
	_load(p)


## A board that closes: the week's or the season's.
static func _closes(d: Dictionary) -> bool:
	return str(d.get("period", "all")) != "all" or not (d.get("rewards", []) as Array).is_empty()


static func _empty_words(period: String) -> String:
	match period:
		"this_week":
			return "No lord is on this week's rolls yet."
		"season":
			return "No lord is on this season's rolls yet."
	return "No lord has made the rolls yet."


# --- the prize row -------------------------------------------------------------------------

## The head of a board that closes: its name and the time it has left, and what
## its places pay. The time counts down from the answer's moment.
static func _prizes(list: Control, d: Dictionary, at: Vector2) -> void:
	var row := Control.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.position = at
	row.size = ROW_SIZE
	row.set_meta("prizes", true)
	list.add_child(row)
	row.add_child(UI.image(PRIZE_ROW, Rect2(Vector2.ZERO, ROW_SIZE)))
	_line(row, str(d.get("name", "")).to_upper(), PRIZE_NAME, 23, UI.GOLD, "title", 700)
	var clock := _line(row, "", PRIZE_TIME, 19, UI.DIM, "body", 600)
	clock.set_meta("clock", true)
	var ends_at := Time.get_ticks_msec() + int(d.get("ends_in", 0)) * 1000
	var tick := func() -> void:
		var left := maxi(0, (ends_at - Time.get_ticks_msec()) / 1000)
		clock.text = ("Closes in %s" % UI.time_left(left)) if left > 0 else "Closing now: its places are paid by letter"
		UI.fit_line(clock, 19, 14)
	tick.call()
	var t := Timer.new()
	t.wait_time = 1.0
	t.autostart = true
	t.timeout.connect(tick)
	row.add_child(t)
	var rewards: Array = d.get("rewards", [])
	if rewards.is_empty():
		return
	var cell_w := PRIZE_CELLS.size.x / float(rewards.size())
	for i in rewards.size():
		var r: Dictionary = rewards[i] if rewards[i] is Dictionary else {}
		var x := PRIZE_CELLS.position.x + cell_w * float(i)
		var place := _line(row, places(int(r.get("from", 0)), int(r.get("to", 0))),
			Rect2(x, PRIZE_CELLS.position.y, cell_w, PRIZE_PLACE_H), 18, UI.INK, "title", 700, HORIZONTAL_ALIGNMENT_CENTER)
		place.set_meta("place", true)
		var lines: Array = r.get("lines", [])
		var first: Dictionary = lines[0] if not lines.is_empty() and lines[0] is Dictionary else {}
		var amount := str(UI.grouped(int(first.get("amount", 0)))) if not first.is_empty() else ""
		# The prize's picture and its figure, centred together in the cell.
		var fig := UI.label(amount, 24, UI.GOLD, "title", 700)
		var fw := fig.label_settings.font.get_string_size(amount, HORIZONTAL_ALIGNMENT_LEFT, -1, 24).x
		var w := PRIZE_ICON + 6.0 + fw
		var left := x + (cell_w - w) / 2.0
		var top := PRIZE_CELLS.position.y + PRIZE_PLACE_H + 2.0
		var icon := TextureRect.new()
		icon.texture = Art.reward_line_icon(first)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		UI.place(icon, Rect2(left, top + (PRIZE_CELLS.end.y - top - PRIZE_ICON) / 2.0, PRIZE_ICON, PRIZE_ICON))
		icon.set_meta("prize_icon", true)
		row.add_child(icon)
		UI.place(fig, Rect2(left + PRIZE_ICON + 6.0, top, fw + 4.0, PRIZE_CELLS.end.y - top))
		fig.set_meta("box_w", fw + 4.0)
		fig.set_meta("prize", int(first.get("amount", 0)))
		row.add_child(fig)


## A run of places as a prize names it: 1st, 2nd–3rd, 11th–50th.
static func places(from: int, to: int) -> String:
	if to <= from:
		return ordinal(from)
	return "%s–%s" % [ordinal(from), ordinal(to)]


## The kit's ordinal, named here as well: the places on a board and the places
## a prize pays are the same words (UI.ordinal).
static func ordinal(n: int) -> String:
	return UI.ordinal(n)


# --- the podium ----------------------------------------------------------------------

static func _podium(p: PaintedPage, i: int, r: Variant, board: String) -> void:
	var names := ["p1_name", "p2_name", "p3_name"]
	var values := ["p1_value", "p2_value", "p3_value"]
	var centre: Vector2 = PODIUM[i][0]
	var d: float = PODIUM[i][1]
	if r == null:
		_name(p, names[i], {}, "", 22)
		_put(p, values[i], "")
		return
	var row: Dictionary = r
	_name(p, names[i], row, str(row.get("name", "")), 24 if i == 0 else 22)
	_put(p, values[i], _value(board, row))
	# The face fills the ring's window, or -- when they wear a frame -- the
	# frame's own window inside the podium's ring.
	var framed := Look.frame_art(row, "ring", d) != ""
	var face := _face(str(row.get("avatar", "")), centre, d * FACE_IN_FRAME if framed else d + 2.0)
	face.set_meta("podium", i)
	p.place(face, Rect2(face.position, face.size))
	Look.paint_frame(face, row, "ring", d).set_meta("podium_frame", i)


## A lord's name on a painted plate (a layout text part): their colour, and their
## seal at the plate's right end (scripts/ui/look.gd).
static func _name(p: PaintedPage, id: String, look: Dictionary, text: String, size: int) -> Label:
	var l := p.node(id) as Label
	if l == null:
		return null
	var box := p.map_rect(Layout.rect_of(Layout.find(PAGE, id)))
	Look.paint_name(l, look, text, box, size, 13, UI.INK, true)
	return l


# --- the list --------------------------------------------------------------------------

static func _row(list: Control, r: Dictionary, board: String, at: Vector2) -> void:
	var row := Control.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.position = at
	row.size = ROW_SIZE
	list.add_child(row)
	row.add_child(UI.image(ROW, Rect2(Vector2.ZERO, ROW_SIZE)))
	var rank := int(r.get("rank", 0))
	_line(row, "#%d" % rank, ROW_RANK, 28, UI.GOLD, "title", 700, HORIZONTAL_ALIGNMENT_CENTER)
	var face := _face(str(r.get("avatar", "")), ROW_FACE[0], ROW_FACE[1])
	row.add_child(face)
	Look.paint_frame(face, r, "ring", ROW_RING)
	var name := _line(row, "", ROW_NAME, 24, UI.INK, "title", 700)
	Look.paint_name(name, r, str(r.get("name", "")), ROW_NAME, 24, 13, UI.INK, true)
	_line(row, _sub(r), ROW_SUB, 19, UI.GOLD_DIM, "body", 600)
	_line(row, _value(board, r), ROW_VALUE, 28, UI.GOLD, "title", 700, HORIZONTAL_ALIGNMENT_CENTER)


## The asker's own place: from the answer's my_rank and my_value, their own
## face and name. Not on the board is said as such, not as a number.
static func _you(p: PaintedPage, d: Dictionary, board: String) -> void:
	var me: Dictionary = GameState.player()
	var look := Look.mine()
	var mine := int(d.get("my_rank", 0))
	_put(p, "you_rank", ("#%d" % mine) if mine > 0 else "—")
	_name(p, "you_name", look, str(me.get("username", me.get("name", ""))), 24)
	var sub := Look.title(look)
	var off := "Not among the hundred yet"
	match str(p.get_meta("period", "all_time")):
		"this_week":
			off = "Not on this week's rolls yet"
		"season":
			off = "Not on this season's rolls yet"
	_put(p, "you_sub", (sub if sub != "" else "Level %d" % int(me.get("level", 0))) if mine > 0 else off, 12)
	_put(p, "you_value", _value(board, {"value": d.get("my_value", 0), "level": me.get("level", 0)}) if mine > 0 else "—")
	var old: Node = p.get_meta("you_face") if p.has_meta("you_face") else null
	if old != null and is_instance_valid(old):
		old.queue_free()
	var framed := Look.frame_art(look, "ring", YOU_RING) != ""
	var face := _face(str(me.get("avatar", "")), YOU_FACE[0], YOU_FACE[1] * (FACE_IN_FRAME if framed else 1.0))
	p.place(face, Rect2(face.position, face.size))
	p.set_meta("you_face", face)
	var ring := Look.paint_frame(face, look, "ring", YOU_RING)
	var old_ring: Node = p.get_meta("you_ring") if p.has_meta("you_ring") else null
	if old_ring != null and is_instance_valid(old_ring) and old_ring != ring:
		old_ring.queue_free()
	p.set_meta("you_ring", ring)


# --- the pieces ------------------------------------------------------------------------

## A text part's words, held to its painted plate: the layout sizes a label to
## its measured sample (the longest name), so it is set back to the plate's
## width, shrunk, and past that cut with an ellipsis.
static func _put(p: PaintedPage, id: String, text: String, min_size: int = 13) -> Label:
	var l := p.set_text(id, text, min_size)
	if l == null:
		return null
	l.set_meta("box_w", Layout.rect_of(Layout.find(PAGE, id)).size.x)
	UI.fit_line(l, int(l.get_meta("painted_size", l.label_settings.font_size)), min_size)
	return l


## A round face in a round window: the portrait's own disc (Art.avatar_ring).
static func _face(avatar: String, centre: Vector2, d: float) -> TextureRect:
	return UI.image(Art.avatar_ring(avatar), Rect2(centre - Vector2(d, d) / 2.0, Vector2(d, d)))


## One line of live text on a painted plate, shrunk to stay on it.
static func _line(host: Control, s: String, rect: Rect2, size: int, col: Color,
		role: String, weight: int, align: int = HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var l := UI.label(s, size, col, role, weight, align)
	UI.place(l, rect)
	l.set_meta("box_w", rect.size.x)
	host.add_child(l)
	UI.fit_line(l, size, 13)
	return l


## Under the name: the title they wear, or their level.
static func _sub(r: Dictionary) -> String:
	var title := Look.title(r)
	return title if title != "" else "Level %d" % int(r.get("level", 0))


## A board's figure: counts grouped, gold and experience shortened past a
## million, level as a level, the Might a season gained with its sign.
static func _value(board: String, r: Dictionary) -> String:
	var v := int(r.get("value", 0))
	match board:
		"level":
			return "Level %d" % v
		"wealth", "week_xp", "season_xp":
			return UI.short_number(v) if v >= 1000000 else UI.grouped(v)
		"season_might":
			return ("+" if v > 0 else "") + (UI.short_number(v) if v >= 1000000 else UI.grouped(v))
	return UI.grouped(v)


## The list panel says what it is waiting on, or that it is empty.
static func _notice(p: PaintedPage, text: String, col: Color, y: float = 40.0) -> void:
	var list := p.content("list")
	var l := UI.label(text, 25, col, "body", 500, HORIZONTAL_ALIGNMENT_CENTER)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(760, 0)
	UI.place(l, Rect2(46, y, 760, 90))
	l.set_meta("notice", true)
	list.add_child(l)


## Takes away what the last board put up: the rows, the prize row, the podium's
## faces and frames, the notice.
static func _clear(p: PaintedPage) -> void:
	var list := p.content("list")
	if list != null:
		for c in list.get_children():
			c.queue_free()
		list.custom_minimum_size.y = 0
	for n in _all(p):
		if n is Control and (n.has_meta("podium") or n.has_meta("podium_frame")):
			n.queue_free()


static func _all(n: Node) -> Array:
	var out: Array = [n]
	for c in n.get_children():
		out.append_array(_all(c))
	return out
