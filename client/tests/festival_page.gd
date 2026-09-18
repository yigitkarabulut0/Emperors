extends SceneTree
## A festival's page (scenes/pages/festival_page.gd), behind the Events page's
## VIEW: everything the server says about the festival a lord is in.
##
## What must hold:
##  - its line reads the server's figures -- how long it has left, the points
##    earned, and the place they stand at of the lords who have earned any --
##    and, before it begins, when it does; the day's line says today's points
##    against the day's cap, so the cap is never a surprise;
##  - its five tasks are on the painted quest tile, each with what it asks, how
##    far it has come and what it pays; a finished one claims when it is
##    tapped, an unfinished one says how far it has come, and a claimed one
##    says it is taken;
##  - its milestones are in the points they open at, each with what it pays,
##    CLAIM while one waits, TAKEN once it is taken and NOT YET before; the
##    last wears the crown;
##  - its board shows the places the server sent, the lord's own marked, and --
##    when they stand past the last row shown -- their row after the rest;
##  - the places it pays and how points are earned are the server's own words;
##  - nothing on it runs off the sheet.
##
## Run: godot --headless --path client --script tests/festival_page.gd

const PAGE := "res://scenes/pages/festival_page.gd"

var _fails := 0
var _checked := 0


func _initialize() -> void:
	await process_frame
	root.get_node("Env").set("api_base_url", "http://127.0.0.1:9")
	var page: GDScript = load(PAGE)
	_words(page)
	for canvas in [Vector2i(941, 1672), Vector2i(941, 2040)]:
		await _page(page, canvas)
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d checks: a festival's page says its line, its tasks, its milestones, its board and its prizes" % _checked)
	quit()


func _expect(ok: bool, what: String) -> void:
	_checked += 1
	if not ok:
		_fails += 1
		print("  FAIL  " + what)


## The words are pure: every case is read without building anything.
func _words(page: GDScript) -> void:
	var running := {"name": "Harvest Festival", "running": true, "ends_in": 3600 * 26, "points": 640,
		"place": 3, "lords": 128, "day": 2, "days": 3, "day_points": 320, "day_cap": 600}
	_expect(page.call("festival_line", running, 0) == "Ends in 1d 02h  ·  640 points  ·  3rd of 128",
		"the line reads \"%s\"" % page.call("festival_line", running, 0))
	# Counted down from the answer's moment, as every clock on a page is.
	_expect(page.call("festival_line", running, 3600) == "Ends in 1d 01h  ·  640 points  ·  3rd of 128",
		"an hour on, the line reads \"%s\"" % page.call("festival_line", running, 3600))
	_expect(page.call("day_line", running) == "Day 2 of 3  ·  320 of today's 600 points",
		"the day reads \"%s\"" % page.call("day_line", running))
	var coming := {"name": "Blood Moon", "running": false, "starts_in": 7200, "ends_in": 7200 + 3 * 86400,
		"points": 0, "place": 0, "day": 0, "days": 3, "day_cap": 600}
	_expect(page.call("festival_line", coming, 0) == "Begins in 2h 00m  ·  0 points",
		"before it begins the line reads \"%s\"" % page.call("festival_line", coming, 0))
	_expect(page.call("places_words", 1, 1) == "1st" and page.call("places_words", 2, 3) == "2nd to 3rd"
		and page.call("places_words", 11, 50) == "11th to 50th",
		"the places read %s / %s / %s" % [page.call("places_words", 1, 1), page.call("places_words", 2, 3),
		page.call("places_words", 11, 50)])


