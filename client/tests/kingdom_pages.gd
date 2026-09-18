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
		await _the_hall_fits(canvas)
	await _the_tabs_swap_what_the_page_shows()
	await _realm_never_leaks_into_another_tab()
	await _no_kingdom_shows_only_the_hall()
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
			"role": "king" if i == 0 else ("marshal" if i == 1 else "member"),
			"level": 30 + i, "donated": str(1000 * i)})
	var upgrades: Array = []
	for i in 4:
		upgrades.append({"id": "u%d" % i, "name": "Kingdom Work %d" % i, "level": i,
			"effect_now": 500 * i, "per_level": 250, "next_cost": 120000 * (i + 1),
			"maxed": i == 3, "bucket": "collect_income_bp"})
	var board: Array = []
	for i in 10:
		board.append({"id": "k%d" % i, "name": "A Kingdom Named %d" % i, "tag": "K%d" % i,
			"level": 20 - i})
	var asking: Array = []
	for i in 2:
		asking.append({"player_id": "r%d" % i, "name": "A Lord Who Asked %d" % i,
			"level": 22 + i, "waiting": 3600 * (i + 1)})
	return {"in_kingdom": true, "me": {"role": "king"},
		"kingdom": {"id": "k0", "name": "Lion Banner", "tag": "LION", "members": 6,
			"member_cap": 50, "level": 5, "join_policy": "request"},
		"members": members, "upgrades": upgrades, "leaderboard": board, "requests": asking}


## A player with no kingdom: an invitation, a cooldown running out, and every
## kind of card the hall can be sent.
func _hall_data(waiting: int = 0) -> Dictionary:
	var cards: Array = []
	var actions := ["join", "request", "requested", "full", "join", "request", "join", "join"]
	for i in actions.size():
		cards.append({"id": "k%d" % i, "kingdom_id": "k%d" % i,
			"name": "The Kingdom of the Very Long Name %d" % i, "tag": "K%d" % i, "level": 1 + i,
			"members": 4 + i, "member_cap": 20, "reputation": 1000 * i,
			"join_policy": "request" if actions[i].begins_with("request") else "open",
			"king": "Aldric the %d" % i, "action": "cooldown" if waiting > 0 else actions[i]})
	var invite: Dictionary = cards[0].duplicate()
	invite["id"] = "inv"
	invite["kingdom_id"] = "inv"
	invite["action"] = "cooldown" if waiting > 0 else "accept"
	return {"in_kingdom": false, "kingdom": null, "members": [], "upgrades": [], "me": null,
		"invites": [invite], "recommended": cards, "leaderboard": [], "requests": [],
		"found_cost": 250000, "found_level": 20, "rejoin_in": waiting,
		"can_found": false, "found_reason": "Reach level 20 to found a kingdom.",
		"max_requests": 5}


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
	page.set("_loaded_once", true)
	page.call("_apply")

	# Through the strip itself, as a thumb does.
	var strip: Control = page.get("_tabs")
	for mode in ["lords", "works", "ranks", "realm"]:
		(strip.get("_hits")[mode] as Button).pressed.emit()
		for i in 3:
			await process_frame
		# In the tree, not the node's own flag: a layer hides what is on it.
		var realm_showing: bool = (ui["realm_card"] as Control).is_visible_in_tree()
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
			if (ui["lords_panel"] as Control).is_visible_in_tree():
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


## What the owner saw: the works rows and their UPGRADE buttons standing on the
## Lords page. The shell refreshes the open tab whenever the game's state
## changes and whenever the tab is reopened, and painting REALM used to switch
## its rows back on whichever tab was showing.
func _realm_never_leaks_into_another_tab() -> void:
	var host := Control.new()
	host.size = Vector2(941, 1672)
	root.add_child(host)
	var page: Control = load("res://scenes/tabs/kingdom.gd").new()
	page.set_anchors_preset(Control.PRESET_FULL_RECT)
	host.add_child(page)
	for i in 3:
		await process_frame
	var ui: Dictionary = page.get("_ui")
	page.set("_data", _data())
	page.set("_shop", {"favour": 100, "goods": []})
	page.set("_loaded_once", true)
	page.call("_apply")
	for mode in ["lords", "works", "ranks"]:
		page.call("_show_section", mode)
		for i in 3:
			await process_frame
		# A refresh the way the shell sends one: recent enough that it repaints
		# rather than asking the server.
		page.set("_loaded_ms", Time.get_ticks_msec())
		page.call("refresh")
		for i in 3:
			await process_frame
		for inst in ui["work_row"]:
			if (inst["node"] as Control).is_visible_in_tree():
				_fail("a REALM works row is standing on the %s tab after a refresh" % mode.to_upper())
				break
		for id in ["realm_card", "treasury_card", "rep_bar_fill", "donate"]:
			if (ui[id] as Control).is_visible_in_tree():
				_fail("REALM's %s shows on the %s tab after a refresh" % [id, mode.to_upper()])
		if page.get("_section") == null:
			_fail("the %s tab lost its section on a refresh" % mode.to_upper())
	print("  a refresh on Lords, Works or Ranks leaves REALM hidden")
	host.queue_free()
	await process_frame


