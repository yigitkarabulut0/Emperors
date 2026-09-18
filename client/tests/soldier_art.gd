extends SceneTree
## A soldier looks like its type and its tier, and every tier has its painted
## numeral.
##
## There was one painting per type, so a tier VII gladiator was drawn as the
## tier I one, and only the villager had a large painting -- the others were
## the small card portrait blown up 1.7x in the selected soldier's window. The
## numerals existed for tiers I-III; IV to VII were a blank plate with the
## numeral set in type, and the selected soldier's large badge existed for I
## alone. Now each type has a rough, a fine and a gilded painting at both sizes
## (art/reference/soldiers_sheet.png), chosen by tier in SoldierArt, and the
## numerals are the sheet's own for all seven tiers, plain and fleur.
##
## Checked on the Army screen itself, built with a row of soldiers of every
## type and tier: each card, the selected soldier and the reroll panel draw
## the painting and numeral SoldierArt names, and no numeral is set in type.
##
## Run: godot --headless --path client --script tests/soldier_art.gd

const TIERS := ["common", "uncommon", "rare", "epic", "legendary", "mystic", "special"]
const TYPES := ["peasant", "mercenary", "gladiator"]
var _fails := 0
var _checked := 0


func _initialize() -> void:
	await process_frame
	var sa: GDScript = load("res://scripts/ui/soldier_art.gd")
	if sa == null:
		print("FAIL  SoldierArt does not exist")
		quit(1)
		return
	_looks_follow_the_tier(sa)
	_every_picture_exists_at_its_size(sa)
	_the_numerals_are_seven_and_centred(sa)
	await _the_army_draws_them(sa)
	await _the_reroll_panel_draws_them(sa)
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d soldiers and numerals drawn as their type and tier" % _checked)
	quit()


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)


func _looks_follow_the_tier(sa: GDScript) -> void:
	var want := {"common": "rough", "uncommon": "rough", "rare": "fine", "epic": "fine",
		"legendary": "gilded", "mystic": "gilded", "special": "gilded"}
	for t in TIERS:
		_checked += 1
		if sa.look(t) != want[t]:
			_fail("a %s soldier wears the %s look, want %s" % [t, sa.look(t), want[t]])
	# Every type is three different paintings, not one repainted.
	for type in TYPES:
		var seen := {}
		for t in ["common", "rare", "special"]:
			seen[sa.portrait(type, t)] = true
			seen[sa.large(type, t)] = true
		_checked += 1
		if seen.size() != 6:
			_fail("a %s has %d distinct pictures across rough, fine and gilded, want 6" % [type, seen.size()])
	_checked += 1
	if sa.portrait("dragon", "rare") != sa.portrait("peasant", "rare"):
		_fail("an unknown type is not drawn as a villager")


func _every_picture_exists_at_its_size(sa: GDScript) -> void:
	for type in TYPES:
		for t in TIERS:
			for pair in [[sa.portrait(type, t), Vector2i(133, 164)], [sa.large(type, t), Vector2i(202, 286)]]:
				var name: String = pair[0]
				_checked += 1
				if not name.contains(type):
					_fail("%s is not the %s's picture" % [name, type])
				var img := Image.load_from_file("res://assets/%s.png" % name)
				if img == null:
					_fail("%s does not exist" % name)
				elif img.get_size() != pair[1]:
					_fail("%s is %s, not the %s its window draws it at" % [name, img.get_size(), pair[1]])


## Seven plain and seven fleur numerals, each its own picture, each centred on
## its box so a badge sits in the same place on every card.
func _the_numerals_are_seven_and_centred(sa: GDScript) -> void:
	var seen := {}
	for tier in range(1, 8):
		for pair in [[sa.numeral(tier), Vector2i(50, 50)], [sa.numeral_large(tier), Vector2i(80, 124)]]:
			var name: String = pair[0]
			var img := Image.load_from_file("res://assets/%s.png" % name)
			_checked += 1
			if img == null:
				_fail("tier %d has no numeral %s" % [tier, name])
				continue
			if img.get_size() != pair[1]:
				_fail("%s is %s, want %s" % [name, img.get_size(), pair[1]])
			var key := img.get_data().hex_encode().sha256_text()
			if seen.has(key):
				_fail("%s is the same picture as %s" % [name, seen[key]])
			seen[key] = name
			# The badge itself -- its solid pixels, not the soft shadow the fleur
			# casts below it -- is at the middle of its box.
			var sx := 0.0
			var sy := 0.0
			var sw := 0.0
			for y in img.get_height():
				for x in img.get_width():
					if img.get_pixel(x, y).a > 0.9:
						sx += x + 0.5
						sy += y + 0.5
						sw += 1.0
			var c := Vector2(sx / sw, sy / sw)
			var mid := Vector2(img.get_size()) / 2.0
			if c.distance_to(mid) > 1.5:
				_fail("%s's badge sits at %s in its box, %.1f units off the middle %s" % [name, c, c.distance_to(mid), mid])
			if img.get_pixel(0, 0).a > 0.05 or img.get_pixel(img.get_width() - 1, img.get_height() - 1).a > 0.05:
				_fail("%s's corners are not clear: it would draw a square over the portrait" % name)


