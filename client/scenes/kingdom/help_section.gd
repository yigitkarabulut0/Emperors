extends Control
## THE KINGDOM'S HELP -- the Kingdom tab's HELP sub-tab, from help.png.
##
## Two panels, built in code like every other section on this tab: the day's
## shared goal, and the calls for aid.
##
## The goal's bar is the SERVER's two numbers (progress and target) and the
## chests' own thresholds; nothing here works out whether a chest is open. The
## aid rows are the calls standing in this kingdom, with the one thing each
## needs: whether this lord has already answered it.

signal grew(height: float)

const WIDTH := 762.0
const PAD := 22.0
const GAP := 20.0
const PLATE := "inventory/card_frame"
const PLATE_MARGIN := 26
## The painting's own objects, at their painted sizes.
const SCENE := Vector2(748.0, 340.0)
const AID_SCENE := Vector2(748.0, 170.0)
const BAR := Vector2(746.0, 34.0)
const KNOB := Vector2(26.0, 34.0)
const CHEST_PLATE := Vector2(126.0, 36.0)
const BUTTON := Vector2(336.0, 76.0)
const SHARE := Vector2(310.0, 76.0)
const STAT := Vector2(382.0, 68.0)
const ROW_H := 96.0
const FACE := 88.0
const AID_BTN := Vector2(126.0, 68.0)
const ASK := Vector2(744.0, 78.0)
## The two lines under the bar: the goal's name and what it asks for.
const NAME_H := 80.0

var _data: Dictionary = {}
var _nodes: Array = []
var _busy := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	custom_minimum_size = Vector2(WIDTH, 400)
	Realtime.frame.connect(_heard)
	Realtime.listen()
	_load()


func _exit_tree() -> void:
	Realtime.hush()


func refresh() -> void:
	_load()


func _heard(kind: String, _d: Dictionary) -> void:
	if kind == "aid" or kind == "goal" or kind == "resync":
		_load()


func _load() -> void:
	if _busy:
		return
	_busy = true
	var res: Api.Response = await Api.get_json("/v1/help")
	_busy = false
	if not is_inside_tree():
		return
	_data = res.data if res.ok else {}
	_paint()


## Paints with a /v1/help answer. Public for tests and captures.
func paint(v: Dictionary) -> void:
	_data = v
	_paint()


func _paint() -> void:
	for n in _nodes:
		(n as Node).queue_free()
	_nodes.clear()
	var y := 0.0
	if _data.is_empty():
		var none := UI.empty_card(self, Rect2(0, 0, WIDTH, 190))
		(none["title"] as Label).text = "NO KINGDOM TO CALL ON"
		(none["body"] as Label).text = "Aid and the day's goal belong to a kingdom. Join one, or found one."
		_nodes.append(none["node"])
		y = 190.0
	else:
		# Each panel answers with the y it ENDS at. They used to answer with
		# their own height, which is the same thing only for a panel starting at
		# zero: the aid panel's offset was dropped, so the section reported the
		# AID panel's height as the whole section's, the Kingdom page -- which
		# grows to what the section says -- never grew past the screen, and the
		# calls for aid and the ASK below the fold could not be reached at all.
		y = _goal_panel(y)
		y += GAP
		y = _aid_panel(y)
	custom_minimum_size = Vector2(WIDTH, y)
	size = Vector2(WIDTH, y)
	grew.emit(y)


func _panel(y: float, h: float) -> Control:
	var np := UI.nine(PLATE, Rect2(0, y, WIDTH, h), PLATE_MARGIN)
	add_child(np)
	_nodes.append(np)
	return np


