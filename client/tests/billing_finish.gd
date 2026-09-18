extends SceneTree
## A purchase is finished only once the server has it, and never lost.
##
## StoreKit keeps handing back a transaction until the app finishes it, and the
## server delivers each transaction once, so the only mistake that loses money
## is finishing one the server never received. These cases drive Billing with a
## stand-in for StoreKitManager and a stand-in server:
##
## - delivered: finished, and the Royal Delivery is shown;
## - the server unreachable, or a 5xx, or a product the catalogue does not know
##   yet: kept, the player told it is safe, and sent again when the network
##   returns;
## - refused for good (a forgery, another app's, a buyer gone): finished;
## - Ask to Buy: nothing finished, the player told it waits for approval;
## - a player's own cancel: silent;
## - a renewal or an old purchase handed back at start: finished, no ceremony;
## - another lord's purchase sent from this session: finished, not adopted;
## - a restore gathers what StoreKit hands back and sends it in one list.
##
## Run: godot --headless --path client --script tests/billing_finish.gd

var _fails := 0
var _checked := 0


class FakeTxn extends Object:
	var jws_representation := ""
	var product_id := ""
	var transaction_id := 0
	var finished := 0

	func _init(id: int, product: String) -> void:
		transaction_id = id
		product_id = product
		jws_representation = "jws-%d" % id

	func finish() -> void:
		finished += 1


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
	var calls: Array = []

	func start() -> void: calls.append("start")
	func request_products(ids: PackedStringArray) -> void: calls.append("request_products")
	func purchase_with_options(product: Object, options: Array) -> void: calls.append("purchase:" + str(product.get("product_id")))
	func restore_purchases() -> void: calls.append("restore")
	func fetch_current_entitlements() -> void: calls.append("entitlements")
	func fetch_unfinished_transactions() -> void: calls.append("unfinished")


## The stand-in server: answers from a queue, recording what it was sent. A
## --script test cannot name an autoload, so Api's Response class is reached
## through its script.
var _answers: Array = []
var _sent: Array = []
var _response: GDScript


func _serve(jws: String):
	_sent.append(jws)
	await process_frame
	return _answers.pop_front()


func _ok(data: Dictionary):
	return _response.new(true, 200, data, "", "")


func _no(status: int, code: String):
	return _response.new(false, status, {}, code, "refused")


