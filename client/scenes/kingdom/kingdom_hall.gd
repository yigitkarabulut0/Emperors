extends "res://scenes/kingdom/kingdom_section.gd"
## The Kingdom hall: JOIN A KINGDOM, what a player with no kingdom is shown
## instead of one. Painted: art/reference/kingdom_hall.png, cut by
## art/slices/kingdom_hall.json.
##
## It used to be the kingdom's own page with the numbers blanked out, then a
## list of dialog plates with the lion on every row. The painting gives it its
## own furniture: a search box, an invitation card with two plates and ACCEPT /
## DECLINE, a kingdom card with a name plate, the lords and the laurel, OR, and
## RAISE YOUR OWN BANNER. Top to bottom, as the painting has it:
##   the search, by name or tag
##   a notice, while a recent leave or removal still has the player waiting
##   the invitations they hold
##   the kingdoms worth joining -- or, while searching, the ones that match
##   OR, and founding one's own
##
## Every button on a kingdom is the one the server names in its card: JOIN for
## an open kingdom, REQUEST for one that joins by request, REQUESTED (tap to
## withdraw), FULL, WAIT. The client does not work out whether a kingdom is full
## or a player may join. Each kingdom wears its own crest, one of the twelve by
## its id (Art.crest), as a rival does on the Attack cards.
##
## The page (scenes/tabs/kingdom.gd) draws the painting's header -- the vista,
## JOIN A KINGDOM and its line -- above this. The hall is everything from the
## search down, laid out in the painting's own units: it sits at x 0 of the page
## and y TOP, and every rect here is the painting's, measured, with y counted
## from the top of the row it belongs to. The painting's rail is the wider,
## eight-entry one of Wave 2, so its content starts at x 187 and so does this.

signal found_pressed
## The rejoin wait has run out: the page should ask the server again rather
## than switch the buttons on itself.
signal reload_wanted

## Where the hall starts on the page: the top of the search row.
const TOP := 462.0
const PAGE_W := 941.0
const DEBOUNCE := 0.35

## The rows, each the height from its top to the next row's in the painting.
const SEARCH_H := 74.0
const HEADING_NARROW_H := 54.0
const HEADING_WIDE_H := 52.0
## The invitation card is 170 tall and its two buttons each want a thumb's 95,
## stacked: the row is as tall as the two tap areas, 22 more than the painting's
## gap to the next heading.
const INVITE_H := 192.0
const KINGDOM_H := 166.0
const OR_H := 46.0
const FOUND_H := 196.0

## The search box and its button (the row's top is the painting's y 462).
const SEARCH_FIELD := Rect2(187, 0, 543, 68)
const SEARCH_TEXT := Rect2(252, 8, 466, 52)
const SEARCH_PAINT := Rect2(738, 2, 177, 64)
const SEARCH_TAP := Rect2(733, -13, 187, 95)

## A heading: the plaque's words, set where the painting sets them.
const HEADING_NARROW_TEXT := Rect2(403, 16, 291, 32)
const HEADING_WIDE_TEXT := Rect2(336, 14, 409, 30)

## An invitation card (its top is the painting's y 590).
const INVITE_CREST := Rect2(228, 11, 111, 147)
const INVITE_NAME := Rect2(384, 37, 284, 44)
const INVITE_INFO := Rect2(388, 97, 198, 37)
const ACCEPT_PAINT := Rect2(719, 32, 178, 63)
const ACCEPT_TAP := Rect2(715, 2, 186, 95)
const DECLINE_PAINT := Rect2(719, 97, 178, 57)
const DECLINE_TAP := Rect2(715, 97, 186, 95)

## A kingdom card (its top is the painting's y 818).
const KINGDOM_CREST := Rect2(225, 8, 105, 138)
## The plates' inner boxes: inside their gold borders (name 842-843 / 879-880,
## lords 891 / 921, laurel 929 / 960 on the painting's first card).
const KINGDOM_NAME := Rect2(380, 26, 298, 35)
const KINGDOM_LORDS := Rect2(439, 74, 168, 29)
const KINGDOM_RENOWN := Rect2(439, 112, 168, 29)
const JOIN_PAINT := Rect2(720, 50, 177, 65)
const JOIN_TAP := Rect2(715, 35, 187, 95)

## Founding (its top is the painting's y 1360). The plate's gold border runs at
## 86-87 and 134-135 and x 402-694; its words keep two units inside it.
const FOUND_TEXT := Rect2(407, 90, 282, 42)
const FOUND_PAINT := Rect2(720, 80, 176, 74)
const FOUND_TAP := Rect2(715, 70, 186, 95)

