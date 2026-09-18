extends SceneTree
## The rankings are their painting (art/reference/rankings.png), on the painted
## pages' host, and hold on every phone.
##
## They were a Sheet: three dialog buttons and a list of plates. Now: the board
## and period rows are the game's tab plates, the first three stand on the
## podium in its rings, the rest of the hundred scroll in the list panel, and
## YOUR RANK is the asker's own. For the hard cases -- a hundred lords with the
## longest names, late-game figures, worn colours, titles and frames, an asker
## ranked and one not -- on 941x1672 and 941x2040, with and without a notch:
##  - the page is a PaintedPage and its list grows on the taller phone;
##  - the podium's faces sit in its three rings, a worn frame inside the ring;
##  - every row wears its lord's name in their colour, and every figure fits;
##  - YOUR RANK says the asker's place, or that they are not among the hundred;
##  - ALL TIME is lit, and THIS WEEK and SEASON do not answer until an answer
##    lists their boards;
##  - nothing leaves the screen or goes under the notch, and CLOSE closes.
## And the week's and the season's boards (Wave 4), from an answer that lists
## all nine boards:
##  - every period answers; the week's boards are RAIDS / EXPERIENCE, two plates
##    at the row of three's size and spacing, centred; the season's RENOWN /
##    RAIDS / EXPERIENCE / MIGHT on the short plates -- all set in type, as no
##    plate carries those words yet;
##  - the list opens with the prize row: the board's name, "Closes in ...", and
##    a cell per run of places (1st, 2nd–3rd, 4th–10th, 11th–50th) with its
##    figure, every word inside its box;
##  - lords level share a place (#4 twice), the podium holds the first three
##    as ordered, and YOUR RANK says when the asker is not on the week's rolls;
##  - an empty week says so under its prize row.
##
## Run: godot --headless --path client --script tests/rankings_page.gd

const CANVASES := [Vector2i(941, 1672), Vector2i(941, 2040)]
const INSETS := [0.0, 141.0]
const PODIUM := [[Vector2(470, 529), 132.0], [Vector2(221, 557), 114.0], [Vector2(718.5, 575.5), 111.0]]
const LONG := "Wwwwwwwwwwwwwwww"

var _fails := 0
var _checked := 0


func _initialize() -> void:
	await process_frame
	root.get_node("Env").set("api_base_url", "http://127.0.0.1:9")
	root.get_node("GameState").set("snapshot", {"player": {"username": LONG, "avatar": "witch", "level": 88,
		"gold": "1", "action_seq": 1, "worn": {"color": "#C84BE0", "title": "the Unbowed"}},
		"energy": {"current": 1, "max": 2}})
	for canvas in CANVASES:
		for inset in INSETS:
			await _check(canvas, inset, 57)
			await _check(canvas, inset, 0)
			await _periods(canvas, inset)
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d checks: the painted rankings hold their podium, their hundred and YOUR RANK on every phone" % _checked)
	quit()


func _rows() -> Array:
	var out: Array = []
	var frames := ["frames/aureole", "frames/patron", ""]
	for i in 100:
		var worn := {}
		if i < 3:
			worn = {"frame": frames[i], "color": "#E9C46A" if i != 1 else "#7FD4FF", "title": "the Magnificent"}
		elif i % 3 == 0:
			worn = {"color": "#FF6B6B", "title": "Lord of the Very Long Title"}
		out.append({"rank": i + 1, "name": LONG if i % 2 == 0 else "Aldric", "avatar": ["knight", "queen", "monk"][i % 3],
			"level": 99, "value": 9999999999 - i, "worn": worn, "vip_seal": i % 4 == 0})
	return out


## The nine boards an answer lists.
func _boards() -> Array:
	return [{"id": "might", "name": "Might", "period": "all"}, {"id": "level", "name": "Level", "period": "all"},
		{"id": "wealth", "name": "Wealth", "period": "all"},
		{"id": "week_raids", "name": "Raids this week", "period": "week"},
		{"id": "week_xp", "name": "Experience this week", "period": "week"},
		{"id": "season_renown", "name": "Renown this season", "period": "season"},
		{"id": "season_raids", "name": "Raids this season", "period": "season"},
		{"id": "season_xp", "name": "Experience this season", "period": "season"},
		{"id": "season_might", "name": "Might gained this season", "period": "season"}]


