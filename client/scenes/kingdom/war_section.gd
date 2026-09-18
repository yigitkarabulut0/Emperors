extends Control
## THE KINGDOM WAR -- the Kingdom tab's WAR sub-tab, from war.png.
##
## Kingdoms are drawn against each other on a Friday evening and fight from
## Saturday to Monday. Three attacks a day, and NOTHING of a lord's own is at
## stake: no gold is taken, no energy is spent, and a shield guards against
## raids, not against this. The screen says so in the server's own words.
##
## What a lord is worth to beat -- the Might ratio, its clamp and the quarter a
## routed lord pays -- is the SERVER'S arithmetic, quoted on the card before the
## tap and paid by the same function after it (GET /v1/war). The client prints
## it and works out nothing.

signal grew(height: float)

const SCREEN := "war"
## The painting's own places, read from the PANEL'S corner: war.png's panel is
## cut from (163, 517) and the section stands at (168, 716), so everything here
## is the painting's own offset from the panel and the whole screen sits five
## units right of where the painting has it -- which is what keeps its frame
## inside the page.
const PANEL := Rect2(0, 3, 769, 415)
## Both names, under their shields.
const NAME_OURS := Rect2(33, 227, 177, 38)
const NAME_THEIRS := Rect2(537, 227, 190, 38)
## The points bar: the two fills meet at the knob, so there is no empty track.
const BAR := Rect2(117, 283, 523, 29)
const KNOB := Vector2(26, 53)
const SCORE_OURS := Rect2(18, 276, 99, 44)
const SCORE_THEIRS := Rect2(640, 276, 103, 44)
## What is left of the week, and the banners this lord still holds.
const ENDS_IN := Rect2(321, 342, 184, 45)
const BANNER_BIG := Vector2(56, 66)
const BANNER_BIG_AT := Vector2(542, 336)
const BANNER_BIG_PITCH := 63.0

## THE ENEMY'S LORDS.
const LORDS_AT := Vector2(0, 429)
const LORDS_W := 769.0
const LORDS_HEAD := 51.0
const ROW_AT := Vector2(5, 51)
const ROW := Vector2(758, 88)
const ROW_PITCH := 94.67
const BODY_MARGIN := 24
const LORDS_FOOT := 18.0
## A row's pieces, from the row's own corner.
const FACE := Rect2(12, 7, 87, 82)
const ROW_NAME := Rect2(110, 25, 139, 40)
const ROW_MIGHT := Rect2(264, 25, 80, 39)
const ROW_BANNER := Vector2(29, 46)
const ROW_BANNER_AT := Vector2(359, 26)
const ROW_BANNER_PITCH := 30.5
const ROW_SWORDS := Rect2(459, 25, 44, 46)
const ROW_WORTH := Rect2(514, 25, 95, 40)
const ROW_FIGHT := Rect2(619, 19, 123, 54)
## The stamp. war.png's own routed row puts it across the NAME plate, which is
## where the artist could put it -- their mock row's name plate is empty. With a
## real name under it neither the name nor the Might beside it can be read, and
## those two are exactly what a lord compares when choosing whom to ride at. It
## goes over the BANNERS and the crossed swords instead (359..503), which for a
## routed lord are the faded ones and say nothing the word does not: the stamp
## is the same picture at the same size, over the part of the row that is
## already spent.
const ROUTED := Rect2(345, 16, 168, 68)

## THE WAR LOG.
const LOG_HEAD := 55.0
const LOG_LINE := 34.0
const LOG_PAD := 14.0

const OFF := Color(0.55, 0.55, 0.6)
const ROUT := Color(0.62, 0.62, 0.66)

var _data: Dictionary = {}
var _nodes: Array = []
var _busy := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	custom_minimum_size = Vector2(LORDS_W + 6.0, 400)
	_load()


func refresh() -> void:
	_load()


func _load() -> void:
	if _busy:
		return
	_busy = true
	var res: Api.Response = await Api.get_json("/v1/war")
	_busy = false
	if not is_inside_tree():
		return
	_data = res.data if res.ok else {}
	_paint()


## Paints with a /v1/war answer. Public for the tests and the captures.
func paint(v: Dictionary) -> void:
	_data = v
	_paint()


func _add(n: Node) -> Node:
	add_child(n)
	_nodes.append(n)
	return n


