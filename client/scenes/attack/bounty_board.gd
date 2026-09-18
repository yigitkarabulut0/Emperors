extends Control
## THE BOUNTY BOARD -- the Attack tab's BOUNTIES body, cut from
## art/reference/bounties.png (art/slices/bounties.json, layout
## client/layout/bounties.json).
##
## A price on a head, set for gold. What the crown takes is BURNED, which is
## why the board is a gold sink and not a way to move gold between two
## accounts, and the lord whose head it is gets a letter -- which is what makes
## it fair for a shield to stop a hunt.
##
## The one rule this screen exists to keep: THE CLIENT PRICES NOTHING. The
## board's three amounts and their fees arrive resolved (GET /v1/bounties), a
## tap names a PLATE and never a number, and a body carrying an "amount" is
## refused outright by the server's strict decode. The fee is printed as the
## server sent it -- never amount times a percentage -- and whether a purse can
## afford it is the server's `affordable`, not a comparison made here.
##
## A hunt is a raid: it costs the raid's energy, it can be stopped by the
## hunted lord's shield (the poster wears the raid's own shield pill for it),
## and it answers with the same replay the Attack tab animates.

signal grew(height: float)

const SCREEN := "bounties"
const DIMMED := Color(0.55, 0.55, 0.55)
const FRAME_BAND := 120.0
const NAME_SIZE := 23
const LINE_SIZE := 24
const LINE_MIN := 17
const FOOT := 1512.0
## What a band says when it holds nothing.
const NO_HEAD := "No price stands on your head."
const NO_MINE := "You have set no prices."

var _ui: Dictionary = {}
var _data: Dictionary = {}
var _posters: Array = []
var _amounts: Array = []
var _head_rows: Array = []
var _my_rows: Array = []
var _plate := ""                 ## the chosen price's plate id
var _target: Dictionary = {}     ## the chosen head
var _busy := false
var _loading := false
var _at_ms := 0


func _ready() -> void:
	size = Vector2(941, 1672)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui = Layout.build(SCREEN, self)
	_posters = _ui["poster"]
	_amounts = _ui["amount"]
	_head_rows = _ui["on_head_row"]
	_my_rows = _ui["your_row"]
	for i in _posters.size():
		var hit := UI.hotspot(Rect2(Vector2.ZERO, (_posters[i]["node"] as Control).size))
		hit.pressed.connect(_hunt.bind(i))
		_posters[i]["node"].add_child(hit)
		_posters[i]["hit"] = hit
	for i in _amounts.size():
		var hit := UI.hotspot(Rect2(Vector2.ZERO, (_amounts[i]["node"] as Control).size))
		hit.pressed.connect(_choose.bind(i))
		_amounts[i]["node"].add_child(hit)
	(_ui["place"] as BaseButton).pressed.connect(_place)
	var tick := Timer.new()
	tick.wait_time = 1.0
	tick.timeout.connect(_paint)
	add_child(tick)
	tick.start()
	_paint()


func height() -> float:
	return FOOT


func refresh() -> void:
	if _loading:
		return
	_loading = true
	var res: Api.Response = await Api.get_json("/v1/bounties")
	_loading = false
	if not is_inside_tree():
		return
	if res.ok and res.data is Dictionary:
		paint(res.data)


## Paints with a /v1/bounties answer. Public for tests and captures.
func paint(v: Dictionary) -> void:
	_data = v
	_at_ms = Time.get_ticks_msec()
	if _plate != "" and _preset(_plate).is_empty():
		_plate = ""
	_paint()


func _age() -> int:
	return int((Time.get_ticks_msec() - _at_ms) / 1000)


func _preset(id: String) -> Dictionary:
	for p in _data.get("presets", []):
		if p is Dictionary and str(p.get("id", "")) == id:
			return p
	return {}