## A board that closes: its rewards and its time, as the server answers them.
func _closing(name: String, period: String, rows: Array, mine: int) -> Dictionary:
	var dia := func(n: int) -> Array: return [{"kind": "diamonds", "amount": n, "text": "%d diamonds" % n, "icon": "diamond"}]
	return {"rows": rows, "my_rank": mine, "my_value": 6 if mine > 0 else 0, "name": name, "period": period,
		"ends_in": 441386, "boards": _boards(),
		"rewards": [{"from": 1, "to": 1, "lines": dia.call(50)}, {"from": 2, "to": 3, "lines": dia.call(30)},
			{"from": 4, "to": 10, "lines": dia.call(15)}, {"from": 11, "to": 50, "lines": dia.call(5)}]}


func _periods(canvas: Vector2i, inset: float) -> void:
	var tag := "%dx%d inset %d" % [canvas.x, canvas.y, int(inset)]
	var vp := SubViewport.new()
	vp.size = canvas
	root.add_child(vp)
	root.get_node("Nav").set("host", vp)
	var host := Control.new()
	host.size = Vector2(canvas)
	vp.add_child(host)
	var script: GDScript = load("res://scenes/pages/leaderboard_page.gd")
	var page: Control = script.open(host, {"inset": inset, "board": "week_raids"})
	for i in 3:
		await process_frame
	# Lords level on raids share a place: two at #1, two at #4.
	var rows: Array = []
	var vals := [40, 40, 25, 12, 12, 9, 6, 3, 3, 1]
	var ranks := [1, 1, 3, 4, 4, 6, 7, 8, 8, 10]
	for i in vals.size():
		rows.append({"rank": ranks[i], "name": LONG if i % 2 == 0 else "Aldric", "avatar": "knight", "level": 60,
			"value": vals[i], "worn": {"frame": "frames/noble_duke", "title": "Duke"} if i == 3 else {}, "vip_seal": false})
	script.paint(page, _closing("Raids this week", "week", rows, 0), "week_raids")
	for i in 3:
		await process_frame
	var periods: Control = page.get_meta("periods")
	for id in ["this_week", "season", "all_time"]:
		_expect(periods.is_enabled(id), "%s: %s does not answer once the boards are listed" % [tag, id])
	var boards: Control = page.get_meta("boards")
	_checked += 1
	_expect(boards != null and boards.ids == ["raids", "experience"], "%s: the week's boards are %s" % [tag, boards.ids if boards else "none"])
	if boards != null:
		_expect(bool(boards.get("set_in_type")), "%s: the week's words are not set in type" % tag)
		var TS: GDScript = load("res://scripts/ui/tab_strip.gd")
		var L: GDScript = load("res://scripts/ui/layout.gd")
		var row: Rect2 = L.rect_of(L.find("rankings", "boards"))
		var three: Dictionary = TS.layout(["might", "level", "wealth"], row.size)
		_expect(boards.get("plate_size") == three["size"], "%s: the week's plates are %s, the row of three's %s" % [tag, boards.get("plate_size"), three["size"]])
		var mid: float = boards.position.x + boards.size.x / 2.0
		_expect(absf(mid - page.call("map_rect", row).get_center().x) <= 1.0, "%s: the week's two are not centred on the row" % tag)
	# The prize row heads the list.
	var list: Control = page.call("content", "list")
	var first: Control = list.get_child(0) if list.get_child_count() > 0 else null
	_checked += 1
	_expect(first != null and first.has_meta("prizes"), "%s: the list does not open with the prize row" % tag)
	if first != null and first.has_meta("prizes"):
		var places: Array = []
		var figures: Array = []
		var clock := ""
		for l in first.get_children():
			if l is Label:
				_expect((l as Label).size.x <= float(l.get_meta("box_w", (l as Label).size.x)) + 0.5, "%s: \"%s\" leaves its box" % [tag, (l as Label).text])
				if l.has_meta("place"):
					places.append((l as Label).text)
				if l.has_meta("prize"):
					figures.append(int(l.get_meta("prize")))
				if l.has_meta("clock"):
					clock = (l as Label).text
		_expect(places == ["1st", "2nd–3rd", "4th–10th", "11th–50th"], "%s: the places read %s" % [tag, places])
		_expect(figures == [50, 30, 15, 5], "%s: the prizes read %s" % [tag, figures])
		_expect(clock.begins_with("Closes in 5d"), "%s: the clock reads \"%s\"" % [tag, clock])
	# Shared places, and the podium's three as ordered.
	var shown: Array = []
	for r in list.get_children():
		if r.has_meta("prizes") or r.has_meta("notice"):
			continue
		for l in r.get_children():
			if l is Label and (l as Label).text.begins_with("#"):
				shown.append((l as Label).text)
	_expect(shown.slice(0, 2) == ["#4", "#4"], "%s: the lords level at 4th read %s" % [tag, shown.slice(0, 2)])
	var faces := 0
	for n in _all(page):
		if n is TextureRect and n.has_meta("podium"):
			faces += 1
	_expect(faces == 3, "%s: %d lords on the podium, two of them level" % [tag, faces])
	var you: Label = page.call("node", "you_sub")
	_expect(you != null and you.text == "Not on this week's rolls yet", "%s: YOUR RANK says \"%s\"" % [tag, you.text if you else ""])
	# An empty week: the prize row, and the notice under it.
	script.paint(page, _closing("Raids this week", "week", [], 0), "week_raids")
	await process_frame
	var notice: Control = null
	for c in list.get_children():
		if c.has_meta("notice") and not c.is_queued_for_deletion():
			notice = c
	_expect(notice != null and notice.position.y >= 95.0, "%s: an empty week's notice is not under its prize row" % tag)
	_expect(notice != null and (notice as Label).text == "No lord is on this week's rolls yet.", "%s: an empty week reads \"%s\"" % [tag, (notice as Label).text if notice else ""])
	# The season: four boards, short, set in type.
	(periods.get("_hits")["season"] as Button).pressed.emit()
	await process_frame
	script.paint(page, _closing("Renown this season", "season", rows, 3), "season_renown")
	await process_frame
	boards = page.get_meta("boards")
	_checked += 1
	_expect(boards != null and boards.ids == ["renown", "raids", "experience", "might"] and bool(boards.get("short")),
		"%s: the season's boards are %s" % [tag, boards.ids if boards else "none"])
	_expect(str(page.get_meta("board")) == "season_renown", "%s: SEASON chose %s" % [tag, page.get_meta("board")])
	page.call("close")
	await process_frame
	vp.queue_free()
	await process_frame


