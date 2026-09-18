extends Control
## THE KINGDOM'S BEAST -- the Kingdom tab's BOSS sub-tab, from boss.png.
##
## One beast stands against the kingdom for forty-eight hours. Every member has
## six blows at it, each costing the energy a raid costs, and a blow is an
## ordinary battle cut short: what comes back is the same replay the Attack tab
## animates.
##
## Nothing here works anything out. The health left and its fraction, what a
## blow costs, how many are left, what counts as valour and what each chest is
## worth are all the server's (GET /v1/boss); the screen prints them. The
## beast's picture is chosen by its id, and the six are the painter's own
## (bosses_<id>.png, drawn down into the panel's window).

signal grew(height: float)

const SCREEN := "boss"
## The painting's own places, relative to the section's corner: the section
## stands at (168, 716) and the panel at (177, 719).
const PANEL := Rect2(9, 3, 749, 450)
const SCENE := Rect2(19, 21, 728, 300)
const GRIFFIN := Vector2(49, 48)
const GRIFFIN_L := Vector2(126, 21)
const GRIFFIN_R := Vector2(575, 21)
const NAME_PLATE := Rect2(174, 26, 400, 40)
## The bar's track, the plate that stands on it, and the plate's own words.
const HP_TRACK := Rect2(46, 327, 674, 27)
const HP_PLATE := Rect2(300, 325, 164, 31)
const TIMER := Rect2(104, 381, 133, 44)
## Six blows across the foot, at the painting's pitch.
const BLOW := Vector2(39, 45)
const BLOW_AT := Vector2(251, 382)
const BLOW_PITCH := 34.4
const ATTACK := Rect2(491, 372, 240, 62)
## Apple's 44 pt on the 941-unit grid: what a tap target may not go under.
const THUMB := 95.0
const ATTACK_COST := Rect2(673, 393, 51, 36)
## The three chests, each at its own painted width.
const CHESTS := [
	{"asset": "boss/chest_struck", "rect": Rect2(13, 463, 236, 151)},
	{"asset": "boss/chest_valour", "rect": Rect2(253, 463, 240, 151)},
	{"asset": "boss/chest_slain", "rect": Rect2(497, 463, 255, 151)},
]
## Where a chest's plate sits inside its card.
const CHEST_PLATE := Rect2(31, 111, 184, 36)
## The damage list: its head, then a row for every lord who has struck.
const DAMAGE_AT := Vector2(9, 620)
const DAMAGE_W := 746.0
const HEAD_H := 43.0
const ROW_TOP := 45.0
const ROW_PITCH := 53.67
const BODY_MARGIN := 24
## A row's pieces, from the row's own corner.
const MEDAL := Rect2(28, 0, 48, 50)
const FACE := Rect2(104, 0, 54, 52)
const ROW_NAME := Rect2(169, 11, 198, 33)
const ROW_TRACK := Rect2(379, 17, 216, 19)
const ROW_VALUE := Rect2(609, 8, 114, 38)
## What the painting leaves under the last row.
const DAMAGE_FOOT := 22.0
## A dim beast: the cycle is over and this is what stood.
const PAST := Color(0.62, 0.62, 0.68)
const OFF := Color(0.55, 0.55, 0.6)

var _data: Dictionary = {}
var _nodes: Array = []
var _busy := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	custom_minimum_size = Vector2(DAMAGE_W + 12.0, 400)
	_load()


func refresh() -> void:
	_load()


func _load() -> void:
	if _busy:
		return
	_busy = true
	var res: Api.Response = await Api.get_json("/v1/boss")
	_busy = false
	if not is_inside_tree():
		return
	_data = res.data if res.ok else {}
	_paint()


## Paints with a /v1/boss answer. Public for the tests and the captures.
func paint(v: Dictionary) -> void:
	_data = v
	_paint()


func _paint() -> void:
	for n in _nodes:
		(n as Node).queue_free()
	_nodes.clear()

	if _data.is_empty() or not bool(_data.get("unlocked", false)) or not bool(_data.get("has_kingdom", false)):
		_shut()
		return
	var beast: Variant = _data.get("beast")
	if not (beast is Dictionary):
		_waiting()
		return

	var standing := bool(_data.get("standing", false))
	_beast_panel(beast, standing)
	_chests()
	var h := _damage()
	custom_minimum_size = Vector2(DAMAGE_W + 12.0, h)
	size = custom_minimum_size
	grew.emit(h)