func _paint() -> void:
	if _ui.is_empty():
		return
	var posters: Array = _data.get("posters", [])
	for i in _posters.size():
		var c: Dictionary = _posters[i]
		if i < posters.size():
			_paint_poster(c, posters[i])
		else:
			_blank_poster(c)
	_paint_rows(_head_rows, _data.get("on_my_head", []), NO_HEAD, true)
	_paint_rows(_my_rows, _data.get("mine", []), NO_MINE, false)

	var presets: Array = _data.get("presets", [])
	for i in _amounts.size():
		var a: Dictionary = _amounts[i]
		a["node"].visible = i < presets.size()
		if i >= presets.size():
			continue
		var p: Dictionary = presets[i]
		var value: Label = a["parts"]["value"]
		value.text = UI.grouped(int(p.get("amount", 0)))
		# Which price is chosen is said by the number's own colour. Nothing is
		# laid over the painted plate: a crop of one plate over another is a
		# different piece of the panel's gradient, and it reads as a patch.
		var chosen := str(p.get("id", "")) == _plate
		value.label_settings.font_color = UI.GOLD if chosen else UI.DIM
		UI.fit_label(value, 27, 18)
	_say_fee()
	var ready := _plate != "" and not _target.is_empty()
	(_ui["place"] as CanvasItem).modulate = Color.WHITE if ready else DIMMED
	grew.emit(height())


## The fee's line: the SERVER'S fee for the chosen plate, printed as it came,
## and the head it would be set on. Never a percentage worked out here.
func _say_fee() -> void:
	var l: Label = _ui["fee"]
	if _plate == "":
		l.text = "Choose a price"
	else:
		var p := _preset(_plate)
		var words := "%s burned" % UI.grouped(int(p.get("fee", 0)))
		if not _target.is_empty():
			words += "  ·  " + str(_target.get("name", ""))
		l.text = words
	UI.fit_label(l, 23, 16)


func _paint_rows(rows: Array, list: Array, empty: String, on_me: bool) -> void:
	for i in rows.size():
		var r: Dictionary = rows[i]
		var show := i < list.size() or (i == 0 and list.is_empty())
		r["node"].visible = show
		if not show:
			continue
		var l: Label = r["parts"]["words"]
		if list.is_empty():
			l.text = empty
		else:
			var b: Dictionary = list[i]
			var left := maxi(0, int(b.get("expires_in", 0)) - _age())
			var who := str(b.get("name", ""))
			l.text = "%s gold %s %s  ·  %s" % [UI.grouped(int(b.get("pot", 0))),
				"from" if on_me else "on", who, UI.short_duration(left)]
		UI.fit_label(l, LINE_SIZE, LINE_MIN)


func _paint_poster(c: Dictionary, b: Dictionary) -> void:
	var p: Dictionary = c["parts"]
	(p["portrait"] as TextureRect).texture = Art.tex(Art.avatar(str(b.get("avatar", ""))))
	(p["portrait"] as CanvasItem).visible = true
	Look.paint_frame(p["portrait"], b, "square", FRAME_BAND)
	Look.paint_name(p["name"], b, str(b.get("name", "")), _part_rect("poster", "name"),
		NAME_SIZE, 15, Color("#2B1B0E"))
	var shielded := int(b.get("shield_seconds", 0)) > 0
	(p["pot"] as Label).visible = not shielded
	(p["shield"] as CanvasItem).visible = shielded
	if shielded:
		(p["pot"] as Label).text = ""
	else:
		(p["pot"] as Label).text = UI.grouped(int(b.get("pot", 0)))
		UI.fit_label(p["pot"], 26, 18)
	(c["hit"] as BaseButton).disabled = shielded


## A slot with no price on it: the painting's own empty poster, at the
## brightness it was painted. Nothing is laid over it -- WANTED over an empty
## window and empty plates is what an empty poster looks like.
func _blank_poster(c: Dictionary) -> void:
	var p: Dictionary = c["parts"]
	(p["portrait"] as CanvasItem).visible = false
	(p["name"] as Label).text = ""
	(p["pot"] as Label).text = ""
	(p["shield"] as CanvasItem).visible = false
	(c["hit"] as BaseButton).disabled = true
	Look.paint_frame(p["portrait"], {}, "square", FRAME_BAND)


func _part_rect(el: String, part: String) -> Rect2:
	for q in Layout.element(SCREEN, el).get("parts", []):
		if str(q.get("id", "")) == part:
			return Layout.rect_of(q)
	return Rect2()


