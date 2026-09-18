class_name Armory
extends RefCounted
## MORE ROOM: a full armory's honest second answer, beside "sell something".
##
## The bag holds `cap` pieces (GET /v1/inventory). When it is full the server
## refuses whatever would add one -- a shop buy, a reroll, a letter's gear --
## with 409 inventory_full, and the player was told to sell something and
## nothing else. The Quartermaster (a Comfort in the Royal Store, +50 slots for
## good) is the other way out, so where the bag is shown full and wherever the
## refusal is said, MORE ROOM is offered too, and leads to the Store's Comforts.
##
## Only while it can be bought: once owned the cap already counts its slots,
## and nothing is offered. Whether it is owned is the Store's answer (GET
## /v1/store/court, the product "quartermaster"), asked when a full bag first
## needs it and kept for a minute; the Store view tells it fresh on every paint.

const PRODUCT := "quartermaster"
## The Store's section MORE ROOM opens at.
const SECTION := "comfort"
const FRESH_MS := 60000

static var _store: Dictionary = {}
static var _store_ms := -1000000


## The Store's answer, from the Store view as it paints or from a fetch here.
static func learn(store: Dictionary) -> void:
	_store = store
	_store_ms = Time.get_ticks_msec()


## Forgets the Store's answer (a purchase landed; a test starts clean).
static func forget() -> void:
	_store = {}
	_store_ms = -1000000


## Asks the Store, unless its answer is under a minute old.
static func ask() -> void:
	if Time.get_ticks_msec() - _store_ms < FRESH_MS and not _store.is_empty():
		return
	var res: Api.Response = await Api.get_json("/v1/store/court")
	if res.ok:
		learn(res.data)


## The Quartermaster as the Store lists it, or {} while it is not known.
static func quartermaster() -> Dictionary:
	for p in _store.get("products", []):
		if str(p.get("id", "")) == PRODUCT:
			return p
	return {}


## Whether MORE ROOM may be offered: the Store lists the Quartermaster, it is
## not owned, and it can be bought now.
static func can_offer() -> bool:
	var p := quartermaster()
	return not p.is_empty() and not bool(p.get("owned", false)) and bool(p.get("available", true))


## Whether a bag at this inventory view is full ({used, cap}).
static func is_full(inventory: Dictionary) -> bool:
	var cap := int(inventory.get("cap", 0))
	return cap > 0 and int(inventory.get("used", 0)) >= cap


## What the Quartermaster brings, in the Store's own words ("+50 bag slots,
## for good"), for a sentence that offers it.
static func brings() -> String:
	var lines: Array = quartermaster().get("lines", [])
	return str(lines[0].get("text", "")) if not lines.is_empty() else ""


## The refusal said: a dialog with OK and, while the Quartermaster can be
## bought, MORE ROOM beside it. `body` is what the screen has to say (a
## letter's gear waits); the server's message when empty.
static func refused(host: Node, message: String, body: String = "") -> void:
	await ask()
	if not is_instance_valid(host) or not host.is_inside_tree():
		return
	var words := body if body != "" else sentence(message) + " Sell or wear something to make room."
	if not can_offer():
		await Dialog.ask(host, {"title": "No room in the armory", "body": words, "confirm_text": "OK"})
		return
	var more := brings()
	if more != "":
		words += "\n\nThe Quartermaster: %s." % more
	if await Dialog.ask(host, {"title": "No room in the armory", "body": words,
			"confirm_text": "MORE ROOM", "cancel_text": "OK"}):
		open_store(host)


## The Royal Store, at its Comforts. `from` is any node of the game's screen:
## the shell above it opens the Store.
static func open_store(from: Node) -> Control:
	var shell := _shell(from)
	if shell == null:
		return null
	var view: Control = shell.call("open_view", "store")
	if view != null and view.has_method("open_at"):
		view.call("open_at", SECTION)
	return view


static func _shell(from: Node) -> Node:
	var n := from
	while n != null:
		if n.has_method("open_view"):
			return n
		n = n.get_parent()
	var cs := from.get_tree().current_scene if from != null and from.is_inside_tree() else null
	return cs if cs != null and cs.has_method("open_view") else null


## "your armory is full — sell something first" -> "Your armory is full."
static func sentence(message: String) -> String:
	var s := message.strip_edges()
	var cut := s.find(" — ")
	if cut > 0:
		s = s.left(cut)
	if s == "":
		s = "your armory is full"
	return s.left(1).to_upper() + s.substr(1) + ("" if s.ends_with(".") else ".")
