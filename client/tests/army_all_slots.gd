extends SceneTree
## A lord who owns every soldier slot gets null for the next one. The Army read
## it straight into a Dictionary, a script error every time the tab painted;
## now there is no next card, and no room kept for one.
##
## Run: godot --headless --path client --script tests/army_all_slots.gd
##
## The Army tab is loaded at run time, never named as a class here.

var _fails := 0


func _initialize() -> void:
	await process_frame
	var army: GDScript = load("res://scenes/tabs/army.gd")
	if not army.has_method("next_slot"):
		print("FAIL  army.next_slot does not exist")
		quit(1)
		return
	_expect(army.next_slot({"next_slot": null}) == {}, "every slot owned: no next slot")
	_expect(army.next_slot({}) == {}, "a view without the key: no next slot")
	var ns := {"slot": 7, "cost": 76076, "unlocked": true}
	_expect(army.next_slot({"next_slot": ns}) == ns, "a next slot to buy is read as sent")
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  a lord who owns every slot has no next card, and no script error")
	quit()


func _expect(cond: bool, what: String) -> void:
	if not cond:
		_fails += 1
		print("  FAIL  " + what)
