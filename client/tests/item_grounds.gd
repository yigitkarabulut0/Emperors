extends SceneTree
## Every piece of gear sits on its rarity's velvet (ItemGround), on every
## surface an item is drawn: the Inventory's bag and equipped slots, the Family's
## and the Army's gear tiles, the Royal Market's cards, the gear picker, the
## Collection's frames and offers, the Royal Mail's rows and letter card, and the
## Royal Delivery. For each tier the ground is the tier's own cut, beneath the
## item (and under a rarity ring where one is drawn over it), inside the window,
## and never drawn up; a bare slot, an unheld frame, and a reward line that does
## not say its tier have no ground; an unknown tier in an item view gets common's.
##
## Run: godot --headless --path client --script tests/item_grounds.gd
##
## Every class is loaded at run time, never named: a class named in this script
## compiles before the autoloads exist.

const TIERS := ["common", "uncommon", "rare", "epic", "legendary", "mystic", "special"]
const ARTS := {"common": "horse_01", "uncommon": "armor_04", "rare": "weapon_07", "epic": "armor_10",
	"legendary": "armor_13", "mystic": "weapon_16", "special": "horse_19"}
const SLOT_OF := {"common": "horse", "uncommon": "armor", "rare": "weapon", "epic": "armor",
	"legendary": "armor", "mystic": "weapon", "special": "horse"}

var _fails := 0
var _checked := 0
var IG: GDScript


func _initialize() -> void:
	await process_frame
	if not ResourceLoader.exists("res://scripts/ui/item_ground.gd"):
		print("FAIL  there is no ItemGround: items are drawn on a bare tile")
		quit(1)
		return
	IG = load("res://scripts/ui/item_ground.gd")
	var gs: Node = root.get_node("GameState")
	gs.set("snapshot", {"player": {"username": "Wwwwwwwwwwwwwwww", "level": 60, "gold": "1", "diamonds": 12,
		"action_seq": 1, "avatar": "knight"}, "energy": {"current": 1, "max": 2}})
	_keys()
	await _inventory()
	await _family()
	await _army()
	await _shop()
	await _picker()
	await _collection()
	await _mail()
	await _delivery()
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d checks: every item on its rarity's velvet, on every surface" % _checked)
	quit()


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)


func _ok(cond: bool, msg: String) -> void:
	_checked += 1
	if not cond:
		_fail(msg)


func _item(tier: String, slot := "") -> Dictionary:
	var s := slot if slot != "" else str(SLOT_OF[tier])
	return {"id": "it_" + tier + "_" + s, "def_id": tier + "_def", "name": "A %s %s" % [tier, s], "tier": tier,
		"slot": s, "art": ARTS[tier], "ilvl": 60, "attack": 900, "defense": 800, "speed": 70, "power": 1234}


func _host(canvas := Vector2i(941, 1672)) -> SubViewport:
	var vp := SubViewport.new()
	vp.size = canvas
	root.add_child(vp)
	root.get_node("Nav").set("host", vp)
	return vp


## The checks one ground must pass. `window` is in the painting's parent's
## coordinates; `beneath` is a node the ground must be under (a rarity ring).
func _check(pic: Control, tier: String, soft: bool, window: Rect2, what: String, beneath: Control = null) -> void:
	var g: TextureRect = pic.get_meta("ground_node") if pic.has_meta("ground_node") else null
	if tier == "":
		_ok(g == null or not g.visible, "%s: a bare slot has no ground" % what)
		return
	_ok(g != null and is_instance_valid(g), "%s: the %s piece has no ground" % [what, tier])
	if g == null:
		return
	_ok(g.visible, "%s: the %s ground is hidden" % [what, tier])
	_ok(str(g.get_meta("item_ground", "")) == tier, "%s: the ground says %s, not %s" % [what, g.get_meta("item_ground", ""), tier])
	var want := ("items/glow_" if soft else "items/ground_") + tier
	var path := g.texture.resource_path if g.texture != null else ""
	_ok(path.contains(want), "%s: the %s ground is %s, want %s" % [what, tier, path, want])
	_ok(g.get_parent() == pic.get_parent() and g.get_index() < pic.get_index(),
		"%s: the %s ground is not beneath its item" % [what, tier])
	if beneath != null:
		_ok(g.get_index() < beneath.get_index(), "%s: the %s ground is over the rarity ring" % [what, tier])
	var r := Rect2(g.position, g.size)
	_ok(window.grow(0.5).encloses(r), "%s: the %s ground %s leaves its window %s" % [what, tier, r, window])
	if g.texture != null:
		var ts := g.texture.get_size()
		_ok(r.size.x <= ts.x + 0.5 and r.size.y <= ts.y + 0.5,
			"%s: the %s ground is drawn up (%s from %s)" % [what, tier, r.size, ts])


