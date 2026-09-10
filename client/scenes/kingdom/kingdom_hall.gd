extends "res://scenes/kingdom/kingdom_section.gd"
## The Kingdom hall: what a player with no kingdom is shown instead of one.
##
## It used to be the kingdom's own page with the numbers blanked out -- "NO
## KINGDOM", "LEVEL -", "+0%", an empty roster -- and one FOUND button laid on
## the painted castle. It read as a kingdom that had gone wrong, and it gave the
## player nowhere to go: joining was by invitation only, so a lord nobody knew
## was a lord without a kingdom.
##
## The hall is a different page with a different job. Top to bottom:
##   a notice, while a recent leave or removal still has the player waiting
##   the invitations they hold
##   a search, by name or tag
##   the kingdoms worth joining -- or, while searching, the ones that match
##   and, under all of them, founding one's own
##
## Every button on a kingdom is the one the server names in its card: JOIN for
## an open kingdom, REQUEST for one that joins by request, and so on. The
## client does not work out whether a kingdom is full or a player may join.
##
## The page draws the vista and the title above this; the hall is the rows.

signal found_pressed
## The rejoin wait has run out: the page should ask the server again rather
## than switch the buttons on itself.
signal reload_wanted

## Every kingdom's banner is the lion -- it is the crest the kingdom's own
## header carries, so a kingdom looks the same in the hall as it does once you
## are in it.
const CREST := "icons/crest_lion"
const CREST_BOX := Vector2(92, 120)
const FOUND_ART := "icons/city_shield"
const FOUND_BOX := Vector2(124, 142)
const KINGDOM_H := 156.0
const FOUND_H := 214.0
const ACTION_W := 200.0
const FIELD_H := 96.0
const SEARCH_W := 180.0
const DEBOUNCE := 0.35

var _search_row: Control
var _field: LineEdit
var _search_button: Button
var _query := ""
var _results: Array = []
var _searching := false
var _search_seq := 0
var _debounce: Timer
var _countdown: Timer
var _wait_left := 0
var _wait_label: Label


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", int(ROW_GAP))
	_list.custom_minimum_size.x = WIDTH
	add_child(_list)
	_list.minimum_size_changed.connect(_measure)

	_debounce = Timer.new()
	_debounce.one_shot = true
	_debounce.wait_time = DEBOUNCE
	_debounce.timeout.connect(func() -> void: _run_search(_field.text))
	add_child(_debounce)
	_countdown = Timer.new()
	_countdown.wait_time = 1.0
	_countdown.timeout.connect(_tick_wait)
	add_child(_countdown)

	_build_search()
	_rebuild()
	await get_tree().process_frame
	_measure()


func _measure() -> void:
	var h := _list.get_combined_minimum_size().y + 20.0
	if absf(h - size.y) < 1.0:
		return
	custom_minimum_size = Vector2(WIDTH, h)
	size = custom_minimum_size
	grew.emit(h)


## New data from the server. The rows are rebuilt; the search field is not, so
## whatever the player is typing survives a refresh.
func update(new_data: Dictionary) -> void:
	data = new_data
	_busy = false
	_rebuild()


func _rebuild() -> void:
	for c in _list.get_children():
		if c == _search_row:
			continue
		_list.remove_child(c)
		c.queue_free()

	_wait_left = int(data.get("rejoin_in", 0))
	if _wait_left > 0:
		_wait_notice()
		_countdown.start()
	else:
		_countdown.stop()
		_wait_label = null

	var invites: Array = data.get("invites", [])
	if not invites.is_empty():
		_heading("INVITATIONS (%d)" % invites.size())
		for c in invites:
			_kingdom_row(c, true)

	_list.move_child(_search_row, _list.get_child_count() - 1)

	if _query != "":
		if _searching:
			_heading("SEARCHING…")
		else:
			_heading("RESULTS FOR “%s”" % _query)
			if _results.is_empty():
				_notice("No kingdom goes by “%s”." % _query)
			for c in _results:
				_kingdom_row(c, false)
	else:
		var suggested: Array = data.get("recommended", [])
		_heading("RECOMMENDED FOR YOU")
		if suggested.is_empty():
			_notice("No kingdom has a seat free right now.\nRaise your own banner below.")
		for c in suggested:
			_kingdom_row(c, false)

	var or_line := UI.label("—   OR   —", 24, UI.GOLD_DIM, "title", 600, HORIZONTAL_ALIGNMENT_CENTER)
	or_line.custom_minimum_size = Vector2(WIDTH, 56)
	_list.add_child(or_line)
	_found_card()


