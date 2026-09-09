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
## The rail owns x 0..160. The painted panels are measured to tuck five units
## under its edge, which is how the reference draws them; what must clear it is
## anything placed by code, which has no painting telling it where to go.
const RAIL_RIGHT := 160.0
const CANVASES := [Vector2(941, 1672), Vector2(941, 2040)]
const TAB_NAMES := ["realm", "lords", "works", "ranks"]

var _fails: int = 0
var _rows: int = 0
var _buttons: int = 0
var _tag := ""
var _screen := Rect2()
## The section's own left and right edge, in screen units. Every row is built
## from the section's width; a row internal that was written against an older,
## wider section runs off the phone, and that is exactly what happened when the
## section was narrowed to clear the rail and the rows were not.
var _band := Vector2.ZERO


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


## The goods the game actually sells, from the generator's own document, so a
## good added without a painting fails here rather than shipping as whatever
## the fallback happens to be.
func _goods() -> Array:
	var fh := FileAccess.open("res://../balance/kingdoms.json", FileAccess.READ)
	if fh == null:
		_fail("balance/kingdoms.json is not readable")
		return []
	var d: Variant = JSON.parse_string(fh.get_as_text())
	return (d as Dictionary).get("favour_shop", []) if d is Dictionary else []


func _check(mode: String, canvas: Vector2) -> void:
	var host := Control.new()
	host.size = canvas
	root.add_child(host)
	var page: Control = load("res://scenes/kingdom/kingdom_section.gd").new()
	page.setup(mode, _data(), {"favour": 480, "goods": _goods()})
	host.add_child(page)
	for i in 4:
		await process_frame

	_tag = "%s on %dx%d" % [mode, int(canvas.x), int(canvas.y)]
	_screen = Rect2(Vector2.ZERO, canvas)
	var before := _buttons
	_band = Vector2(page.global_position.x, page.global_position.x + page.size.x)
	_walk(page)
	_nothing_eats_the_drag(page)
	if mode == "works":
		_the_favour_shop_is_a_shelf(page)
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
	# Nothing a tab shows may sit under the rail, and REALM has to use the room
	# the other tabs use rather than stopping a third of the way down.
	page.call("_show_section", "lords")
	for i in 3:
		await process_frame
	var section: Control = page.get("_section")
	if section != null and section.position.x < RAIL_RIGHT:
		_fail("a section starts at x %.0f, behind the rail's %.0f"
			% [section.position.x, RAIL_RIGHT])
	page.call("_show_section", "realm")
	for i in 3:
		await process_frame
	var lowest := 0.0
	# REALM is the reference's whole painted page now, so what has to be down
	# there is the page's own foot -- the ranking card and the two panels.
	for id in ["ranking_card", "works_panel", "lords_panel", "donate"]:
		if ui.has(id):
			var c: Control = ui[id]
			lowest = maxf(lowest, c.position.y + c.size.y)
	if lowest < 1200.0:
		_fail("the realm tab finishes at y %.0f and leaves the rest of the page empty"
			% lowest)
	# REALM's own buttons are painted plates seated in the reference's page, so
	# what is asked of them is the thumb rule, not extra height: the painting
	# says where DONATE goes and stretching it stretches the word on it.
	for id in ["donate", "edit_name", "lords_view_all", "works_view_all", "view_rankings"]:
		if not ui.has(id):
			continue
		var d: Control = ui[id]
		if minf(d.size.x, d.size.y) * PT_PER_UNIT < 44.0:
			_fail("the realm's %s is %.0fx%.0f pt, under the 44 a thumb needs"
				% [id, d.size.x * PT_PER_UNIT, d.size.y * PT_PER_UNIT])
	_the_strip_matches_the_painting(page, ui)
	_the_rows_meet(ui)
	print("  the four tabs each swap the page's content, clear of the rail")
	host.queue_free()
	await process_frame


## A tab taller than the phone has to scroll, and a ScrollContainer only sees a
## drag its children let through. Every row of these sections is a full-width
## Control, and a plain Control stops mouse input: seven of them across the
## Works tab swallowed every drag, so the tab could not be scrolled at all and
## the Favour shop under the works was unreachable.
func _nothing_eats_the_drag(page: Control) -> void:
	var stack: Array = [page]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if not (n is Control) or n is Button or n == page:
			continue
		var c2 := n as Control
		if c2.mouse_filter != Control.MOUSE_FILTER_STOP:
			continue
		# A control narrower than half the section cannot be in the way of a
		# thumb dragging down the middle of it.
		if c2.size.x > page.size.x / 2.0:
			_fail("%s: a %s %.0f units wide takes the drag before the scroll can"
				% [_tag, n.get_class(), c2.size.x])
			return


