extends Control
## THE CONQUEST CAMPAIGN -- the Attack tab's CAMPAIGN body, cut from the ten
## maps and campaign_nodes_sheet.png (art/slices/campaign.json, layout
## client/layout/campaign.json).
##
## Ten chapters of twelve miles against the realm's own garrisons, from level
## six -- four levels before another lord may raid back. A lord learns what a
## battle is here, against a wall that is written down and never rolled, before
## one can happen to them.
##
## The map is the painting, whole and unscaled, and the twelve nodes stand ON
## its road: scripts/campaign-road.py seams the road out of each painting and
## writes twelve points per chapter into client/layout/campaign_nodes.json, in
## the painting's own pixels. This adds the map's own corner and nothing else,
## so a node's place is a measurement and never a guess.
##
## Every number here is the server's (GET /v1/campaign, /v1/campaign/{id}): what
## a mile costs, what it pays, what its garrison is worth, and how many stars
## the walk was worth. The fight is POST /v1/campaign/fight, the lord's own
## sequenced action, and what comes back is the same replay a raid animates --
## the client never simulates a battle.

signal grew(height: float)
## Asks the tab to bring a place on the page into view: the mile the lord is
## standing in front of, when the map opens. A body inside a scroll cannot move
## it itself, and reaching up the tree for its parent's container is how a
## screen starts depending on where it happens to be mounted.
signal scroll_to(y: float)

const SCREEN := "campaign"
const NODES := "res://layout/campaign_nodes.json"
## Where the map is drawn, which is the one place the road's own pixels become
## screen units.
const MAP := Vector2(160, 566)
const MAP_SIZE := Vector2(776, 1030)
## The strip of chapter plates, and the pitch it flows them at.
const PLATE_PITCH := 158.0
const PLATE_LIT := Vector2(160, 194)
## The chapter plate's own name board, which the layout measures off the
## painting: what a name has to fit into.
const NAME_H := 41.0
## ...but the three plate PICTURES do not carry that board in the same place,
## and a layout can record only one rect. Measured off the assets themselves
## (left edge, width, in the plate's own pixels):
##
##   plate_gold  28..126   99 wide
##   plate_shut  15..129  115 wide
##   plate_lit   29..133  105 wide
##
## The one recorded rect fits plate_gold, so on a SHUT chapter every name sat
## six units right of its board -- "THE MILLWATERS" left sixteen units of empty
## board on the left and touched the frame on the right.
const NAME_FIELD := {
	"campaign/plate_gold": Vector2(28.0, 99.0),
	"campaign/plate_shut": Vector2(15.0, 115.0),
	"campaign/plate_lit": Vector2(29.0, 105.0),
}
## Breathing room inside the board, so a long name never touches the frame.
const NAME_INSET := 6.0
## Under the map: the chapter's three chests, and the foot of the whole flow.
const CHEST_Y := 1622.0
const CHEST_PITCH := 150.0
const CHEST_X := 250.0
const FOOT := 1800.0
const DIMMED := Color(0.55, 0.55, 0.55)

var _ui: Dictionary = {}
var _data: Dictionary = {}          ## GET /v1/campaign
var _chapter: Dictionary = {}       ## GET /v1/campaign/{id}
var _roads: Dictionary = {}         ## the measured node points, by map number
var _plates: Array = []             ## the chapter strip's built plates
var _nodes: Array = []              ## the twelve built nodes of the open chapter
var _chests: Array = []
var _map: TextureRect
var _open := ""                     ## the chapter whose map is showing
var _busy := false
var _loading := false


func _ready() -> void:
	size = Vector2(941, 1672)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui = Layout.build(SCREEN, self)
	_map = _ui["map"]
	_roads = _read_roads()
	_paint()


## The measured twelve points of every map, in the paintings' own pixels.
func _read_roads() -> Dictionary:
	if not FileAccess.file_exists(NODES):
		push_warning("[campaign] no measured road points")
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(NODES))
	return parsed if parsed is Dictionary else {}


## The height the flow reaches, so the tab lays its foliage under it.
func height() -> float:
	return FOOT


func refresh() -> void:
	if _loading:
		return
	_loading = true
	var res: Api.Response = await Api.get_json("/v1/campaign")
	_loading = false
	if not is_inside_tree():
		return
	if res.ok and res.data is Dictionary:
		paint(res.data)
		await _open_chapter(str(res.data.get("chapter_id", "")))


## Paints with a /v1/campaign answer. Public for tests and captures.
func paint(v: Dictionary) -> void:
	_data = v
	_paint()


## Paints one chapter's twelve miles with a /v1/campaign/{id} answer. Public for
## the same reason.
func paint_chapter(v: Dictionary) -> void:
	_chapter = v
	_open = str(v.get("id", ""))
	_paint_map()