const GREEN := "hall/btn_green"
const DARK := "hall/btn_dark"
## The painted words on the buttons and the plaques: Cinzel, whose small
## letters are small capitals -- "Join" is how the painting's JOIN is set --
## ivory with a drop shadow, at the sizes measured off the painting.
const WORD := Color("#FBF7EE")
## The least a plate's words are set at: one line down to ONE_LINE_MIN, then two
## lines down to TWO_LINE_MIN; below that they would not read on the phone.
const ONE_LINE_MIN := 17
const TWO_LINE_MIN := 15
const BUTTON_SIZE := 26
const NARROW_SIZE := 30
const WIDE_SIZE := 28

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
	_list.add_theme_constant_override("separation", 0)
	_list.custom_minimum_size.x = PAGE_W
	_list.mouse_filter = Control.MOUSE_FILTER_PASS
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
	var h := _list.get_combined_minimum_size().y
	if absf(h - size.y) < 1.0:
		return
	custom_minimum_size = Vector2(PAGE_W, h)
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
		_heading("Invitations" if invites.size() == 1 else "Invitations (%d)" % invites.size())
		for c in invites:
			_invite_card(c)

	if _query != "":
		if _searching:
			_heading("Searching…")
		else:
			_heading("Results for “%s”" % _query)
			if _results.is_empty():
				_notice("No kingdom goes by “%s”." % _query)
			for c in _results:
				_kingdom_card(c)
	else:
		var suggested: Array = data.get("recommended", [])
		_heading("Recommended for you")
		if suggested.is_empty():
			_notice("No kingdom has a seat free right now.\nRaise your own banner below.")
		for c in suggested:
			_kingdom_card(c)

	var or_row := _painted_row(OR_H)
	or_row.add_child(UI.image("hall/or", Rect2(186, 0, 737, 44)))
	_found_card()


## A row of the hall: as wide as the page, `h` tall, deaf to the mouse so a drag
## that starts on it still scrolls the page (its buttons still answer).
func _painted_row(h: float) -> Control:
	var row := Control.new()
	row.custom_minimum_size = Vector2(PAGE_W, h)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_list.add_child(row)
	return row


## A line of live text over a painted plate, shrunk to stay in it -- across and
## down, a line being taller than its letters -- centred on the plate's inside,
## and cut with an ellipsis only past the smallest size.
func _plate_text(row: Control, s: String, rect: Rect2, size: int, col: Color,
		role: String = "body", weight: int = 600,
		align: int = HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var l := UI.label(s, size, col, role, weight, align)
	UI.place(l, rect)
	l.set_meta("box_w", rect.size.x)
	l.set_meta("plate_rect", rect)
	row.add_child(l)
	var top := size
	var f: Font = l.label_settings.font
	while top > 13 and f.get_height(top) > rect.size.y:
		top -= 1
	UI.fit_line(l, top, 13)
	var line := f.get_height(l.label_settings.font_size)
	l.position.y = rect.position.y + (rect.size.y - line) / 2.0
	l.size.y = line
	return l


## Whether `s` goes on one line `w` wide at `size` or larger.
func _fits_one_line(s: String, w: float, size: int, role: String, weight: int) -> bool:
	var f: Font = UI.settings(size, UI.INK, role, weight).font
	return f.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x <= w


## Words that must be read whole on a plate: one line, shrunk no further than
## ONE_LINE_MIN; failing that two lines, shrunk until both sit inside `rect`;
## never cut with an ellipsis.
func _plate_words(row: Control, s: String, rect: Rect2, max_size: int, col: Color) -> Label:
	var l := UI.label(s, max_size, col, "body", 600, HORIZONTAL_ALIGNMENT_CENTER)
	var f: Font = l.label_settings.font
	var size := max_size
	while size > ONE_LINE_MIN and f.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x > rect.size.x:
		size -= 1
	if f.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x > rect.size.x:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		size = max_size
		while size > TWO_LINE_MIN and _block(f, s, rect.size.x, size).y > rect.size.y:
			size -= 1
	l.label_settings.font_size = size
	l.custom_minimum_size = Vector2(rect.size.x, 0)
	UI.place(l, rect)
	l.set_meta("plate_rect", rect)
	row.add_child(l)
	return l


## The height of `s` wrapped at `w`, as a Label sets it: one font height a line.
static func _block(f: Font, s: String, w: float, size: int) -> Vector2:
	var m := f.get_multiline_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, w, size)
	return m


