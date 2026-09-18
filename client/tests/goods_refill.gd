extends SceneTree
## BUY on a diamond good asks what the server's description allows, and nothing
## else: the day's refills used up is a refusal in the server's words, a held
## potion or charter is offered beside the diamonds, and the request names the
## token only when the player chose it.
##
## Run: godot --headless --path client --script tests/goods_refill.gd
##
## Goods is loaded at run time, never named as a class here: a class named in
## this script compiles before the autoloads exist.

var _fails := 0


func _initialize() -> void:
	await process_frame
	var goods: GDScript = load("res://scripts/ui/goods.gd")
	for m in ["plan", "request", "buyable"]:
		if not goods.has_method(m):
			print("FAIL  Goods.%s does not exist" % m)
			quit(1)
			return
	var refill := {"id": "energy_refill", "title": "ENERGY REFILL", "blurb": "Fill your pool back to 236 right now.",
		"diamonds": 20, "affordable": true, "useful": true, "caption": "Refill 1 of 3 today",
		"token_id": "energy_potion", "token_name": "Energy Potion", "tokens": 0}

	# The day's refills used up: refused, in the server's words.
	var spent := refill.duplicate()
	spent.merge({"useful": false, "note": "you have used today's refills", "caption": "No refills left today",
		"diamonds": 45, "tokens": 2}, true)
	var p: Dictionary = goods.plan(spent, 500)
	_expect(p["kind"] == "refuse", "a used-up day is refused, not offered (%s)" % p["kind"])
	_expect(str(p.get("body", "")).contains("you have used today's refills"), "the refusal says why, in the server's words")
	_expect(not goods.buyable(spent), "a used-up refill does not look buyable, potion or not")

	# A potion held and the diamonds too: both are offered, the potion first.
	var held := refill.duplicate()
	held["tokens"] = 2
	p = goods.plan(held, 127)
	_expect(p["kind"] == "choose", "a held potion is offered beside the diamonds (%s)" % p["kind"])
	var opts: Array = p.get("options", [])
	_expect(opts.size() == 2 and opts[0]["id"] == "token" and opts[1]["id"] == "diamonds", "the potion, then the diamonds")
	if opts.size() == 2:
		_expect(opts[0]["label"] == "Use Energy Potion" and opts[0]["sub"] == "2 left", "the potion says how many are left: %s" % str(opts[0]))
		_expect(opts[1]["label"] == "Pay 20 diamonds" and opts[1]["sub"] == "You have 127", "the diamonds say the price: %s" % str(opts[1]))

	# A potion held and too few diamonds: the potion alone.
	var poor := held.duplicate()
	poor["affordable"] = false
	p = goods.plan(poor, 5)
	_expect(p["kind"] == "confirm" and p.get("pay", "") == "token", "without the diamonds, the potion is the one way (%s)" % str(p))
	_expect(str(p.get("confirm_text", "")) == "Use Energy Potion", "and the button says so")
	_expect(goods.buyable(poor), "a potion makes the refill buyable without the diamonds")

	# No potion, too few diamonds: refused with the price.
	var broke := refill.duplicate()
	broke["affordable"] = false
	p = goods.plan(broke, 5)
	_expect(p["kind"] == "refuse" and str(p["body"]).contains("Costs 20 diamonds, and you have 5"), "no potion and no diamonds is a refusal with the price")
	_expect(not goods.buyable(broke), "and does not look buyable")

	# No potion, diamonds enough: the plain purchase.
	p = goods.plan(refill, 127)
	_expect(p["kind"] == "confirm" and p.get("pay", "") == "diamonds", "diamonds alone is a plain Buy")

	# The request names the token only when it was chosen.
	_expect(goods.request("energy_refill", "token") == {"good": "energy_refill", "pay": "token"}, "a potion is sent as pay: token")
	_expect(goods.request("energy_refill", "diamonds") == {"good": "energy_refill"}, "diamonds are the default and not named")

	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  BUY offers what the server allows and sends what the player chose")
	quit()


func _expect(cond: bool, what: String) -> void:
	if not cond:
		_fails += 1
		print("  FAIL  " + what)
