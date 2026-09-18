extends RefCounted
## THE DEEDS -- twenty-four deeds, each in four tiers (bronze, silver, gold,
## imperial), counted over a lord's life or read off their state, each tier
## paid when it is claimed and the fourth with its title. Painted:
## art/reference/deeds.png, cut by art/slices/deeds.json and laid out by
## layout/deeds.json on the painted pages' host (PaintedPage).
##
## Under the title, DEEDS / VICTORY ROAD: the Victory Road is the other page
## under the same two tabs, and a tap on its tab gives it this page's place
## (PaintedPage.swap), as the Deeds tab on the road gives it back.
##
## The seven discs are the deeds' seven kinds (labour, war, the kingdom, the
## crown, duty, fortune, trade): a tap shows that kind alone and dims the
## others; a tap on the one chosen shows them all again. A disc with a tier to
## claim in it wears the rail's count bubble.
##
## A row is one deed, as the painting's rows are drawn:
##  - its medallion is the highest medal claimed -- bronze, silver, gold,
##    imperial. The iron padlock is a deed not yet begun (nothing counted), and
##    the dark "?" a deed begun that has not yet won a medal: the medal it will
##    be is still to be decided, which is the one thing a "?" can honestly say
##    of a deed every lord can see;
##  - its name in the title plate, its sentence in the description plate;
##  - the bar to its next tier and the count on its plate ("5 / 100", the
##    server's figures); CLAIM while a tier waits, which takes every tier
##    reached; the tick seal once all four are claimed.
## A tap anywhere else on a row opens the deed: its four tiers, what each pays,
## and the title the fourth gives.
##
## GET /v1/achievements; POST /v1/achievements/claim {"id"}. Not the player's
## sequenced action: no action_seq, the answer's snapshot goes through
## GameState.adopt_async, and what a claim paid plays as the Royal Delivery.
##
## Opened from the Family screen's DEEDS card, from the Victory Road's DEEDS
## tab, and by --page deeds (--page deed with a deed's page open over it).

const PAGE := "deeds"
const ROAD_PAGE := "res://scenes/pages/road_page.gd"
const TABS := ["deeds", "victory_road"]
const CLAIM := "/v1/achievements/claim"
## The deeds' seven kinds, in the painting's order (the server's too).
const CATEGORIES := ["work", "war", "kingdom", "crown", "scroll", "laurel", "chest"]
## A disc while another kind is chosen: a TabStrip's tab that is off.
const OFF := TabStrip.OFF
## The painted rows' pitch (row 1's top to row 2's).
const PITCH := 137.0
## The medallion a deed wears, by the highest medal claimed; and the two
## states before the first.
const MEDALS := {"bronze": "deeds/medal_bronze", "silver": "deeds/medal_silver",
	"gold": "deeds/medal_gold", "imperial": "deeds/medal_imperial"}
const LOCKED := "deeds/medal_locked"
const UNKNOWN := "deeds/medal_unknown"
## Type: a name on one line of its plate, or on two smaller ones before it
## would go smaller still; a sentence on up to two lines; the count on its
## plate. The plates are painted two lines tall: lines are set LEADING of
## their size apart.
const NAME_SIZE := 24
const NAME_MIN := 20
const NAME_TWO := 20
const NAME_TWO_MIN := 15
const BLURB_SIZE := 21
const BLURB_MIN := 15
const COUNT_SIZE := 24
const COUNT_MIN := 16
const LEADING := 1.0
## The deed's page (a Sheet over this one): its rows, and the medals drawn
## down in them.
const DETAIL_LAYER := 62
const DETAIL_TOP_H := 176.0
const DETAIL_ROW_H := 118.0
const DETAIL_MEDAL := 146.0
const DETAIL_TIER_MEDAL := 96.0
const DETAIL_ICON := 56.0
const MEDAL_WORDS := {"bronze": "BRONZE", "silver": "SILVER", "gold": "GOLD", "imperial": "IMPERIAL"}