## No kingdom, or too young for the beast: said in as many words, with what the
## three chests hold, so a lord can see what a kingdom is for.
func _shut() -> void:
	var at := int(_data.get("unlock_level", 10))
	var words := "The kingdom's beast opens at level %d." % at
	if bool(_data.get("unlocked", false)) and not bool(_data.get("has_kingdom", false)):
		words = "A beast is a kingdom's. Join one, or found one, and one will come for you."
	var card := UI.empty_card(self, Rect2(PANEL.position.x, PANEL.position.y, PANEL.size.x, 220))
	(card["title"] as Label).text = "NO BEAST"
	(card["body"] as Label).text = words
	_nodes.append(card["node"])
	var h := 240.0
	_chests(220.0 + PANEL.position.y + 20.0)
	h = PANEL.position.y + 220.0 + 20.0 + 151.0
	custom_minimum_size = Vector2(DAMAGE_W + 12.0, h)
	size = custom_minimum_size
	grew.emit(h)


## Between beasts: the kingdom has never seen one.
func _waiting() -> void:
	var card := UI.empty_card(self, Rect2(PANEL.position.x, PANEL.position.y, PANEL.size.x, 220))
	(card["title"] as Label).text = "THE ROADS ARE QUIET"
	(card["body"] as Label).text = ("No beast stands against the kingdom. One comes for every "
		+ "kingdom in its turn, and every lord will have six blows at it.")
	_nodes.append(card["node"])
	var h := PANEL.position.y + 220.0 + 20.0 + 151.0
	_chests(PANEL.position.y + 240.0)
	custom_minimum_size = Vector2(DAMAGE_W + 12.0, h)
	size = custom_minimum_size
	grew.emit(h)


func _add(n: Node) -> Node:
	add_child(n)
	_nodes.append(n)
	return n


