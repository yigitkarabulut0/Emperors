extends Node
## Billing -- App Store purchases, through StoreKit 2 (GodotApplePlugins'
## StoreKitManager).
##
## One rule above the rest: a transaction is finished only after the server has
## answered 2xx for it, or has said it can never deliver it to anyone. The
## server delivers each transaction exactly once (its unique transaction id), so
## sending one twice is harmless; finishing one the server never saw loses what
## the player paid for. Until then StoreKit keeps handing it back -- at start,
## when the app returns to the front, when the network comes back -- and each
## time it is sent again.
##
## What the server answers is what was delivered, with the confirmed snapshot,
## adopted through GameState.adopt_async. No action_seq: money arrives on the
## App Store's schedule, and a purchase must never move the sequence queued
## collects count on.
##
## Where StoreKit is missing -- desktop, the editor, headless tests -- `available`
## is false and the store says so, instead of offering a button that cannot
## work. The plugin's classes are reached through ClassDB, never by name, so
## this script compiles without the plugin (the client lint compiles it).

## Prices arrived, or changed.
signal products_changed
## A purchase reached a lord: the store shows the Royal Delivery. `delivery` is
## the server's (service.Delivery), snapshot included.
signal delivered(delivery: Dictionary)
## Ask to Buy: the purchase waits for a parent's approval, and will arrive by
## itself once it is given.
signal pending(store_id: String)
## A purchase that did not go through, in words to show. A player's own cancel
## is not a failure and says nothing.
signal failed(store_id: String, message: String)
## A purchase or a restore started or ended: the store dims its buttons.
signal busy_changed(busy: bool)
## A restore finished: {restored: [Delivery], refused: [...]}.
signal restored(result: Dictionary)

## StoreKitStatus, as StoreKitManager emits it.
const OK := 0
const INVALID_PRODUCT := 1
const CANCELLED := 2
const UNVERIFIED := 3
const USER_CANCELLED := 4
const PURCHASE_PENDING := 5
const UNKNOWN_STATUS := 6

## Server codes that mean it will never deliver this transaction to anyone: a
## forgery, another app's purchase, or a buyer whose account is gone. The phone
## finishes these so StoreKit stops handing them back. Everything else -- no
## network, a 5xx, a product the live catalogue does not know yet, no session --
## keeps the transaction for the next try.
const FINAL_CODES := ["iap_invalid", "iap_wrong_app", "owned_by_another_account"]

## How long a restore listens for the entitlements StoreKit hands back, which
## come one by one with no end marker: this long after the last, or at most the
## cap after the App Store answered.
const RESTORE_QUIET := 0.8
const RESTORE_CAP := 4.0

## Said where StoreKit is missing: on a computer, where there is no App Store
## to buy through, and on a phone whose build does not carry the plugin yet.
const NOT_HERE := "Purchases are made through the App Store, on an iPhone."
const NOT_IN_BUILD := "Purchases are not open in this build of the game yet."
const KEPT := "Your purchase is safe with the App Store. It will arrive as soon as the connection returns."

var available := false
var busy := false
## Send one signed transaction, and a restore's list, and return the server's
## answer. Seams for tests; the game posts to /v1/iap/apple/verify and /restore.
var sender: Callable
var restorer: Callable

var _kit: Object = null
var _products := {}          ## store id -> StoreProduct
var _buying := ""            ## the store id of the purchase in flight
var _sending := {}           ## transaction id -> true while its JWS is out
var _waiting: Array = []     ## transactions kept for the next try
var _started := false
var _restoring := false
var _restore_jws: Array[String] = []
var _restore_timer: SceneTreeTimer = null


## Why purchases are not open here, in words to show.
static func unavailable_reason() -> String:
	return NOT_IN_BUILD if OS.has_feature("ios") else NOT_HERE


func _init() -> void:
	sender = _post_verify
	restorer = _post_restore


func _ready() -> void:
	if not ClassDB.class_exists("StoreKitManager"):
		return
	use_kit(ClassDB.instantiate("StoreKitManager"))