static func open(host: Node, opts: Dictionary = {}) -> PaintedPage:
	var p := PaintedPage.open(host, PAGE, opts)
	p.set_meta("host", host)
	p.set_meta("opts", opts)
	var r := Layout.rect_of(Layout.find(PAGE, "tabs"))
	var tabs := TabStrip.make(TABS, r, "deeds")
	p.place(tabs, r)
	tabs.changed.connect(func(id: String) -> void:
		if id == "victory_road":
			to_road(p))
	p.set_meta("tabs", tabs)
	p.set_meta("category", "")
	for inst in p.parts.get("category", []):
		var id := str((inst["data"] as Dictionary).get("id", ""))
		var ps: Dictionary = inst["parts"]
		(ps["disc"] as BaseButton).pressed.connect(func() -> void:
			if p.armed():
				choose(p, id))
		(ps["bubble"] as CanvasItem).visible = false
		(ps["count"] as CanvasItem).visible = false
	_load(p)
	return p


## The Victory Road in this page's place.
static func to_road(p: PaintedPage) -> PaintedPage:
	var o: Dictionary = (p.get_meta("opts", {}) as Dictionary).duplicate()
	o["instant"] = true
	var host: Node = p.get_meta("host", p)
	return p.swap(func() -> PaintedPage: return load(ROAD_PAGE).open(host, o))


static func _load(p: PaintedPage) -> void:
	var res: Api.Response = await Api.get_json("/v1/achievements")
	if not is_instance_valid(p):
		return
	if res.ok and res.data is Dictionary:
		paint(p, res.data)
		# A deed's page on arrival (--page deed): the one named, or "first" --
		# the first with a tier waiting, else the first.
		var want := str((p.get_meta("opts", {}) as Dictionary).get("detail", ""))
		if want != "" and not p.has_meta("detail_shown"):
			p.set_meta("detail_shown", true)
			var all: Array = res.data.get("achievements", [])
			var pick: Dictionary = {}
			for a in all:
				if a is Dictionary and (str(a.get("id", "")) == want or (want == "first" and int(a.get("claimable", 0)) > 0)):
					pick = a
					break
			if pick.is_empty() and want == "first" and not all.is_empty():
				pick = all[0]
			if not pick.is_empty():
				open_detail(p, pick)
	else:
		GameState.action_failed.emit("The deeds could not be read. " + res.error)


## Fills the page from a /v1/achievements answer. Separate from the load so a
## test can hand it the hard cases.
static func paint(p: PaintedPage, data: Dictionary) -> void:
	p.set_meta("data", data)
	_paint_categories(p, data)
	var chosen := str(p.get_meta("category", ""))
	var shown: Array = []
	for a in data.get("achievements", []):
		if a is Dictionary and (chosen == "" or str(a.get("category", "")) == chosen):
			shown.append(a)
	var content := p.content("list")
	var rows: Array = p.get_meta("rows", [])
	var tpl := Layout.find(PAGE, "row")
	while rows.size() < shown.size():
		var built := Layout.instantiate(tpl)
		content.add_child(built["node"])
		var i := rows.size()
		var ps: Dictionary = built["parts"]
		(ps["claim"] as BaseButton).pressed.connect(func() -> void:
			if p.armed():
				_claim_row(p, i))
		(ps["tap"] as BaseButton).pressed.connect(func() -> void:
			if p.armed():
				_tapped(p, i))
		rows.append(built)
	for i in rows.size():
		var node: Control = rows[i]["node"]
		node.visible = i < shown.size()
		if i < shown.size():
			node.position = Vector2(0, PITCH * float(i))
			dress(rows[i], shown[i])
	p.set_meta("rows", rows)
	p.set_meta("shown", shown)
	var sc := p.node("list") as ScrollContainer
	var h := PITCH * float(shown.size()) - (PITCH - Layout.rect_of(tpl).size.y)
	content.custom_minimum_size = Vector2(content.custom_minimum_size.x, maxf(h, 0.0))
	if sc != null and sc.scroll_vertical > int(maxf(0.0, h - sc.size.y)):
		sc.scroll_vertical = 0


## The discs: a bubble on each kind with a tier to claim, and the chosen kind
## lit with the rest dimmed (all lit while none is chosen).
static func _paint_categories(p: PaintedPage, data: Dictionary) -> void:
	var waiting := {}
	for c in data.get("categories", []):
		if c is Dictionary:
			waiting[str(c.get("id", ""))] = int(c.get("claimable", 0))
	var chosen := str(p.get_meta("category", ""))
	for inst in p.parts.get("category", []):
		var id := str((inst["data"] as Dictionary).get("id", ""))
		var ps: Dictionary = inst["parts"]
		var n := int(waiting.get(id, 0))
		(ps["bubble"] as CanvasItem).visible = n > 0
		var count: Label = ps["count"]
		count.visible = n > 0
		count.text = str(n) if n < 10 else "9+"
		(ps["disc"] as CanvasItem).modulate = Color.WHITE if chosen == "" or chosen == id else OFF


