extends SceneTree
## THE FORGE on the inventory card (scenes/tabs/inventory.gd) and THE TALENT
## TREE (scenes/pages/talents_page.gd).
##
## What must hold, on the card:
##  - SELL and FORGE stand side by side, each a thumb's 95 units, neither
##    sharing a pixel with the other or with EQUIP, and both inside the card;
##  - FORGE is lit only when the bag holds enough of that slot and rank, dim
##    when it does not, and gone on a piece at the top of the ladder;
##  - the client picks no pieces and prices nothing: the three ids and the fee
##    are the server's offer, printed as sent.
##
## And on the tree:
##  - every rank's worth is printed in its bucket's own units, from the
##    server's per_rank -- percentages as percentages, energy and minutes flat.
##
## The tree itself is the owner's painting now (art/reference/talents.png): its
## medallions, its rings and its ranks are held by tests/talents_tree.gd, and
## what a shut tier needs is said where the painting has room for it -- the
## dialog a tap opens.
##
## Run: godot --headless --path client --script tests/forge_and_talents.gd

const THUMB := 95.0

var _fails := 0
var _checked := 0


func _initialize() -> void:
	await process_frame
	root.get_node("Env").set("api_base_url", "http://127.0.0.1:9")
	_card_buttons_fit()
	_no_pricing()
	await _card_states()
	_worth_words()
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d checks: the anvil and the tree print the server's own numbers" % _checked)
	quit()


func _expect(ok: bool, what: String) -> void:
	_checked += 1
	if not ok:
		_fails += 1
		print("  FAIL  " + what)


func _card_buttons_fit() -> void:
	var LO: GDScript = load("res://scripts/ui/layout.gd")
	var card: Dictionary = LO.call("find", "inventory", "item_card")
	_expect(not card.is_empty(), "the inventory layout has no item card")
	var rects := {}
	for p in card.get("parts", []):
		var id := str((p as Dictionary).get("id", ""))
		if id in ["btn_equip", "btn_sell", "btn_forge"]:
			rects[id] = LO.call("rect_of", p)
	for id in ["btn_equip", "btn_sell", "btn_forge"]:
		_expect(rects.has(id), "the card has no %s" % id)
		if not rects.has(id):
			continue
		var r: Rect2 = rects[id]
		_expect(r.size.x >= THUMB and r.size.y >= THUMB,
			"%s takes a %.0fx%.0f tap" % [id, r.size.x, r.size.y])
		_expect(Rect2(LO.call("rect_of", card)).size.x >= r.position.x + r.size.x,
			"%s runs off the card" % id)
	var ids: Array = rects.keys()
	for i in ids.size():
		for j in range(i + 1, ids.size()):
			_expect(not (rects[ids[i]] as Rect2).intersects(rects[ids[j]] as Rect2),
				"%s and %s share pixels" % [ids[i], ids[j]])


## The client neither picks the three nor prices the work.
func _no_pricing() -> void:
	var src := FileAccess.get_file_as_string("res://scenes/tabs/inventory.gd")
	for word in ["fee_bp", "next_tier", "sell_ratio", "ForgeFee"]:
		_expect(not src.contains(word), "inventory.gd works out %s: the offer is the server's" % word)
	_expect(src.contains("o.get(\"items\", [])"), "inventory.gd does not send the server's own three ids")


func _item(id: String, tier: String, offer: Variant) -> Dictionary:
	var it := {"id": id, "def_id": "weapon_rare_01", "name": "Riverbend Leafblade", "slot": "weapon",
		"tier": tier, "art": "weapon_21", "ilvl": 24, "quality_pct": 100, "masterwork": false,
		"attack": 64, "defense": 12, "speed": 0, "power": 76, "sell_price": 300,
		"equipped": false, "equipped_on": ""}
	if offer is Dictionary:
		it["forge"] = offer
	return it


func _card_states() -> void:
	var host := Control.new()
	host.size = Vector2(941, 1672)
	root.add_child(host)
	var tab: Control = (load("res://scenes/tabs/inventory.gd") as GDScript).new()
	host.add_child(tab)
	for i in 3:
		await process_frame

	var ready_offer := {"items": ["a", "b", "c"], "tier": "epic", "ilvl": 24, "fee": 1593, "have": 4}
	var thin_offer := {"items": [], "tier": "epic", "ilvl": 0, "fee": 0, "have": 2}
	tab.set("_inventory", {"items": [_item("a", "rare", ready_offer), _item("b", "rare", thin_offer),
			_item("c", "special", null)],
		"equipped": {"weapon": null, "armor": null, "horse": null},
		"used": 3, "cap": 150, "hero": {"attack": 1, "defense": 1, "speed": 0, "might": 1},
		"forge": {"unlocked": true, "unlock_level": 12, "pieces": 3, "quality_min_pct": 95,
			"quality_max_pct": 105, "masterwork_chance_bp": 300, "tiers": ["rare"]}})
	tab.call("_paint")
	await process_frame

	# The grid sorts by rank and power, so the cards are found by the piece they
	# hold and never by the order they were handed over.
	var cards: Array = tab.get("_cards")
	_expect(cards.size() >= 3, "%d cards are built" % cards.size())
	var want := {"a": [true, true], "b": [true, false], "c": [false, false]}
	var seen := {}
	for card in cards:
		var c: Dictionary = card
		if not (c["node"] as CanvasItem).visible:
			continue
		var id := str((c.get("item", {}) as Dictionary).get("id", ""))
		if not want.has(id):
			continue
		seen[id] = true
		var b: BaseButton = c["parts"]["btn_forge"]
		var w: Array = want[id]
		_expect(b.visible == bool(w[0]), "%s: FORGE is %s" % [id, "shown" if b.visible else "hidden"])
		if bool(w[0]):
			_expect((b.modulate == Color.WHITE) == bool(w[1]),
				"%s: FORGE is %s" % [id, "lit" if b.modulate == Color.WHITE else "dim"])
	_expect(seen.size() == 3, "only %d of the three pieces were drawn" % seen.size())
	host.queue_free()
	await process_frame


## What a rank is worth, said in the bucket's own units.
func _worth_words() -> void:
	var P: GDScript = load("res://scenes/pages/talents_page.gd")
	var cases := [
		[{"bucket": "soldier_atk_bp", "per_rank": 150, "ranks": 4}, "+1.5%", "+6.0%"],
		[{"bucket": "max_energy_flat", "per_rank": 6, "ranks": 4}, "+6 max energy", "+24"],
		[{"bucket": "storehouse_minutes", "per_rank": 30, "ranks": 3}, "+30 minutes", "+90 minutes"],
	]
	for c in cases:
		var words: String = P.call("worth_words", (c as Array)[0])
		_expect(words.contains(str((c as Array)[1])) and words.contains(str((c as Array)[2])),
			"a rank of %s reads %s" % [((c as Array)[0] as Dictionary)["bucket"], words])