## TODAY'S GOAL: the painting's title plate, its scene, the bar with its three
## chests, and what this lord may take.
func _goal_panel(top: float) -> float:
	var goal: Variant = _data.get("goal")
	var h := 54.0 + SCENE.y + 96.0 + NAME_H + 52.0 + BUTTON.y + PAD * 2.0
	if not (goal is Dictionary):
		h = 54.0 + 190.0 + PAD * 2.0
	var panel := _panel(top, h)
	var y := PAD
	panel.add_child(UI.image("help/title_goal", Rect2(PAD, y - 6.0, 320, 50)))
	y += 54.0
	if not (goal is Dictionary):
		var none := UI.empty_card(panel, Rect2(PAD, y, WIDTH - PAD * 2.0, 190))
		(none["title"] as Label).text = "NO GOAL TODAY"
		(none["body"] as Label).text = ("A shared goal needs a kingdom of three. Bring another lord in and "
			+ "the realm will set one tomorrow.")
		return top + h

	var g: Dictionary = goal
	var x := (WIDTH - SCENE.x) / 2.0
	panel.add_child(UI.image("help/goal_scene", Rect2(x, y, SCENE.x, SCENE.y)))
	y += SCENE.y - 26.0

	# The chests are the scene's own: the painter stood them on the bar inside
	# help/goal_scene, and a second copy of them laid over it drew a rectangle of
	# crowd across the picture. What is live is the bar under them -- its fill,
	# its knobs at the balance's own thresholds and the plates that name them.
	var chests: Array = g.get("chests", [])
	y += 18.0
	var track := UI.nine("help/bar_track", Rect2(x, y, BAR.x, BAR.y), 16)
	panel.add_child(track)
	var target := maxf(1.0, float(g.get("target", 1)))
	var share := clampf(float(g.get("progress", 0)) / target, 0.0, 1.0)
	if share > 0.0:
		var fill := UI.nine("help/bar_fill", Rect2(x + 4.0, y + 3.0, maxf(8.0, (BAR.x - 8.0) * share), BAR.y - 6.0), 12)
		panel.add_child(fill)
	for i in chests.size():
		var c: Dictionary = chests[i]
		var at := clampf(float(c.get("at_bp", 0)) / 10000.0, 0.0, 1.0)
		var kx := clampf(x + 4.0 + (BAR.x - 8.0) * at - KNOB.x / 2.0, x, x + BAR.x - KNOB.x)
		panel.add_child(UI.image("help/knob", Rect2(kx, y, KNOB.x, KNOB.y)))
		# The last chest stands at the bar's end, and its plate is as wide as
		# four numbers: kept inside the panel rather than hung off it.
		var px := clampf(kx + KNOB.x / 2.0 - CHEST_PLATE.x / 2.0, PAD, WIDTH - PAD - CHEST_PLATE.x)
		var plate := UI.image("help/plate", Rect2(px, y + 40.0, CHEST_PLATE.x, CHEST_PLATE.y))
		panel.add_child(plate)
		var words := "TAKEN" if bool(c.get("claimed", false)) else UI.grouped(int(c.get("at", 0)))
		var l := UI.label(words, 22, UI.INK, "body", 600, HORIZONTAL_ALIGNMENT_CENTER)
		UI.place(l, Rect2(px, plate.position.y, CHEST_PLATE.x, CHEST_PLATE.y))
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		panel.add_child(l)
		if not bool(c.get("reached", false)):
			(plate as CanvasItem).modulate = Color(0.55, 0.55, 0.6)
			l.modulate = Color(0.55, 0.55, 0.6)
	y += 96.0

	# What the day asks for, under its bar: on the scene it stood across the
	# chests the painter put there.
	var what := UI.label(str(g.get("name", "")), 30, UI.GOLD, "title", 700, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(what, Rect2(PAD, y, WIDTH - PAD * 2.0, 40))
	panel.add_child(what)
	var blurb := UI.label(str(g.get("blurb", "")), 22, UI.INK, "body", 500, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(blurb, Rect2(PAD, y + 40.0, WIDTH - PAD * 2.0, 32))
	panel.add_child(blurb)
	y += NAME_H

	# What this lord has done of it, and what they must do to claim.
	var mine := UI.label("Your share: %s of %s" % [UI.grouped(int(g.get("mine", 0))),
		UI.grouped(int(g.get("mine_need", 0)))], 22, UI.DIM, "body", 500, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(mine, Rect2(PAD, y, WIDTH - PAD * 2.0, 30))
	panel.add_child(mine)
	y += 38.0

	var share_btn := UI.tex_button("help/share", Rect2(PAD, y, SHARE.x, SHARE.y))
	share_btn.pressed.connect(_share)
	panel.add_child(share_btn)
	var take := _first_claimable(chests)
	var claim := UI.tex_button("help/claim", Rect2(WIDTH - PAD - BUTTON.x, y, BUTTON.x, BUTTON.y))
	claim.disabled = take < 0
	(claim as CanvasItem).modulate = Color.WHITE if take >= 0 else Color(0.5, 0.5, 0.55)
	claim.pressed.connect(func() -> void: _claim(take))
	panel.add_child(claim)
	return top + h


## The first chest this lord may take: reached, not taken, and their own share
## done. The server refuses the rest, and says which rule it was.
func _first_claimable(chests: Array) -> int:
	var goal: Dictionary = _data.get("goal", {})
	var enough := int(goal.get("mine", 0)) >= int(goal.get("mine_need", 1))
	for i in chests.size():
		var c: Dictionary = chests[i]
		if bool(c.get("reached", false)) and not bool(c.get("claimed", false)) and enough:
			return i
	return -1


func _claim(index: int) -> void:
	if index < 0 or _busy:
		return
	_busy = true
	var res: Api.Response = await Api.post_json("/v1/help/claim", {"index": index})
	_busy = false
	if res.ok:
		var lines: Array = res.data.get("lines", [])
		GameState.toast("Taken: " + ", ".join(PackedStringArray(lines)) if not lines.is_empty() else "Taken.")
		if res.data.get("snapshot") is Dictionary:
			GameState.adopt_async(res.data["snapshot"])
		_load()
	else:
		GameState.toast(res.error)


func _share() -> void:
	var g: Dictionary = _data.get("goal", {})
	var text := "%s: %s of %s in %s" % [str(g.get("name", "Our goal")),
		UI.grouped(int(g.get("progress", 0))), UI.grouped(int(g.get("target", 0))),
		UI.time_left(int(g.get("ends_in", 0)))]
	DisplayServer.clipboard_set(text)
	GameState.toast("Copied, to tell the hall.")


## AID: the calls standing in this kingdom, and this lord's own.
func _aid_panel(top: float) -> float:
	var calls: Array = _data.get("calls", [])
	var rows := maxi(1, calls.size())
	var h := 54.0 + AID_SCENE.y + 84.0 + rows * (ROW_H + 10.0) + ASK.y + PAD * 2.0
	var panel := _panel(top, h)
	var y := PAD
	var x := (WIDTH - AID_SCENE.x) / 2.0
	panel.add_child(UI.image("help/aid_scene", Rect2(x, y, AID_SCENE.x, AID_SCENE.y)))
	y += AID_SCENE.y + 12.0

	var members := UI.image("help/stat_members", Rect2(x, y, STAT.x, STAT.y))
	panel.add_child(members)
	var m := UI.label("%d of %d stacks" % [int(_data.get("my_stacks", 0)), int(_data.get("max_stacks", 0))],
		24, UI.INK, "body", 600, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(m, Rect2(x + 60.0, y, STAT.x - 70.0, STAT.y))
	m.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	panel.add_child(m)

	var energy := UI.image("help/stat_energy", Rect2(x + STAT.x + 6.0, y, 362, STAT.y))
	panel.add_child(energy)
	# Both sides of one answered call, which is how the server sends it: what it
	# gives the lord who asked, and what it pays the lord who answers. The
	# favour was computed every request and said nowhere, so a lord was asked to
	# spend one of the day's answers without being told they are paid for it.
	var words := "+%d%% for %dh" % [int(_data.get("aid_stack_bp", 0)) / 100, int(_data.get("aid_hours", 0))]
	var pays := int(_data.get("aid_favour", 0))
	if pays > 0:
		# "to answer" would drop the whole plate to 19 where its neighbour is at
		# 24; the plate is 286 wide and this reads at the row's own size.
		words += "  ·  +%d favour" % pays
	var e := UI.label(words, 24, UI.INK, "body", 600, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(e, Rect2(x + STAT.x + 66.0, y, 362 - 76.0, STAT.y))
	e.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	e.set_meta("box_w", 362 - 76.0)
	UI.fit_line(e, 24, 15)
	panel.add_child(e)
	y += STAT.y + 16.0

	if calls.is_empty():
		var none := UI.empty_card(panel, Rect2(PAD, y, WIDTH - PAD * 2.0, ROW_H))
		(none["title"] as Label).text = "NOBODY IS ASKING"
		(none["body"] as Label).text = "When a lord of this kingdom calls for aid, they appear here."
		y += ROW_H + 10.0
	else:
		for c in calls:
			_aid_row(panel, c, y)
			y += ROW_H + 10.0

	var ask := UI.tex_button("help/ask", Rect2((WIDTH - ASK.x) / 2.0, y, ASK.x, ASK.y))
	var wait := int(_data.get("ask_in", 0))
	ask.disabled = wait > 0
	(ask as CanvasItem).modulate = Color.WHITE if wait == 0 else Color(0.5, 0.5, 0.55)
	ask.pressed.connect(_ask)
	panel.add_child(ask)
	if wait > 0:
		var soon := UI.label("You may call again in %s" % UI.short_duration(wait), 20, UI.DIM, "body", 500,
			HORIZONTAL_ALIGNMENT_CENTER)
		UI.place(soon, Rect2(PAD, y + ASK.y - 6.0, WIDTH - PAD * 2.0, 26))
		panel.add_child(soon)
	return top + h


func _aid_row(panel: Control, call: Dictionary, y: float) -> void:
	var row := Control.new()
	row.mouse_filter = Control.MOUSE_FILTER_PASS
	UI.place(row, Rect2(PAD, y, WIDTH - PAD * 2.0, ROW_H))
	panel.add_child(row)
	var face := UI.image(Art.avatar_ring(str(call.get("avatar", ""))), Rect2(0, (ROW_H - FACE) / 2.0, FACE, FACE))
	face.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	row.add_child(face)
	Look.paint_frame(face, call, "ring", FACE * 0.11)
	row.add_child(UI.image("help/hand", Rect2(FACE + 8.0, (ROW_H - 72.0) / 2.0, 42, 72)))

	var plate := UI.image("help/row_name", Rect2(FACE + 60.0, (ROW_H - 52.0) / 2.0, 240, 52))
	row.add_child(plate)
	var who := UI.label("", 24, UI.INK, "body", 600, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(who, Rect2(FACE + 70.0, (ROW_H - 52.0) / 2.0, 220, 52))
	who.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(who)
	Look.paint_name(who, call, str(call.get("name", "")), Rect2(FACE + 70.0, (ROW_H - 52.0) / 2.0, 220, 52), 24, 16)

	var small := UI.image("help/row_small", Rect2(FACE + 310.0, (ROW_H - 58.0) / 2.0, 116, 58))
	row.add_child(small)
	var answered := UI.label("%d" % int(call.get("answers", 0)), 24, UI.INK, "body", 600,
		HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(answered, Rect2(FACE + 310.0, (ROW_H - 58.0) / 2.0, 116, 58))
	answered.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(answered)

	var give := UI.tex_button("help/aid_button", Rect2(row.size.x - AID_BTN.x, (ROW_H - AID_BTN.y) / 2.0,
		AID_BTN.x, AID_BTN.y))
	var done := bool(call.get("answered", false)) or int(_data.get("aid_left", 0)) <= 0
	give.disabled = done
	(give as CanvasItem).modulate = Color.WHITE if not done else Color(0.5, 0.5, 0.55)
	give.pressed.connect(func() -> void: _answer(str(call.get("id", ""))))
	row.add_child(give)


func _answer(aid_id: String) -> void:
	if aid_id == "" or _busy:
		return
	_busy = true
	var res: Api.Response = await Api.post_json("/v1/help/answer", {"aid_id": aid_id})
	_busy = false
	if res.ok:
		GameState.toast("+%d favour" % int(res.data.get("favour", 0)))
		_load()
	else:
		GameState.toast(res.error)


func _ask() -> void:
	if _busy:
		return
	_busy = true
	var res: Api.Response = await Api.post_json("/v1/help/ask", {})
	_busy = false
	if res.ok:
		GameState.toast("The hall has been told.")
		_load()
	else:
		GameState.toast(res.error)