func _keys() -> void:
	_ok(str(IG.call("key", "legendary")) == "items/ground_legendary", "legendary's ground key")
	_ok(str(IG.call("key", "dragonforged")) == "items/ground_common", "an unknown tier gets common's cloth")
	_ok(str(IG.call("key", "mystic", true)) == "items/glow_mystic", "mystic's soft key")
	for t in TIERS:
		for soft in [false, true]:
			var tex: Texture2D = IG.call("texture", t, soft)
			_ok(tex != null and tex.get_size() == Vector2(256, 256), "%s's %s cut is 256 square" % [t, "soft" if soft else "full"])


func _inventory() -> void:
	var vp := _host()
	var tab: Control = (load("res://scenes/tabs/inventory.gd") as GDScript).new()
	tab.size = Vector2(941, 1672)
	vp.add_child(tab)
	await process_frame
	var items: Array = []
	for t in TIERS:
		items.append(_item(t))
	tab.set("_inventory", {"used": items.size(), "cap": 150, "items": items,
		"equipped": {"weapon": _item("special", "weapon"), "armor": _item("legendary", "armor")}})
	tab.call("_paint")
	await process_frame
	var cards: Array = tab.get("_cards")
	var seen := {}
	for c in cards:
		if not c["node"].visible or not c.has("item"):
			continue
		var tier := str(c["item"].get("tier", ""))
		var frame: Control = c["frame"]
		_check(c["parts"]["painting"], tier, false, Rect2(frame.position, frame.size), "the bag's %s card" % tier, frame)
		seen[tier] = true
	_ok(seen.size() == TIERS.size(), "the bag shows all seven tiers (%d)" % seen.size())
	var eq: Array = tab.get("_equipped")
	var want := ["special", "legendary", ""]
	for i in eq.size():
		var p: Dictionary = eq[i]["parts"]
		var tile: Control = p["tile"]
		_check(p["painting"], want[i], false, Rect2(tile.position, tile.size), "the equipped %s slot" % ["weapon", "armor", "horse"][i])
		_ring(p["painting"], "family/gear_tile_ring", "the equipped slot")
	vp.queue_free()


func _ring(pic: Control, asset: String, what: String) -> void:
	var r: TextureRect = pic.get_meta("ring_node") if pic.has_meta("ring_node") else null
	_ok(r != null and r.texture != null and r.texture.resource_path.contains(asset), "%s: no %s over the item" % [what, asset])
	if r != null:
		_ok(r.get_index() > pic.get_index(), "%s: the ring is under the item" % what)


func _family() -> void:
	var vp := _host()
	var tab: Control = (load("res://scenes/tabs/family.gd") as GDScript).new()
	tab.size = Vector2(941, 1672)
	vp.add_child(tab)
	await process_frame
	tab.set("_inventory", {"hero": {"attack": 1, "defense": 1, "power": 1}, "items": [],
		"equipped": {"weapon": _item("mystic", "weapon"), "horse": _item("common", "horse")}})
	tab.call("_paint_gear")
	await process_frame
	var want := {"weapon": "mystic", "armor": "", "horse": "common"}
	for slot in ["weapon", "armor", "horse"]:
		var t: Dictionary = tab.call("_gear_tile", slot)
		var p: Dictionary = t["parts"]
		var tile: Control = p["art"]
		_check(p["painting"], want[slot], false, Rect2(tile.position, tile.size), "the Family's %s tile" % slot)
		_ring(p["painting"], "family/gear_tile_ring", "the Family's %s tile" % slot)
		if want[slot] != "":
			_ok(p["gem"].get_index() > (p["painting"].get_meta("ring_node") as Node).get_index(),
				"the Family's %s stone is under the ring" % slot)
	vp.queue_free()