func _the_army_draws_them(sa: GDScript) -> void:
	var host := Control.new()
	host.size = Vector2(941, 1672)
	root.add_child(host)
	var screen: Control = load("res://scenes/tabs/army.gd").new()
	screen.size = host.size
	host.add_child(screen)
	for i in 3:
		await process_frame
	var slots: Array = []
	for i in 7:
		slots.append({"index": i + 1, "soldier": {"id": "s%d" % i, "type": TYPES[i % 3], "tier": TIERS[i],
			"attack": 500, "defense": 400, "ehp": 3000, "hp": 300, "equipped": {}, "reroll_cost": 20000}})
	slots.append({"index": 8, "soldier": null})
	screen.set("_army", {"slots": slots, "totals": {"might": 1000},
		"next_slot": {"index": 9, "cost": 1000, "unlocked": true}, "recruits": []})
	screen.call("_paint")
	await process_frame
	var cards: Array = screen.get("_cards")
	for i in 7:
		var p: Dictionary = cards[i]["parts"]
		_checked += 1
		_same(p["portrait"], sa.portrait(TYPES[i % 3], TIERS[i]), "card %d's portrait" % (i + 1))
		_same(p["numeral"], sa.numeral(i + 1), "card %d's numeral" % (i + 1))
		if not (p["numeral"] as Control).visible:
			_fail("card %d (tier %d) shows no numeral" % [i + 1, i + 1])
		_no_numeral_in_type(cards[i]["node"], "card %d" % (i + 1))
	var empty: Dictionary = cards[7]["parts"]
	_checked += 1
	if (empty["numeral"] as Control).visible:
		_fail("an empty slot's card shows a tier")

	var ui: Dictionary = screen.get("_ui")
	for i in 7:
		screen.call("_select", i + 1)
		await process_frame
		_checked += 1
		_same(screen.get("_sel_art"), sa.large(TYPES[i % 3], TIERS[i]), "selected soldier %d's portrait" % (i + 1))
		_same(ui["sel_numeral"], sa.numeral_large(i + 1), "selected soldier %d's badge" % (i + 1))
		var art: TextureRect = screen.get("_sel_art")
		if art.modulate != Color.WHITE:
			_fail("selected soldier %d is drawn dimmed" % (i + 1))
	_no_numeral_in_type(screen, "the Army screen")
	screen.call("_select", 8)
	await process_frame
	_checked += 1
	if (ui["sel_numeral"] as Control).visible:
		_fail("an empty slot selected shows a tier badge")
	if (screen.get("_sel_art") as TextureRect).modulate == Color.WHITE:
		_fail("an empty slot selected shows a soldier at full strength")
	# The badge's top fleur stays inside the ring, as the painting's I did.
	var badge := Rect2((ui["sel_numeral"] as Control).position, (ui["sel_numeral"] as Control).size)
	var ring := Rect2((ui["sel_frame"] as Control).position, (ui["sel_frame"] as Control).size)
	_checked += 1
	if not ring.encloses(badge):
		_fail("the selected soldier's badge %s runs out of its ring %s" % [badge, ring])
	host.queue_free()
	await process_frame


func _the_reroll_panel_draws_them(sa: GDScript) -> void:
	var host := Control.new()
	host.size = Vector2(941, 1672)
	root.add_child(host)
	var soldier := {"id": "s1", "type": "mercenary", "tier": "uncommon", "attack": 844, "defense": 687,
		"ehp": 6950, "hp": 180, "equipped": {}, "reroll_cost": 20835}
	var panel: Control = load("res://scenes/army/reroll_panel.gd").open(host, {"soldier": soldier,
		"odds": [], "name": "MERCENARY", "type": "mercenary"})
	for i in 3:
		await process_frame
	var card: Dictionary = panel.get("_card")
	_checked += 1
	_same(card["parts"]["portrait"], sa.portrait("mercenary", "uncommon"), "the reroll card's portrait")
	_same(card["parts"]["numeral"], sa.numeral(2), "the reroll card's numeral")
	_same(panel.get("_big"), sa.numeral_large(2), "the reroll panel's big numeral")
	# A roll lands legendary: the card turns gilded and the numerals follow.
	var legendary := soldier.duplicate()
	legendary["tier"] = "legendary"
	panel.set("_soldier", legendary)
	panel.set("_tier", 5)
	panel.call("_paint")
	_checked += 1
	_same(card["parts"]["portrait"], sa.portrait("mercenary", "legendary"), "the reroll card after a legendary roll")
	_same(panel.get("_big"), sa.numeral_large(5), "the big numeral after a legendary roll")
	_no_numeral_in_type(panel, "the reroll panel")
	panel.call("_close")
	host.queue_free()
	await process_frame


func _same(node: Variant, asset: String, what: String) -> void:
	var t: Texture2D = (node as TextureRect).texture if node is TextureRect else null
	if t == null or t.resource_path != "res://assets/%s.png" % asset:
		_fail("%s is %s, want %s" % [what, t.resource_path if t != null else "nothing", asset])


## No Roman numeral is set in type as a tier badge any more: every one is painted.
func _no_numeral_in_type(root_node: Node, where: String) -> void:
	var stack: Array = [root_node]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if n is Label and (n as Label).visible and (n as Label).text in ["I", "II", "III", "IV", "V", "VI", "VII"]:
			_fail("%s sets the numeral \"%s\" in type" % [where, (n as Label).text])
