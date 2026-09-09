extends SceneTree
## Lords, Works and Ranks build inside the Kingdom page and fit the phone.
##
## They were Dialog.choose lists of up to twelve options -- a roster, a build
## list and three leaderboards -- inside a modal built for asking one question.
## The page already has a header, a crest and a tab strip, so a tab changes what
## is under it rather than opening anything: what a section has to do is build
## its rows at the page's width, with every button a thumb can reach.
##
## Run: godot --headless --path client --script tests/kingdom_pages.gd

const PT_PER_UNIT := 440.0 / 941.0
const CANVASES := [Vector2(941, 1672), Vector2(941, 2040)]

var _fails: int = 0
var _rows: int = 0
var _buttons: int = 0
var _tag := ""
var _screen := Rect2()


func _initialize() -> void:
	await process_frame
	for canvas in CANVASES:
		for mode in ["lords", "works", "ranks"]:
			await _check(mode, canvas)
	await _the_tabs_swap_what_the_page_shows()
	if _rows == 0:
		_fail("no page built any rows, so nothing was measured")
	else:
		print("  built %d row(s) and %d button(s) across the three pages" % [_rows, _buttons])
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  the kingdom's three sections build as pages that fit the phone")
	quit()


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)


## A kingdom with a roster, works to build and a table to stand in.
func _data() -> Dictionary:
	var members: Array = []
	for i in 6:
		members.append({"player_id": "p%d" % i, "name": "Lord Number %d" % i,
			"role": "king" if i == 0 else "lord", "level": 30 + i, "donated": str(1000 * i)})
	var upgrades: Array = []
	for i in 4:
		upgrades.append({"id": "u%d" % i, "name": "Kingdom Work %d" % i, "level": i,
			"effect_now": 500 * i, "effect_per_level": 250, "next_cost": 120000 * (i + 1),
			"maxed": i == 3, "bucket": "collect_income_bp"})
	var board: Array = []
	for i in 10:
		board.append({"id": "k%d" % i, "name": "A Kingdom Named %d" % i, "tag": "K%d" % i,
			"level": 20 - i})
	return {"in_kingdom": true, "me": {"role": "king"},
		"kingdom": {"id": "k0", "name": "Lion Banner", "tag": "LION", "members": 6,
			"member_cap": 50, "level": 5},
		"members": members, "upgrades": upgrades, "leaderboard": board}


func _check(mode: String, canvas: Vector2) -> void:
	var host := Control.new()
	host.size = canvas
	root.add_child(host)
	var page: Control = load("res://scenes/kingdom/kingdom_section.gd").new()
	page.setup(mode, _data(), {"favour": 480, "goods": [
		{"id": "g1", "name": "Energy Draught", "blurb": "Restores your energy.", "cost": 40},
		{"id": "g2", "name": "Kingdom Banner", "blurb": "A standard for the gate.", "cost": 800}]})
	host.add_child(page)
	for i in 4:
		await process_frame

	_tag = "%s on %dx%d" % [mode, int(canvas.x), int(canvas.y)]
	_screen = Rect2(Vector2.ZERO, canvas)
	var before := _buttons
	_walk(page)
	if mode != "ranks" and _buttons == before:
		_fail("%s: built no buttons at all" % _tag)
	if page.size.y < 200.0:
		_fail("%s: the section came out %.0f units tall; it has not built its rows"
			% [_tag, page.size.y])
	page.queue_free()
	host.queue_free()
	await process_frame


## A tab has to change what is under it. The strip used to be anchors down one
## long page, so every section was on the screen at once and a tab scrolled to
## it; nothing would have noticed if it went back to that.
func _the_tabs_swap_what_the_page_shows() -> void:
	var host := Control.new()
	host.size = Vector2(941, 1672)
	root.add_child(host)
	var page: Control = load("res://scenes/tabs/kingdom.gd").new()
	page.set_anchors_preset(Control.PRESET_FULL_RECT)
	host.add_child(page)
	for i in 3:
		await process_frame

	var ui: Dictionary = page.get("_ui")
	if ui == null or not ui.has("realm_card"):
		_fail("the kingdom page did not build")
		host.queue_free()
		return
	page.set("_data", _data())
	page.set("_shop", {"favour": 100, "goods": []})

	for mode in ["lords", "works", "ranks", "realm"]:
		page.call("_show_section", mode)
		for i in 3:
			await process_frame
		var realm_showing: bool = (ui["realm_card"] as Control).visible
		if mode == "realm":
			if not realm_showing:
				_fail("the REALM tab does not show the realm card")
			if page.get("_section") != null:
				_fail("the REALM tab left another section standing")
		else:
			if realm_showing:
				_fail("the %s tab still shows the realm card under it" % mode.to_upper())
			if page.get("_section") == null:
				_fail("the %s tab built nothing" % mode.to_upper())
			if (ui["lords_panel"] as Control).visible:
				_fail("the %s tab left the half-width lords panel showing" % mode.to_upper())
	print("  the four tabs each swap the page's content")
	host.queue_free()
	await process_frame


func _walk(n: Node) -> void:
	if n is Button:
		_buttons += 1
		var r := Rect2((n as Control).global_position, (n as Control).size)
		# A row's buttons scroll with it, so only what the page pins down is
		# required to be on the screen -- but everything must be thumb-sized.
		if r.size.y * PT_PER_UNIT < 44.0:
			_fail("%s: a button is %.0f pt tall, under the 44 a thumb needs"
				% [_tag, r.size.y * PT_PER_UNIT])
		if r.size.x > _screen.size.x:
			_fail("%s: a button is %.0f units wide on a %.0f screen"
				% [_tag, r.size.x, _screen.size.x])
	if n is Label and (n as Label).text != "":
		_rows += 1
	for c in n.get_children():
		_walk(c)