# --- the wait -----------------------------------------------------------------------

func _wait_notice() -> void:
	var row := _row(110.0)
	_wait_label = _text(row, "", Rect2(PAD, 0, INNER, 110), 25, UI.GOLD, "body", 600,
		HORIZONTAL_ALIGNMENT_CENTER, true)
	_paint_wait()


func _paint_wait() -> void:
	if _wait_label != null and is_instance_valid(_wait_label):
		_wait_label.text = "You left a kingdom recently.\nYou can join another in %s." \
			% UI.short_duration(_wait_left)


## Counts the server's wait down a second at a time. At zero it asks the server
## again: the buttons are the server's to switch on, not the clock's.
func _tick_wait() -> void:
	_wait_left -= 1
	if _wait_left <= 0:
		_countdown.stop()
		reload_wanted.emit()
		return
	_paint_wait()


# --- search -------------------------------------------------------------------------

## The search sits high on the page, under the title, so the keyboard -- which
## rises over the bottom half of a phone -- never covers the field it is for.
func _build_search() -> void:
	_search_row = Control.new()
	_search_row.custom_minimum_size = Vector2(WIDTH, FIELD_H)
	_search_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_list.add_child(_search_row)

	_field = LineEdit.new()
	_field.placeholder_text = "Search kingdoms by name or tag"
	_field.max_length = 24
	_field.add_theme_font_override("font", UI.font("body", 600))
	_field.add_theme_font_size_override("font_size", 30)
	_field.add_theme_color_override("font_color", UI.INK)
	_field.add_theme_color_override("font_placeholder_color", Color(UI.DIM, 0.7))
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color("#08121A")
	sb.border_color = UI.GOLD_DIM
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(18)
	_field.add_theme_stylebox_override("normal", sb)
	var lit := sb.duplicate()
	lit.border_color = UI.GOLD
	_field.add_theme_stylebox_override("focus", lit)
	# PASS, not the default STOP: a tap still reaches the field, but a drag
	# that starts on it carries on to the page, which is what a thumb that
	# happens to land there means.
	_field.mouse_filter = Control.MOUSE_FILTER_PASS
	UI.place(_field, Rect2(0, 0, WIDTH - SEARCH_W - BUTTON_GAP, FIELD_H))
	_field.text_changed.connect(func(_t: String) -> void: _debounce.start())
	_field.text_submitted.connect(func(t: String) -> void:
		_debounce.stop()
		_field.release_focus()
		_run_search(t))
	_search_row.add_child(_field)

	_search_button = _plate_button("SEARCH", "inventory/btn_sell_plate", UI.GOLD)
	UI.place(_search_button, Rect2(WIDTH - SEARCH_W, 0, SEARCH_W, FIELD_H))
	_search_button.pressed.connect(func() -> void:
		_debounce.stop()
		if _query != "":
			_field.text = ""
		_field.release_focus()
		_run_search(_field.text))
	_search_row.add_child(_search_button)


func _run_search(text: String) -> void:
	var term := text.strip_edges()
	_search_seq += 1
	var mine := _search_seq
	# Under two letters is not a search, it is the whole realm: the server
	# answers it with nothing, so it is not asked.
	if term.length() < 2:
		_query = ""
		_results = []
		_searching = false
		_search_button.text = "SEARCH"
		_rebuild()
		return
	_query = term
	_searching = true
	_search_button.text = "CLEAR"
	_rebuild()
	var res: Api.Response = await Api.get_json("/v1/kingdoms/search?q=" + term.uri_encode())
	# A later keystroke, or a tab change, may have overtaken this answer.
	if mine != _search_seq or not is_inside_tree():
		return
	_results = res.data.get("kingdoms", []) if res.ok else []
	_searching = false
	_rebuild()