func _check(canvas: Vector2i, inset: float, mine: int) -> void:
	var tag := "%dx%d inset %d rank %d" % [canvas.x, canvas.y, int(inset), mine]
	var vp := SubViewport.new()
	vp.size = canvas
	root.add_child(vp)
	root.get_node("Nav").set("host", vp)
	var host := Control.new()
	host.size = Vector2(canvas)
	vp.add_child(host)
	var script: GDScript = load("res://scenes/pages/leaderboard_page.gd")
	var page: Control = script.open(host, {"inset": inset})
	for i in 3:
		await process_frame
	# By its script, not its class: naming the class here would compile the host
	# with this test, before the autoloads it uses exist.
	_expect(page != null and page.get_script().resource_path.ends_with("scripts/ui/painted_page.gd"),
		"%s: the rankings are not a painted page" % tag)
	for board in ["might", "wealth", "level"]:
		script.paint(page, {"rows": _rows(), "my_rank": mine, "my_value": 123456789}, board)
		for i in 3:
			await process_frame
		_board(page, tag + " " + board, canvas, mine)
	# The periods: all time only.
	var periods: Control = page.get_meta("periods")
	_expect(periods.is_enabled("all_time") and not periods.is_enabled("this_week") and not periods.is_enabled("season"),
		"%s: the periods answer before seasons exist" % tag)
	# The list takes a taller phone's height.
	var list: ScrollContainer = page.call("node", "list")
	if canvas.y > 1672 and inset == 0.0:
		_expect(list.size.y > 574.0 + 100.0, "%s: the list stays %.0f tall on a taller phone" % [tag, list.size.y])
	# CLOSE closes.
	var closed := [false]
	page.connect("closed", func() -> void: closed[0] = true)
	page.call("close")
	await process_frame
	_expect(closed[0], "%s: CLOSE did not close" % tag)
	vp.queue_free()
	await process_frame