## Shows one kind alone, or all again when it is the kind already shown.
static func choose(p: PaintedPage, id: String) -> void:
	p.set_meta("category", "" if str(p.get_meta("category", "")) == id else id)
	var sc := p.node("list") as ScrollContainer
	if sc != null:
		sc.scroll_vertical = 0
	paint(p, p.get_meta("data", {}))


## One row from one deed.
static func dress(row: Dictionary, a: Dictionary) -> void:
	var ps: Dictionary = row["parts"]
	row["deed"] = a
	(ps["medal"] as TextureRect).texture = Art.tex(medal_asset(a))
	var name: Label = ps["name"]
	name.text = str(a.get("name", ""))
	name.autowrap_mode = TextServer.AUTOWRAP_OFF
	if not fit_lines(name, NAME_SIZE, NAME_MIN, 1):
		name.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		fit_lines(name, NAME_TWO, NAME_TWO_MIN, 2)
	var blurb: Label = ps["blurb"]
	blurb.text = str(a.get("blurb", ""))
	fit_lines(blurb, BLURB_SIZE, BLURB_MIN, 2)
	Layout.set_fill(ps["fill"], fill(a))
	var state := row_state(a)
	(ps["claim"] as CanvasItem).visible = state == "claim"
	(ps["seal"] as CanvasItem).visible = state == "done"
	(ps["count_plate"] as CanvasItem).visible = state == "count"
	var count: Label = ps["count"]
	count.visible = state == "count"
	count.text = count_words(a)
	count.label_settings.font_size = COUNT_SIZE
	UI.fit_line(count, COUNT_SIZE, COUNT_MIN)


## Sets a plate's words at the largest size, `max_size` down to `min_size`,
## at which they fit its box in at most `lines` lines LEADING apart, the lines
## evened, the block centred in the box. Returns whether they fitted (at
## min_size they are set regardless, and cut short on one line).
##
## UI.fit_wrapped measures with the font's own leading, a third taller than
## the plates allow: two lines never fitted, and every sentence came out on
## one line at the smallest size.
static func fit_lines(l: Label, max_size: int, min_size: int, lines: int) -> bool:
	if not l.has_meta("box_w"):
		l.set_meta("box_w", l.size.x)
	if not l.has_meta("box_rect"):
		l.set_meta("box_rect", Rect2(l.position, Vector2(float(l.get_meta("box_w")), l.size.y)))
	var box: Rect2 = l.get_meta("box_rect")
	var s := l.label_settings
	var size := max_size
	var fits := false
	while true:
		var n := UI.wrapped_lines(l.text, s.font, size, box.size.x).size() if lines > 1 else 1
		var w := s.font.get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
		fits = (lines > 1 and n <= lines) or (lines == 1 and w <= box.size.x)
		fits = fits and float(maxi(n, 1)) * float(size) * LEADING <= box.size.y + 0.5
		if fits or size <= min_size:
			break
		size -= 1
	s.font_size = size
	s.line_spacing = 0.0
	s.line_spacing = float(size) * LEADING - s.font.get_height(size)
	l.clip_text = lines == 1
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS if lines == 1 else TextServer.OVERRUN_NO_TRIMMING
	l.custom_minimum_size = Vector2.ZERO
	l.position = box.position
	l.size = box.size
	if lines > 1:
		l.set_meta("box_x", box.position.x)
		UI.balance_lines(l)
	# A Label is never shorter than its lines: centred on the box, not grown
	# down from its top.
	var block := l.get_minimum_size().y
	if block > box.size.y:
		l.position.y = box.position.y - (block - box.size.y) / 2.0
	return fits


## The medallion a deed wears (see the page's note).
static func medal_asset(a: Dictionary) -> String:
	var medal := str(a.get("medal", ""))
	if MEDALS.has(medal):
		return MEDALS[medal]
	return LOCKED if int(a.get("progress", 0)) <= 0 else UNKNOWN


## What the row's right shows: "claim" while a tier waits, "done" once every
## tier is claimed, else "count" -- the way to the next.
static func row_state(a: Dictionary) -> String:
	if int(a.get("claimable", 0)) > 0:
		return "claim"
	var tiers: Array = a.get("tiers", [])
	if not tiers.is_empty() and int(a.get("claimed", 0)) >= tiers.size():
		return "done"
	return "count"