## Without a kingdom there is no kingdom page to show: no crest, no stats, no
## strip of tabs for a realm the player does not have. Only the hall.
func _no_kingdom_shows_only_the_hall() -> void:
	var host := Control.new()
	host.size = Vector2(941, 1672)
	root.add_child(host)
	var page: Control = load("res://scenes/tabs/kingdom.gd").new()
	page.set_anchors_preset(Control.PRESET_FULL_RECT)
	host.add_child(page)
	for i in 3:
		await process_frame
	var ui: Dictionary = page.get("_ui")
	page.set("_data", _hall_data())
	page.set("_loaded_once", true)
	page.call("_apply")
	for i in 4:
		await process_frame
	for id in ["header", "kingdom_name", "stat_members", "realm_card", "lords_panel"]:
		if (ui[id] as Control).is_visible_in_tree():
			_fail("with no kingdom, the page still shows the kingdom's %s" % id)
	if (page.get("_tabs") as Control).is_visible_in_tree():
		_fail("with no kingdom, the page still shows the REALM/LORDS/WORKS/RANKS strip")
	var hall: Control = page.get("_hall")
	if hall == null or not hall.is_visible_in_tree():
		_fail("with no kingdom, the hall is not shown")
	else:
		# All of it can be scrolled to: the page grew to hold it.
		var content: Control = page.get("_content")
		var bottom := hall.global_position.y + hall.size.y
		if content.custom_minimum_size.y < bottom:
			_fail("the hall runs to y %.0f but the page stops at %.0f -- its foot cannot be reached"
				% [bottom, content.custom_minimum_size.y])
	# And the kingdom it joins takes its place, opening on REALM.
	page.set("_data", _data())
	page.call("_apply")
	for i in 3:
		await process_frame
	if page.get("_hall") != null:
		_fail("joining a kingdom left the hall standing")
	if not (ui["realm_card"] as Control).is_visible_in_tree():
		_fail("joining a kingdom did not open on REALM")
	print("  with no kingdom only the hall shows, and a kingdom replaces it")
	host.queue_free()
	await process_frame


## The hall's rows fit the phone, and every button in it is one a thumb can hit.
func _the_hall_fits(canvas: Vector2) -> void:
	for waiting in [0, 2400]:
		var host := Control.new()
		host.size = canvas
		root.add_child(host)
		var hall_script: GDScript = load("res://scenes/kingdom/kingdom_hall.gd")
		var hall: Control = hall_script.new()
		hall.setup("hall", _hall_data(waiting), {})
		# Where the Kingdom page puts it: the painting's own units, from x 0.
		hall.position = Vector2(0, float(hall_script.get_script_constant_map()["TOP"]))
		host.add_child(hall)
		for i in 4:
			await process_frame
		_tag = "the hall%s on %dx%d" % [" (waiting)" if waiting > 0 else "", int(canvas.x), int(canvas.y)]
		_screen = Rect2(Vector2.ZERO, canvas)
		_band = Vector2(hall.global_position.x, hall.global_position.x + hall.size.x)
		var before := _buttons
		_walk(hall)
		_nothing_eats_the_drag(hall)
		if _buttons == before:
			_fail("%s: built no buttons" % _tag)
		if waiting > 0:
			var live := 0
			var stack: Array = [hall]
			while not stack.is_empty():
				var n: Node = stack.pop_back()
				for c in n.get_children():
					stack.append(c)
				if n is Button and not (n as Button).disabled and (n as Button).text in ["Join", "Request", "Accept"]:
					live += 1
			if live > 0:
				_fail("%s: %d join button(s) still answer while the player waits" % [_tag, live])
		hall.queue_free()
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


## The tab strip is the one tab row (scripts/ui/tab_strip.gd): four painted
## plates of one size, standing on the painting's gold rule, their outer edges
## on the painted strip's, the one showing lit. Its predecessor nine-patched two
## emptied plates to four widths and laid word crops over them; the gold rule
## under it stepped between tabs until each was drawn at the painting's height.
func _the_strip_matches_the_painting(page: Control, ui: Dictionary) -> void:
	var strip: Control = page.get("_tabs")
	if strip == null:
		_fail("the kingdom has no tab strip")
		return
	var ids: Array = strip.get("ids")
	if ids != TAB_NAMES:
		_fail("the strip shows %s" % str(ids))
		return
	var first: TextureRect = strip.call("plate", ids[0])
	for i in ids.size():
		var p: TextureRect = strip.call("plate", ids[i])
		var r := Rect2(p.global_position, p.size)
		if p.size != first.size:
			_fail("tab %d is %s, tab 0 %s -- the plates are one size" % [i, p.size, first.size])
		# On the gold rule the painting stands its plates on, y 615.
		if absf(r.end.y - 615.0) > 1.0:
			_fail("tab %d stands at y %.0f, not on the rule at 615" % [i, r.end.y])
		var lit: bool = p.texture.resource_path.ends_with("_lit.png")
		if lit != (ids[i] == str(page.get("_view"))):
			_fail("tab %d is %s while %s shows" % [i, "lit" if lit else "unlit", page.get("_view")])
	var last: TextureRect = strip.call("plate", ids[ids.size() - 1])
	if absf(first.global_position.x - 151.0) > 1.0 or absf(last.global_position.x + last.size.x - 931.0) > 1.0:
		_fail("the strip runs %.0f..%.0f, not the painted 151..931"
			% [first.global_position.x, last.global_position.x + last.size.x])


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