## A festival part-way through: one task done and one taken, one milestone
## taken and one reached and waiting, and the lord twelfth of twelve.
func _festival(points: int = 900) -> Dictionary:
	var lines := [{"kind": "gold", "amount": 588, "text": "588 gold", "icon": "gold"}]
	var tasks: Array = []
	for i in 5:
		tasks.append({"index": i, "id": "t%d" % i, "name": "Bring in the Sheaves", "short": "Collect 300 times",
			"icon": "quest_bolt", "target": 300, "progress": 300 if i == 0 else 20,
			"done": i == 0, "claimed": i == 1, "lines": lines})
	var milestones: Array = []
	var at := [300, 800, 1400, 1800]
	for i in 4:
		milestones.append({"index": i, "at": at[i], "reached": points >= at[i], "claimed": i == 0,
			"crown": i == 3, "lines": lines})
	var board: Array = []
	for i in 12:
		board.append({"place": i + 1, "name": "Wwwwwwwwwwwwwwww" if i == 11 else "Lord %d" % i,
			"avatar": "knight", "level": 30, "points": 1000 - i * 10, "me": i == 11, "worn": {}, "vip_seal": false})
	return {"id": 1, "name": "Harvest Festival", "theme": "harvest", "blurb": "The granaries overflow.",
		"bucket": "collect_income_bp", "bp": 2500, "effective_bp": 2500, "running": true, "starts_in": 0,
		"ends_in": 3600 * 26, "day": 2, "days": 3, "points": points, "day_points": 320, "day_cap": 600,
		"place": 12, "lords": 12, "claimable": 2,
		"sources": [{"deed": "collects", "text": "Each collect", "points": 1, "icon": "quest_bolt"}],
		"tasks": tasks, "milestones": milestones,
		"ranks": [{"from": 1, "to": 1, "lines": lines}, {"from": 2, "to": 3, "lines": lines}],
		"board": board}


func _page(page: GDScript, canvas: Vector2i) -> void:
	var tag := "%dx%d" % [canvas.x, canvas.y]
	var vp := SubViewport.new()
	vp.size = canvas
	root.add_child(vp)
	root.get_node("Nav").set("host", vp)
	var host := Control.new()
	host.size = Vector2(canvas)
	vp.add_child(host)
	var sheet: Node = page.call("open", host, _festival())
	for i in 4:
		await process_frame
	_expect(sheet != null, "%s: the page did not open" % tag)
	if sheet == null:
		vp.queue_free()
		return

	var words: Array = []
	var rects: Array = []
	var stack: Array = [sheet]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if n is Label and (n as Label).text != "":
			words.append((n as Label).text)
		if n is Control and (n as Control).is_visible_in_tree():
			rects.append((n as Control).get_global_rect())
	# Its line, its day, the tasks, the milestones' states, the board and the
	# prizes: all the server's own words.
	for w in ["Ends in 1d 02h  ·  900 points  ·  12th of 12", "Day 2 of 3  ·  320 of today's 600 points",
			"THE FESTIVAL'S TASKS", "BRING IN THE SHEAVES", "Collect 300 times", "WHAT THE POINTS OPEN",
			"300 points", "1,800 points", "TAKEN", "CLAIM", "NOT YET", "THE BOARD", "12th",
			"Wwwwwwwwwwwwwwww", "WHAT THE PLACES PAY", "1st", "2nd to 3rd", "HOW POINTS ARE EARNED",
			"Each collect"]:
		_expect(words.has(w), "%s: the page does not say \"%s\"" % [tag, w])
	# The board shows ten places and the lord's own row after them.
	var twelfth := 0
	for w in words:
		if str(w) == "12th":
			twelfth += 1
	_expect(twelfth == 1, "%s: the lord's row is drawn %d times" % [tag, twelfth])
	_expect(words.has("10th") and not words.has("11th"),
		"%s: the board shows %s" % [tag, "no tenth place" if not words.has("10th") else "an eleventh"])
	# Nothing runs off the sheet's own box.
	var sheet_rect: Rect2 = (sheet as Control).get_global_rect()
	for r in rects:
		var box: Rect2 = r
		_expect(box.position.x >= -1.0 and box.end.x <= float(canvas.x) + 1.0,
			"%s: something runs off the side: %s" % [tag, box])
	_expect(sheet_rect.size.x <= float(canvas.x), "%s: the sheet is wider than the screen" % tag)
	(sheet as Node).queue_free()
	vp.queue_free()
	await process_frame
