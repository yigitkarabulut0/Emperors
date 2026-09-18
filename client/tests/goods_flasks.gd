extends SceneTree
## The flasks are offered by the energy pill's "+" while they are held, and
## never sold.
##
## The Small and Great Flasks come free (the Tax Cart, the calendar, letters).
## The store lists them apart from its goods (GET /v1/store `flasks`), so no
## screen that sells goods can offer one for diamonds. Checked, on the pure
## rules the "+" follows (Goods.flask_options, Goods.find_flask):
##  - a flask held is offered with what one would add now, the server's figure;
##  - a flask not held is not offered; with none held the "+" is the refill
##    alone, as before;
##  - a full pool still offers a held flask, without a figure, and drinking it
##    is refused before any request (Goods.drink reads `useful`);
##  - a flask listed among the goods -- a server that sells it -- is not offered.
##
## Run: godot --headless --path client --script tests/goods_flasks.gd

var _fails := 0


func _initialize() -> void:
	await process_frame
	var goods: GDScript = load("res://scripts/ui/goods.gd")
	if not goods.has_method("flask_options"):
		_fail("the energy pill's \"+\" knows nothing of flasks (Goods.flask_options)")
		_done()
		return
	var refill := {"id": "energy_refill", "title": "ENERGY REFILL", "diamonds": 20, "useful": true, "affordable": true}
	var small := {"id": "flask_small", "name": "Small Flask", "token_id": "flask_small", "tokens": 2, "amount": 47, "useful": true}
	var large := {"id": "flask_large", "name": "Great Flask", "token_id": "flask_large", "tokens": 0, "amount": 118, "useful": true}
	var store := {"goods": [refill], "flasks": [small, large]}

	var opts: Array = goods.call("flask_options", store)
	_expect(opts.size() == 1 and str(opts[0]["id"]) == "flask_small",
		"with a Small Flask held and no Great Flask, the \"+\" offers %s" % [opts])
	if opts.size() == 1:
		_expect(str(opts[0]["label"]) == "Drink a Small Flask (+47)" and str(opts[0]["sub"]) == "2 held",
			"the Small Flask reads \"%s\" / \"%s\"" % [opts[0]["label"], opts[0]["sub"]])
	large["tokens"] = 1
	opts = goods.call("flask_options", store)
	_expect(opts.size() == 2 and str(opts[1]["label"]) == "Drink a Great Flask (+118)", "both flasks held: %s" % [opts])

	# None held: nothing to offer, the refill alone.
	opts = goods.call("flask_options", {"goods": [refill], "flasks": [
		{"id": "flask_small", "name": "Small Flask", "tokens": 0, "amount": 47, "useful": true}]})
	_expect(opts.is_empty(), "a flask not held is offered: %s" % [opts])
	_expect((goods.call("flask_options", {"goods": [refill]}) as Array).is_empty(),
		"a store without flasks offers some")

	# A full pool: the flask is still offered, without a figure it would not add.
	var full := {"goods": [refill], "flasks": [{"id": "flask_small", "name": "Small Flask", "tokens": 3, "amount": 0, "useful": false}]}
	opts = goods.call("flask_options", full)
	_expect(opts.size() == 1 and str(opts[0]["label"]) == "Drink a Small Flask", "a full pool's flask reads %s" % [opts])

	# Never from the goods: a flask the store lists for sale is not a flask to drink.
	var sold := {"goods": [refill, {"id": "flask_small", "name": "Small Flask", "tokens": 1, "amount": 47, "useful": true,
		"diamonds": 5}]}
	_expect((goods.call("flask_options", sold) as Array).is_empty(), "a flask listed among the goods is offered")
	_expect((goods.call("find_flask", store, "flask_large") as Dictionary).get("amount", 0) == 118,
		"find_flask does not find the Great Flask")
	_expect((goods.call("find_flask", sold, "flask_small") as Dictionary).is_empty(),
		"find_flask reads the goods")
	_done()


func _done() -> void:
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  the flasks are offered while held, with the server's figure, and never from the goods")
	quit()


func _expect(ok: bool, why: String) -> void:
	if not ok:
		_fail(why)


func _fail(why: String) -> void:
	_fails += 1
	printerr("  ", why)