## How far the bar runs: the count toward the next tier, as the plate says it;
## full once there is no tier left to reach.
static func fill(a: Dictionary) -> float:
	var next := int(a.get("next", 0))
	if next <= 0:
		return 1.0
	return clampf(float(int(a.get("progress", 0))) / float(next), 0.0, 1.0)


## The plate's count: "5 / 100", the server's figures, written as the
## paintings write money past a hundred thousand ("5.23M / 100B").
static func count_words(a: Dictionary) -> String:
	var n := int(a.get("progress", 0))
	var next := int(a.get("next", 0))
	if next <= 0:
		return UI.short_number(n)
	return "%s / %s" % [UI.short_number(n), UI.short_number(next)]


static func _tapped(p: PaintedPage, i: int) -> void:
	var shown: Array = p.get_meta("shown", [])
	if i < shown.size():
		open_detail(p, shown[i])


static func _claim_row(p: PaintedPage, i: int) -> void:
	var shown: Array = p.get_meta("shown", [])
	if i < shown.size():
		claim(p, str(shown[i].get("id", "")))


## Claims every tier waiting on one deed. One at a time.
static func claim(p: PaintedPage, id: String) -> void:
	if bool(p.get_meta("busy", false)) or id == "":
		return
	p.set_meta("busy", true)
	var res: Api.Response = await Api.post_json(CLAIM, {"id": id})
	if not is_instance_valid(p):
		return
	if res.ok:
		if res.data.get("snapshot", null) is Dictionary:
			GameState.adopt_async(res.data["snapshot"])
		var data: Variant = res.data.get("achievements", null)
		if data is Dictionary:
			paint(p, data)
			# The Family's DEEDS card and the rail count what waits; the next
			# heartbeat would say it in thirty seconds, the page knows it now.
			var b := GameState.badges.duplicate()
			b["achievements"] = int((data as Dictionary).get("claimable", 0))
			GameState.set_badges(b)
		var lines: Array = res.data.get("lines", [])
		if not lines.is_empty():
			var ceremony: GDScript = load("res://scenes/pages/ceremony.gd")
			ceremony.delivery(p.get_meta("host", p), {"title": "THE DEEDS", "lines": lines})
	elif res.code == "nothing_to_claim":
		GameState.toast("Nothing waits on that deed yet")
		_load(p)
	else:
		GameState.action_failed.emit(res.error)
	if is_instance_valid(p):
		p.set_meta("busy", false)


# --- a deed's page ------------------------------------------------------------------

## A deed: its medallion and its count, then its four tiers -- each medal, its
## target, what it pays and whether it is claimed -- and the title the fourth
## gives. CLAIM while a tier waits.
static func open_detail(p: PaintedPage, a: Dictionary) -> Sheet:
	var s := Sheet.open(p.get_meta("host", p), str(a.get("name", "")).to_upper(), str(a.get("blurb", "")),
		DETAIL_LAYER, "page:deed")
	var w := s.inner_w

	# The deed as it stands.
	var top := s.slot(DETAIL_TOP_H)
	var medal := UI.image(medal_asset(a), Rect2(10, (DETAIL_TOP_H - DETAIL_MEDAL) / 2.0, DETAIL_MEDAL, DETAIL_MEDAL))
	top.add_child(medal)
	var x := 10.0 + DETAIL_MEDAL + 12.0
	var tw := w - x - 20.0
	Sheet.put(top, standing_words(a), Rect2(x, 26, tw, 44), 30, UI.GOLD, "title", 700)
	var n := int(a.get("next", 0))
	var toward := "Every tier reached" if n <= 0 else "%s / %s toward %s" % [UI.grouped(int(a.get("progress", 0))),
		UI.grouped(n), str(MEDAL_WORDS.get(next_medal(a), "")).to_lower()]
	Sheet.put(top, toward, Rect2(x, 76, tw, 36), 24, UI.INK, "body", 600)
	var waiting := int(a.get("claimable", 0))
	var note := "%d tier%s to claim" % [waiting, "" if waiting == 1 else "s"] if waiting > 0 else ""
	if note != "":
		Sheet.put(top, note, Rect2(x, 118, tw, 34), 22, UI.GOLD, "body", 700)

	# The four tiers.
	var tiers: Array = a.get("tiers", [])
	for t in tiers:
		if t is Dictionary:
			_tier_row(s, t, int(a.get("progress", 0)))
	var title := str(a.get("title", ""))
	if title != "":
		s.paragraph("The imperial tier also gives the title “%s”." % title, 22, UI.DIM,
			HORIZONTAL_ALIGNMENT_CENTER)
	if waiting > 0:
		s.add_button("CLAIM", "confirm", func() -> void:
			s.close()
			claim(p, str(a.get("id", ""))))
	s.add_close()
	return s