## Takes a StoreKitManager (or a test's stand-in with the same signals and
## methods), and starts it once a lord is signed in: what StoreKit hands back
## at start is sent under that lord's session.
func use_kit(kit: Object) -> void:
	_kit = kit
	available = kit != null
	if kit == null:
		return
	kit.connect("products_request_completed", _on_products)
	kit.connect("purchase_completed", _on_purchase_completed)
	kit.connect("transaction_updated", _on_transaction)
	kit.connect("unverified_transaction_updated", _on_unverified)
	kit.connect("restore_completed", _on_restore_completed)
	if not Session.signed_in.is_connected(_start):
		Session.signed_in.connect(_start)
	if not Api.online.is_connected(_retry):
		Api.online.connect(_retry)
	if Session.is_signed_in():
		_start()


func _start() -> void:
	if _kit == null:
		return
	if _started:
		# Another lord signed in: hand back what is unfinished under their session.
		_kit.call("fetch_unfinished_transactions")
		return
	_started = true
	_kit.call("start")


func _notification(what: int) -> void:
	# Back at the front: a purchase approved, or made on another device, while
	# the game was away is waiting.
	if what == NOTIFICATION_APPLICATION_RESUMED and _kit != null and _started:
		_kit.call("fetch_unfinished_transactions")


# --- products ---------------------------------------------------------------------

## Asks the App Store for these products' prices, in the player's own currency.
func load_products(store_ids: PackedStringArray) -> void:
	if _kit == null or store_ids.is_empty():
		return
	_kit.call("request_products", store_ids)


func _on_products(products: Array, status: int) -> void:
	if status != OK:
		return
	for p in products:
		if p != null:
			_products[str(p.get("product_id"))] = p
	products_changed.emit()


## The App Store's price for a product, "" until it is known. The only price the
## store ever shows: the balance's usd_cents is Royal Favour's arithmetic, not
## what the player pays in their own currency.
func price(store_id: String) -> String:
	var p: Object = _products.get(store_id)
	return str(p.get("display_price")) if p != null else ""


func has_product(store_id: String) -> bool:
	return _products.has(store_id)


# --- buying -----------------------------------------------------------------------

## Buys one product. The result arrives as `delivered`, `pending` or `failed`.
func buy(store_id: String) -> void:
	if busy:
		return
	if _kit == null:
		failed.emit(store_id, unavailable_reason())
		return
	if not Session.is_signed_in() or Session.player_id == "":
		failed.emit(store_id, "Sign in first: a purchase belongs to a lord.")
		return
	var product: Object = _products.get(store_id)
	if product == null:
		failed.emit(store_id, "The App Store has not told us this item's price yet. Try again in a moment.")
		load_products(PackedStringArray([store_id]))
		return
	_set_busy(true)
	_buying = store_id
	_kit.call("purchase_with_options", product, purchase_options(Session.player_id))


## The purchase names its lord: Apple signs the token into the transaction, and
## the server delivers to whoever it names, whichever session sends it. The
## plugin takes a typed array of its own option class, reached by name so this
## compiles without the plugin; without it (a test's stand-in) there is none.
static func purchase_options(player_id: String) -> Array:
	if not ClassDB.class_exists("StoreProductPurchaseOption"):
		return []
	var token: Object = ClassDB.class_call_static("StoreProductPurchaseOption", "app_account_token", player_id)
	return Array([token], TYPE_OBJECT, &"StoreProductPurchaseOption", null)


func _on_purchase_completed(transaction: Object, status: int, message: String) -> void:
	var id := _buying
	match status:
		OK:
			if transaction != null:
				await _deliver(transaction, true)
				return
		PURCHASE_PENDING:
			pending.emit(id)
		USER_CANCELLED:
			pass
		UNVERIFIED:
			# StoreKit keeps it unfinished and hands it back through
			# unverified_transaction_updated; the server has the last word then.
			failed.emit(id, "The App Store could not confirm this purchase. If you were charged, it will arrive by itself.")
		_:
			failed.emit(id, message if message != "" else "The App Store could not complete the purchase.")
	_buying = ""
	_set_busy(false)


func _on_transaction(transaction: Object) -> void:
	if _restoring:
		_collect_restore(transaction)
		return
	await _deliver(transaction, false)


## StoreKit could not verify it on the phone. It goes to the server all the
## same: a forgery is refused there and finished; anything the server can prove
## is delivered.
func _on_unverified(transaction: Object, _verification_error: int) -> void:
	if _restoring:
		return
	await _deliver(transaction, false)


