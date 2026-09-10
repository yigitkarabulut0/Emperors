extends RefCounted
## RANKINGS — the lords of the realm by might, by level and by wealth.
##
## The server has kept these three boards (GET /v1/leaderboards/{board}) since
## the boards were built, and no screen showed them: a lord without a kingdom
## had no ranking to look at at all. Opened from the profile page.

const BOARDS := [["might", "MIGHT"], ["level", "LEVEL"], ["wealth", "WEALTH"]]
const ROW_H := 88.0


static func open(host: Node) -> Sheet:
	var s := Sheet.open(host, "RANKINGS", "The hundred greatest lords of the realm.", 70)
	s.set_meta("board", "might")
	_load(s)
	s.add_close()
	return s


static func _load(s: Sheet) -> void:
	s.clear_body()
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 12)
	tabs.custom_minimum_size = Vector2(s.inner_w, 96)
	s.body.add_child(tabs)
	var current := str(s.get_meta("board"))
	for b in BOARDS:
		var on: bool = b[0] == current
		var t := Sheet.button(str(b[1]), Dialog.CONFIRM_PLATE if on else Dialog.QUIET_PLATE,
			Color("#F3FBF3") if on else UI.DIM, 96, 24)
		t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		t.pressed.connect(func() -> void:
			s.set_meta("board", b[0])
			_load(s))
		tabs.add_child(t)
	var wait := s.paragraph("Reading the rolls...", 22, UI.DIM, HORIZONTAL_ALIGNMENT_CENTER)
	var res: Api.Response = await Api.get_json("/v1/leaderboards/%s" % current)
	if not is_instance_valid(s) or not is_instance_valid(wait):
		return
	wait.queue_free()
	if not res.ok:
		s.paragraph("The rankings could not be read. " + res.error, 22, UI.RED, HORIZONTAL_ALIGNMENT_CENTER)
		return
	var mine := int(res.data.get("my_rank", 0))
	s.paragraph(("You are ranked #%d" % mine) if mine > 0 else "You are not among the hundred yet.",
		24, UI.GOLD if mine > 0 else UI.DIM, HORIZONTAL_ALIGNMENT_CENTER)
	for r in res.data.get("rows", []):
		_row(s, r, int(r.get("rank", 0)) == mine, current)


static func _row(s: Sheet, r: Dictionary, me: bool, board: String) -> void:
	var row := s.slot(ROW_H)
	if me:
		row.self_modulate = Color(1.3, 1.15, 0.85)
	var rank := int(r.get("rank", 0))
	Sheet.put(row, "#%d" % rank, Rect2(18, 0, 84, ROW_H), 28, UI.GOLD if rank <= 3 else UI.INK, "title", 700)
	var face := UI.image(Art.avatar(str(r.get("avatar", ""))), Rect2(104, 10, 68, 68))
	face.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	face.clip_contents = true
	row.add_child(face)
	Sheet.put(row, str(r.get("name", "")), Rect2(188, 8, s.inner_w - 420, 40), 26, UI.INK, "body", 700)
	Sheet.put(row, "LEVEL %d" % int(r.get("level", 0)), Rect2(188, 46, 200, 30), 19, Color("#E4B13C"), "title", 600)
	var value := int(r.get("value", 0))
	var shown := UI.short_number(value) if board == "wealth" else UI.grouped(value)
	Sheet.put(row, shown, Rect2(s.inner_w - 230, 0, 212, ROW_H), 28, UI.INK, "body", 700, HORIZONTAL_ALIGNMENT_RIGHT)
