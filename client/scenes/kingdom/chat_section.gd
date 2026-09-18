extends Control
## THE HALL -- the Kingdom tab's CHAT sub-tab, from chat.png.
##
## A section like LORDS, WORKS and RANKS (kingdom_section.gd): the page keeps
## its header and both tab strips, and this is what sits under them. It is
## built in code from the painting's own objects (art/slices/chat.json) rather
## than from a layout template, because a hall is a LIST of rows whose heights
## depend on what was said.
##
## Three rules it keeps.
##
## The client says nothing about a line but what the server said. Whether a word
## was starred, whether a lord may speak, when the hall will listen again --
## every one of those is in the answer to GET /v1/chat, and this only draws it.
##
## A line is said over HTTP and never over the socket. The socket brings what
## OTHER lords said (Realtime), and when it is not there the hall polls instead:
## a hall that only works on a good connection is a hall nobody trusts.
##
## The rules are agreed to before a lord may speak (App Review 1.2). The server
## sends them with the room whenever this lord has not agreed to the current
## version, and their presence is what opens the page.

signal grew(height: float)
signal acted(path: String, body: Dictionary)

## Until the hall answers: the balance's own figure at the time of writing, so
## the field is never unbounded before the first load.
const DEFAULT_MAX_CHARS := 240
const WIDTH := 762.0
const PAD := 8.0
## A day's rule, and the word between its halves.
const DIVIDER_H := 22.0
const DAY_WORD_SIZE := 24
## A lord's row: the round portrait, the plates over the bubble, the bubble.
const FACE := 128.0
const PLATE_H := 55.0
const BUBBLE_MIN := 92.0
const BUBBLE_PAD := Vector4(40.0, 26.0, 30.0, 26.0)
const ROW_GAP := 18.0
## A system line: the horn (only on the first of a run) and the scroll.
const HORN := Vector2(143.0, 152.0)
const SCROLL_MIN := 84.0
## How far a scroll that follows another is set in from the horn's own.
const RUN_INDENT := 87.0
## The parchment's own margins: where its words start, and how much of it is
## left clear on the right. Measured off chat.png's painted scroll.
const SCROLL_PAD_L := 28.0
const SCROLL_PAD_R := 40.0
## The bar at the foot, which never scrolls with the room.
const BAR := Vector2(772.0, 130.0)
## How often the room is re-read when there is no socket to bring it.
const POLL_SECONDS := 4.0
## The most rows kept on screen. The server sends at most its own history; this
## is the guard against a room that grows all session.
const KEEP := 60

var _rows: Array = []          ## the built row nodes, oldest first
var _room: ScrollContainer
var _list: Control
## The height the tab gives the section: the page from under the strips to the
## foliage. 0 until it says.
var _room_h := 0.0
var _bar: Control
var _field: LineEdit
var _send: BaseButton
var _notice: Label
var _data: Dictionary = {}
var _head := 0
var _busy := false
var _poll := 0.0
var _next_in := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	custom_minimum_size = Vector2(WIDTH, 400)
	# The room scrolls inside the section and the bar stands at its foot, where
	# the painting puts it: the page under it does not scroll on this tab, so a
	# lord never has to travel to the end of the hall to say something.
	_room = ScrollContainer.new()
	_room.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_room.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	_room.scroll_deadzone = 14
	_room.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(_room)
	_list = Control.new()
	_list.mouse_filter = Control.MOUSE_FILTER_PASS
	_room.add_child(_list)
	_build_bar()
	Realtime.frame.connect(_heard)
	Realtime.listen()
	set_process(true)
	_load(0)


func _exit_tree() -> void:
	Realtime.hush()