func _paint() -> void:
	for n in _nodes:
		(n as Node).queue_free()
	_nodes.clear()

	var war: Variant = _data.get("war")
	if _data.is_empty() or not bool(_data.get("unlocked", false)) or not bool(_data.get("has_kingdom", false)) \
			or not (war is Dictionary):
		var h := _between()
		custom_minimum_size = Vector2(LORDS_W + 6.0, h)
		size = custom_minimum_size
		grew.emit(h)
		return

	_banner(war)
	var h := _lords(war)
	h = _log(h)
	custom_minimum_size = Vector2(LORDS_W + 6.0, h)
	size = custom_minimum_size
	grew.emit(h)


## No war this week: why, and when the next pairs are drawn.
func _between() -> float:
	var title := "NO WAR THIS WEEK"
	var words := "The kingdom wars open at level %d." % int(_data.get("unlock_level", 10))
	if bool(_data.get("unlocked", false)) and not bool(_data.get("has_kingdom", false)):
		words = "A war is a kingdom's. Join one, or found one, and the realm will find you a foe."
	elif bool(_data.get("bye", false)):
		title = "NO FOE THIS WEEK"
		words = ("No kingdom was near enough in strength to be matched with yours. The banners rest, "
			+ "and the next pairs are drawn in %s.") % UI.time_left(int(_data.get("draws_in", 0)))
	elif bool(_data.get("has_kingdom", false)):
		words = ("The pairs are drawn in %s. A kingdom needs %d lords to be drawn at all."
			% [UI.time_left(int(_data.get("draws_in", 0))),
			int((_data.get("rules", {}) as Dictionary).get("min_members", 3))])
	var card := UI.empty_card(self, Rect2(0, PANEL.position.y, PANEL.size.x, 240))
	(card["title"] as Label).text = title
	(card["body"] as Label).text = words
	_nodes.append(card["node"])
	return PANEL.position.y + 260.0


