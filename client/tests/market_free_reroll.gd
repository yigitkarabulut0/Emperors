extends SceneTree
## The hour's gifts to the market and the refill:
##
## - Fresh Wares: while the server says a free restock is left, REROLL MARKET
##   is "free" whatever the purse or the day's allowance, lit, and wears its
##   free face (shop/reroll_button_free, the diamond and the price lifted) with
##   FREE centred under its title's words (x 738..889, 813.5); after it, the
##   painted face and the price where they were;
## - Quartermaster's Sale: every price the refill is asked at is said with the
##   one it had ("10 diamonds, not 20"), and the Shop's refill card sets the old
##   price small and struck through after the sale's, inside its plate, before
##   BUY; with no sale on, no old price.
##
## Run: godot --headless --path client --script tests/market_free_reroll.gd
##
## The Shop tab and Goods are loaded at run time, never named as classes here.

const TITLE_MID := 813.5
## The price plate's end: BUY stands at x 238 of the goods panel.
const BUY_X := 238.0

var _fails := 0
var _checked := 0


func _initialize() -> void:
	await process_frame
	root.get_node("Env").set("api_base_url", "http://127.0.0.1:9")
	var shop: GDScript = load("res://scenes/tabs/shop.gd")
	var goods: GDScript = load("res://scripts/ui/goods.gd")
	# Free, whatever else is so.
	var free := {"reroll_cost": 14, "can_afford_reroll": false, "rerolls_left": 0, "rerolls_per_day": 20, "free_rerolls": 1}
	_expect(shop.reroll_state(free) == "free", "a free restock left is %s, not free" % shop.reroll_state(free))
	_expect(shop.reroll_look(free) == Color.WHITE, "a free restock is drawn dimmed")
	free["free_rerolls"] = 0
	_expect(shop.reroll_state(free) == "spent", "with the free restock taken the day's allowance holds again")

	# The sale's words.
	var refill := {"id": "energy_refill", "title": "ENERGY REFILL", "blurb": "Fill your pool back to 236 right now.",
		"diamonds": 10, "regular_diamonds": 20, "affordable": true, "useful": true, "caption": "Refill 1 of 3 today",
		"token_id": "energy_potion", "token_name": "Energy Potion", "tokens": 0}
	_expect(goods.on_sale(refill) == 20, "the refill on sale reads %d before the sale" % goods.on_sale(refill))
	var p: Dictionary = goods.plan(refill, 127)
	_expect(p["kind"] == "confirm" and str(p["body"]).ends_with("10 diamonds, not 20 while the sale lasts. You have 127."),
		"the sale's confirm reads: %s" % p.get("body", ""))
	var held := refill.duplicate()
	held["tokens"] = 1
	p = goods.plan(held, 127)
	_expect(p["kind"] == "choose" and (p["options"] as Array)[1]["label"] == "Pay 10 diamonds, not 20",
		"the sale's choice reads: %s" % str(p.get("options", [])))
	var poor := refill.duplicate()
	poor["affordable"] = false
	p = goods.plan(poor, 5)
	_expect(p["kind"] == "refuse" and str(p["body"]).contains("Costs 10 diamonds, not 20, and you have 5"),
		"the sale's refusal reads: %s" % p.get("body", ""))
	var plain := refill.duplicate()
	plain.erase("regular_diamonds")
	plain["diamonds"] = 20
	_expect(goods.on_sale(plain) == 0 and str(goods.plan(plain, 127)["body"]).ends_with("20 diamonds. You have 127."),
		"with no sale on the refill still says a sale")

	# The Shop tab's faces.
	var vp := SubViewport.new()
	vp.size = Vector2i(941, 1672)
	root.add_child(vp)
	root.get_node("Nav").set("host", vp)
	root.get_node("GameState").call("adopt", {"player": {"level": 30, "gold": "1", "diamonds": 3, "action_seq": 1}, "jobs": [], "energy": {}})
	var tab: Control = shop.new()
	tab.size = Vector2(941, 1672)
	vp.add_child(tab)
	await process_frame
	var ui: Dictionary = tab.get("_ui")
	var button: TextureButton = ui["reroll"]
	var cost: Label = ui["reroll_cost"]
	var home := Rect2(cost.position, cost.size)
	tab.set("_store", {"goods": [refill], "flasks": []})
	tab.set("_shop", {"reroll_cost": 14, "can_afford_reroll": false, "rerolls_left": 0, "rerolls_per_day": 20,
		"free_rerolls": 1, "free_ends_in": 3000, "seconds_left": 200, "offers": []})
	tab.call("_paint")
	_expect(button.texture_normal.resource_path.ends_with("shop/reroll_button_free.png") and cost.text == "FREE"
		and button.modulate == Color.WHITE, "Fresh Wares: the button wears %s, says %s" % [button.texture_normal.resource_path, cost.text])
	_expect(absf(cost.position.x + cost.size.x / 2.0 - TITLE_MID) <= 1.0 and cost.horizontal_alignment == HORIZONTAL_ALIGNMENT_CENTER,
		"FREE is centred at %.1f, not under the title at %.1f" % [cost.position.x + cost.size.x / 2.0, TITLE_MID])
	var f := cost.label_settings.font
	_expect(f.get_string_size("FREE", HORIZONTAL_ALIGNMENT_LEFT, -1, cost.label_settings.font_size).x <= cost.size.x,
		"FREE does not fit its box")
	# The refill on sale: the old price struck through after the sale's.
	var dp: Dictionary = ui["diamond_panel"].get_meta("parts")
	var price: Label = dp["energy_price"]
	var was: Label = tab.get("_refill_was")
	_expect(price.text == "10" and was != null and was.visible and was.text == "20", "the sale's card reads %s, was %s" % [price.text, was.text if was != null else "-"])
	if was != null:
		var w_price := price.label_settings.font.get_string_size(price.text, HORIZONTAL_ALIGNMENT_LEFT, -1, price.label_settings.font_size).x
		_expect(was.position.x >= price.position.x + w_price and was.position.x + was.size.x <= BUY_X - 2.0,
			"the old price (x %.0f..%.0f) is not after the sale's (ending %.0f) and before BUY" % [was.position.x, was.position.x + was.size.x, price.position.x + w_price])
		var strike: ColorRect = was.get_node("strike")
		_expect(strike.size.x >= was.size.x - 2.0 and strike.position.y > 6.0 and strike.position.y < was.size.y - 6.0,
			"the old price is not struck through its middle (%s in %s)" % [Rect2(strike.position, strike.size), was.size])
	# The hour over: the painted face, the price where it was, no old price.
	refill.erase("regular_diamonds")
	refill["diamonds"] = 20
	tab.set("_store", {"goods": [refill], "flasks": []})
	tab.set("_shop", {"reroll_cost": 14, "can_afford_reroll": true, "rerolls_left": 5, "rerolls_per_day": 20,
		"free_rerolls": 0, "seconds_left": 200, "offers": []})
	tab.call("_paint")
	_expect(button.texture_normal.resource_path.ends_with("shop/reroll_button.png") and cost.text == "14"
		and Rect2(cost.position, cost.size).is_equal_approx(home) and cost.horizontal_alignment == HORIZONTAL_ALIGNMENT_LEFT,
		"after the hour the button says %s at %s" % [cost.text, Rect2(cost.position, cost.size)])
	_expect(was != null and not was.visible and price.text == "20", "with no sale on the card still strikes a price")
	vp.queue_free()
	await process_frame
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d checks: Fresh Wares rerolls for FREE on its own face; the sale says the price it had, struck through on the card" % _checked)
	quit()


func _expect(ok: bool, why: String) -> void:
	_checked += 1
	if not ok:
		_fails += 1
		print("  FAIL  " + why)
