extends SceneTree
## The market's REROLL plate and the diamonds figure on it dim together.
##
## The plate dimmed when the day's rerolls were spent or the purse was short,
## but the figure is its own label over the plate and stayed full white: a
## reroll that could not be had still showed its price as if it could. What
## must hold: spent and poor, the plate and its figure wear the one dimmed look
## every plate that cannot be pressed wears; ok, both are lit.
##
## Run: godot --headless --path client --script tests/shop_reroll_plate.gd
##
## The Shop tab is loaded at run time, never named as a class here.

var _fails := 0


func _initialize() -> void:
	await process_frame
	root.get_node("Env").set("api_base_url", "http://127.0.0.1:9")
	var vp := SubViewport.new()
	vp.size = Vector2i(941, 1672)
	root.add_child(vp)
	root.get_node("Nav").set("host", vp)
	var tab: Control = (load("res://scenes/tabs/shop.gd") as GDScript).new()
	tab.size = Vector2(941, 1672)
	vp.add_child(tab)
	await process_frame
	var dimmed := Color(0.55, 0.55, 0.55)
	var cases := {
		"spent": [{"reroll_cost": 8, "can_afford_reroll": true, "rerolls_left": 0, "rerolls_per_day": 20}, false],
		"poor": [{"reroll_cost": 8, "can_afford_reroll": false, "rerolls_left": 5, "rerolls_per_day": 20}, false],
		"ok": [{"reroll_cost": 8, "can_afford_reroll": true, "rerolls_left": 5, "rerolls_per_day": 20}, true],
	}
	for what in cases:
		var shop: Dictionary = cases[what][0].duplicate()
		shop["offers"] = []
		tab.set("_shop", shop)
		tab.call("_paint")
		var ui: Dictionary = tab.get("_ui")
		var plate: Color = (ui["reroll"] as Control).modulate
		var figure: Color = (ui["reroll_cost"] as Control).modulate
		var want := Color.WHITE if cases[what][1] else dimmed
		if not plate.is_equal_approx(want):
			_fail("%s: the plate is %s, want %s" % [what, plate, want])
		if not figure.is_equal_approx(plate):
			_fail("%s: the diamonds figure is %s on a plate drawn %s" % [what, figure, plate])
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  the REROLL plate and its figure dim together, and light together")
	quit()


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)