## A painted button: the plate drawn where the painting has it (`paint`), its
## word in type, and a tap area a thumb can find (`tap`).
func _button(row: Control, word: String, plate: String, tap: Rect2, paint: Rect2) -> Button:
	var b := UI.plate_button(plate, word, tap, BUTTON_SIZE, WORD, 600, 16)
	UI.inset_plate(b, tap, paint)
	b.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.55))
	b.add_theme_constant_override("shadow_offset_x", 0)
	b.add_theme_constant_override("shadow_offset_y", 2)
	row.add_child(b)
	return b


# --- headings and notices -----------------------------------------------------------

## A heading on the painting's plaque, the words in type: the short plaque for
## a short word, the long one for the rest.
func _heading(text: String) -> void:
	var probe := UI.settings(NARROW_SIZE, WORD, "title", 600)
	var narrow := probe.font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, NARROW_SIZE).x \
		<= HEADING_NARROW_TEXT.size.x
	var row := _painted_row(HEADING_NARROW_H if narrow else HEADING_WIDE_H)
	row.add_child(UI.image("hall/heading_narrow" if narrow else "hall/heading_wide",
		Rect2(186, 0, 737, 56 if narrow else 52)))
	_plate_text(row, text, HEADING_NARROW_TEXT if narrow else HEADING_WIDE_TEXT,
		NARROW_SIZE if narrow else WIDE_SIZE, WORD, "title", 600, HORIZONTAL_ALIGNMENT_CENTER)


## What a list says when it has nothing to show, on the ground between the
## heading and what comes next.
func _notice(text: String) -> void:
	var row := _painted_row(110.0)
	var l := UI.label(text, 25, UI.DIM, "body", 500, HORIZONTAL_ALIGNMENT_CENTER)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(720, 0)
	UI.place(l, Rect2(200, 8, 720, 94))
	row.add_child(l)


# --- the wait -----------------------------------------------------------------------

func _wait_notice() -> void:
	var row := _painted_row(96.0)
	_wait_label = UI.label("", 25, UI.GOLD, "body", 600, HORIZONTAL_ALIGNMENT_CENTER)
	_wait_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_wait_label.custom_minimum_size = Vector2(720, 0)
	UI.place(_wait_label, Rect2(200, 8, 720, 80))
	row.add_child(_wait_label)
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
## The painted box is the field's plate: the LineEdit draws none of its own.
func _build_search() -> void:
	_search_row = _painted_row(SEARCH_H)
	_search_row.add_child(UI.image("hall/search_field", SEARCH_FIELD))

	_field = UI.field("Search kingdoms by name or tag", 28)
	for st in ["normal", "focus", "read_only"]:
		_field.add_theme_stylebox_override(st, StyleBoxEmpty.new())
	_field.max_length = 24
	# PASS, not the default STOP: a tap still reaches the field, but a drag
	# that starts on it carries on to the page, which is what a thumb that
	# happens to land there means.
	_field.mouse_filter = Control.MOUSE_FILTER_PASS
	UI.place(_field, SEARCH_TEXT)
	_field.text_changed.connect(func(_t: String) -> void: _debounce.start())
	_field.text_submitted.connect(func(t: String) -> void:
		_debounce.stop()
		_field.release_focus()
		_run_search(t))
	_search_row.add_child(_field)

	_search_button = _button(_search_row, "Search", GREEN, SEARCH_TAP, SEARCH_PAINT)
	_search_button.pressed.connect(func() -> void:
		_debounce.stop()
		if _query != "":
			_field.text = ""
		_field.release_focus()
		_run_search(_field.text))


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
		_search_button.text = "Search"
		_rebuild()
		return
	_query = term
	_searching = true
	_search_button.text = "Clear"
	_rebuild()
	var res: Api.Response = await Api.get_json("/v1/kingdoms/search?q=" + term.uri_encode())
	# A later keystroke, or a tab change, may have overtaken this answer.
	if mine != _search_seq or not is_inside_tree():
		return
	_results = res.data.get("kingdoms", []) if res.ok else []
	_searching = false
	_rebuild()


# --- kingdoms -----------------------------------------------------------------------

## An invitation: the kingdom's crest, its name and what it is, and the two
## buttons -- the one its card names (ACCEPT, or why not) and DECLINE.
func _invite_card(c: Dictionary) -> void:
	var row := _painted_row(INVITE_H)
	row.add_child(UI.image("hall/card_invite", Rect2(183, 0, 740, 170)))
	var id := _id_of(c)
	_crest(row, id, INVITE_CREST)
	var name := str(c.get("name", ""))
	_plate_text(row, name, INVITE_NAME, 28, UI.INK, "title", 700)
	_plate_text(row, "[%s]  ·  Lv %d  ·  %d/%d lords" % [str(c.get("tag", "")),
		int(c.get("level", 1)), int(c.get("members", 0)), int(c.get("member_cap", 0))],
		INVITE_INFO, 20, UI.GOLD_DIM)
	var action := str(c.get("action", ""))
	if action == "accept":
		var yes := _button(row, "Accept", GREEN, ACCEPT_TAP, ACCEPT_PAINT)
		yes.pressed.connect(_accept.bind(id, c))
	else:
		_state_button(row, action, id, name, ACCEPT_TAP, ACCEPT_PAINT, c)
	var no := _button(row, "Decline", DARK, DECLINE_TAP, DECLINE_PAINT)
	no.pressed.connect(_decline.bind(id, name))