func _choose(i: int) -> void:
	var presets: Array = _data.get("presets", [])
	if i >= presets.size():
		return
	_plate = str((presets[i] as Dictionary).get("id", ""))
	_paint()


## Whose head. The lords the SERVER says a price may be set on: a name typed
## here could name somebody no rule allows, and the refusal would arrive as an
## error where a list is an answer.
func _place() -> void:
	if _busy:
		return
	if _plate == "":
		GameState.toast("Choose a price first")
		return
	var can: Array = _data.get("can_place", [])
	if can.is_empty():
		GameState.toast("Nobody to hunt yet — raid a rival first")
		return
	if _target.is_empty():
		await open_target_picker()
		return
	var p := _preset(_plate)
	_busy = true
	if await Dialog.ask(self, {"title": "Put %s on %s's head?" % [
			UI.grouped(int(p.get("amount", 0))), str(_target.get("name", ""))],
			"body": "%s gold is set on the head and %s is burned by the crier. It stands %d hours." % [
				UI.grouped(int(p.get("amount", 0))), UI.grouped(int(p.get("fee", 0))),
				int(_data.get("rules", {}).get("hours", 48))],
			"confirm_text": "Set the price", "danger": true}):
		var res: Api.Response = await GameState.act("/v1/bounties/place",
			{"target_id": str(_target.get("player_id", "")), "plate": _plate})
		if res.ok:
			_plate = ""
			_target = {}
	await refresh()
	_busy = false


## WHOSE HEAD? -- the lords the SERVER offers, on the painted sheet. The board
## has no name field, and that is the design working for us: a name typed here
## could name a lord no rule allows.
func open_target_picker() -> void:
	var can: Array = _data.get("can_place", [])
	if can.is_empty():
		return
	var sheet: Node = Sheet.open(self, "WHOSE HEAD?", "The lords you have crossed lately.")
	for t in can:
		var lord: Dictionary = t
		var row: NinePatchRect = sheet.slot(96.0)
		var face := UI.image(Art.avatar(str(lord.get("avatar", ""))), Rect2(14, 12, 72, 72))
		row.add_child(face)
		var name_l := UI.label("", 26, UI.INK, "body", 600)
		UI.place(name_l, Rect2(102, 14, sheet.inner_w - 130, 36))
		row.add_child(name_l)
		Look.paint_name(name_l, lord, str(lord.get("name", "")), Rect2(102, 14, sheet.inner_w - 130, 36), 26, 16)
		Sheet.put(row, "Level %d" % int(lord.get("level", 1)), Rect2(102, 52, 300, 32), 22, UI.DIM)
		var hit := UI.hotspot(Rect2(0, 0, sheet.inner_w, 96))
		hit.pressed.connect(func() -> void:
			_target = lord
			sheet.close()
			_paint()
			await _place())
		row.add_child(hit)
	sheet.add_close()


func _hunt(i: int) -> void:
	var posters: Array = _data.get("posters", [])
	if _busy or i >= posters.size():
		return
	_busy = true
	var b: Dictionary = posters[i]
	var body := "Costs %d energy. Win, and you carry off %s gold of the price on their head." % [
		int(b.get("energy_cost", 0)), UI.grouped(int(b.get("pays", 0)))]
	var attack: GDScript = load("res://scenes/tabs/attack.gd")
	var warn: String = attack.call("raid_warning", false,
		GameState.display_shield_seconds(), {"shield_breaks": true})
	if warn != "":
		body = warn + "\n" + body
	if await Dialog.ask(self, {"title": "Hunt %s?" % str(b.get("name", "")),
			"body": body, "confirm_text": "Hunt", "danger": true}):
		var res: Api.Response = await GameState.act("/v1/bounties/claim",
			{"bounty_id": str(b.get("id", ""))})
		if res.ok:
			await _show(res.data, b)
	await refresh()
	_busy = false


func _show(result: Dictionary, target: Dictionary) -> void:
	var replay: CanvasLayer = load("res://scenes/battle/battle_replay.gd").new()
	replay.setup(result, target)
	Nav.overlay_parent().add_child(replay)
	await replay.finished
	var paid := int(result.get("bounty_paid", 0))
	if paid > 0:
		GameState.toast("You collected %s gold of the price" % UI.grouped(paid))