func _board(page: Control, tag: String, canvas: Vector2i, mine: int) -> void:
	var screen := Rect2(0, 0, canvas.x, canvas.y)
	var inset: float = page.get("inset")
	# The podium: a face in each ring, and a worn frame inside it.
	var faces := 0
	var frames := 0
	for n in _all(page):
		if n is TextureRect and n.has_meta("podium"):
			var i := int(n.get_meta("podium"))
			faces += 1
			var c: Vector2 = (n as Control).position + (n as Control).size / 2.0
			var want: Vector2 = page.call("map_rect", Rect2(PODIUM[i][0], Vector2.ZERO)).position
			_checked += 1
			_expect(c.distance_to(want) < 2.0, "%s: podium face %d is at %s, not its ring's %s" % [tag, i, c, want])
			_expect((n as Control).size.x <= float(PODIUM[i][1]) + 3.0, "%s: podium face %d is bigger than its ring" % [tag, i])
		if n is TextureRect and n.has_meta("podium_frame") and (n as TextureRect).visible:
			frames += 1
	_expect(faces == 3, "%s: %d faces on the podium" % [tag, faces])
	_expect(frames == 2, "%s: %d worn frames on the podium, want the two worn" % [tag, frames])
	# The rows: ranks 4 to 100, each name in its colour, every figure fitting.
	var list_content: Control = page.call("content", "list")
	var rows := 0
	for r in list_content.get_children():
		if r.has_meta("notice"):
			continue
		rows += 1
		for l in r.get_children():
			if l is Label:
				var lab: Label = l
				_expect(lab.label_settings.font_size >= 13, "%s: \"%s\" is set at %d" % [tag, lab.text, lab.label_settings.font_size])
				_expect(lab.size.x <= float(lab.get_meta("box_w", lab.size.x)) + 0.5, "%s: \"%s\" leaves its plate" % [tag, lab.text])
	_expect(rows == 97, "%s: %d rows in the list, want ranks 4 to 100" % [tag, rows])
	var coloured := false
	for n in _all(list_content):
		if n is Label and (n as Label).label_settings.font_color == Color("#FF6B6B"):
			coloured = true
	_expect(coloured, "%s: no row wears its lord's colour" % tag)
	# YOUR RANK.
	var you: Label = page.call("node", "you_rank")
	_expect(you != null and you.text == (("#%d" % mine) if mine > 0 else "—"), "%s: YOUR RANK says %s" % [tag, you.text if you else "nothing"])
	var you_name: Label = page.call("node", "you_name")
	_expect(you_name != null and you_name.label_settings.font_color == Color("#C84BE0"), "%s: YOUR RANK's name is not in the asker's colour" % tag)
	# On the screen, under the notch.
	for id in ["p1_name", "p1_value", "p2_name", "p3_value", "you_rank", "you_value", "close"]:
		var n: Control = page.call("node", id)
		if n == null:
			_fails += 1
			print("  FAIL  %s: no %s" % [tag, id])
			continue
		var r := Rect2(n.global_position, n.size * page.get("page_scale"))
		_checked += 1
		_expect(screen.encloses(r.grow(-0.5)), "%s: %s is off the screen (%s)" % [tag, id, r])
		_expect(r.position.y >= inset - 0.5, "%s: %s is under the notch" % [tag, id])
		if n is Label:
			var lab: Label = n
			_expect(lab.label_settings.font_size >= 12, "%s: %s is set at %d" % [tag, id, lab.label_settings.font_size])
	# Every word on its painted plate: in the plate's rect, not grown past it
	# to the width of the longest name the layout was measured with.
	var L: GDScript = load("res://scripts/ui/layout.gd")
	for id in ["p1_name", "p1_value", "p2_name", "p2_value", "p3_name", "p3_value", "you_rank", "you_name", "you_sub", "you_value"]:
		var l: Label = page.call("node", id)
		var want: Rect2 = page.call("map_rect", L.rect_of(L.find("rankings", id)))
		_checked += 1
		_expect(l != null and want.grow(1.0).encloses(Rect2(l.position, l.size)),
			"%s: %s is drawn at %s, off its plate %s" % [tag, id, Rect2(l.position, l.size) if l else Rect2(), want])
	var close: Control = page.call("node", "close")
	_expect(close != null and close.size.y >= 95.0, "%s: CLOSE is not a thumb's tap" % tag)


func _all(n: Node) -> Array:
	var out: Array = [n]
	for c in n.get_children():
		out.append_array(_all(c))
	return out


func _expect(cond: bool, what: String) -> void:
	if not cond:
		_fails += 1
		print("  FAIL  " + what)
