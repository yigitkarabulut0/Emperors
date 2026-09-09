extends SceneTree
## Every scrolling region can actually be dragged, and the army's row is wider
## than its window.
##
## A ScrollContainer only sees a drag its children did not eat, and every row in
## this game is made of buttons, so without a deadzone the drag never arrives.
## Each screen set that by hand until one was added that did not, and the army's
## slot row could be seen and not moved: five cards fitted the window and the
## tile to buy the sixth sat past its edge, unreachable.
##
## Run: godot --headless --path client --script tests/scrolls_move.gd

const SCREENS := ["collect", "inventory", "shop", "family", "kingdom", "army"]
## Screens whose list comes from the layout. Shop, Family and Kingdom build
## their own ScrollContainer in code; _a_scroll_built_by_hand_sets_its_deadzone
## covers those.
const MUST_SCROLL := ["collect", "inventory", "army"]

var _fails: int = 0
var _L: GDScript


func _initialize() -> void:
	await process_frame
	# Loaded, not referenced by class name: under --script the global class is a
	# GDScript resource and every static call on it fails at runtime. Those
	# failures do not stop the run, so a test written that way prints PASS
	# without having checked anything -- which is how this one first shipped.
	_L = load("res://scripts/ui/layout.gd")
	if _L == null or not _L.has_method("build"):
		print("FAIL  could not load layout.gd; no check below actually ran")
		quit(1)
		return
	var checked := 0
	for screen in SCREENS:
		checked += _every_scroll_takes_a_drag(screen)
	if checked == 0:
		_fail("no scrolling region was found on any screen, so nothing was tested")
	else:
		print("  checked %d scrolling region(s)" % checked)
	_the_army_row_is_longer_than_its_window()
	_a_scroll_built_by_hand_sets_its_deadzone()
	_nothing_stands_on_a_scroll_and_eats_its_drags()
	_a_card_that_is_all_button_passes_the_drag_on()
	_a_rows_first_card_starts_inside_the_window()
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  every scroll takes a drag, and the army row runs past its window")
	quit()


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)


func _every_scroll_takes_a_drag(screen: String) -> int:
	var host := Control.new()
	host.size = Vector2(941, 1672)
	root.add_child(host)
	var ui: Dictionary = _L.build(screen, host)
	var found := 0
	for id in ui:
		var n: Variant = ui[id]
		if not (n is ScrollContainer):
			continue
		found += 1
		var sc: ScrollContainer = n
		if sc.scroll_deadzone <= 0:
			_fail("%s/%s has no scroll deadzone, so a drag starting on a button is eaten"
				% [screen, id])
		var h_off := sc.horizontal_scroll_mode == ScrollContainer.SCROLL_MODE_DISABLED
		var v_off := sc.vertical_scroll_mode == ScrollContainer.SCROLL_MODE_DISABLED
		if h_off and v_off:
			_fail("%s/%s cannot scroll on either axis" % [screen, id])
	host.queue_free()
	if found == 0 and MUST_SCROLL.has(screen):
		_fail("%s has no scrolling region at all" % screen)
	return found


## Five slots fill the window exactly, so the tile for the sixth is only
## reachable by scrolling: the row has to run past the window at the slot counts
## the balance allows.
func _the_army_row_is_longer_than_its_window() -> void:
	var strip: Dictionary = _L.element("army", "soldier_strip")
	var card: Dictionary = _L.find("army", "soldier_card")
	var nxt: Dictionary = _L.find("army", "next_slot_card")
	if strip.is_empty() or card.is_empty() or nxt.is_empty():
		_fail("the army row is missing a piece (strip/card/next)")
		return
	var window: float = _L.rect_of(strip).size.x
	var pitch: float = float(card.get("pitch", 0))
	var next_w: float = _L.rect_of(nxt).size.x
	var maxs := _max_slots()
	if maxs <= 0 or pitch <= 0:
		_fail("could not read max_slots (%d) or pitch (%.0f)" % [maxs, pitch])
		return
	var full := maxs * pitch + next_w
	if full <= window:
		_fail("all %d slots and the next tile fit in %.0f units; nothing would ever scroll"
			% [maxs, window])
	print("  army row: %d slots x %.0f + %.0f = %.0f units in a %.0f window"
		% [maxs, pitch, next_w, full, window])