## Sends one transaction and finishes it if the server's answer allows.
## `ours`: the purchase this phone just made, whose outcome the store waits for.
func _deliver(transaction: Object, ours: bool) -> void:
	var tid := str(transaction.get("transaction_id"))
	var store_id := str(transaction.get("product_id"))
	if _sending.has(tid):
		return
	_sending[tid] = true
	var res: Api.Response = await sender.call(str(transaction.get("jws_representation")))
	_sending.erase(tid)
	var v := verdict(res.ok, res.status, res.code)
	if v == "finish":
		transaction.call("finish")
		_waiting.erase(transaction)
	elif not _waiting.has(transaction):
		_waiting.append(transaction)

	if res.ok:
		var d: Dictionary = res.data
		var snap: Variant = d.get("snapshot", null)
		if snap is Dictionary and not (snap as Dictionary).is_empty() and not bool(d.get("for_another", false)):
			GameState.adopt_async(snap)
		if bool(d.get("for_another", false)):
			if ours:
				failed.emit(store_id, "This purchase was made by another of your lords, and has gone to them.")
		elif not bool(d.get("already", false)) or ours:
			delivered.emit(d)
	elif ours:
		failed.emit(store_id, KEPT if v == "keep" else _refusal(res))
	if ours:
		_buying = ""
		_set_busy(false)


## Whether a transaction may be finished, from the server's answer to it:
## "finish" once delivered or refused for good, "keep" for every other answer.
## Pure, so the rule is tested without StoreKit or a server.
static func verdict(ok: bool, status: int, code: String) -> String:
	if ok:
		return "finish"
	if status >= 400 and status < 500 and FINAL_CODES.has(code):
		return "finish"
	return "keep"


func _refusal(res: Api.Response) -> String:
	match res.code:
		"owned_by_another_account":
			return "This purchase belongs to another account, and cannot be delivered here."
		_:
			return "The App Store's purchase could not be accepted (%s)." % (res.code if res.code != "" else str(res.status))


## Sends what the last tries could not.
func _retry() -> void:
	if not Session.is_signed_in():
		return
	for t in _waiting.duplicate():
		await _deliver(t, false)


func _post_verify(jws: String) -> Api.Response:
	return await Api.post_json("/v1/iap/apple/verify", {"jws": jws})


func _post_restore(list: Array[String]) -> Api.Response:
	return await Api.post_json("/v1/iap/apple/restore", {"jws": list})


# --- restoring --------------------------------------------------------------------

## Brings back what this Apple ID owns (the Steward, the Quartermaster, a
## running patronage) onto the lord signed in. The result arrives as `restored`.
func restore() -> void:
	if busy:
		return
	if _kit == null:
		failed.emit("", unavailable_reason())
		return
	_set_busy(true)
	_restoring = true
	_restore_jws.clear()
	_kit.call("restore_purchases")


func _on_restore_completed(status: int, message: String) -> void:
	if not _restoring:
		return
	if status != OK:
		_restoring = false
		_set_busy(false)
		failed.emit("", message if message != "" else "The App Store could not restore your purchases.")
		return
	_kit.call("fetch_current_entitlements")
	_arm_restore(RESTORE_CAP)


func _collect_restore(transaction: Object) -> void:
	var jws := str(transaction.get("jws_representation"))
	if jws != "" and not _restore_jws.has(jws):
		_restore_jws.append(jws)
	_arm_restore(RESTORE_QUIET)


func _arm_restore(after: float) -> void:
	var t := get_tree().create_timer(after)
	_restore_timer = t
	await t.timeout
	if _restore_timer == t and _restoring:
		_send_restore()


func _send_restore() -> void:
	_restoring = false
	if _restore_jws.is_empty():
		_set_busy(false)
		restored.emit({"restored": [], "refused": []})
		return
	var res: Api.Response = await restorer.call(_restore_jws)
	_set_busy(false)
	if not res.ok:
		failed.emit("", "Your purchases could not be restored just now. " + res.error)
		return
	var snap: Variant = res.data.get("snapshot", null)
	if snap is Dictionary and not (snap as Dictionary).is_empty():
		GameState.adopt_async(snap)
	restored.emit(res.data)


func _set_busy(b: bool) -> void:
	if busy == b:
		return
	busy = b
	busy_changed.emit(b)