## The bar a line is written on: the painting's own, with a field over its
## parchment and SEND cut out of it so it can dim.
func _build_bar() -> void:
	_bar = Control.new()
	_bar.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(_bar)
	var plate := UI.image("chat/bar", Rect2(Vector2.ZERO, BAR))
	_bar.add_child(plate)
	# The field sits on the painting's parchment: no plate of its own, because
	# the painting already drew one.
	_field = LineEdit.new()
	_field.flat = true
	_field.add_theme_font_override("font", UI.font("body", 500))
	_field.add_theme_font_size_override("font_size", 28)
	_field.add_theme_color_override("font_color", Color("#2A2013"))
	_field.add_theme_color_override("font_placeholder_color", Color(0.35, 0.28, 0.18, 0.7))
	_field.add_theme_color_override("caret_color", Color("#2A2013"))
	_field.placeholder_text = "Say something"
	# The limit is set from the hall's own answer (`max_chars`), not written
	# down here: the rule is `social.chat.max_chars` in the balance, and a
	# second copy in the client is a number that starts agreeing and ends
	# disagreeing -- a lord allowed a longer line would have it cut at 240 by
	# their own phone. This is only the value before the first answer lands.
	_field.max_length = DEFAULT_MAX_CHARS
	UI.place(_field, Rect2(122, 26, 466, 76))
	_field.text_submitted.connect(func(_t: String) -> void: _say())
	_field.text_changed.connect(func(_t: String) -> void: _light_send())
	_bar.add_child(_field)
	_send = UI.tex_button("chat/send", Rect2(581, 16, 168, 86))
	_send.pressed.connect(_say)
	_bar.add_child(_send)
	# What the hall says back: a wait, a silence, or a refusal. One line, under
	# the bar, in the realm's own red.
	_notice = UI.label("", 22, UI.RED, "body", 600, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(_notice, Rect2(0, BAR.y - 2, BAR.x, 30))
	_bar.add_child(_notice)


func height() -> float:
	return _room_h if _room_h > 0.0 else _bar.position.y + BAR.y + 12.0


## The room the tab has for the hall, from under the strips to the foliage. The
## hall takes all of it: the rows scroll inside and the bar keeps its place.
func fill_height(h: float) -> void:
	_room_h = maxf(h, BAR.y + 200.0)
	_lay_out()


func refresh() -> void:
	_load(0)


func _process(delta: float) -> void:
	if _next_in > 0.0:
		_next_in = maxf(0.0, _next_in - delta)
		_light_send()
	if not Realtime.polling():
		return
	_poll -= delta
	if _poll <= 0.0:
		_poll = POLL_SECONDS
		_load(_head)


## Something happened in the room. A frame is a statement, never a command: the
## hall re-reads what it is missing rather than trusting the frame's own copy.
func _heard(kind: String, _data_in: Dictionary) -> void:
	match kind:
		"chat", "chat_hidden", "resync":
			_load(_head)


func _load(after: int) -> void:
	if _busy:
		return
	_busy = true
	var path := "/v1/chat"
	if after > 0:
		path += "?after=%d" % after
	var res: Api.Response = await Api.get_json(path)
	_busy = false
	if not is_inside_tree():
		return
	if not res.ok:
		if res.code == "no_hall":
			_data = {}
			_paint()
		return
	if after > 0 and res.data.get("lines", []) is Array and (res.data["lines"] as Array).is_empty():
		# Nothing new. Keep what is drawn, but take the room's own clock and
		# the lord's own state (a silence may have started elsewhere).
		_head = maxi(_head, int(res.data.get("head", _head)))
		_data["muted_for"] = res.data.get("muted_for", 0)
		_data["next_in"] = res.data.get("next_in", 0)
		_data["rules"] = res.data.get("rules")
		_next_in = float(_data.get("next_in", 0))
		_light_send()
		return
	if after > 0:
		var lines: Array = _data.get("lines", [])
		lines.append_array(res.data.get("lines", []))
		if lines.size() > KEEP:
			lines = lines.slice(lines.size() - KEEP, lines.size())
		res.data["lines"] = lines
	_data = res.data
	_head = int(_data.get("head", 0))
	_next_in = float(_data.get("next_in", 0))
	_paint()
	_mark_read()


func _mark_read() -> void:
	if _head <= 0:
		return
	await Api.post_json("/v1/chat/read", {"seq": _head})


## The rules page, opened when the server says this lord has not agreed.
func _open_rules() -> void:
	var rules: Variant = _data.get("rules")
	if not (rules is Dictionary):
		return
	var page: Variant = load("res://scenes/pages/rules_of_the_hall.gd").call("open", self, {"rules": rules})
	if page != null and page.has_signal("closed"):
		page.closed.connect(func() -> void: _load(0))


func _say() -> void:
	if _busy or _field.text.strip_edges() == "":
		return
	if _data.get("rules") != null:
		_open_rules()
		return
	_busy = true
	_notice.text = ""
	var body := _field.text
	var res: Api.Response = await Api.post_json("/v1/chat", {"body": body})
	_busy = false
	if not is_inside_tree():
		return
	if res.ok:
		_field.text = ""
		_next_in = float(res.data.get("next_in", 0))
		if bool(res.data.get("masked", false)):
			_notice.text = "The hall starred a word out of that."
		_load(_head)
		return
	match res.code:
		"rules_unread":
			_open_rules()
		"muted", "too_fast", "too_much", "line_refused", "line_too_long", "no_hall":
			_notice.text = res.error
		_:
			_notice.text = res.error if res.error != "" else "The hall did not take that."


func _light_send() -> void:
	var shut := float(_data.get("muted_for", 0)) > 0.0 or _next_in > 0.0
	var empty := _field.text.strip_edges() == ""
	_send.disabled = shut or empty or _busy
	(_send as CanvasItem).modulate = Color.WHITE if not _send.disabled else Color(0.5, 0.5, 0.55)
	_field.editable = not shut
	if float(_data.get("muted_for", 0)) > 0.0:
		_notice.text = "The hall is shut to you for %s." % UI.short_duration(int(_data["muted_for"]))
	elif _next_in > 0.0:
		_notice.text = "A moment yet."
	elif _notice.text == "A moment yet.":
		_notice.text = ""


func _paint() -> void:
	# What the hall lets a lord say, in the hall's own words.
	var most := int(_data.get("max_chars", 0))
	if most > 0 and _field != null:
		_field.max_length = most

	for r in _rows:
		(r as Node).queue_free()
	_rows.clear()

	var y := 0.0
	if _data.is_empty():
		var none := _empty_card("NO HALL YET",
			"A hall belongs to a kingdom. Join one, or found one, and the realm will have somewhere to talk.")
		none.position = Vector2(0, y)
		y += none.size.y
	else:
		var lines: Array = _data.get("lines", [])
		if lines.is_empty():
			var quiet := _empty_card("THE HALL IS QUIET",
				"Nobody has spoken today. Say something -- the whole kingdom reads this.")
			quiet.position = Vector2(0, y)
			y += quiet.size.y
		var last_day := ""
		var last_kind := ""
		for i in lines.size():
			var line: Dictionary = lines[i]
			var day := _day_of(int(line.get("at", 0)))
			if day != last_day:
				y += _divider(day, y)
				last_day = day
				last_kind = ""
			if str(line.get("kind", "")) == "system":
				y += _system_row(line, last_kind != "system", y)
			else:
				y += _lord_row(line, y)
			last_kind = str(line.get("kind", ""))
			y += ROW_GAP

	_list.custom_minimum_size = Vector2(WIDTH, y)
	_list.size = Vector2(WIDTH, y)
	_light_send()
	_lay_out()
	# A hall opens at its newest line, as a room does: what was said while you
	# were away is behind you, not in front.
	await get_tree().process_frame
	if is_instance_valid(_room):
		_room.scroll_vertical = int(maxf(0.0, _list.size.y - _room.size.y))


## Puts the room and the bar in the height the tab gave (fill_height), or
## round the rows when it has not said yet.
func _lay_out() -> void:
	if _room == null or _bar == null:
		return
	var bar_h := BAR.y + 34.0
	var h := height()
	UI.place(_room, Rect2(0, 0, WIDTH, maxf(0.0, h - bar_h)))
	_bar.position = Vector2((WIDTH - BAR.x) / 2.0, maxf(0.0, h - bar_h) + 16.0)
	custom_minimum_size = Vector2(WIDTH, h)
	size = Vector2(WIDTH, h)
	grew.emit(h)


## How tall `words` are when they are wrapped to `w`.
##
## A Label's own minimum height is ONE line however it wraps -- it is the
## height it insists on, not the height its words take -- and a bubble measured
## by it carried three lines in the room for one, with the rest under the bar.
## The font is asked instead, the way every other wrapped box in the game is
## measured (UI.fit_wrapped).
static func _wrapped_h(l: Label, words: String, w: float) -> float:
	var st := l.label_settings
	return st.font.get_multiline_string_size(words, HORIZONTAL_ALIGNMENT_LEFT, w, st.font_size).y


## The day a line belongs to, as the hall writes it.
func _day_of(at: int) -> String:
	if at <= 0:
		return ""
	var now := Time.get_unix_time_from_system()
	var day := 86400.0
	var today := floori(now / day)
	var theirs := floori(float(at) / day)
	if theirs == today:
		return "TODAY"
	if theirs == today - 1:
		return "YESTERDAY"
	var d := Time.get_datetime_dict_from_unix_time(at)
	return "%d %s" % [int(d["day"]), UI.MONTHS[int(d["month"]) - 1].to_upper()]


func _divider(word: String, y: float) -> float:
	var row := Control.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UI.place(row, Rect2(0, y, WIDTH, DIVIDER_H + 12.0))
	_list.add_child(row)
	_rows.append(row)
	var left := UI.image("chat/divider_left", Rect2(0, 6, 322, DIVIDER_H))
	row.add_child(left)
	var right := UI.image("chat/divider_right", Rect2(WIDTH - 304, 6, 304, DIVIDER_H))
	row.add_child(right)
	var l := UI.label(word, DAY_WORD_SIZE, UI.GOLD, "title", 700, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(l, Rect2(322, 0, WIDTH - 626, DIVIDER_H + 12.0))
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(l)
	return DIVIDER_H + 18.0


## One lord's line: their face, their name and the hour, and the bubble.
func _lord_row(line: Dictionary, y: float) -> float:
	var words := str(line.get("body", ""))
	var text := UI.label(words, 26, UI.INK, "body", 500)
	text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var inner := WIDTH - FACE - 14.0 - BUBBLE_PAD.x - BUBBLE_PAD.z
	text.size.x = inner
	var lines_h := maxf(_wrapped_h(text, words, inner), 30.0)
	var bubble_h := maxf(BUBBLE_MIN, lines_h + BUBBLE_PAD.y + BUBBLE_PAD.w)
	var row_h := PLATE_H + 6.0 + bubble_h

	var row := Control.new()
	row.mouse_filter = Control.MOUSE_FILTER_PASS
	UI.place(row, Rect2(0, y, WIDTH, row_h))
	_list.add_child(row)
	_rows.append(row)

	# The face: the round portrait every screen draws, with this lord's own
	# frame over it (Look.paint_frame), and their page a tap away.
	var face := UI.image(Art.avatar_ring(str(line.get("avatar", ""))), Rect2(0, row_h - FACE, FACE, FACE))
	face.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	row.add_child(face)
	Look.paint_frame(face, line, "ring", FACE * 0.11)
	var pid := str(line.get("player_id", ""))
	if pid != "" and not bool(line.get("mine", false)):
		var hit := UI.hotspot(Rect2(0, row_h - FACE, FACE, FACE))
		hit.pressed.connect(func() -> void: _open_lord(pid))
		row.add_child(hit)

	var x := FACE + 14.0
	# A king or a marshal wears the painting's crown over their name.
	var role := str(line.get("role", ""))
	if role == "king" or role == "marshal":
		row.add_child(UI.image("chat/crown", Rect2(x, 0, 44, 72)))
		x += 50.0
	var name_plate := UI.image("chat/name_plate", Rect2(x, 8, 235, PLATE_H))
	row.add_child(name_plate)
	var who := UI.label("", 24, UI.INK, "body", 600, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(who, Rect2(x + 12, 8, 211, PLATE_H))
	who.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(who)
	Look.paint_name(who, line, str(line.get("name", "")), Rect2(x + 12, 8, 211, PLATE_H), 24, 16)

	var when_plate := UI.image("chat/time_plate", Rect2(x + 243, 8, 172, PLATE_H))
	row.add_child(when_plate)
	var hour := UI.label(_hour_of(int(line.get("at", 0))), 22, UI.DIM, "body", 500,
		HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(hour, Rect2(x + 243, 8, 172, PLATE_H))
	hour.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(hour)

	var bubble := UI.nine("chat/bubble", Rect2(FACE + 14.0, PLATE_H + 6.0, WIDTH - FACE - 14.0, bubble_h), 40)
	row.add_child(bubble)
	UI.place(text, Rect2(FACE + 14.0 + BUBBLE_PAD.x, PLATE_H + 6.0 + BUBBLE_PAD.y, inner, bubble_h - BUBBLE_PAD.y - BUBBLE_PAD.w))
	row.add_child(text)
	if bool(line.get("hidden", false)):
		# Only ever this lord's own line: the room does not see it at all.
		(row as CanvasItem).modulate = Color(0.62, 0.62, 0.66)
		var gone := UI.label("hidden by the crown", 20, UI.RED, "body", 600)
		UI.place(gone, Rect2(FACE + 14.0 + BUBBLE_PAD.x, PLATE_H + 6.0 + bubble_h - 30.0, inner, 26))
		row.add_child(gone)
	elif not bool(line.get("mine", false)):
		# Reporting is where the talking is (App Review 1.2).
		var flag := UI.hotspot(Rect2(WIDTH - 60.0, PLATE_H + 6.0, 56, 56))
		flag.pressed.connect(func() -> void: _report(line))
		row.add_child(flag)
	return row_h


## A line the realm says. The horn is drawn only on the first of a run, which is
## what the painting shows.
func _system_row(line: Dictionary, first: bool, y: float) -> float:
	var words := str(line.get("body", ""))
	var text := UI.label(words, 24, Color("#2A2013"), "body", 600)
	text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# A line that follows another of the realm's is set IN from the horn, so its
	# scroll is narrower by that indent -- and the words must be measured against
	# the scroll they are going on, not the first one's. They were not: the
	# second scroll of a run wrapped to the full width and ran its last word
	# under the parchment's own right border.
	var left := HORN.x + 12.0 + (0.0 if first else RUN_INDENT)
	var inner := (WIDTH - left) - SCROLL_PAD_L - SCROLL_PAD_R
	text.size.x = inner
	var scroll_h := maxf(SCROLL_MIN, _wrapped_h(text, words, inner) + 44.0)
	var row_h := maxf(scroll_h, HORN.y if first else 0.0)

	var row := Control.new()
	row.mouse_filter = Control.MOUSE_FILTER_PASS
	UI.place(row, Rect2(0, y, WIDTH, row_h))
	_list.add_child(row)
	_rows.append(row)
	if first:
		row.add_child(UI.image("chat/horn", Rect2(0, 0, HORN.x, HORN.y)))
	# The horn is sounded once for a run; the scroll is laid from `left`, which
	# the words were already measured against.
	var scroll := UI.nine("chat/scroll", Rect2(left, 0, WIDTH - left, scroll_h), 30)
	row.add_child(scroll)
	UI.place(text, Rect2(left + SCROLL_PAD_L, 20.0, inner, scroll_h - 40.0))
	row.add_child(text)
	return row_h


## A lord's page, from their face in the hall.
func _open_lord(player_id: String) -> void:
	load("res://scenes/pages/rival_page.gd").call("open", self, {"player_id": player_id})


func _report(line: Dictionary) -> void:
	var id := str(line.get("id", ""))
	if id == "":
		return
	var reason: String = await Dialog.choose(self, {
		"title": "REPORT THIS LINE",
		"body": "The crown reads what is reported. Three lords reporting one line hides it from the hall at once.",
		"options": [
			{"id": "abuse", "label": "Abuse or threats"},
			{"id": "hate", "label": "Hate"},
			{"id": "spam", "label": "Spam or selling"},
			{"id": "private", "label": "Somebody's private life"},
			{"id": "other", "label": "Something else"},
		],
	})
	if reason == "":
		return
	var res: Api.Response = await Api.post_json("/v1/chat/report", {"message_id": id, "reason": reason})
	if res.ok:
		GameState.toast("Reported. The crown will read it.")
		_load(0)
	else:
		GameState.toast(res.error)


func _hour_of(at: int) -> String:
	if at <= 0:
		return ""
	var d := Time.get_datetime_dict_from_unix_time(at)
	return "%02d:%02d" % [int(d["hour"]), int(d["minute"])]


## The card every empty list in the game shows (UI.empty_card).
func _empty_card(title: String, body: String) -> Control:
	var card := UI.empty_card(_list, Rect2(0, 0, WIDTH, 190))
	(card["title"] as Label).text = title
	(card["body"] as Label).text = body
	_rows.append(card["node"])
	return card["node"]
