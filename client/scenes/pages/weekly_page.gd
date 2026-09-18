extends RefCounted
## THIS WEEK'S QUESTS — the whole week: all six tasks, each on the painted
## quest tile (collect_events.png) under its name, and the week's chest bar
## with what each chest holds. Opened from the Collect tab's quests pager (its
## week heading, a tile still open, a chest not yet ready).
##
## Reads the week the Collect tab holds (GET /v1/weekly); a task claimed or a
## chest opened here goes through the tab (Collect.claim_weekly_task,
## open_chest), so the tab, its dot and this page all show the same week.

const SCREEN := "page:weekly_quests"
const TILE := "collect/week_tile"
## The painted tile's size, and the grid's gaps.
const TILE_SIZE := Vector2(237, 222)
const COL_GAP := 18.0
const ROW_GAP := 18.0
## A task's name over its tile, in the headings' gold.
const NAME_H := 34.0
const NAME_FIT := Vector2i(20, 14)
## What a chest holds, under its plate: each line its picture and its words.
const LINE_ICON := 40.0
const LINE_H := 46.0
const LINE_FIT := Vector2i(18, 13)


static func open(host: Node, weekly: Dictionary, tab: Node) -> Sheet:
	var s := Sheet.open(host, "THIS WEEK'S QUESTS", "", 60, SCREEN)
	s.set_meta("tab", tab)
	s.set_meta("weekly", weekly)
	s.add_close()
	_paint(s)
	# Its line counts the week down while it is open.
	var timer := Timer.new()
	timer.wait_time = 1.0
	timer.autostart = true
	timer.timeout.connect(func() -> void: _paint_line(s))
	s.add_child(timer)
	return s


## The Collect tab the page was opened from, or null (a test, a capture).
## (A null meta is no meta: get_meta would report it missing.)
static func _tab(s: Sheet) -> Variant:
	return s.get_meta("tab") if s.has_meta("tab") else null


## The week, as the tab holds it now (or as the page was opened with).
static func _week(s: Sheet) -> Dictionary:
	var tab: Variant = _tab(s)
	if tab is Node and is_instance_valid(tab) and (tab as Node).get("_weekly") is Dictionary \
			and not ((tab as Node).get("_weekly") as Dictionary).is_empty():
		return (tab as Node).get("_weekly")
	return s.get_meta("weekly", {})


static func _paint(s: Sheet) -> void:
	s.clear_body()
	var w := _week(s)
	var line := s.paragraph("", 24, UI.DIM, HORIZONTAL_ALIGNMENT_CENTER)
	line.name = "WeekLine"
	s.set_meta("line", line)
	_paint_line(s)
	_tasks(s, w)
	s.heading("THE WEEK'S CHESTS")
	_chests(s, w)


## "Ends in 3d 14h · 120 of 240 points".
static func week_line(w: Dictionary, age_s: int) -> String:
	var left := maxi(0, int(w.get("ends_in", 0)) - age_s)
	return "Ends in %s  ·  %s of %s points" % [UI.time_left(left), UI.grouped(int(w.get("points", 0))),
		UI.grouped(int(w.get("points_max", 0)))]


static func _paint_line(s: Sheet) -> void:
	var line: Variant = s.get_meta("line") if s.has_meta("line") else null
	if not (line is Label) or not is_instance_valid(line):
		return
	var tab: Variant = _tab(s)
	var left := -1
	if tab is Node and is_instance_valid(tab) and (tab as Node).has_method("weekly_ends_in"):
		left = int((tab as Node).call("weekly_ends_in"))
	var w := _week(s)
	if left >= 0:
		w = w.duplicate()
		w["ends_in"] = left
	(line as Label).text = week_line(w, 0)


## The six tasks, three to a row, in the server's order: each its name over the
## painted tile, the tile painted as the Collect tab paints it.
static func _tasks(s: Sheet, w: Dictionary) -> void:
	var tasks: Array = w.get("tasks", [])
	var cols := 3
	var rows := int(ceil(tasks.size() / float(cols)))
	var grid := Control.new()
	grid.name = "Tasks"
	grid.mouse_filter = Control.MOUSE_FILTER_PASS
	var cell_h := NAME_H + TILE_SIZE.y
	grid.custom_minimum_size = Vector2(s.inner_w, rows * cell_h + maxi(0, rows - 1) * ROW_GAP)
	s.body.add_child(grid)
	var x0 := (s.inner_w - (cols * TILE_SIZE.x + (cols - 1) * COL_GAP)) / 2.0
	var tpl := Layout.element("collect", "quest_card")
	for i in tasks.size():
		var q: Dictionary = tasks[i]
		var at := Vector2(x0 + (i % cols) * (TILE_SIZE.x + COL_GAP), (i / cols) * (cell_h + ROW_GAP))
		var name := UI.label(str(q.get("name", "")).to_upper(), NAME_FIT.x, UI.GOLD, "title", 700, HORIZONTAL_ALIGNMENT_CENTER)
		UI.place(name, Rect2(at, Vector2(TILE_SIZE.x, NAME_H)))
		name.set_meta("box_w", TILE_SIZE.x)
		grid.add_child(name)
		UI.fit_line(name, NAME_FIT.x, NAME_FIT.y)
		var tile := UI.image(TILE, Rect2(at + Vector2(0, NAME_H), TILE_SIZE))
		tile.name = "Tile%d" % i
		grid.add_child(tile)
		var built := Layout.instantiate(tpl)
		built["node"].position = tile.position
		grid.add_child(built["node"])
		var st := QuestTile.paint_weekly(built["parts"], q)
		if st == "claimed":
			tile.modulate = QuestTile.CLAIMED_TINT
			built["node"].modulate = QuestTile.CLAIMED_TINT
		var hit := UI.hotspot(Rect2(tile.position, TILE_SIZE), true)
		hit.pressed.connect(func() -> void: _on_task(s, q))
		grid.add_child(hit)