func _paint() -> void:
	if _ui.is_empty():
		return
	_paint_strip()
	_paint_map()


# --- the chapter strip ---------------------------------------------------------------

func _paint_strip() -> void:
	var strip: ScrollContainer = _ui.get("strip")
	if strip == null:
		return
	var content: Control = strip.get_meta("content")
	var chapters: Array = _data.get("chapters", [])
	while _plates.size() < chapters.size():
		var i := _plates.size()
		var built := Layout.instantiate(Layout.element(SCREEN, "chapter"))
		var node: Control = built["node"]
		content.add_child(node)
		var tap: BaseButton = built["parts"].get("tap")
		if tap != null:
			tap.pressed.connect(func() -> void: _tap_chapter(i))
		_plates.append(built)
	for i in _plates.size():
		var p: Dictionary = _plates[i]
		var node: Control = p["node"]
		node.visible = i < chapters.size()
		if not node.visible:
			continue
		var c: Dictionary = chapters[i]
		var here := str(c.get("id", "")) == _open
		var plate: TextureRect = p["parts"]["plate"]
		# The lit plate is a larger picture of the same object (it carries the
		# painting's own glow), so the row keeps its pitch and the lit one grows
		# out of its own middle rather than shoving its neighbours along.
		var lit_dx := (PLATE_LIT.x - node.size.x) / 2.0
		var art := "campaign/plate_lit" if here \
			else ("campaign/plate_gold" if bool(c.get("open", false)) else "campaign/plate_shut")
		plate.texture = Art.tex(art)
		UI.place(plate, Rect2(-lit_dx if here else 0.0, -5.0 if here else 0.0,
			PLATE_LIT.x if here else node.size.x, PLATE_LIT.y if here else node.size.y))
		node.position = Vector2(i * PLATE_PITCH, 0.0)
		var num: Label = p["parts"]["num"]
		num.text = str(i + 1)
		num.modulate = Color.WHITE if bool(c.get("open", false)) else DIMMED
		var name_l: Label = p["parts"]["name"]
		# The name goes on the board THIS plate carries, not the one the layout
		# could record. The lit plate is drawn a little left of its node, and
		# its board rides along with it.
		var field: Vector2 = NAME_FIELD.get(art, Vector2(29.0, 99.0))
		var name_rect := Rect2(field.x + NAME_INSET - (lit_dx if here else 0.0),
			Layout.rect_of(Layout.find(SCREEN, "name")).position.y,
			field.y - NAME_INSET * 2.0, NAME_H)
		UI.place(name_l, name_rect)
		name_l.set_meta("box_w", name_rect.size.x)
		name_l.text = board_name(str(c.get("name", "")), name_l, name_rect.size, 11)
		name_l.modulate = num.modulate
		# A wrapping name is fitted in BOTH directions: fit_line measures one
		# line and would shrink "The Cloudbreak Peaks" until it fitted on one,
		# spending the second line the board was sized for.
		# The board's own height, from the layout: a wrapping label has already
		# grown to its words by the time it is fitted, so it is told the box.
		UI.fit_wrapped(name_l, 17, 11, NAME_H)
	content.custom_minimum_size = Vector2(maxf(781.0, chapters.size() * PLATE_PITCH), PLATE_LIT.y)


## What the little board can actually carry.
##
## It is 41 units tall -- two lines of the painting's own type -- and a chapter
## of three words ("The Cloudbreak Peaks") wants three. Setting it small enough
## for three would make one plate in the row noticeably smaller than the rest, so
## the ARTICLE is dropped instead, which is what a nameplate does. The chapter is
## still The Cloudbreak Peaks on its map, in its dialogs and in the balance; only
## this board abbreviates, and only when the full name will not go.
static func board_name(full: String, l: Label, box: Vector2, min_size: int) -> String:
	var s := l.label_settings
	if s == null or s.font == null:
		return full
	var m := s.font.get_multiline_string_size(
		full.to_upper(), HORIZONTAL_ALIGNMENT_LEFT, box.x, min_size)
	if m.y <= box.y and m.x <= box.x:
		return full
	return full.substr(4) if full.begins_with("The ") else full


func _tap_chapter(i: int) -> void:
	var chapters: Array = _data.get("chapters", [])
	if i >= chapters.size() or _busy:
		return
	var c: Dictionary = chapters[i]
	if not bool(c.get("open", false)):
		GameState.toast("Walk the chapter before it to open %s." % str(c.get("name", "this map")))
		return
	await _open_chapter(str(c.get("id", "")))


func _open_chapter(id: String) -> void:
	if id == "":
		return
	_loading = true
	var res: Api.Response = await Api.get_json("/v1/campaign/%s" % id)
	_loading = false
	if not is_inside_tree():
		return
	if res.ok and res.data is Dictionary:
		paint_chapter(res.data)
		_paint_strip()


