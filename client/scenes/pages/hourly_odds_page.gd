extends RefCounted
## THE ROYAL HOURS — behind the Events page's ROYAL HOURS strip: what every
## hour may bring, and how often.
##
## Every row is one row of the server's published table (GET /v1/festivals
## `hourly_table`): its painted mark, its name and what it does, how long it
## lasts, and its chance of an hour, worked out from the basis points the
## server rolls with. The chances are the server's own and add up to the whole
## hour; the page never works one out. The hour running is marked as such.
##
## A plain page, as the Tax Cart's odds are (cart_odds_page.gd): the painted
## header scenes each belong to one information page, and the rows carry the
## kit's own paintings.

const ROW_H := 104.0
const ICON := 76.0
## The quiet hour's row carries no mark of its own: the dark gauge stands for
## the hour with nothing on it, as the rail's seal does.
const QUIET_MARK := "events_kit/gauge_dark"
const NAME_FIT := Vector2i(24, 17)
const BLURB_FIT := Vector2i(20, 14)
const PCT_FIT := Vector2i(26, 18)
## The hour running, in the gold the Collect tab marks a ready chest with.
const NOW_INK := Color("#F0D27A")


## `table` is the answer's `hourly_table`; `hourly` its `hourly`, so the hour
## running can be marked.
static func open(host: Node, table: Array, hourly: Dictionary = {}) -> Sheet:
	var s := Sheet.open(host, "THE ROYAL HOURS", "What each hour may bring, and how often.")
	if table.is_empty():
		s.paragraph("The hours could not be read. Close this and try again in a moment.", 22, UI.DIM)
	else:
		var now := str(hourly.get("id", ""))
		for row in table:
			if row is Dictionary:
				_row(s, row, str(row.get("id", "")) == now and now != "")
		s.paragraph("One hour in every " + _quiet_words(table) + " is quiet, and no event ever runs two hours "
			+ "running. What is on now, and what the next hour brings, are on the Events page.", 21, UI.DIM)
	s.add_close()
	return s


static func _row(s: Sheet, e: Dictionary, now: bool) -> void:
	var row := s.slot(ROW_H)
	var icon := str(e.get("icon", ""))
	var pic := TextureRect.new()
	pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pic.texture = Art.tex(icon if icon != "" else QUIET_MARK)
	UI.place(pic, Rect2(16, (ROW_H - ICON) / 2.0, ICON, ICON))
	row.add_child(pic)

	var x := 16.0 + ICON + 18.0
	var pct_w := 132.0
	var w := s.inner_w - x - pct_w - 16.0
	var name := UI.label(str(e.get("name", "")), NAME_FIT.x, NOW_INK if now else UI.GOLD, "title", 700)
	UI.place(name, Rect2(x, 16, w, 30))
	name.set_meta("box_w", w)
	row.add_child(name)
	UI.fit_line(name, NAME_FIT.x, NAME_FIT.y)

	var blurb := UI.label(_what(e, now), BLURB_FIT.x, UI.INK, "body", 600)
	UI.place(blurb, Rect2(x, 50, w, 38))
	blurb.set_meta("box_w", w)
	row.add_child(blurb)
	UI.fit_line(blurb, BLURB_FIT.x, BLURB_FIT.y)

	var pct := UI.label(chance_words(int(e.get("bp", 0))), PCT_FIT.x, UI.GOLD, "title", 800,
		HORIZONTAL_ALIGNMENT_RIGHT)
	UI.place(pct, Rect2(s.inner_w - pct_w - 16.0, (ROW_H - 34.0) / 2.0, pct_w, 34))
	pct.set_meta("box_w", pct_w)
	row.add_child(pct)
	UI.fit_line(pct, PCT_FIT.x, PCT_FIT.y)


## What a row does, and how long it lasts: "Every job pays double gold. 15
## minutes." The hour running says so first.
static func _what(e: Dictionary, now: bool) -> String:
	var out := str(e.get("blurb", ""))
	var mins := int(e.get("minutes", 0))
	if mins > 0:
		out += "  ·  %d minutes" % mins
	if now:
		out = "On now.  " + out
	return out


## A row's chance of an hour, from the basis points the server rolls with:
## "13%", and a hundredth where a row is thinner than a per cent.
static func chance_words(bp: int) -> String:
	if bp <= 0:
		return "—"
	if bp % 100 == 0:
		return "%d%%" % (bp / 100)
	return "%.1f%%" % (bp / 100.0)


## How often the quiet hour comes, as a reader counts it: "three".
static func _quiet_words(table: Array) -> String:
	var quiet := 0
	for e in table:
		if e is Dictionary and int(e.get("bp", 0)) > 0 and str(e.get("icon", "")) == "":
			quiet = int(e.get("bp", 0))
	if quiet <= 0:
		return "several"
	var every := roundi(10000.0 / float(quiet))
	const WORDS := ["", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
	return WORDS[every] if every < WORDS.size() else str(every)
