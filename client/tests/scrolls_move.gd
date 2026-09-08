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
