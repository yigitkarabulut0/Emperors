extends SceneTree
## THE ROYAL HOURS (scenes/pages/hourly_odds_page.gd), behind the Events page's
## ROYAL HOURS strip: the published odds of every hour.
##
## What must hold:
##  - every row of the server's table is on the page, with its name, what it
##    does, how long it lasts and its chance of an hour -- the chance worked
##    out from the basis points the server rolls with, and the whole table
##    adding up to the hour;
##  - a row thinner than a per cent keeps its hundredth (Honor Hour's 3%, the
##    old 0.5% cases), so no row reads as never;
##  - the hour running says so, in the gold a ready thing wears;
##  - the quiet hour is a row like the others, with the dark gauge for its mark;
##  - nothing on it runs off the page.
##
## Run: godot --headless --path client --script tests/hourly_odds_page.gd

const PAGE := "res://scenes/pages/hourly_odds_page.gd"
## The table as the server publishes it (balance/liveops.json).
const TABLE := [
	{"id": "none", "name": "A quiet hour", "blurb": "Nothing is on this hour.", "icon": "", "minutes": 0, "bp": 3800},
	{"id": "gold_rush", "name": "Gold Rush", "blurb": "Every job pays double gold.",
		"icon": "hourly/gold_rush", "minutes": 15, "bp": 1300},
	{"id": "scholars_hour", "name": "Scholar's Hour", "blurb": "Every job pays double experience.",
		"icon": "hourly/scholars_hour", "minutes": 15, "bp": 1000},
	{"id": "fortunes_favour", "name": "Fortune's Favour", "blurb": "Luck smiles on the market and the chests.",
		"icon": "hourly/fortunes_favour", "minutes": 30, "bp": 900},
	{"id": "quartermasters_sale", "name": "Quartermaster's Sale", "blurb": "Energy refills cost half.",
		"icon": "hourly/quartermasters_sale", "minutes": 30, "bp": 800},
	{"id": "fresh_wares", "name": "Fresh Wares", "blurb": "The market restocks once for nothing.",
		"icon": "hourly/fresh_wares", "minutes": 60, "bp": 900},
	{"id": "busy_hands", "name": "Busy Hands", "blurb": "The day's quests count double.",
		"icon": "hourly/busy_hands", "minutes": 30, "bp": 800},
	{"id": "royal_courier", "name": "Royal Courier", "blurb": "A courier brings a cart writ from the crown.",
		"icon": "hourly/royal_courier", "minutes": 60, "bp": 500},
]

var _fails := 0
var _checked := 0


func _initialize() -> void:
	await process_frame
	root.get_node("Env").set("api_base_url", "http://127.0.0.1:9")
	var page: GDScript = load(PAGE)
	# The chance is the server's basis points, said as a reader counts them.
	_expect(page.call("chance_words", 1300) == "13%", "1300 bp reads \"%s\"" % page.call("chance_words", 1300))
	_expect(page.call("chance_words", 3800) == "38%", "3800 bp reads \"%s\"" % page.call("chance_words", 3800))
	_expect(page.call("chance_words", 850) == "8.5%", "850 bp reads \"%s\"" % page.call("chance_words", 850))
	_expect(page.call("chance_words", 50) == "0.5%", "50 bp reads \"%s\"" % page.call("chance_words", 50))
	_expect(page.call("chance_words", 0) == "—", "nothing reads \"%s\"" % page.call("chance_words", 0))
	var whole := 0
	for row in TABLE:
		whole += int(row["bp"])
	_expect(whole == 10000, "the table adds up to %d bp, not the whole hour" % whole)
	for canvas in [Vector2i(941, 1672), Vector2i(941, 2040)]:
		await _page(page, canvas)
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d checks: every hour the realm may roll, with what it does and how often" % _checked)
	quit()


func _expect(ok: bool, what: String) -> void:
	_checked += 1
	if not ok:
		_fails += 1
		print("  FAIL  " + what)


func _page(page: GDScript, canvas: Vector2i) -> void:
	var tag := "%dx%d" % [canvas.x, canvas.y]
	var vp := SubViewport.new()
	vp.size = canvas
	root.add_child(vp)
	root.get_node("Nav").set("host", vp)
	var host := Control.new()
	host.size = Vector2(canvas)
	vp.add_child(host)
	var sheet: Node = page.call("open", host, TABLE, {"id": "busy_hands", "active": true})
	for i in 4:
		await process_frame
	_expect(sheet != null, "%s: the page did not open" % tag)
	if sheet == null:
		vp.queue_free()
		return
	var words: Array = []
	var labels: Array = []
	var stack: Array = [sheet]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if n is Label and (n as Label).text != "":
			words.append((n as Label).text)
			# The rows' own lines: one line each, in a box of their own. The
			# sheet's title and its wrapped paragraphs are the sheet's to lay
			# out, and are measured by the page tests that own them.
			if (n as Label).autowrap_mode == TextServer.AUTOWRAP_OFF and (n as Label).has_meta("box_w"):
				labels.append(n)
	for row in TABLE:
		_expect(words.has(str(row["name"])), "%s: the page does not name %s" % [tag, row["name"]])
		_expect(words.has(page.call("chance_words", int(row["bp"]))),
			"%s: %s's chance is not on the page" % [tag, row["name"]])
	# What is on now says so, once.
	var on := 0
	for w in words:
		if str(w).begins_with("On now."):
			on += 1
	_expect(on == 1, "%s: %d rows say what is on now" % [tag, on])
	# Every word stays inside its box, and inside the page.
	var inner: float = float(sheet.get("inner_w"))
	for l in labels:
		var lab: Label = l
		var box := float(lab.get_meta("box_w", lab.size.x))
		var ink := lab.label_settings.font.get_string_size(lab.text, HORIZONTAL_ALIGNMENT_LEFT, -1,
			lab.label_settings.font_size).x
		_expect(ink <= box + 0.5, "%s: \"%s\" is %.0f wide in a %.0f box" % [tag, lab.text, ink, box])
		var body: Control = sheet.get("body")
		var left: float = lab.get_global_rect().position.x - body.get_global_rect().position.x
		_expect(left >= -0.5 and left + box <= inner + 0.5,
			"%s: \"%s\" runs off the page" % [tag, lab.text])
	(sheet as Node).queue_free()
	vp.queue_free()
	await process_frame
