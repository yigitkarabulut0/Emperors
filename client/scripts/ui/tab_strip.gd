class_name TabStrip
extends Control
## The one row of tabs. Every tab in the game is one of the painted plates in
## art/reference/tabs_sheet_a.png, tabs_sheet_b.png and tabs_sheet_c.png, cut by
## art/slices/tabs_sheet.json as tabs/<id> (slate navy, steel rim) and
## tabs/<id>_lit (crimson, gold rim), the word painted on it.
##
## A strip of three or more whose words all have a short plate
## (tabs_sheet_c.png, tabs/short_<id>, about three to one) draws those: the
## long plates four abreast shrank to 0.54 and their words went thinner than
## the paintings'. The Kingdom's REALM / LORDS / WORKS / RANKS, the battle
## history's ALL / MY RAIDS / ON ME and the strips of four to come (Attack's
## RAID / ARENA / CAMPAIGN / BOUNTIES, the Kingdom's second row) are one plate;
## each is drawn at its own painting's size, as every strip is. The ids stay the
## words; only the plates change.
##
## A strip is given the ids it shows and the rect it may fill. It draws every
## plate at one size -- the largest that puts them side by side inside the rect
## without drawing a painting up -- with the outer two on the rect's edges and
## the same space between each pair, all standing on the rect's floor, where the
## paintings stand theirs on a rule. A tap lights that plate and says so with
## `changed`. A tab that is off (not yet open, or locked) is dimmed and does not
## answer.
##
## The plates of a sheet are all one size, and each crop is centred on its own
## plate, so lighting a tab changes its colour and nothing else. They are never
## stretched: a strip that mixes the two sheets' plates draws each at its own
## proportions, centred in the one box.
##
## The tap area of each plate is the whole height of the rect and its share of
## the width, so a short plate is still a thumb's target.
##
## A word no plate carries yet (the rankings' RAIDS, EXPERIENCE and RENOWN) is
## set in type on the plates with the word lifted (art/slices/tabs_blank.json:
## tabs/blank and tabs/short_blank, and their _lit), in the paintings' ivory
## Cinzel at the painted words' cap height -- and a strip that needs one sets
## every word of it so, as a strip never mixes long and short plates: a set
## word beside a painted one reads as two hands. The id is the word
## ("raids" -> RAIDS). When the word is painted, its plate takes over with no
## change to the strip's caller.

signal changed(id: String)
## A tab that is off but not deaf: the tap is answered with the words that say
## when it opens. A plate that simply swallows a finger reads as a broken
## screen, and the rail's locked entries have always said "Unlocks at level N".
signal refused(id: String, words: String)

const PREFIX := "tabs/"
const LIT := "_lit"
## The short plates: their prefix under PREFIX, and the least tabs a strip
## needs to take them.
const SHORT := "short_"
const SHORT_MIN := 3
## The count bubble the rail's entries wear, on a plate's upper right corner.
const BUBBLE := "icons/count_bubble"
const BUBBLE_SIZE := 42.0
## How a tab that is off is drawn: the plate and its word, dimmed.
const OFF := Color(0.5, 0.5, 0.55)
## The least space between two plates, so their rims never run into one.
const MIN_GAP := 6.0
## The plate with no word, under PREFIX (and after SHORT), for a word set in type.
const BLANK := "blank"
## A set word's cap height as a share of its plate's, as the paintings' words
## stand: 26 of the long plates' 87, 22.5 of the short ones' 80.
const WORD_CAP := 26.0 / 87.0
const SHORT_WORD_CAP := 22.5 / 80.0
## Cinzel's capitals are this share of its size.
const CINZEL_CAP := 0.70
## The painted words' ivory, their weight (stems three units across at the
## rankings' plate, as painted: UI.settings lifts it by 100), and the width a
## set word may take of its plate.
const WORD_INK := Color("#EDE6D6")
const WORD_WEIGHT := 550
const WORD_SPAN := 0.8

var ids: Array = []
var selected := ""
## Whether this strip draws the short plates.
var short := false
## Whether this strip sets its words in type on the plates with no word.
var set_in_type := false
var plate_size := Vector2.ZERO
var _plates: Dictionary = {}
var _hits: Dictionary = {}
var _bubbles: Dictionary = {}
var _off: Dictionary = {}
## What a tab that is off says when it is tapped, by id.
var _words: Dictionary = {}


## A strip of `tab_ids` filling `rect` (in its parent's space), `first` lit.
## `max_scale` caps how large a plate is drawn against its painting; leave it at
## 1 so none is ever drawn up.
static func make(tab_ids: Array, rect: Rect2, first: String = "", max_scale: float = 1.0) -> TabStrip:
	var s := TabStrip.new()
	s.setup(tab_ids, rect, first, max_scale)
	return s


