extends SceneTree
## The Army's selected soldier's name, its tier chip and the next-slot price:
## each in the painting's type, in its box, at one size.
##
## The name was built round its sample at 34/700, 181 wide in a box of 150,
## and every name was fitted to a chip pinned at 553: VILLAGER came out at 28
## (the painting's is 29), GLADIATOR at 23 and MERCENARY at 22, and EMPTY SLOT,
## never fitted, kept whichever size the soldier before it had. The chip's
## TIER III and TIER VII ran into its rims. The next-slot price was set at
## 34/700 against the painting's 26/400, and 76,076 ran from the coin's rim to
## the tile's frame. What must hold:
##  - every name, EMPTY SLOT included and whatever was selected before it, is
##    set at the layout's size, fits its box, and the label is its box's width;
##  - the chip follows the name at the painting's gap, holds every tier word
##    at the chip's own size with the painting's room round it, and ends clear
##    of the troop column -- with MERCENARY, the longest name, too;
##  - the next-slot price, for every real slot cost and state, is set at the
##    painting's size and stays inside the tile's frame.
##
## Run: godot --headless --path client --script tests/army_title_fit.gd
##
## The Army tab is loaded at run time, never named as a class here.

const TIERS := ["common", "uncommon", "rare", "epic", "legendary", "mystic", "special"]
## balance/soldiers.json's slot costs, as UI.short_number sets them: the widest
## is six characters ("76,076"), then the level gate and FREE.
const NEXT_SLOTS := [{"unlocked": true, "cost": 500}, {"unlocked": true, "cost": 18103},
	{"unlocked": true, "cost": 76076}, {"unlocked": true, "cost": 155956}, {"unlocked": true, "cost": 319709},
	{"unlocked": false, "level_gate": 37}, {"unlocked": true, "free": true}]
## The next-slot tile's inner frame, in the tile: 918 on the painting, cut from 778.
const TILE_FRAME_X := 140.0
## The painting's eight units from VILLAGER's ink to the chip, less Cinzel's
## margin after the R; and ten units short of the troop column's divider (716).
const CHIP_GAP := 6.0
const CHIP_RIGHT := 706.0

var _fails := 0
var _checked := 0