# --- the map -------------------------------------------------------------------------

func _paint_map() -> void:
	if _ui.is_empty():
		return
	var art := str(_chapter.get("art", ""))
	if art != "":
		_map.texture = Art.tex(art)
	UI.place(_map, Rect2(MAP, MAP_SIZE))
	_paint_nodes()
	_paint_chests()
	grew.emit(FOOT)


## The twelve nodes of the open chapter, each on its own measured point.
func _paint_nodes() -> void:
	for n in _nodes:
		(n["node"] as Control).queue_free()
	_nodes.clear()

	var stages: Array = _chapter.get("stages", [])
	var points: Array = _points_for(str(_chapter.get("art", "")))
	if points.is_empty():
		return
	var standing := -1
	var here: Control = null
	var bosses: Array = []
	for i in mini(stages.size(), points.size()):
		var s: Dictionary = stages[i]
		var boss := str(s.get("kind", "")) == "boss"
		var id := _template_for(boss, s)
		var e := Layout.element(SCREEN, id)
		var built := Layout.instantiate(e)
		var node: Control = built["node"]
		var centre: Array = e.get("centre", [node.size.x / 2.0, node.size.y / 2.0])
		var at := MAP + Vector2(float(points[i][0]), float(points[i][1]))
		node.position = at - Vector2(float(centre[0]), float(centre[1]))
		add_child(node)
		var num: Label = built["parts"].get("num")
		if num != null:
			num.text = str(int(s.get("stage", i + 1)))
		var hit := UI.hotspot(Rect2(Vector2.ZERO, node.size))
		# A node is 96 units wide, which is 40pt: the tap target is grown to the
		# thumb's own 44pt round the ring's middle rather than the crop's corner.
		UI.place(hit, Rect2(Vector2(float(centre[0]), float(centre[1])) - Vector2(55, 55), Vector2(110, 110)))
		node.add_child(hit)
		hit.pressed.connect(func() -> void: _tap_stage(i))
		built["hit"] = hit
		_nodes.append(built)
		if boss:
			bosses.append(node)
		if standing < 0 and bool(s.get("open", false)) and not bool(s.get("cleared", false)):
			standing = i
			here = node

	# The road is crowded on purpose -- twelve miles and 87 units between them --
	# so who stands in FRONT is decided rather than left to the order they were
	# built in. A boss is a landmark and its crown is never covered by the mile
	# above it; the mile the lord is standing in front of is in front of them all.
	for b in bosses:
		move_child(b, get_child_count() - 1)
	if here != null:
		move_child(here, get_child_count() - 1)
		# And the map opens where the lord left off, not at a chapter's far end.
		# Low enough on the screen that the road ahead is what a lord sees, and
		# high enough that the four sub-tabs are still under their thumb.
		scroll_to.emit(here.position.y - 760.0)


## Which of the eight node pictures a stage wears.
func _template_for(boss: bool, s: Dictionary) -> String:
	var stem := "boss" if boss else "node"
	if bool(s.get("cleared", false)):
		return stem + "_done"
	if not bool(s.get("open", false)):
		return stem + "_shut"
	return stem + "_now" if _is_next(s) else stem + "_open"


## The mile the lord stands in front of: the first open one they have not walked.
func _is_next(s: Dictionary) -> bool:
	for x in _chapter.get("stages", []):
		if bool(x.get("open", false)) and not bool(x.get("cleared", false)):
			return int(x.get("stage", 0)) == int(s.get("stage", -1))
	return false


func _points_for(art: String) -> Array:
	# "campaign/map_03" -> the third map's measured points.
	var key := art.get_slice("_", art.get_slice_count("_") - 1)
	var pts: Variant = _roads.get(key, [])
	return pts if pts is Array else []


# --- the chapter's chests ------------------------------------------------------------

func _paint_chests() -> void:
	var chests: Array = _chapter.get("chests", [])
	while _chests.size() < chests.size():
		var i := _chests.size()
		var built := Layout.instantiate(Layout.element(SCREEN, "chest"))
		add_child(built["node"])
		var tap: BaseButton = built["parts"].get("tap")
		if tap != null:
			tap.pressed.connect(func() -> void: _tap_chest(i))
		_chests.append(built)
	for i in _chests.size():
		var c: Dictionary = _chests[i]
		var node: Control = c["node"]
		node.visible = i < chests.size()
		if not node.visible:
			continue
		var v: Dictionary = chests[i]
		node.position = Vector2(CHEST_X + i * CHEST_PITCH, CHEST_Y)
		var open := bool(v.get("open", false)) and not bool(v.get("claimed", false))
		var box: TextureRect = c["parts"]["box"]
		box.texture = Art.tex("campaign/chest_open" if open else "campaign/chest_shut")
		UI.place(box, Rect2(0, 0 if open else 18, 127, 143 if open else 107))
		box.modulate = Color.WHITE if open or bool(v.get("claimed", false)) else DIMMED
		# What the chest is waiting for, in the fewest words that are true: the
		# stars still missing while it is shut, and its state once it is not.
		var need: Label = c["parts"]["need"]
		need.modulate = Color.WHITE if bool(v.get("open", false)) else DIMMED
		if bool(v.get("claimed", false)):
			need.text = "TAKEN"
		elif open:
			need.text = "OPEN"
		else:
			need.text = "%d / %d" % [int(_chapter.get("stars", 0)), int(v.get("stars", 0))]