## Where each of `tab_ids` goes inside `rect`, and the one size they share:
## {"size": Vector2, "rects": [Rect2 per id, in the rect's own space], "scale": float}.
## Static and pure (bar reading the textures' sizes), so a test can ask it.
static func layout(tab_ids: Array, rect_size: Vector2, max_scale: float = 1.0) -> Dictionary:
	var n := tab_ids.size()
	var painted := Vector2.ZERO
	var use_short := takes_short(tab_ids)
	var typed := typeset(tab_ids)
	for id in tab_ids:
		for suffix in ["", LIT]:
			var t: Texture2D = Art.tex(plate_of(str(id), use_short, typed) + suffix)
			if t != null:
				painted = painted.max(t.get_size())
	if n == 0 or painted.x <= 0.0:
		return {"size": Vector2.ZERO, "rects": [], "scale": 0.0}
	var s := minf(max_scale, rect_size.y / painted.y)
	s = minf(s, (rect_size.x - MIN_GAP * float(n - 1)) / (painted.x * float(n)))
	# Whole units, and the painting's own shape to within half of one: the
	# height is floored and the width follows it.
	var h := floorf(painted.y * s + 0.001)   # a scale given as h / painted comes back as h
	var size := Vector2(minf(roundf(h * painted.x / painted.y), floorf(painted.x * s)), h)
	var gap := 0.0 if n < 2 else (rect_size.x - size.x * float(n)) / float(n - 1)
	var rects: Array = []
	for i in n:
		var x := (rect_size.x - size.x) / 2.0 if n == 1 else (size.x + gap) * float(i)
		rects.append(Rect2(Vector2(x, rect_size.y - size.y).round(), size))
	return {"size": size, "rects": rects, "scale": s, "short": use_short, "typeset": typed}


## Whether a strip of `tab_ids` takes the short plates: three or more tabs,
## every one of whose words has one -- or three or more set in type, which
## the short plate with no word carries. A strip never mixes the two.
static func takes_short(tab_ids: Array) -> bool:
	if tab_ids.size() < SHORT_MIN:
		return false
	if typeset(tab_ids):
		return true
	return _all_painted(tab_ids, true)


## Whether a strip of `tab_ids` sets its words in type: when the painted
## plates cannot draw it -- a word with no long plate, in a strip that cannot
## take the short ones either.
static func typeset(tab_ids: Array) -> bool:
	if tab_ids.is_empty():
		return false
	if _all_painted(tab_ids, false):
		return false
	return not (tab_ids.size() >= SHORT_MIN and _all_painted(tab_ids, true))


static func _all_painted(tab_ids: Array, use_short: bool) -> bool:
	for id in tab_ids:
		var key := plate_name(str(id), use_short)
		if not Art.has(key) or not Art.has(key + LIT):
			return false
	return true


## The plate a tab wears, unlit: tabs/<id> or tabs/short_<id>.
static func plate_name(id: String, use_short: bool) -> String:
	return PREFIX + (SHORT if use_short else "") + id


## The plate a tab wears in a strip: its painted plate, or -- set in type --
## the plate with no word.
static func plate_of(id: String, use_short: bool, typed: bool) -> String:
	return (PREFIX + (SHORT if use_short else "") + BLANK) if typed else plate_name(id, use_short)


## A tab's word as it is set: its id in capitals, "this_week" -> THIS WEEK.
static func word_of(id: String) -> String:
	return id.replace("_", " ").to_upper()


func setup(tab_ids: Array, rect: Rect2, first: String = "", max_scale: float = 1.0) -> void:
	ids = tab_ids.duplicate()
	UI.place(self, rect)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var lay := layout(ids, rect.size, max_scale)
	plate_size = lay["size"]
	short = bool(lay.get("short", false))
	set_in_type = bool(lay.get("typeset", false))
	var rects: Array = lay["rects"]
	# Each plate's tap area reaches halfway to its neighbours and the full height.
	var gap := 0.0 if ids.size() < 2 else (rects[1] as Rect2).position.x - (rects[0] as Rect2).end.x
	for i in ids.size():
		var id := str(ids[i])
		var r: Rect2 = rects[i]
		var plate := TextureRect.new()
		plate.texture = Art.tex(plate_of(id, short, set_in_type))
		plate.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		plate.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
		UI.place(plate, r)
		add_child(plate)
		_plates[id] = plate
		if set_in_type:
			_set_word(plate, id)
		var left := 0.0 if i == 0 else r.position.x - gap / 2.0
		var right := rect.size.x if i == ids.size() - 1 else r.end.x + gap / 2.0
		var hit := UI.hotspot(Rect2(left, 0, right - left, rect.size.y))
		hit.pressed.connect(_tap.bind(id))
		add_child(hit)
		_hits[id] = hit
	select(first if first != "" else (str(ids[0]) if not ids.is_empty() else ""))