## The tab strip is four plates the painting cut to four different widths, and
## each is drawn at the height the painting gave its state. They were being
## squeezed into one set of numbers -- the lit plate is 206x68 and was going
## into 200x66 -- so the gold rule under the strip stepped between tabs and the
## words drifted off the ones the painting baked.
func _the_strip_matches_the_painting(page: Control, ui: Dictionary) -> void:
	var L: GDScript = load("res://scripts/ui/layout.gd")
	var strip: Dictionary = L.find("kingdom", "tabs")
	var widths: Array = strip.get("widths", [])
	var tabs: Array = ui.get("tabs", [])
	if widths.size() != tabs.size() or tabs.is_empty():
		_fail("the tab strip has %d plates and %d widths" % [tabs.size(), widths.size()])
		return
	for i in tabs.size():
		var chip: Control = tabs[i]["parts"]["chip"]
		var tex: Texture2D = chip.get("texture")
		if tex == null:
			_fail("tab %d has no plate" % i)
			continue
		if absf(chip.size.x - float(widths[i])) > 0.5:
			_fail("tab %d is drawn %.0f wide, not the %d the painting cut"
				% [i, chip.size.x, int(widths[i])])
		# A plate keeps the height of its own crop; only its width is patched.
		if absf(chip.size.y - float(tex.get_height())) > 0.5:
			_fail("tab %d is drawn %.0f tall against a plate of %d -- it is being squeezed"
				% [i, chip.size.y, tex.get_height()])
		var word: TextureRect = tabs[i]["parts"]["label"]
		var spot: Dictionary = strip.get("labels", {}).get(str(TAB_NAMES[i]), {})
		var lr: Array = spot.get("rect", [])
		if lr.size() == 4 and word.global_position.distance_to(
				Vector2(float(lr[0]), float(lr[1]))) > 1.5:
			_fail("tab %d's word sits at %s, not the %s the painting has"
				% [i, word.global_position, Vector2(float(lr[0]), float(lr[1]))])


## The Realm tab is three rows of two cards. Each pair meets within a few units
## in the painting; the castle's crop stopped 34 units short of the card beside
## it, and what showed between them was bare ground, so the right-hand card read
## as adrift. A crop cut shorter than the painting leaves no other trace.
const PAIRS := [["realm_card", "realm_bonuses"], ["treasury_card", "reputation_card"],
	["lords_panel", "works_panel"]]
const MAX_GAP := 8.0


func _the_rows_meet(ui: Dictionary) -> void:
	for pair in PAIRS:
		if not (ui.has(pair[0]) and ui.has(pair[1])):
			_fail("the realm tab is missing %s or %s" % [pair[0], pair[1]])
			continue
		var left: Control = ui[pair[0]]
		var right: Control = ui[pair[1]]
		var gap := right.position.x - (left.position.x + left.size.x)
		if gap > MAX_GAP:
			_fail("%s ends at x %.0f and %s starts at %.0f -- %.0f units of bare ground"
				% [pair[0], left.position.x + left.size.x, pair[1], right.position.x, gap])
		elif gap < -2.0:
			_fail("%s overlaps %s by %.0f units" % [pair[0], pair[1], -gap])


## The Favour shop is three cards abreast, the way the Royal Market lays out
## what it sells: one painting each, and a price a thumb can press. They were
## three rows of type in which a potion, a market and a scholar's draught looked
## exactly alike.
func _the_favour_shop_is_a_shelf(page: Control) -> void:
	var arts := {}
	var wide := 0.0
	var stack: Array = [page]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if n is TextureRect and (n as TextureRect).texture != null:
			var path := (n as TextureRect).texture.resource_path
			if path.contains("/icons/"):
				arts[path] = true
				wide = maxf(wide, (n as Control).size.x)
	if arts.size() < 3:
		_fail("%s: the favour shop shows %d painting(s); three goods, three paintings"
			% [_tag, arts.size()])


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
	if n is Control and _band != Vector2.ZERO and n.get_parent() != null:
		var c := n as Control
		var l := c.global_position.x
		var rr := l + c.size.x
		if rr > _band.y + 1.0:
			_fail("%s: a %s reaches x %.0f, past the section's right edge at %.0f"
				% [_tag, n.get_class(), rr, _band.y])
		if l < _band.x - 1.0:
			_fail("%s: a %s starts at x %.0f, left of the section's %.0f"
				% [_tag, n.get_class(), l, _band.x])
	for c2 in n.get_children():
		_walk(c2)