func _initialize() -> void:
	await process_frame
	root.get_node("Env").set("api_base_url", "http://127.0.0.1:9")
	var vp := SubViewport.new()
	vp.size = Vector2i(941, 1672)
	root.add_child(vp)
	root.get_node("Nav").set("host", vp)
	var tab: Control = (load("res://scenes/tabs/army.gd") as GDScript).new()
	tab.size = Vector2(941, 1672)
	vp.add_child(tab)
	await process_frame
	var layout: GDScript = load("res://scripts/ui/layout.gd")
	var name_part: Dictionary = layout.call("element", "army", "sel_name")
	var chip_part: Dictionary = layout.call("element", "army", "sel_tier_chip")
	var word_part: Dictionary = layout.call("element", "army", "sel_tier_text")
	var ui: Dictionary = tab.get("_ui")
	var l: Label = ui["sel_name"]
	var chip: Control = ui["sel_tier_chip"]
	var word: Label = ui["sel_tier_text"]
	var box: float = float(name_part["rect"][2])
	var want_size := int(name_part["size"])
	var chip_w: float = float(chip_part["rect"][2])
	var word_size := int(word_part["size"])
	# An empty slot first, then every type, then the empty slot again after the
	# longest name: EMPTY SLOT must not take the size of whoever came before.
	var slots := [{"index": 1}]
	var types := ["peasant", "mercenary", "gladiator"]
	for i in types.size():
		slots.append({"index": i + 2, "soldier": {"type": types[i], "tier": "common", "attack": 215, "defense": 176, "might": 1420, "hp": 320, "equipped": {}}})
	tab.set("_army", {"slots": slots, "totals": {"might": 5000}})
	for index in [1, 2, 3, 4, 1]:
		tab.set("_selected", index)
		tab.call("_paint_selected")
		var what := l.text
		_checked += 1
		if l.label_settings.font_size != want_size:
			_fail("%s is set at %d, not the layout's %d" % [what, l.label_settings.font_size, want_size])
		var adv := _advance(l, l.text)
		if adv > box + 0.5:
			_fail("%s is %.0f wide in a box of %.0f" % [what, adv, box])
		if absf(l.size.x - box) > 0.5:
			_fail("%s's label is %.0f wide, its box %.0f" % [what, l.size.x, box])
		if chip.visible:
			var want_x := roundf(l.position.x + adv + CHIP_GAP)
			if absf(chip.position.x - want_x) > 0.5:
				_fail("%s's tier chip stands at %.0f, not after the name at %.0f" % [what, chip.position.x, want_x])
	# The painting's own VILLAGER: ink 142 wide from 404, 21 tall. Cinzel 29 at
	# the lifted 550 is 21 tall with the painting's 4-unit stems, and 150 to its
	# advance (its letters are set a little wider than the painting's).
	tab.set("_selected", 2)
	tab.call("_paint_selected")
	_checked += 1
	var villager := _advance(l, "VILLAGER")
	if absf(villager - 150.0) > 3.0 or absf(l.position.x - 403.0) > 1.0:
		_fail("VILLAGER is %.0f to its advance from x %.0f; the painting's is 150 from 403" % [villager, l.position.x])
	# Every tier word after the longest name.
	var room := chip_w - _advance(word, "TIER I")
	for t in TIERS:
		slots[2]["soldier"]["tier"] = t
		tab.set("_selected", 3)
		tab.call("_paint_selected")
		_checked += 1
		var ww := word.text
		if word.label_settings.font_size != word_size:
			_fail("MERCENARY's %s is set at %d, not the chip's %d" % [ww, word.label_settings.font_size, word_size])
		var need := _advance(word, ww) + room
		if chip.size.x + 0.5 < need:
			_fail("the chip is %.0f round %s, which needs %.0f to keep the painting's room" % [chip.size.x, ww, need])
		if chip.position.x + chip.size.x > CHIP_RIGHT + 0.5:
			_fail("the chip round %s ends at %.0f, past %.0f" % [ww, chip.position.x + chip.size.x, CHIP_RIGHT])
		if absf(word.size.x - chip.size.x) > 0.5 or absf(word.position.x - chip.position.x - (float(word_part["rect"][0]) - float(chip_part["rect"][0]))) > 0.5:
			_fail("%s is not centred on its chip" % ww)
	# The next-slot price.
	var nc_parts: Dictionary = {}
	for ns in NEXT_SLOTS:
		tab.set("_army", {"slots": slots, "totals": {}, "next_slot": ns})
		tab.call("_paint")
		var nc: Dictionary = tab.get("_next_card")
		nc_parts = nc["parts"]
		var price: Label = nc_parts["price"]
		_checked += 1
		var pw := _advance(price, price.text)
		var pbox := float(price.get_meta("box_w", -1.0))
		if price.label_settings.font_size != 26:
			_fail("the next slot's %s is set at %d, not the painting's 26" % [price.text, price.label_settings.font_size])
		if pw > pbox + 0.5 or absf(price.size.x - pbox) > 0.5:
			_fail("the next slot's %s is %.0f wide, its label %.0f, in a box of %.0f" % [price.text, pw, price.size.x, pbox])
		if price.position.x + price.size.x > TILE_FRAME_X + 0.5:
			_fail("the next slot's %s runs to %.0f, past the tile's frame at %.0f" % [price.text, price.position.x + price.size.x, TILE_FRAME_X])
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d Army titles and prices: one size each, in their boxes, the chip after the name" % _checked)
	quit()


func _advance(l: Label, text: String) -> float:
	var s := l.label_settings
	return s.font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, s.font_size).x


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)