func _tap_chest(i: int) -> void:
	var chests: Array = _chapter.get("chests", [])
	if _busy or i >= chests.size():
		return
	var v: Dictionary = chests[i]
	if bool(v.get("claimed", false)):
		GameState.toast("You have taken that chest.")
		return
	if not bool(v.get("open", false)):
		GameState.toast("%d stars open that chest." % int(v.get("stars", 0)))
		return
	_busy = true
	var res: Api.Response = await GameState.act("/v1/campaign/chest",
		{"chapter_id": _open, "index": i},
		{"chest_shut": "That chest is not open yet.", "chest_taken": "You have taken that chest."})
	if res.ok:
		GameState.toast(_claimed(res.data.get("granted", {})))
		await _load_map()
	_busy = false


# --- walking a mile ------------------------------------------------------------------

func _tap_stage(i: int) -> void:
	var stages: Array = _chapter.get("stages", [])
	if _busy or i >= stages.size():
		return
	var s: Dictionary = stages[i]
	if not bool(s.get("open", false)):
		GameState.toast("Walk the mile before it first.")
		return
	_busy = true
	if await _ask(s):
		await _fight(s)
	_busy = false


## The card that opens on a node: what stands there, what it costs and what it
## pays. Every line is the server's.
func _ask(s: Dictionary) -> bool:
	var cost := int(s.get("energy", 0))
	var have := GameState.display_energy()
	var lines: Array = s.get("lines", [])
	var body := "%s stands here with %d at their back.\nThe garrison is worth %s.\n\nCosts %d energy%s.\n%s" % [
		str(s.get("enemy", "A captain")), int(s.get("soldiers", 0)),
		UI.grouped(int(s.get("might", 0))), cost,
		"" if have >= cost else " -- you have %d" % have,
		"Wins: " + ", ".join(lines) if not lines.is_empty() else "",
	]
	if int(s.get("stars", 0)) > 0:
		body += "\nBest: %d of 3 stars." % int(s.get("stars", 0))
	else:
		body += "\nThree stars: win with more than half your health."
	return await Dialog.ask(self, {
		"title": "%s %d" % ["Boss" if str(s.get("kind", "")) == "boss" else "Stage", int(s.get("stage", 0))],
		"body": body, "confirm_text": "Fight", "danger": true,
	})


func _fight(s: Dictionary) -> void:
	var res: Api.Response = await GameState.act("/v1/campaign/fight",
		{"chapter_id": _open, "stage": int(s.get("stage", 0))},
		{"stage_shut": "The road to that mile is not open.",
		 "not_enough_energy": "Not enough energy for that mile.",
		 "campaign_locked": "The campaign opens later."})
	if not res.ok:
		return
	var replay: CanvasLayer = load("res://scenes/battle/battle_replay.gd").new()
	replay.setup(res.data, {"name": str(s.get("enemy", "")), "avatar": ""})
	Nav.overlay_parent().add_child(replay)
	await replay.finished
	if bool(res.data.get("won", false)):
		var stars := int(res.data.get("stars", 0))
		var best := int(res.data.get("best_stars", stars))
		var said := "%s -- %d of 3 stars%s" % [
			"The mile is yours" if bool(res.data.get("first_clear", false)) else "Walked again",
			stars, "" if stars >= best else " (best %d)" % best]
		var paid := _claimed(res.data.get("granted", {}))
		GameState.toast(said if paid == "" else said + ". " + paid)
	await _load_map()


## What a reward paid, in its own words: the server writes the lines and the
## screen prints them, as the letters do (mail_view.claimed_words).
func _claimed(granted: Dictionary) -> String:
	var lines: Array = granted.get("lines", [])
	if lines.is_empty():
		return ""
	var words: Array[String] = []
	for i in mini(lines.size(), 3):
		words.append(str(lines[i].get("text", "")))
	var out := ", ".join(words)
	if lines.size() > 3:
		out += " and %d more" % (lines.size() - 3)
	return out


## Reads the map and the chapter again, after something changed on it.
func _load_map() -> void:
	var res: Api.Response = await Api.get_json("/v1/campaign")
	if res.ok and res.data is Dictionary:
		paint(res.data)
	await _open_chapter(_open)