# --- kingdoms -----------------------------------------------------------------------

## One kingdom: its banner, its name and tag, how big and how renowned, and the
## one thing the player can do about it.
func _kingdom_row(c: Dictionary, invited: bool) -> void:
	var row := _row(KINGDOM_H)
	_picture(row, CREST, CREST_BOX, KINGDOM_H)
	var action := str(c.get("action", ""))
	var two := invited and action == "accept"
	var buttons_w := (ACCEPT_W + BUTTON_GAP + REFUSE_W) if two else ACTION_W
	var text_x := PAD + CREST_BOX.x + GUTTER
	var text_w := WIDTH - PAD - buttons_w - GUTTER - text_x

	var name := str(c.get("name", ""))
	_one_line(_text(row, name, Rect2(text_x, 18, text_w, 44), 32, UI.INK, "title", 700), 32, 20)
	_one_line(_text(row, "[%s]  ·  Level %d  ·  %d/%d lords" % [str(c.get("tag", "")),
		int(c.get("level", 1)), int(c.get("members", 0)), int(c.get("member_cap", 0))],
		Rect2(text_x, 66, text_w, 32), 23, UI.GOLD_DIM, "body", 600), 23, 16)
	var about := "%s renown" % UI.grouped(int(c.get("reputation", 0)))
	if str(c.get("king", "")) != "":
		about += "  ·  King %s" % str(c.get("king", ""))
	if str(c.get("join_policy", "")) == "request":
		about += "  ·  by request"
	_one_line(_text(row, about, Rect2(text_x, 102, text_w, 30), 22, UI.DIM), 22, 15)

	var id := str(c.get("id", c.get("kingdom_id", "")))
	var y := (KINGDOM_H - BUTTON_H) / 2.0
	var right := WIDTH - PAD
	if two:
		var yes := _plate_button("ACCEPT", "shop/buy_plate", Color("#F3FBF3"))
		yes.add_theme_font_size_override("font_size", 24)
		UI.place(yes, Rect2(right - buttons_w, y, ACCEPT_W, BUTTON_H))
		yes.pressed.connect(_accept.bind(id, c))
		row.add_child(yes)
		var no := _plate_button("DECLINE", "inventory/btn_sell_plate", UI.DIM)
		no.add_theme_font_size_override("font_size", 24)
		UI.place(no, Rect2(right - REFUSE_W, y, REFUSE_W, BUTTON_H))
		no.pressed.connect(_decline.bind(id, name))
		row.add_child(no)
		return

	var b: Button
	match action:
		"join", "accept":
			b = _plate_button("JOIN", "shop/buy_plate", Color("#F3FBF3"))
			b.pressed.connect(_join.bind(id, c))
		"request":
			b = _plate_button("REQUEST", "inventory/btn_sell_plate", UI.GOLD)
			b.pressed.connect(_request.bind(id, c))
		"requested":
			b = _plate_button("REQUESTED", "inventory/btn_sell_plate", UI.DIM)
			b.add_theme_font_size_override("font_size", 24)
			b.pressed.connect(_withdraw.bind(id, name))
		"full":
			b = _plate_button("FULL", "inventory/btn_sell_plate", UI.DIM)
			b.disabled = true
		"cooldown":
			b = _plate_button("WAIT", "inventory/btn_sell_plate", UI.DIM)
			b.disabled = true
		_:
			return
	UI.place(b, Rect2(right - ACTION_W, y, ACTION_W, BUTTON_H))
	row.add_child(b)


