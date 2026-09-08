extends SceneTree
## Every slot a player can own is on the screen, and the next one to buy is at
## the end of them.
##
## The army row was four cards at fixed positions, because that is what the
## reference painting happened to show. balance/soldiers.json allows ten, so
## slots five upward existed on the server, held soldiers, counted toward might
## -- and could not be seen, selected, geared or dismissed. The row scrolls
## sideways now and is built from the slot count.
##
## Run: godot --headless --path client --script tests/army_strip.gd

var _fails: int = 0
var _L: GDScript


func _initialize() -> void:
	await process_frame
	_L = load("res://scripts/ui/layout.gd")
	_the_row_scrolls_sideways()
	_it_holds_every_slot_the_balance_allows()
	_the_next_slot_comes_after_the_last_one()
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  the army row carries every slot, with the next one after them")
	quit()


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)


func _strip() -> Dictionary:
	return _L.element("army", "soldier_strip")


func _the_row_scrolls_sideways() -> void:
	var s := _strip()
	if s.is_empty():
		_fail("army has no soldier_strip")
		return
	if str(s.get("kind", "")) != "scroll":
		_fail("soldier_strip is a %s, not a scroll" % str(s.get("kind", "")))
	if str(s.get("axis", "")) != "horizontal":
		_fail("soldier_strip does not scroll horizontally, so it can only ever show what fits")
	var ids := []
	for c in s.get("content", []):
		ids.append(str(c.get("id", "")))
	for want in ["soldier_card", "next_slot_card"]:
		if not ids.has(want):
			_fail("soldier_strip has no %s in it (has %s)" % [want, str(ids)])


## The strip must be able to lay out max_slots cards, not just the few the
## painting showed.
func _it_holds_every_slot_the_balance_allows() -> void:
	var maxs := _max_slots()
	if maxs <= 0:
		_fail("could not read max_slots from balance/soldiers.json")
		return
	var card: Dictionary = _L.find("army", "soldier_card")
	if card.has("instances"):
		_fail("soldier_card still carries %d fixed instances; the screen must build one per slot"
			% card["instances"].size())
	var pitch := float(card.get("pitch", 0))
	if pitch <= 0:
		_fail("soldier_card has no pitch, so a row of them cannot be spaced")
		return
	var r: Rect2 = _L.rect_of(card)
	if pitch < r.size.x:
		_fail("pitch %.0f is narrower than the card (%.0f); they would overlap" % [pitch, r.size.x])
	# The strip is a window, not the whole row: it must be narrower than the row
	# it scrolls, or scrolling was never needed and something else is wrong.
	var strip: Rect2 = _L.rect_of(_strip())
	if strip.size.x >= maxs * pitch:
		_fail("the strip is %.0f wide and %d slots need %.0f; nothing would scroll"
			% [strip.size.x, maxs, maxs * pitch])


func _the_next_slot_comes_after_the_last_one() -> void:
	var ns: Dictionary = _L.find("army", "next_slot_card")
	if ns.is_empty():
		_fail("no next_slot_card")
		return
	var ids := []
	for q in ns.get("parts", []):
		ids.append(str(q.get("id", "")))
	for want in ["tile", "price", "unlock"]:
		if not ids.has(want):
			_fail("next_slot_card has no %s (has %s)" % [want, str(ids)])
	# It must not still be a fixed element sitting to the right of four cards.
	if not _L.element("army", "next_slot").is_empty():
		_fail("the old fixed next_slot element is still in the layout")


func _max_slots() -> int:
	var f := FileAccess.open("res://../balance/soldiers.json", FileAccess.READ)
	if f == null:
		return 0
	var d: Variant = JSON.parse_string(f.get_as_text())
	return int(d.get("max_slots", 0)) if d is Dictionary else 0