## THE BEAST: its painting in the panel's window, its name on the plate, what is
## left of it on the bar, and the blows this lord has left.
func _beast_panel(b: Dictionary, standing: bool) -> void:
	var art := str(b.get("art", ""))
	var key := "boss/scene_" + str(b.get("id", ""))
	if not Art.has(key) and art != "":
		key = "boss/scene_" + art.get_slice("/", 1)
	if Art.has(key):
		var scene := UI.image(key, SCENE)
		if not standing:
			(scene as CanvasItem).modulate = PAST
		_add(scene)
	_add(UI.image("boss/panel", PANEL))

	# The griffin is one ornament: the painting has the other turned round.
	_add(UI.image("boss/griffin", Rect2(PANEL.position + GRIFFIN_L, GRIFFIN)))
	var right := UI.image("boss/griffin", Rect2(PANEL.position + GRIFFIN_R, GRIFFIN))
	(right as TextureRect).flip_h = true
	_add(right)

	var plate := Rect2(PANEL.position + NAME_PLATE.position, NAME_PLATE.size)
	_add(UI.image("boss/name_plate", plate))
	var title := str(b.get("name", "")).to_upper()
	if int(b.get("level", 1)) > 1:
		title += "  ·  %d" % int(b.get("level", 1))
	var name_label := UI.label(title, 30, UI.GOLD, "title", 700, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(name_label, plate)
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	UI.fit_wrapped(name_label, 30, 20, plate.size.y)
	_add(name_label)

	# What is left of it. The share is the SERVER'S basis points, never a
	# division done here: the bar and the figure beside it must agree.
	var left_bp := clampf(float(b.get("hp_left_bp", 0)) / 10000.0, 0.0, 1.0)
	var track := Rect2(PANEL.position + HP_TRACK.position, HP_TRACK.size)
	if left_bp > 0.0:
		_add(UI.nine("boss/hp_fill", Rect2(track.position,
			Vector2(maxf(18.0, track.size.x * left_bp), track.size.y)), 12))
	_add(UI.image("boss/hp_plate", Rect2(PANEL.position + HP_PLATE.position, HP_PLATE.size)))
	var hp := UI.label("%s / %s" % [UI.short_number(int(b.get("hp_left", 0))),
		UI.short_number(int(b.get("hp_max", 0)))], 22, UI.INK, "body", 600, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(hp, Rect2(PANEL.position + HP_PLATE.position, HP_PLATE.size))
	hp.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_add(hp)

	# The hourglass is painted; what it counts is the server's.
	var seconds := int(b.get("ends_in", 0)) if standing else int(_data.get("rises_in", 0))
	var when := UI.label(UI.time_left(seconds) if seconds > 0 else "OVER",
		24, UI.INK, "body", 600, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(when, Rect2(PANEL.position + TIMER.position, TIMER.size))
	when.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_add(when)

	var mine: Dictionary = _data.get("mine", {})
	var total := int(mine.get("hits_total", 6))
	var used := int(mine.get("hits", 0))
	# The painting stands the blows a lord still HAS first, in gold, and the
	# spent ones after them in steel.
	for i in total:
		var at := PANEL.position + BLOW_AT + Vector2(BLOW_PITCH * float(i), 0.0)
		_add(UI.image("boss/blow_on" if i < total - used else "boss/blow_off", Rect2(at, BLOW)))

	# The plate is the painting's 240x62; the TAP is a thumb's 95 both ways,
	# centred on it. The plate itself takes no press -- a painted plate that is
	# also the hit area cannot be given a bigger one.
	var can := bool(mine.get("can_strike", false))
	var plate_rect := Rect2(PANEL.position + ATTACK.position, ATTACK.size)
	var attack := UI.image("boss/attack", plate_rect)
	(attack as CanvasItem).modulate = Color.WHITE if can else OFF
	_add(attack)
	var tap := UI.hotspot(Rect2(plate_rect.position.x,
		plate_rect.position.y + (plate_rect.size.y - THUMB) / 2.0, plate_rect.size.x, THUMB))
	tap.disabled = not can
	tap.pressed.connect(_strike)
	_add(tap)
	var cost := UI.label(str(int(mine.get("energy", 0))), 24, UI.INK, "body", 700, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(cost, Rect2(PANEL.position + ATTACK_COST.position, ATTACK_COST.size))
	cost.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_add(cost)


## The three chests: what each asks for, what it holds, and whether this lord
## has earned it yet.
func _chests(top: float = -1.0) -> void:
	var chests: Array = _data.get("chests", [])
	for i in CHESTS.size():
		var spec: Dictionary = CHESTS[i]
		var rect: Rect2 = spec["rect"]
		if top >= 0.0:
			rect = Rect2(rect.position.x, top, rect.size.x, rect.size.y)
		var card := UI.image(str(spec["asset"]), rect)
		var c: Dictionary = chests[i] if i < chests.size() else {}
		var earned := bool(c.get("earned", false))
		if not earned:
			(card as CanvasItem).modulate = Color(0.78, 0.78, 0.82)
		_add(card)
		var plate := Rect2(rect.position + CHEST_PLATE.position, CHEST_PLATE.size)
		var words := str(c.get("name", "")).to_upper()
		var l := UI.label(words, 21, UI.GOLD if earned else UI.DIM, "title", 700,
			HORIZONTAL_ALIGNMENT_CENTER)
		UI.place(l, plate)
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		UI.fit_wrapped(l, 21, 15, plate.size.y)
		_add(l)
		# What it holds is one tap away: the card is the painting's own, and it
		# has room for a name and nothing else.
		var tap := UI.hotspot(rect)
		tap.pressed.connect(func() -> void: _chest_sheet(c))
		_add(tap)


## THE DAMAGE LIST: who has hurt it most. Returns the section's height.
func _damage() -> float:
	var rows: Array = _data.get("damage", [])
	var n := maxi(1, rows.size())
	var h := HEAD_H + ROW_TOP - HEAD_H + ROW_PITCH * float(n) + DAMAGE_FOOT
	var top := DAMAGE_AT.y
	_add(UI.image("boss/damage_head", Rect2(DAMAGE_AT.x, top, DAMAGE_W, HEAD_H)))
	_add(UI.nine("boss/damage_body", Rect2(DAMAGE_AT.x, top + HEAD_H, DAMAGE_W, h - HEAD_H), BODY_MARGIN))
	# What the first three take, said once beside the heading rather than on
	# every row: the rows are 54 apart and a caption under each one sat on the
	# next lord's plate.
	var top_diamonds: Array = _data.get("top_diamonds", [])
	if not top_diamonds.is_empty():
		var each := PackedStringArray()
		for d in top_diamonds:
			each.append(str(int(d)))
		var gems := UI.label("first three: %s diamonds" % " · ".join(each), 20, UI.GOLD_DIM,
			"body", 500, HORIZONTAL_ALIGNMENT_RIGHT)
		UI.place(gems, Rect2(DAMAGE_AT.x, top + 12.0, DAMAGE_W - 24.0, 24))
		_add(gems)

	if rows.is_empty():
		var none := UI.label("Nobody has raised a sword at it yet.", 24, UI.DIM, "body", 500,
			HORIZONTAL_ALIGNMENT_CENTER)
		UI.place(none, Rect2(DAMAGE_AT.x, top + HEAD_H + 20.0, DAMAGE_W, 40))
		_add(none)
		return top + h

	for i in rows.size():
		var r: Dictionary = rows[i]
		var y := top + ROW_TOP + ROW_PITCH * float(i)
		var place := int(r.get("place", i + 1))
		var medal := "boss/place_%d" % place if place <= 3 else "boss/place_plain"
		_add(UI.image(medal, Rect2(DAMAGE_AT.x + MEDAL.position.x, y + MEDAL.position.y, MEDAL.size.x, MEDAL.size.y)))
		if place > 3:
			var num := UI.label(str(place), 22, UI.GOLD_DIM, "title", 700, HORIZONTAL_ALIGNMENT_CENTER)
			UI.place(num, Rect2(DAMAGE_AT.x + MEDAL.position.x, y + MEDAL.position.y + 2.0,
				MEDAL.size.x, MEDAL.size.y - 4.0))
			num.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			_add(num)

		# A lord's face is the same object it is on every other screen.
		var face := UI.image(Art.avatar_ring(str(r.get("avatar", ""))),
			Rect2(DAMAGE_AT.x + FACE.position.x, y + FACE.position.y, FACE.size.x, FACE.size.y))
		_add(face)
		Look.paint_frame(face, r, "ring", FACE.size.x)

		var name_rect := Rect2(DAMAGE_AT.x + ROW_NAME.position.x, y + ROW_NAME.position.y,
			ROW_NAME.size.x, ROW_NAME.size.y)
		_add(UI.image("boss/damage_name", name_rect))
		var who := UI.label("", 24, UI.GOLD if bool(r.get("mine", false)) else UI.INK, "body", 600)
		UI.place(who, Rect2(name_rect.position.x + 10.0, name_rect.position.y,
			name_rect.size.x - 20.0, name_rect.size.y))
		who.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_add(who)
		Look.paint_name(who, r, str(r.get("name", "")), Rect2(name_rect.position.x + 10.0,
			name_rect.position.y, name_rect.size.x - 20.0, name_rect.size.y), 24, 16)

		var track := Rect2(DAMAGE_AT.x + ROW_TRACK.position.x, y + ROW_TRACK.position.y,
			ROW_TRACK.size.x, ROW_TRACK.size.y)
		_add(UI.image("boss/damage_track", track))
		var share := clampf(float(r.get("share_bp", 0)) / 10000.0, 0.0, 1.0)
		if share > 0.0:
			_add(UI.nine("boss/damage_fill", Rect2(track.position + Vector2(2, 2),
				Vector2(maxf(8.0, (track.size.x - 4.0) * share), track.size.y - 4.0)), 6))

		var value := Rect2(DAMAGE_AT.x + ROW_VALUE.position.x, y + ROW_VALUE.position.y,
			ROW_VALUE.size.x, ROW_VALUE.size.y)
		_add(UI.image("boss/damage_value", value))
		var dmg := UI.label(UI.short_number(int(r.get("damage", 0))), 22, UI.INK, "body", 600,
			HORIZONTAL_ALIGNMENT_CENTER)
		UI.place(dmg, value)
		dmg.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_add(dmg)

	return top + h


## One blow. Sequenced, because it spends energy: GameState.act attaches the
## number and adopts what comes back.
func _strike() -> void:
	if _busy:
		return
	var mine: Dictionary = _data.get("mine", {})
	if int(mine.get("hits_left", 0)) <= 0:
		GameState.toast("You have struck it as often as you may.")
		return
	_busy = true
	var res: Api.Response = await GameState.act("/v1/boss/hit", {}, {
		"no_blows": "You have struck it as often as you may.",
		"boss_down": "The beast is already down.",
		"boss_over": "This beast's days are over.",
		"no_boss": "No beast stands against your kingdom.",
		"not_enough_energy": "Not enough energy to raise a sword at it.",
	})
	_busy = false
	if not res.ok:
		return
	var beast: Dictionary = _data.get("beast", {})
	var replay: CanvasLayer = load("res://scenes/battle/battle_replay.gd").new()
	replay.setup(res.data, {"name": str(beast.get("name", "")), "avatar": ""})
	Nav.overlay_parent().add_child(replay)
	await replay.finished
	var said := "%s taken off it." % UI.short_number(int(res.data.get("damage", 0)))
	if bool(res.data.get("killed", false)):
		said = "%s is down. The chests come when the cycle closes." % str(beast.get("name", "It"))
	GameState.toast(said)
	_load()


## What a chest asks for and what it holds, in the server's own words.
func _chest_sheet(c: Dictionary) -> void:
	if c.is_empty():
		return
	var asks := {"hit": "Land one blow on the beast.",
		"valour": "Do half of an equal share of the kingdom's damage.",
		"kill": "Be in the kingdom that puts it down."}
	var lines: Array = c.get("lines", [])
	await Dialog.ask(self, {
		"title": str(c.get("name", "")),
		"body": "%s\n\n%s\n\nThe chests come by letter when the cycle closes." % [
			str(asks.get(str(c.get("need", "")), "")),
			", ".join(PackedStringArray(lines)) if not lines.is_empty() else "Nothing at all."],
		"confirm_text": "Close", "no_cancel": true,
	})