## A list places its rows from the template's own position, measured against the
## window's. Put the window somewhere the template is not and the first row is
## laid out above the top of it and clipped: the inventory's list was moved down
## to give the filter chips room, the card was left where it was, and the top
## item came out cut in half.
func _a_rows_first_card_starts_inside_the_window() -> void:
	# The screens that lay a list out from the painting's own coordinates:
	# top = card.y - window.y, so a card above its window gives a negative top
	# and the first row is drawn off the top of it.
	const MEASURED := [["inventory", "list", "item_card"], ["collect", "job_list", "job_row"]]
	for pair in MEASURED:
		var window: Dictionary = _L.element(pair[0], pair[1])
		var card: Dictionary = _L.find(pair[0], pair[2])
		if window.is_empty() or card.is_empty():
			_fail("%s: no %s or no %s" % [pair[0], pair[1], pair[2]])
			continue
		var w: Rect2 = _L.rect_of(window)
		var c: Rect2 = _L.rect_of(card)
		if c.position.y < w.position.y:
			_fail("%s/%s starts at y %.0f and its window at y %.0f: the first row is drawn %.0f units above the top and clipped"
				% [pair[0], pair[2], c.position.y, w.position.y, w.position.y - c.position.y])


## A button lying over a scrolling region takes the drags that start on it.
##
## Growing the tap targets did this: auto_equip reached 44 pt by extending down
## into the slot row's window, and every drag begun in that band hit a button
## instead of the row.
func _nothing_stands_on_a_scroll_and_eats_its_drags() -> void:
	for screen in SCREENS:
		var elements: Array = _L.spec(screen).get("elements", [])
		for e in elements:
			if not (e is Dictionary) or str(e.get("kind", "")) != "scroll":
				continue
			var box: Rect2 = _L.rect_of(e)
			for other in elements:
				if not (other is Dictionary) or other == e:
					continue
				if not (str(other.get("kind", "")) in ["button", "hotspot"]):
					continue
				var r: Rect2 = _L.rect_of(other)
				if box.intersects(r):
					_fail("%s: %s %s lies over the scrolling region %s and will take its drags"
						% [screen, str(other.get("id", "")), r, box])


## A control that covers a whole card inside a scroll has to let the drag past.
##
## A Button consumes the press, so a row whose cards are covered by one can be
## tapped and never dragged -- which is exactly what the army's row did, while
## looking correct and measuring correct.
func _a_card_that_is_all_button_passes_the_drag_on() -> void:
	for screen in SCREENS:
		for e in _L.spec(screen).get("elements", []):
			if not (e is Dictionary) or str(e.get("kind", "")) != "scroll":
				continue
			for card in e.get("content", []):
				if not (card is Dictionary) or str(card.get("kind", "")) != "template":
					continue
				var cr: Rect2 = _L.rect_of(card)
				var area := cr.size.x * cr.size.y
				for q in card.get("parts", []):
					if not (str(q.get("kind", "")) in ["button", "hotspot"]):
						continue
					var qr: Rect2 = _L.rect_of(q)
					if area <= 0 or qr.size.x * qr.size.y < area * 0.8:
						continue
					if not bool(q.get("pass_drag", false)):
						_fail("%s/%s/%s covers its card and does not pass_drag, so the row cannot be dragged"
							% [screen, str(card.get("id", "")), str(q.get("id", ""))])


## Layout gives every scroll it builds a deadzone. A screen that makes one
## itself has to do the same, and this is the miss that costs a whole row: the
## scroll is on screen, looks right, and does not move.
func _a_scroll_built_by_hand_sets_its_deadzone() -> void:
	var dir := DirAccess.open("res://scenes/tabs")
	if dir == null:
		_fail("could not read scenes/tabs")
		return
	for name in dir.get_files():
		if not name.ends_with(".gd"):
			continue
		var src := FileAccess.get_file_as_string("res://scenes/tabs/" + name)
		if not src.contains("ScrollContainer.new()"):
			continue
		if not src.contains("scroll_deadzone"):
			_fail("%s builds a ScrollContainer and never sets scroll_deadzone; a drag \
starting on one of its buttons will be eaten" % name)


func _max_slots() -> int:
	var f := FileAccess.open("res://../balance/soldiers.json", FileAccess.READ)
	if f == null:
		return 0
	var d: Variant = JSON.parse_string(f.get_as_text())
	return int(d.get("max_slots", 0)) if d is Dictionary else 0
