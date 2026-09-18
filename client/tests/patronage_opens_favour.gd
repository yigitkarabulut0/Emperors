extends SceneTree
## Crown Patronage is sold in one place: THE CROWN'S FAVOUR.
##
## App Review 3.1.2 asks a subscription offer to show its title, its length, its
## price, that it renews by itself until cancelled, and the Terms and the
## Privacy Policy, where it is bought. The store's patronage plate called
## Billing.buy straight from a card that carries none of that. It opens the
## Favour page now, which carries all of it beside SUBSCRIBE; the plate still
## says its price a month.
##
## A StoreKit stand-in that records purchases proves the plate buys nothing,
## and the shell is asked what it opened.
##
## Run: godot --headless --path client --script tests/patronage_opens_favour.gd

var _fails := 0


class FakeProduct extends Object:
	var product_id := ""
	var display_price := ""

	func _init(id: String, price: String) -> void:
		product_id = id
		display_price = price


class FakeKit extends Object:
	signal products_request_completed(products: Array, status: int)
	signal purchase_completed(transaction: Object, status: int, error_message: String)
	signal transaction_updated(transaction: Object)
	signal unverified_transaction_updated(transaction: Object, verification_error: int)
	signal restore_completed(status: int, error_message: String)
	var purchases: Array = []
	func start() -> void: pass
	func request_products(_ids: PackedStringArray) -> void: pass
	func purchase_with_options(p: Object, _o: Array) -> void: purchases.append(p)
	func restore_purchases() -> void: pass
	func fetch_current_entitlements() -> void: pass
	func fetch_unfinished_transactions() -> void: pass


func _initialize() -> void:
	await process_frame
	# The boot scene runs beside this test, and when it decides where to send the
	# player it calls Nav.go -- which frees every overlay layer, the painted page
	# opened below among them. Pointed at a dead port it stays on its own screen,
	# and THE CROWN'S FAVOUR outlives the frame it opened on. (painted_pages.gd
	# does the same, for the same reason.)
	root.get_node("Env").set("api_base_url", "http://127.0.0.1:9")
	for i in 8:
		await process_frame
	root.get_node("GameState").set("snapshot", {"player": {"username": "Wwwwwwwwwwwwwwww", "level": 30, "gold": "1",
		"diamonds": 12, "action_seq": 1}, "energy": {"current": 1, "max": 2}, "sections": []})
	var billing: Node = root.get_node("Billing")
	var kit := FakeKit.new()
	billing.call("use_kit", kit)
	var sid := "com.emperors.game.patronage.month"
	kit.products_request_completed.emit([FakeProduct.new(sid, "₺279,99")], 0)

	var parent := Control.new()
	parent.size = Vector2(941, 1672)
	root.add_child(parent)
	var shell: Control = (load("res://scenes/shell/shell.tscn") as PackedScene).instantiate()
	parent.add_child(shell)
	shell.set_anchors_preset(Control.PRESET_FULL_RECT)
	for i in 4:
		await process_frame
	var view: Control = shell.call("open_view", "store", {"products": [
		{"id": "patronage", "store_id": sid, "kind": "subscription", "shelf": "passes", "title": "Crown Patronage",
			"available": true, "usd_cents": 699, "lines": [
				{"kind": "diamonds", "amount": 60, "text": "60 diamonds each month", "icon": "diamond"},
				{"kind": "patronage", "amount": 1, "text": "1 free energy refill each day", "icon": "energy_potion"}]}],
		"patronage": {"active": false, "seconds": 0}, "stipend": {}, "deals": {}, "herald": {"enabled": false}})
	for i in 3:
		await process_frame
	var plate: BaseButton = null
	var price: Label = null
	for e in view.get("_buys"):
		if str((e["product"] as Dictionary).get("kind", "")) == "subscription":
			plate = e["button"]
			price = e["label"]
	if plate == null:
		print("FAIL  the store shows no patronage plate")
		quit(1)
		return
	_expect(price.text == "₺279,99 a month", "the patronage plate says \"%s\", not its price a month" % price.text)

	plate.pressed.emit()
	for i in 3:
		await process_frame
	_expect(kit.purchases.is_empty() and not bool(billing.get("busy")), "the patronage plate bought through StoreKit")
	var page := _favour(root)
	_expect(page != null, "the patronage plate did not open THE CROWN'S FAVOUR")
	if page != null:
		page.call("close")
		for i in 4:
			await process_frame

	# A tap on the card opens it too.
	var perks: BaseButton = _find_hit(view, "perks_hit")
	_expect(perks != null, "the patronage card has no tap")
	if perks != null:
		perks.pressed.emit()
		for i in 3:
			await process_frame
		_expect(_favour(root) != null, "a tap on the patronage card did not open THE CROWN'S FAVOUR")
	_expect(kit.purchases.is_empty(), "the patronage card bought through StoreKit")

	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  the patronage plate and card open THE CROWN'S FAVOUR and buy nothing themselves")
	quit()


## The open Favour page (its view is named FavourView on the page), or null.
func _favour(n: Node) -> Node:
	for c in n.get_children():
		if c.name == "FavourView" and not c.is_queued_for_deletion():
			return c.get_parent()
		var f := _favour(c)
		if f != null:
			return f
	return null


## The patronage card's tap: the one hotspot the layout names perks_hit.
func _find_hit(view: Node, id: String) -> BaseButton:
	var spec: Dictionary = (load("res://scripts/ui/layout.gd") as GDScript).call("find", "store", id)
	var r: Array = spec.get("rect", [0, 0, 0, 0])
	var stack: Array = [view]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if n is Button and (n as Button).flat and (n as Button).size == Vector2(float(r[2]), float(r[3])) \
				and (n as Button).position == Vector2(float(r[0]), float(r[1])):
			return n
	return null


func _expect(ok: bool, why: String) -> void:
	if not ok:
		_fails += 1
		printerr("  ", why)