## A word set in type on a plate with none: the paintings' ivory Cinzel, its
## capitals the painted words' height, centred on the plate, shrunk only if it
## would run past the plate's face. A child of the plate, so it dims with it.
func _set_word(plate: TextureRect, id: String) -> void:
	var cap := (SHORT_WORD_CAP if short else WORD_CAP) * plate_size.y
	var size := int(roundf(cap / CINZEL_CAP))
	var l := UI.label(word_of(id), size, WORD_INK, "title", WORD_WEIGHT, HORIZONTAL_ALIGNMENT_CENTER)
	var box := Rect2(Vector2(plate_size.x * (1.0 - WORD_SPAN) / 2.0, 0), Vector2(plate_size.x * WORD_SPAN, plate_size.y))
	UI.place(l, box)
	l.set_meta("box_w", box.size.x)
	l.set_meta("word", word_of(id))
	plate.add_child(l)
	UI.fit_line(l, size, maxi(12, size - 8))


## The word set on `id`'s plate, or null when its plate is painted with it.
func word_label(id: String) -> Label:
	var p: TextureRect = _plates.get(id)
	if p == null:
		return null
	for c in p.get_children():
		if c is Label:
			return c
	return null


## Lights `id` and puts the others out. `announce` sends `changed` as a tap does.
func select(id: String, announce: bool = false) -> void:
	if not _plates.has(id):
		return
	selected = id
	for k in _plates:
		(_plates[k] as TextureRect).texture = Art.tex(plate_of(str(k), short, set_in_type) + (LIT if k == id else ""))
	if announce:
		changed.emit(id)


## Puts every plate out. A strip that is not the row you are on carries no lit
## tab: the Kingdom's two rows are one choice between eight, and CHAT lit below
## means REALM is not lit above.
func unlight() -> void:
	selected = ""
	for k in _plates:
		(_plates[k] as TextureRect).texture = Art.tex(plate_of(str(k), short, set_in_type))


## Turns a tab off (dimmed, deaf) or on again.
func set_enabled(id: String, on: bool) -> void:
	if not _plates.has(id):
		return
	_off[id] = not on
	if on:
		_words.erase(id)
	(_plates[id] as TextureRect).modulate = Color.WHITE if on else OFF
	(_hits[id] as Button).disabled = not on


## Turns a tab off but leaves it able to answer: dimmed, and a tap says `words`
## through `refused` rather than doing nothing at all.
func set_off(id: String, words: String) -> void:
	if not _plates.has(id):
		return
	_off[id] = true
	_words[id] = words
	(_plates[id] as TextureRect).modulate = OFF
	(_hits[id] as Button).disabled = false


func is_enabled(id: String) -> bool:
	return not bool(_off.get(id, false))


## A count on a tab, in the rail's own bubble on the plate's upper right corner;
## 0 takes it away. A bubble with nothing in it reads as though something waits.
func set_count(id: String, n: int) -> void:
	if not _plates.has(id):
		return
	var b: TextureRect = _bubbles.get(id)
	if b == null:
		b = UI.image(BUBBLE, Rect2())
		var label := UI.label("", 24, Color("#FFF4EC"), "title", 800, HORIZONTAL_ALIGNMENT_CENTER)
		UI.place(label, Rect2(0, 0, BUBBLE_SIZE, BUBBLE_SIZE - 2))
		b.add_child(label)
		b.set_meta("count", label)
		add_child(b)
		_bubbles[id] = b
	var r := Rect2((_plates[id] as TextureRect).position, plate_size)
	UI.place(b, Rect2(r.end.x - BUBBLE_SIZE * 0.75, r.position.y - BUBBLE_SIZE * 0.3,
		BUBBLE_SIZE, BUBBLE_SIZE))
	b.visible = n > 0
	(b.get_meta("count") as Label).text = str(n) if n < 10 else "9+"


## The plate drawn for `id`, for tests and for anything placed against it.
func plate(id: String) -> TextureRect:
	return _plates.get(id)


func _tap(id: String) -> void:
	if not is_enabled(id):
		if _words.has(id):
			refused.emit(id, str(_words[id]))
		return
	if id == selected:
		return
	select(id, true)