func _initialize() -> void:
	await process_frame
	_response = (load("res://scripts/autoload/api.gd") as GDScript).Response
	_verdicts()

	var session: Node = root.get_node("Session")
	session.set("refresh_token", "test")
	session.set("access_token", "test")
	session.set("player_id", "5f7c4f7a-8f0e-4b9a-9f7e-2b1c3d4e5f60")

	var billing: Node = (load("res://scripts/autoload/billing.gd") as GDScript).new()
	root.add_child(billing)
	var kit := FakeKit.new()
	billing.call("use_kit", kit)
	billing.set("sender", _serve)
	_expect(billing.get("available") == true, "a kit makes purchases available")
	_expect(kit.calls.has("start"), "StoreKit was not started for a signed-in lord")

	var got := {"delivered": [], "failed": [], "pending": []}
	billing.connect("delivered", func(d: Dictionary) -> void: got["delivered"].append(d))
	billing.connect("failed", func(id: String, m: String) -> void: got["failed"].append(m))
	billing.connect("pending", func(id: String) -> void: got["pending"].append(id))

	kit.products_request_completed.emit([FakeProduct.new("com.emperors.game.gems.60", "₺39,99")], 0)
	_checked += 1
	_expect(billing.call("price", "com.emperors.game.gems.60") == "₺39,99", "the App Store's own price is not shown")

	# 1. Delivered: finished, and the ceremony shown.
	var t1 := FakeTxn.new(1, "com.emperors.game.gems.60")
	_answers = [_ok({"transaction_id": "1", "lines": [{"kind": "diamonds", "amount": 120, "text": "120 diamonds"}]})]
	billing.call("buy", "com.emperors.game.gems.60")
	_expect(billing.get("busy") == true, "a purchase in flight does not hold the buttons")
	_expect(kit.calls.has("purchase:com.emperors.game.gems.60"), "the purchase never reached StoreKit")
	kit.purchase_completed.emit(t1, 0, "")
	await _settle()
	_checked += 1
	_expect(t1.finished == 1, "a delivered purchase was finished %d times, want 1" % t1.finished)
	_expect(got["delivered"].size() == 1, "the Royal Delivery was not shown")
	_expect(billing.get("busy") == false, "the buttons stayed held after the delivery")

	# 2. The server unreachable: kept, the player told it is safe, sent again later.
	var t2 := FakeTxn.new(2, "com.emperors.game.gems.60")
	_answers = [_response.new(false, 0, {}, "", "Cannot reach the server")]
	billing.call("buy", "com.emperors.game.gems.60")
	kit.purchase_completed.emit(t2, 0, "")
	await _settle()
	_checked += 1
	_expect(t2.finished == 0, "a purchase the server never received was finished")
	_expect(got["failed"].size() == 1 and str(got["failed"][0]).contains("safe"), "the player was not told the purchase is safe: %s" % [got["failed"]])
	_answers = [_ok({"transaction_id": "2", "lines": []})]
	root.get_node("Api").emit_signal("online")
	await _settle()
	_expect(t2.finished == 1, "the kept purchase was not sent again when the network returned")

	# 3. A 5xx and a product the catalogue does not know yet: kept.
	for answer in [_no(503, "iap_unavailable"), _no(500, "internal"), _no(409, "unknown_product")]:
		var t := FakeTxn.new(10 + _checked, "com.emperors.game.gems.60")
		_answers = [answer]
		kit.transaction_updated.emit(t)
		await _settle()
		_checked += 1
		_expect(t.finished == 0, "a transaction answered %d %s was finished" % [answer.status, answer.code])

	# 4. Refused for good: finished, so StoreKit stops handing it back.
	for code in ["iap_invalid", "iap_wrong_app", "owned_by_another_account"]:
		var t := FakeTxn.new(20 + _checked, "com.emperors.game.gems.60")
		_answers = [_no(400 if code != "owned_by_another_account" else 409, code)]
		kit.unverified_transaction_updated.emit(t, 1)
		await _settle()
		_checked += 1
		_expect(t.finished == 1, "a transaction refused for good (%s) was left unfinished" % code)

	# 5. Ask to Buy, and a player's own cancel.
	var failed_before: int = got["failed"].size()
	billing.call("buy", "com.emperors.game.gems.60")
	kit.purchase_completed.emit(null, 5, "Purchase pending")
	await _settle()
	_checked += 1
	_expect(got["pending"].size() == 1, "Ask to Buy did not say it waits for approval")
	_expect(billing.get("busy") == false, "the buttons stayed held while waiting for approval")
	billing.call("buy", "com.emperors.game.gems.60")
	kit.purchase_completed.emit(null, 4, "User cancelled")
	await _settle()
	_expect(got["failed"].size() == failed_before, "a player's own cancel was reported as a failure")
	_expect(billing.get("busy") == false, "the buttons stayed held after a cancel")

	# 6. A renewal handed back at start: finished, no ceremony for what was delivered before.
	var shown: int = got["delivered"].size()
	var t6 := FakeTxn.new(60, "com.emperors.game.patronage.month")
	_answers = [_ok({"already": true, "lines": []})]
	kit.transaction_updated.emit(t6)
	await _settle()
	_checked += 1
	_expect(t6.finished == 1, "a purchase delivered before was left unfinished")
	_expect(got["delivered"].size() == shown, "a purchase delivered before was celebrated again")

	# 7. Another lord's purchase, from this session: finished, and nothing shown here.
	var t7 := FakeTxn.new(70, "com.emperors.game.gems.60")
	_answers = [_ok({"for_another": true, "lines": [], "snapshot": {"player": {"id": "someone-else"}}})]
	billing.call("buy", "com.emperors.game.gems.60")
	kit.purchase_completed.emit(t7, 0, "")
	await _settle()
	_checked += 1
	_expect(t7.finished == 1, "a purchase delivered to its buyer elsewhere was left unfinished")
	_expect(got["delivered"].size() == shown, "another lord's purchase was celebrated here")
	var gs: Node = root.get_node("GameState")
	var snap: Dictionary = gs.get("snapshot")
	_expect(str(snap.get("player", {}).get("id", "")) != "someone-else", "another lord's snapshot was adopted as ours")

	# 8. A restore gathers what StoreKit hands back, and sends it in one list.
	var lists: Array = []
	billing.set("restorer", func(list: Array[String]):
		lists.append(list.duplicate())
		await process_frame
		return _ok({"restored": [{}, {}], "refused": []}))
	var restored := []
	billing.connect("restored", func(r: Dictionary) -> void: restored.append(r))
	billing.call("restore")
	kit.restore_completed.emit(0, "")
	_expect(kit.calls.has("entitlements"), "a restore did not ask for the current entitlements")
	kit.transaction_updated.emit(FakeTxn.new(80, "com.emperors.game.comfort.steward"))
	kit.transaction_updated.emit(FakeTxn.new(81, "com.emperors.game.comfort.quartermaster"))
	await create_timer(1.6).timeout
	await _settle()
	_checked += 1
	_expect(lists.size() == 1 and (lists[0] as Array).size() == 2, "the restore sent %s, want one list of two" % [lists])
	_expect(restored.size() == 1, "the restore's result was not reported")
	_expect(billing.get("busy") == false, "the buttons stayed held after the restore")

	# 9. Without StoreKit (desktop, the editor): nothing pretends to work.
	var bare: Node = (load("res://scripts/autoload/billing.gd") as GDScript).new()
	root.add_child(bare)
	var said := []
	bare.connect("failed", func(id: String, m: String) -> void: said.append(m))
	bare.call("buy", "com.emperors.game.gems.60")
	_checked += 1
	_expect(bare.get("available") == false and said.size() == 1, "a phone without StoreKit offered a purchase")

	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d billing cases finish only what the server holds" % _checked)
	quit()


## The rule itself, answer by answer.
func _verdicts() -> void:
	var b: GDScript = load("res://scripts/autoload/billing.gd")
	for c in [
		[true, 200, "", "finish"],
		[false, 400, "iap_invalid", "finish"],
		[false, 400, "iap_wrong_app", "finish"],
		[false, 409, "owned_by_another_account", "finish"],
		[false, 409, "unknown_product", "keep"],
		[false, 503, "iap_unavailable", "keep"],
		[false, 500, "internal", "keep"],
		[false, 401, "unauthorized", "keep"],
		[false, 0, "", "keep"],
		[false, 0, "transport_predelivery", "keep"],
	]:
		_checked += 1
		var v: String = b.verdict(c[0], c[1], c[2])
		_expect(v == c[3], "an answer %d %s says %s, want %s" % [c[1], c[2], v, c[3]])


func _settle() -> void:
	for i in 6:
		await process_frame


func _expect(ok: bool, why: String) -> void:
	if not ok:
		_fails += 1
		printerr("  ", why)