static func _on_task(s: Sheet, q: Dictionary) -> void:
	if QuestTile.state(q) != "done" or bool(s.get_meta("busy", false)):
		return
	var tab: Variant = _tab(s)
	if not (tab is Node) or not is_instance_valid(tab):
		return
	s.set_meta("busy", true)
	var res: Api.Response = await (tab as Node).call("claim_weekly_task", int(q.get("slot", 0)))
	s.set_meta("busy", false)
	if res.ok and is_instance_valid(s):
		GameState.toast("Task done: " + str(load("res://scenes/tabs/collect.gd").lines_words(res.data.get("lines", []),
			int(q.get("points", 0)))))
		_paint(s)


## The chest bar as the Collect tab draws it, and under each chest's plate what
## it holds.
static func _chests(s: Sheet, w: Dictionary) -> void:
	var spec := Layout.element("collect", "week_bar")
	var built := Layout.instantiate(spec)
	var bar_size: Vector2 = Layout.rect_of(spec).size
	var chests: Array = w.get("chests", [])
	var most := 0
	for c in chests:
		if c is Dictionary:
			most = maxi(most, (c.get("lines", []) as Array).size())
	var holder := Control.new()
	holder.name = "Chests"
	holder.mouse_filter = Control.MOUSE_FILTER_PASS
	holder.custom_minimum_size = Vector2(s.inner_w, bar_size.y + 8.0 + most * LINE_H)
	s.body.add_child(holder)
	var node: Control = built["node"]
	node.position = Vector2((s.inner_w - bar_size.x) / 2.0, 0)
	holder.add_child(node)
	var parts: Dictionary = built["parts"]
	var collect: GDScript = load("res://scenes/tabs/collect.gd")
	Layout.set_fill(parts["fill"], collect.bar_fraction(parts, chests, int(w.get("points", 0)), int(w.get("points_max", 0))))
	for i in 3:
		var c: Dictionary = chests[i] if i < chests.size() and chests[i] is Dictionary else {}
		var ready := bool(c.get("ready", false)) and not bool(c.get("claimed", false))
		var need: Label = parts.get(collect.CHEST_NEEDS[i])
		if need != null:
			need.label_settings = need.label_settings.duplicate()
			need.text = collect.chest_words(c) if not c.is_empty() else ""
			need.label_settings.font = UI.font("title" if ready else "body", 800 if ready else 700)
			need.label_settings.font_color = collect.READY if ready else (UI.DIM if bool(c.get("claimed", false)) else QuestTile.INK)
			UI.fit_line(need, 20, 14)
		var chest: CanvasItem = parts.get(collect.CHEST_PARTS[i])
		if chest != null:
			chest.modulate = collect.CHEST_OPENED if bool(c.get("claimed", false)) else (Color.WHITE if ready else collect.CHEST_LOCKED)
		var tap: BaseButton = parts.get(collect.CHEST_TAPS[i])
		if tap != null:
			tap.pressed.connect(func() -> void: _on_chest(s, c))
		var plate: Control = parts.get(collect.CHEST_PLATES[i])
		if plate != null and not c.is_empty():
			_holds(holder, node.position + plate.position + Vector2(0, plate.size.y + 8.0), plate.size.x, c.get("lines", []))


## A chest's lines, one under another in its plate's column: the picture, and
## the server's words beside it.
static func _holds(holder: Control, at: Vector2, width: float, lines: Array) -> void:
	var col_w := maxf(width + 60.0, 180.0)
	var x := at.x + (width - col_w) / 2.0
	for i in lines.size():
		var l: Dictionary = lines[i] if lines[i] is Dictionary else {}
		var y := at.y + i * LINE_H
		var icon := TextureRect.new()
		icon.texture = Art.reward_line_icon(l)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		UI.place(icon, Rect2(x, y + (LINE_H - LINE_ICON) / 2.0, LINE_ICON, LINE_ICON))
		holder.add_child(icon)
		ItemGround.for_line(icon, l, Rect2(icon.position, icon.size))
		var words := UI.label(str(l.get("text", "")), LINE_FIT.x, UI.INK, "body", 600)
		UI.place(words, Rect2(x + LINE_ICON + 8.0, y, col_w - LINE_ICON - 8.0, LINE_H))
		words.set_meta("box_w", col_w - LINE_ICON - 8.0)
		holder.add_child(words)
		UI.fit_line(words, LINE_FIT.x, LINE_FIT.y)


static func _on_chest(s: Sheet, c: Dictionary) -> void:
	if not bool(c.get("ready", false)) or bool(c.get("claimed", false)) or bool(s.get_meta("busy", false)):
		return
	var tab: Variant = _tab(s)
	if not (tab is Node) or not is_instance_valid(tab):
		return
	s.set_meta("busy", true)
	var res: Api.Response = await (tab as Node).call("open_chest", int(c.get("tier", 0)))
	s.set_meta("busy", false)
	if res.ok and is_instance_valid(s):
		_paint(s)