func _army() -> void:
	var vp := _host()
	var tab: Control = (load("res://scenes/tabs/army.gd") as GDScript).new()
	tab.size = Vector2(941, 1672)
	vp.add_child(tab)
	await process_frame
	var soldier := {"type": "gladiator", "tier": "rare", "attack": 215, "defense": 176, "might": 1420, "hp": 320,
		"equipped": {"weapon": _item("epic", "weapon"), "armor": _item("uncommon", "armor")}}
	tab.set("_army", {"slots": [{"index": 1, "soldier": soldier}], "totals": {"might": 5000}})
	tab.set("_selected", 1)
	tab.call("_paint")
	await process_frame
	var tiles: Array = tab.get("_gear_tiles")
	var want := ["epic", "uncommon", ""]
	for i in tiles.size():
		var p: Dictionary = tiles[i]["parts"]
		var tile: Control = p["art"]
		_check(p["painting"], want[i], false, Rect2(tile.position, tile.size), "the Army's %s tile" % ["weapon", "armor", "horse"][i])
		_ring(p["painting"], "army/gear_tile_ring", "the Army's gear tile")
	vp.queue_free()


func _shop() -> void:
	for batch in [TIERS.slice(0, 6), TIERS.slice(6, 7)]:
		var vp := _host()
		var tab: Control = (load("res://scenes/tabs/shop.gd") as GDScript).new()
		tab.size = Vector2(941, 1672)
		vp.add_child(tab)
		await process_frame
		var offers: Array = []
		for i in batch.size():
			offers.append({"slot": i, "purchased": false, "price": 1000, "power": 99, "item": _item(batch[i])})
		tab.set("_shop", {"offers": offers, "reroll_cost": 8, "can_afford_reroll": true, "rerolls_left": 20,
			"rerolls_per_day": 20, "seconds_left": 200})
		tab.set("_store", {"goods": []})
		tab.call("_paint")
		await process_frame
		var cards: Array = tab.get("_cards")
		for i in batch.size():
			var c: Dictionary = cards[i]
			_check(c["parts"]["painting"], batch[i], true, Rect2(Vector2.ZERO, Vector2(361, 247)), "the Market's %s card" % batch[i])
		vp.queue_free()


func _picker() -> void:
	var vp := _host()
	var items: Array = []
	for t in TIERS:
		items.append(_item(t, "weapon"))
	var picker: GDScript = load("res://scenes/pages/item_picker.gd")
	picker.call("pick", vp, "YOUR WEAPON", items, _item("special", "weapon"))
	await process_frame
	await process_frame
	var found := 0
	for g in _grounds(root):
		found += 1
		var pic: Control = null
		for sib in g.get_parent().get_children():
			if sib.has_meta("ground_node") and sib.get_meta("ground_node") == g:
				pic = sib
		if pic != null:
			_check(pic, str(g.get_meta("item_ground")), false, Rect2(16, 16, 144, 144), "the gear picker's row")
	_ok(found == TIERS.size() + 1, "the picker shows %d grounds, want %d" % [found, TIERS.size() + 1])
	for c in root.get_children():
		if c is CanvasLayer:
			c.queue_free()
	vp.queue_free()
	await process_frame


func _grounds(n: Node) -> Array:
	var out: Array = []
	for c in n.get_children():
		if c.has_meta("item_ground") and (c as CanvasItem).visible:
			out.append(c)
		out.append_array(_grounds(c))
	return out


func _collection() -> void:
	var vp := _host()
	var page: GDScript = load("res://scenes/pages/collection_page.gd")
	var inv := {"items": [_item("special", "horse"), _item("rare", "weapon")]}
	var p: Control = page.call("open", vp, inv, {})
	await process_frame
	var sets: Array = []
	for slot in ["weapon", "armor", "horse"]:
		for t in TIERS:
			var held: bool = slot == "weapon" or (slot == "armor" and t == "epic")
			sets.append({"slot": slot, "tier": t, "entries": [{"id": "%s_%s_1" % [t, slot], "name": "A " + t,
				"art": ARTS[t], "held": held}, {"id": "%s_%s_2" % [t, slot], "name": "B", "art": ARTS[t], "held": false}]})
	p.set_meta("wall", {"held": 8, "total": 42, "luck_bp": 100, "sets": sets})
	page.call("paint", p)
	await process_frame
	var cells: Array = p.get("parts").get("cell", [])
	var i := 0
	for slot in ["weapon", "armor", "horse"]:
		for t in TIERS:
			var held: bool = slot == "weapon" or (slot == "armor" and t == "epic")
			var parts: Dictionary = cells[i]["parts"]
			var cell: Control = cells[i]["node"]
			_check(parts["pic"], t if held else "", true, Rect2(Vector2.ZERO, cell.size), "the Collection's %s %s frame" % [t, slot])
			i += 1
	var offers := 0
	for g in _grounds(p):
		if bool(g.get_meta("soft", false)) and g.get_parent().get_parent() != null and g.size.x > 90:
			offers += 1
	_ok(offers >= 2, "the Collection's offers stand on their velvet (%d)" % offers)
	p.call("close")
	vp.queue_free()
	await process_frame