## A line that stays in its column: shrunk toward min first, and only then cut
## with an ellipsis. A Label grows to its text, so without the cut a long name
## ran under the button beside it.
func _one_line(l: Label, max_size: int, min_size: int) -> void:
	UI.fit_label(l, max_size, min_size)
	var w: float = float(l.get_meta("box_w", l.size.x))
	l.clip_text = true
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	l.custom_minimum_size.x = 0
	l.size.x = w


## "[LION] · Level 5 · 12/20 lords", for a confirmation's opening line.
func _brief(c: Dictionary) -> String:
	return "[%s]  ·  Level %d  ·  %d/%d lords" % [str(c.get("tag", "")), int(c.get("level", 1)),
		int(c.get("members", 0)), int(c.get("member_cap", 0))]


func _join(id: String, c: Dictionary) -> void:
	var name := str(c.get("name", ""))
	if await Dialog.ask(self, {"title": "Join %s?" % name,
			"body": "%s\nYou share its bonuses from the moment you join, and its lords can no longer raid you. You can leave whenever you like." % _brief(c),
			"confirm_text": "Join"}):
		_act("/v1/kingdom/join", {"kingdom_id": id, "_name": name})


func _request(id: String, c: Dictionary) -> void:
	var name := str(c.get("name", ""))
	if await Dialog.ask(self, {"title": "Ask to join %s?" % name,
			"body": "%s\nIts king or a captain will answer. You may ask up to %d kingdoms at once." \
				% [_brief(c), int(data.get("max_requests", 5))],
			"confirm_text": "Ask"}):
		_act("/v1/kingdom/join", {"kingdom_id": id, "_name": name})


func _accept(id: String, c: Dictionary) -> void:
	var name := str(c.get("name", ""))
	if await Dialog.ask(self, {"title": "Join %s?" % name,
			"body": "%s\nThey invited you. You share their bonuses from the moment you join." % _brief(c),
			"confirm_text": "Join"}):
		_act("/v1/kingdom/accept", {"kingdom_id": id, "_name": name})


func _decline(id: String, name: String) -> void:
	if await Dialog.ask(self, {"title": "Decline %s?" % name,
			"body": "The invitation is gone once declined. They can send another.",
			"confirm_text": "Decline", "danger": true}):
		_act("/v1/kingdom/decline", {"kingdom_id": id, "_name": name})


func _withdraw(id: String, name: String) -> void:
	if await Dialog.ask(self, {"title": "Withdraw your request?",
			"body": "%s will no longer see that you asked to join." % name,
			"confirm_text": "Withdraw"}):
		_act("/v1/kingdom/request/cancel", {"kingdom_id": id, "_name": name})


# --- founding -----------------------------------------------------------------------

## Raising one's own banner: what it costs and what it asks, and the button --
## off, with the reason in its place, when the server says it cannot be done.
func _found_card() -> void:
	var row := _row(FOUND_H)
	_picture(row, FOUND_ART, FOUND_BOX, FOUND_H)
	var text_x := PAD + FOUND_BOX.x + GUTTER
	var text_w := _text_span(text_x, ACTION_W)
	UI.fit_label(_text(row, "RAISE YOUR OWN BANNER", Rect2(text_x, 30, text_w, 40), 27, UI.GOLD,
		"title", 700), 27, 18)
	_text(row, "Found a kingdom and rule it as its king.", Rect2(text_x, 76, text_w, 60), 23,
		UI.INK, "body", 500, HORIZONTAL_ALIGNMENT_LEFT, true)
	var can := bool(data.get("can_found", true))
	var cost := "%s gold  ·  level %d and up" % [UI.grouped(int(data.get("found_cost", 0))),
		int(data.get("found_level", 20))]
	_text(row, cost if can else str(data.get("found_reason", "")),
		Rect2(text_x, 142, text_w, 44), 22, UI.GOLD_DIM if can else UI.RED, "body", 600,
		HORIZONTAL_ALIGNMENT_LEFT, true)
	var b := _action(row, "FOUND", "shop/buy_plate", Color("#F3FBF3"), ACTION_W, FOUND_H)
	b.disabled = not can
	b.pressed.connect(func() -> void: found_pressed.emit())