## THE WEEK'S BANNER: both kingdoms, the points between them, what is left of
## the week and the banners this lord still holds.
func _banner(w: Dictionary) -> void:
	_add(UI.image("war/panel", PANEL))
	var mine: Dictionary = w.get("mine", {})
	var theirs: Dictionary = w.get("theirs", {})

	_side(mine, Rect2(PANEL.position + NAME_OURS.position, NAME_OURS.size))
	_side(theirs, Rect2(PANEL.position + NAME_THEIRS.position, NAME_THEIRS.size))

	# The bar is two fills that meet: the share is worked out from the two
	# scores the server sent, and an even week stands the knob in the middle.
	var ours := float(mine.get("points", 0))
	var them := float(theirs.get("points", 0))
	var share := 0.5 if ours + them <= 0.0 else clampf(ours / (ours + them), 0.06, 0.94)
	var bar := Rect2(PANEL.position + BAR.position, BAR.size)
	_add(UI.nine("war/points_ours", Rect2(bar.position, Vector2(bar.size.x * share, bar.size.y)), 10))
	_add(UI.nine("war/points_theirs", Rect2(bar.position + Vector2(bar.size.x * share, 0.0),
		Vector2(bar.size.x * (1.0 - share), bar.size.y)), 10))
	_add(UI.image("war/points_knob", Rect2(
		bar.position + Vector2(bar.size.x * share - KNOB.x / 2.0, (bar.size.y - KNOB.y) / 2.0), KNOB)))

	_score(Rect2(PANEL.position + SCORE_OURS.position, SCORE_OURS.size), int(ours))
	_score(Rect2(PANEL.position + SCORE_THEIRS.position, SCORE_THEIRS.size), int(them))

	var live := bool(w.get("live", false))
	var seconds := int(w.get("ends_in", 0)) if live else int(w.get("starts_in", 0))
	var when := UI.time_left(seconds) if seconds > 0 else "OVER"
	if bool(w.get("settled", false)):
		when = "WON" if bool(w.get("won", false)) else ("DRAWN" if bool(w.get("drawn", false)) else "LOST")
	var l := UI.label(when, 24, UI.INK, "body", 600, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(l, Rect2(PANEL.position + ENDS_IN.position, ENDS_IN.size))
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_add(l)

	# This lord's own banners: one for each the defender has left.
	var me: Dictionary = _data.get("mine", {})
	var banners := int(me.get("banners", 3))
	var lost := int(me.get("banners_lost", 0))
	for i in banners:
		var at := PANEL.position + BANNER_BIG_AT + Vector2(BANNER_BIG_PITCH * float(i), 0.0)
		var b := UI.image("war/banner_big", Rect2(at, BANNER_BIG))
		if i >= banners - lost:
			(b as CanvasItem).modulate = ROUT
		_add(b)


## One kingdom on its plate: its name, fitted to the plate the painting gave it.
##
## The plate holds one line and no more. A kingdom's name runs to twenty-four
## characters, so the type comes down until the whole of it is inside -- the tag
## and the muster are on the Kingdom tab's own header, a finger's width above.
func _side(s: Dictionary, rect: Rect2) -> void:
	var name_label := UI.label(str(s.get("name", "")).to_upper(), 24, UI.GOLD, "title", 700,
		HORIZONTAL_ALIGNMENT_CENTER)
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UI.place(name_label, rect)
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	# Two lines if it needs them: a kingdom's name runs to twenty-four letters
	# and the painting's plate is 177 wide, which is eleven at a readable size.
	UI.fit_wrapped(name_label, 24, 13, rect.size.y)
	_add(name_label)


func _score(rect: Rect2, points: int) -> void:
	var l := UI.label(UI.grouped(points), 28, UI.INK, "title", 700, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(l, rect)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_add(l)


## THE ENEMY'S LORDS, and what each is worth. Returns the height used.
func _lords(w: Dictionary) -> float:
	var rows: Array = _data.get("enemies", [])
	var n := maxi(1, rows.size())
	var h := LORDS_HEAD + ROW_PITCH * float(n) + LORDS_FOOT
	_add(UI.image("war/lords_head", Rect2(LORDS_AT.x, LORDS_AT.y, LORDS_W, LORDS_HEAD)))
	_add(UI.nine("war/lords_body", Rect2(LORDS_AT.x, LORDS_AT.y + LORDS_HEAD, LORDS_W, h - LORDS_HEAD),
		BODY_MARGIN))

	if rows.is_empty():
		var none := UI.label("The other side has nobody to fight.", 24, UI.DIM, "body", 500,
			HORIZONTAL_ALIGNMENT_CENTER)
		UI.place(none, Rect2(LORDS_AT.x, LORDS_AT.y + LORDS_HEAD + 22.0, LORDS_W, 40))
		_add(none)
		return LORDS_AT.y + h

	var live := bool(w.get("live", false)) and not bool(w.get("settled", false))
	var left := int((_data.get("mine", {}) as Dictionary).get("attacks_left", 0))
	for i in rows.size():
		_lord_row(rows[i], LORDS_AT + ROW_AT + Vector2(0.0, ROW_PITCH * float(i)), live and left > 0)
	return LORDS_AT.y + h


func _lord_row(r: Dictionary, at: Vector2, can_fight: bool) -> void:
	var routed := bool(r.get("routed", false))
	_add(UI.image("war/row", Rect2(at, ROW)))

	var face := UI.image(Art.avatar_ring(str(r.get("avatar", ""))),
		Rect2(at + FACE.position, FACE.size))
	if routed:
		(face as CanvasItem).modulate = ROUT
	_add(face)
	Look.paint_frame(face, r, "ring", FACE.size.x)

	var name_rect := Rect2(at + ROW_NAME.position, ROW_NAME.size)
	_add(UI.image("war/name_plate", name_rect))
	var who := UI.label("", 23, UI.INK, "body", 600)
	var inner := Rect2(name_rect.position.x + 9.0, name_rect.position.y, name_rect.size.x - 18.0, name_rect.size.y)
	UI.place(who, inner)
	who.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_add(who)
	Look.paint_name(who, r, str(r.get("name", "")), inner, 23, 15)

	var might_rect := Rect2(at + ROW_MIGHT.position, ROW_MIGHT.size)
	_add(UI.image("war/might_plate", might_rect))
	var might := UI.label(UI.short_number(int(r.get("might", 0))), 21, UI.INK, "body", 600,
		HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(might, might_rect)
	might.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_add(might)

	# Their banners: the ones they still hold first, as the painting stands
	# them, and the fallen ones after in the painting's own dimmed red.
	var banners := int(r.get("banners", 3))
	var lost := int(r.get("banners_lost", 0))
	for i in banners:
		var bat := at + ROW_BANNER_AT + Vector2(ROW_BANNER_PITCH * float(i), 0.0)
		_add(UI.image("war/banner" if i < banners - lost else "war/banner_lost", Rect2(bat, ROW_BANNER)))

	_add(UI.image("war/swords_dim" if routed else "war/swords", Rect2(at + ROW_SWORDS.position, ROW_SWORDS.size)))

	var worth_rect := Rect2(at + ROW_WORTH.position, ROW_WORTH.size)
	_add(UI.image("war/worth_plate", worth_rect))
	var worth := UI.label("%d pts" % int(r.get("worth", 0)), 21, UI.GOLD if not routed else UI.DIM,
		"body", 600, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(worth, worth_rect)
	worth.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_add(worth)

	# The plate is the painting's 123x54; the tap is as tall as the row it sits
	# in, which is what the painting left between one lord and the next.
	var plate_rect := Rect2(at + ROW_FIGHT.position, ROW_FIGHT.size)
	var fight := UI.image("war/fight", plate_rect)
	(fight as CanvasItem).modulate = Color.WHITE if can_fight else OFF
	_add(fight)
	var tap := UI.hotspot(Rect2(plate_rect.position.x, at.y, plate_rect.size.x, ROW.y))
	tap.disabled = not can_fight
	tap.pressed.connect(func() -> void: _attack(r))
	_add(tap)

	# The stamp goes on last, over the spent banners: a lord with none left may
	# still be ridden at, for a quarter.
	if routed:
		_add(UI.image("war/routed", Rect2(at + ROUTED.position, ROUTED.size)))


## THE WAR LOG: what has happened this week, newest first.
func _log(top: float) -> float:
	var lines: Array = _data.get("log", [])
	var n := maxi(1, mini(lines.size(), 12))
	var h := LOG_HEAD + LOG_PAD + LOG_LINE * float(n) + LOG_PAD
	var y := top + 16.0
	_add(UI.image("war/log_head", Rect2(0, y, LORDS_W, LOG_HEAD)))
	_add(UI.nine("war/log_body", Rect2(0, y + LOG_HEAD, LORDS_W, h - LOG_HEAD), BODY_MARGIN))

	if lines.is_empty():
		var none := UI.label("Nothing has happened yet this week.", 23, UI.DIM, "body", 500,
			HORIZONTAL_ALIGNMENT_CENTER)
		UI.place(none, Rect2(0, y + LOG_HEAD + LOG_PAD, LORDS_W, LOG_LINE))
		_add(none)
		return y + h

	for i in n:
		var e: Dictionary = lines[i]
		var won := bool(e.get("won", false))
		var ours := bool(e.get("ours", false))
		var words := "%s %s %s" % [str(e.get("attacker", "")),
			"broke" if won else "was held by", str(e.get("defender", ""))]
		if int(e.get("points", 0)) > 0:
			words += "  ·  %d pts" % int(e.get("points", 0))
		if bool(e.get("routed", false)):
			words += "  ·  routed"
		var l := UI.label(words, 22, UI.INK if ours else UI.DIM, "body", 500)
		UI.place(l, Rect2(22, y + LOG_HEAD + LOG_PAD + LOG_LINE * float(i), LORDS_W - 44.0, LOG_LINE))
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_add(l)
	return y + h


## One attack. NOT sequenced: nothing of the lord's own moves, so the number the
## client's queued collects are waiting on must not move either.
func _attack(r: Dictionary) -> void:
	if _busy:
		return
	var rules: Dictionary = _data.get("rules", {})
	var ok := await Dialog.ask(self, {
		"title": "Ride out",
		"body": "%s  ·  %s Might\nWorth %d points to your kingdom.\n\n%s" % [
			str(r.get("name", "")), UI.short_number(int(r.get("might", 0))),
			int(r.get("worth", 0)), str(rules.get("shield_note", ""))],
		"confirm_text": "Fight", "danger": true,
	})
	if not ok:
		return
	_busy = true
	var res: Api.Response = await Api.post_json("/v1/war/attack", {"player_id": str(r.get("player_id", ""))})
	_busy = false
	if not res.ok:
		GameState.toast(res.error)
		return
	if res.data.get("snapshot") is Dictionary:
		GameState.adopt_async(res.data["snapshot"])
	var replay: CanvasLayer = load("res://scenes/battle/battle_replay.gd").new()
	replay.setup(res.data, {"name": str(r.get("name", "")), "avatar": str(r.get("avatar", ""))})
	Nav.overlay_parent().add_child(replay)
	await replay.finished
	var said := "Held. %d point for turning up." % int(res.data.get("points", 0))
	if bool(res.data.get("won", false)):
		said = "A banner taken. %d points for the kingdom." % int(res.data.get("points", 0))
	GameState.toast(said)
	_load()