func _mail() -> void:
	var vp := _host()
	var mail: Control = (load("res://scenes/court/mail_view.gd") as GDScript).new()
	mail.size = Vector2(941, 1672)
	vp.add_child(mail)
	await process_frame
	var gear := {"kind": "item", "id": "d", "amount": 1, "tier": "legendary", "text": "Dawnward (Legendary)",
		"icon": "items/painted/armor_13"}
	var old := {"kind": "item", "id": "d", "amount": 1, "text": "Warden's Charger (Rare)", "icon": "items/painted/horse_07"}
	var stone := {"kind": "item", "id": "rare", "amount": 1, "tier": "rare", "text": "1 × Rare weapon", "icon": "item:rare"}
	var letter := {"id": 1, "kind": "gift", "sender": "The Crown", "title": "Gear", "body": "x",
		"created_at": "2026-09-14T08:00:00Z", "expires_in": 30 * 86400, "read": false, "claimed": false,
		"claimable": true, "lines": [gear, old, stone]}
	mail.call("paint", {"mail": [letter], "waiting": 1})
	await process_frame
	var rows: Array = _grounds(mail)
	_ok(rows.size() == 1 and str(rows[0].get_meta("item_ground")) == "legendary",
		"the mail row grounds only the piece that says its tier (%d)" % rows.size())
	mail.call("read_letter", letter)
	for k in 6:
		await process_frame
	# The card opens over the view (wherever the shell's overlays go): every
	# ground in the tree now, less the row's.
	var on_card := 0
	for g in _grounds(root):
		if rows.has(g):
			continue
		on_card += 1
		var pic: Control = null
		for sib in g.get_parent().get_children():
			if sib.has_meta("ground_node") and sib.get_meta("ground_node") == g:
				pic = sib
		if pic != null:
			var gc: Vector2 = g.position + g.size / 2.0
			var pc: Vector2 = pic.position + pic.size / 2.0
			_ok(gc.distance_to(pc) < 1.0, "the letter's ground stays on its piece after the card is laid out (%s vs %s)" % [gc, pc])
	_ok(on_card == 1, "the letter card grounds only the piece that says its tier (%d)" % on_card)
	for c in root.get_children():
		if c is CanvasLayer:
			c.queue_free()
	mail.queue_free()
	vp.queue_free()
	await process_frame


func _delivery() -> void:
	var vp := _host()
	var lines: Array = []
	for t in TIERS.slice(2, 7):
		lines.append({"kind": "item", "id": t, "amount": 1, "tier": t, "text": "A %s piece" % t,
			"icon": "items/painted/" + str(ARTS[t])})
	lines.append({"kind": "diamonds", "amount": 100, "text": "100 diamonds", "icon": "diamond"})
	var ceremony: GDScript = load("res://scenes/pages/ceremony.gd")
	ceremony.call("delivery", vp, {"title": "Gear", "lines": lines, "first_bonus": false, "vip_reached": 0})
	await create_timer(1.0).timeout
	var tiers := {}
	for c in root.get_children():
		if c is CanvasLayer:
			for g in _grounds(c):
				tiers[str(g.get_meta("item_ground"))] = true
	for c in vp.get_children():
		for g in _grounds(c):
			tiers[str(g.get_meta("item_ground"))] = true
	_ok(tiers.size() == 5, "the Royal Delivery grounds its five pieces and not the diamonds (%s)" % [tiers.keys()])
	vp.queue_free()
