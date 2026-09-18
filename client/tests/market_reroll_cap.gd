extends SceneTree
## The market's REROLL knows the day's allowance before the tap: spent is a
## refusal whatever the purse holds, a short purse is its own refusal, and the
## confirm says how many are left. A shop from a server that sends no allowance
## is never called spent.
##
## Run: godot --headless --path client --script tests/market_reroll_cap.gd
##
## The Shop tab is loaded at run time, never named as a class here: a class
## named in this script compiles before the autoloads exist.

var _fails := 0


func _initialize() -> void:
	await process_frame
	var shop: GDScript = load("res://scenes/tabs/shop.gd")
	for m in ["reroll_state", "rerolls_left_line"]:
		if not shop.has_method(m):
			print("FAIL  shop.%s does not exist" % m)
			quit(1)
			return

	var rich := {"reroll_cost": 14, "can_afford_reroll": true, "rerolls_left": 7, "rerolls_per_day": 20}
	_expect(shop.reroll_state(rich) == "ok", "a purse and rerolls left is ok")
	_expect(shop.rerolls_left_line(rich) == "7 of today's 20 rerolls left.", "the confirm says how many are left (%s)" % shop.rerolls_left_line(rich))

	var spent := rich.duplicate()
	spent["rerolls_left"] = 0
	_expect(shop.reroll_state(spent) == "spent", "the day's allowance used is spent, however full the purse")

	var both := spent.duplicate()
	both["can_afford_reroll"] = false
	_expect(shop.reroll_state(both) == "spent", "spent is said before a short purse: more diamonds would not help")

	var poor := rich.duplicate()
	poor["can_afford_reroll"] = false
	_expect(shop.reroll_state(poor) == "poor", "a short purse with rerolls left is poor")

	var old := {"reroll_cost": 8, "can_afford_reroll": true}
	_expect(shop.reroll_state(old) == "ok", "a server with no allowance never makes the market spent")
	_expect(shop.rerolls_left_line(old) == "", "and the confirm says nothing about one")

	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  REROLL knows the day's allowance before the tap")
	quit()


func _expect(cond: bool, what: String) -> void:
	if not cond:
		_fails += 1
		print("  FAIL  " + what)