## A kingdom to join: its crest, its name and tag, its lords and its renown, and
## the one thing the player can do about it.
func _kingdom_card(c: Dictionary) -> void:
	var row := _painted_row(KINGDOM_H)
	row.add_child(UI.image("hall/card_kingdom", Rect2(183, 0, 740, 159)))
	var id := _id_of(c)
	_crest(row, id, KINGDOM_CREST)
	# The name on its plate; beside the lords, how many; beside the laurel, how
	# great. The tag has no plate here -- it is on an invitation, and it is what
	# the search finds -- and whether a kingdom takes requests is its button's
	# word.
	var name := str(c.get("name", ""))
	_plate_text(row, name, KINGDOM_NAME, 26, UI.INK, "title", 700)
	_plate_text(row, "%d/%d lords" % [int(c.get("members", 0)), int(c.get("member_cap", 0))],
		KINGDOM_LORDS, 20, UI.INK)
	# Always with its unit: a bare number beside a laurel could be anything.
	# In full while it reads; past that, the short form ("60K renown").
	var rep := int(c.get("reputation", 0))
	var renown := "Level %d  ·  %s renown" % [int(c.get("level", 1)), UI.grouped(rep)]
	if not _fits_one_line(renown, KINGDOM_RENOWN.size.x, ONE_LINE_MIN, "body", 600):
		renown = "Level %d  ·  %s renown" % [int(c.get("level", 1)), UI.short_number(rep)]
	_plate_text(row, renown, KINGDOM_RENOWN, 20, UI.GOLD_DIM)
	_state_button(row, str(c.get("action", "")), id, name, JOIN_TAP, JOIN_PAINT, c)


## The button a card's action names, in the painting's place for it.
func _state_button(row: Control, action: String, id: String, name: String,
		tap: Rect2, paint: Rect2, c: Dictionary) -> void:
	var b: Button
	match action:
		"join", "accept":
			b = _button(row, "Join", GREEN, tap, paint)
			b.pressed.connect(_join.bind(id, c))
		"request":
			b = _button(row, "Request", GREEN, tap, paint)
			b.pressed.connect(_request.bind(id, c))
		"requested":
			b = _button(row, "Requested", DARK, tap, paint)
			b.pressed.connect(_withdraw.bind(id, name))
		"full":
			b = _button(row, "Full", DARK, tap, paint)
			b.disabled = true
		"cooldown":
			b = _button(row, "Wait", DARK, tap, paint)
			b.disabled = true
		_:
			return
	b.set_meta("action", action)


## The kingdom's crest, over the painted shield's place: one of the twelve by
## the kingdom's id, drawn at its own 91:120 and centred in the place.
func _crest(row: Control, id: String, box: Rect2) -> void:
	var t := UI.image(Art.crest(id), box)
	Look.paint_crest(t, Art.crest(id))
	row.add_child(t)


func _id_of(c: Dictionary) -> String:
	return str(c.get("id", c.get("kingdom_id", "")))


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

## RAISE YOUR OWN BANNER: what it costs and asks, on the card's plate, and FOUND
## -- dim, with the reason on the plate instead, when the server says it cannot
## be done.
func _found_card() -> void:
	var row := _painted_row(FOUND_H)
	row.add_child(UI.image("hall/card_found", Rect2(183, 0, 740, 192)))
	var can := bool(data.get("can_found", true))
	var cost := "%s gold  ·  level %d and up" % [UI.grouped(int(data.get("found_cost", 0))),
		int(data.get("found_level", 20))]
	# The plate takes the cost, or the server's reason for refusing (the only
	# one it sends is "Reach level 20"; the tests try a longer one). Never cut:
	# one line at a size that reads, or two inside the border.
	var line := _plate_words(row, cost if can else str(data.get("found_reason", "")), FOUND_TEXT, 22,
		UI.GOLD if can else UI.RED)
	line.set_meta("found_plate", true)
	var b := _button(row, "Found", GREEN, FOUND_TAP, FOUND_PAINT)
	b.disabled = not can
	b.set_meta("action", "found")
	b.pressed.connect(func() -> void: found_pressed.emit())