## One tier: its medal drawn down, its name and target, what it pays, and its
## state -- the seal once claimed, "Ready" while it waits, the count toward it.
static func _tier_row(s: Sheet, t: Dictionary, progress: int) -> void:
	var row := s.slot(DETAIL_ROW_H)
	var w := s.inner_w
	var medal := str(t.get("medal", ""))
	var reached := bool(t.get("reached", false))
	var claimed := bool(t.get("claimed", false))
	var pic := UI.image(str(MEDALS.get(medal, UNKNOWN)),
		Rect2(10, (DETAIL_ROW_H - DETAIL_TIER_MEDAL) / 2.0, DETAIL_TIER_MEDAL, DETAIL_TIER_MEDAL))
	pic.modulate = Color.WHITE if reached else OFF
	row.add_child(pic)
	var x := 10.0 + DETAIL_TIER_MEDAL + 10.0
	var state_w := 128.0
	var reward_w := 250.0
	var text_w := w - x - reward_w - state_w - 24.0
	Sheet.put(row, str(MEDAL_WORDS.get(medal, medal.to_upper())), Rect2(x, 18, text_w, 40), 26,
		UI.GOLD if reached else UI.DIM, "title", 700)
	Sheet.put(row, "Reach " + UI.grouped(int(t.get("target", 0))), Rect2(x, 60, text_w, 36), 22,
		UI.INK if reached else UI.DIM, "body", 600)
	# What it pays: each line's picture and its figure (a title in its words).
	var rx := x + text_w + 8.0
	var ly := 14.0
	var lines: Array = t.get("lines", [])
	for line in lines:
		if not (line is Dictionary):
			continue
		var icon := TextureRect.new()
		icon.texture = Art.reward_line_icon(line)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var h := (DETAIL_ROW_H - 28.0) / float(maxi(1, lines.size()))
		var ic := minf(DETAIL_ICON, h)
		UI.place(icon, Rect2(rx, ly + (h - ic) / 2.0, ic, ic))
		row.add_child(icon)
		var words := UI.grouped(int(line.get("amount", 0))) if str(line.get("kind", "")) == "diamonds" \
			else str(line.get("text", ""))
		Sheet.put(row, words, Rect2(rx + ic + 8.0, ly, reward_w - ic - 8.0, h), 22 if lines.size() == 1 else 20,
			UI.INK, "body", 700)
		ly += h
	# Its state.
	var sx := w - state_w - 12.0
	if claimed:
		var seal := UI.image("deeds/seal", Rect2(sx + (state_w - 78.0) / 2.0, (DETAIL_ROW_H - 91.0) / 2.0, 78, 91))
		row.add_child(seal)
	elif reached:
		Sheet.put(row, "Ready", Rect2(sx, 0, state_w, DETAIL_ROW_H), 26, UI.GOLD, "title", 700,
			HORIZONTAL_ALIGNMENT_CENTER)
	else:
		Sheet.put(row, "%s / %s" % [UI.short_number(progress), UI.short_number(int(t.get("target", 0)))],
			Rect2(sx, 0, state_w, DETAIL_ROW_H), 22, UI.DIM, "body", 700, HORIZONTAL_ALIGNMENT_CENTER)


## The deed's standing, as its page's heading says it.
static func standing_words(a: Dictionary) -> String:
	var medal := str(a.get("medal", ""))
	if MEDAL_WORDS.has(medal):
		return "%s MEDAL" % MEDAL_WORDS[medal]
	return "NOT YET BEGUN" if int(a.get("progress", 0)) <= 0 else "NO MEDAL YET"


## The medal the next tier gives: the first tier not reached.
static func next_medal(a: Dictionary) -> String:
	for t in a.get("tiers", []):
		if t is Dictionary and not bool(t.get("reached", false)):
			return str(t.get("medal", ""))
	return ""
