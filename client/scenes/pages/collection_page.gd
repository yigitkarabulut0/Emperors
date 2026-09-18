extends RefCounted
## THE COLLECTION — one of every design, given to the wall for good, paid in
## luck on every roll.
##
## It was a list of item names in a dialog, eight at most, offering pieces the
## wall would refuse. Here it is the wall: every design in the game by slot and
## tier, the ones held lit and the ones still to find dark, the luck it all adds
## up to, and the pieces in the bags the wall would take -- nobody is wearing
## them and their design is not on it yet.
##
## Now it is its own painting (art/reference/collection.png, layout
## client/layout/collection.json) on the painted pages' host. Its three panels
## have a rarity frame for each tier, common to special, so each frame is a
## tier's set of three designs: the grandest of them on the wall stands in it,
## lit, how many of the three are held under it, and a tap names them. The
## offers are rows cut from the painting's own, DONATE on each.

const PAGE := "collection"
const SLOTS := [["weapon", "WEAPONS"], ["armor", "ARMOR"], ["horse", "HORSES"]]
const TIERS := ["common", "uncommon", "rare", "epic", "legendary", "mystic", "special"]
## A design not on the wall yet: its shape in the dark of the frame.
const UNHELD := Color(0.08, 0.1, 0.14, 0.9)
## The velvet's rects, measured off collection.png: a rarity frame's window
## (x 82..158, y 638..706 for the frame at 72,625 -- inside its gold, clear of
## its corner filigree) and the gold frame on an offer row (collection/row).
const CELL_GROUND := Rect2(8, 11, 80, 72)
const OFFER_GROUND := Rect2(44, 20, 98, 90)


## `inventory` is /v1/inventory's answer, for the offers. `opts` goes to
## PaintedPage.open (a test's inset).
static func open(host: Node, inventory: Dictionary, opts: Dictionary = {}) -> PaintedPage:
	var p := PaintedPage.open(host, PAGE, opts)
	p.set_meta("inventory", inventory)
	p.set_meta("wall", {})
	var cells: Array = p.parts.get("cell", [])
	for i in cells.size():
		var tap: BaseButton = cells[i]["parts"]["tap"]
		tap.pressed.connect(func() -> void:
			if bool(p.get("_armed")):
				_name_the_set(p, i))
	p.set_shown("offers_empty", false)
	_load(p)
	return p


static func _pct(bp: int) -> String:
	return (str(bp / 100) if bp % 100 == 0 else "%.1f" % (bp / 100.0)) + "%"


static func _load(p: PaintedPage) -> void:
	var res: Api.Response = await Api.get_json("/v1/collection")
	if not is_instance_valid(p):
		return
	if not res.ok:
		p.set_text("luck", "The Collection could not be read.", 18).label_settings.font_color = UI.RED
		p.set_text("luck_note", res.error, 14)
		return
	p.set_meta("wall", res.data)
	paint(p)


## The wall and the offers, from the wall already read.
static func paint(p: PaintedPage) -> void:
	var wall: Dictionary = p.get_meta("wall")
	p.set_text("luck", "%d of %d designs  ·  +%s luck on every roll" % [int(wall.get("held", 0)),
		int(wall.get("total", 0)), _pct(int(wall.get("luck_bp", 0)))], 18).label_settings.font_color = UI.GOLD
	p.set_text("luck_note", "Each design adds %s; all three of a slot and tier, %s more." % [
		_pct(int(wall.get("luck_per_piece_bp", 0))), _pct(int(wall.get("luck_per_set_bp", 0)))], 14)
	var cells: Array = p.parts.get("cell", [])
	for s in SLOTS.size():
		for t in TIERS.size():
			var i := s * TIERS.size() + t
			if i < cells.size():
				_paint_cell(cells[i]["parts"], _set_of(wall, str(SLOTS[s][0]), TIERS[t]))
	_paint_offers(p, wall)


static func _set_of(wall: Dictionary, slot: String, tier: String) -> Dictionary:
	for set in wall.get("sets", []):
		if str(set.get("slot", "")) == slot and str(set.get("tier", "")) == tier:
			return set
	return {}


## A tier's frame: the grandest of its designs on the wall (the last held, in
## the balance's order), or, while none is, the first one dark; and n/3 under it.
static func _paint_cell(parts: Dictionary, set: Dictionary) -> void:
	var entries: Array = set.get("entries", [])
	var shown: Dictionary = entries[0] if not entries.is_empty() else {}
	var held := 0
	for e in entries:
		if bool(e.get("held", false)):
			held += 1
			shown = e
	var pic: TextureRect = parts["pic"]
	pic.texture = Art.item(str(shown.get("art", ""))) if not shown.is_empty() else null
	pic.modulate = Color.WHITE if held > 0 else UNHELD
	# The frame's velvet, soft inside the painted frame's window (clear of its
	# corner ornaments), once a design of it is held: an unheld frame keeps its
	# dark window, as an empty gear slot keeps its empty tile.
	ItemGround.under(pic, str(set.get("tier", "")) if held > 0 else "", CELL_GROUND, true)
	var count: Label = parts["count"]
	count.text = "%d/%d" % [held, entries.size()] if not entries.is_empty() else ""
	count.label_settings.font_color = UI.GOLD if held > 0 and held == entries.size() \
		else (UI.INK if held > 0 else UI.DIM)


## The three designs of the frame tapped: held ones by name, the rest a mark.
static func _name_the_set(p: PaintedPage, i: int) -> void:
	var s: Array = SLOTS[i / TIERS.size()]
	var tier: String = TIERS[i % TIERS.size()]
	var set := _set_of(p.get_meta("wall"), str(s[0]), tier)
	if set.is_empty():
		return
	var lines: Array = []
	for e in set.get("entries", []):
		lines.append(("✓  " + str(e.get("name", ""))) if bool(e.get("held", false)) else "?  Not on the wall yet")
	var complete := bool(set.get("complete", false))
	await Dialog.ask(p, {"title": "%s  ·  %s" % [str(s[1]), tier.to_upper()],
		"body": "\n".join(lines) + ("\n\nThe set is complete." if complete else ""), "confirm_text": "OK"})


## The pieces in the bags the wall would take: nobody wears them and their
## design is not on it. Grandest first.
static func _paint_offers(p: PaintedPage, wall: Dictionary) -> void:
	var held := {}
	for set in wall.get("sets", []):
		for e in set.get("entries", []):
			if bool(e.get("held", false)):
				held[str(e.get("def_id", ""))] = true
	var offer: Array = []
	var seen := {}
	for it in (p.get_meta("inventory") as Dictionary).get("items", []):
		var def := str(it.get("def_id", ""))
		if str(it.get("equipped_on", "")) != "" or held.has(def) or seen.has(def):
			continue
		seen[def] = true
		offer.append(it)
	offer.sort_custom(func(a, b): return TIERS.find(str(a.get("tier", ""))) > TIERS.find(str(b.get("tier", ""))))

	var content := p.content("offers")
	for c in content.get_children():
		c.queue_free()
	var tpl := Layout.find(PAGE, "offer")
	var pitch := float(tpl.get("pitch", 135))
	var row_h := Layout.rect_of(tpl).size.y
	for i in offer.size():
		var it: Dictionary = offer[i]
		var built := Layout.instantiate(tpl)
		built["node"].position = Vector2(0, i * pitch)
		built["node"].set_meta("parts", built["parts"])
		content.add_child(built["node"])
		var parts: Dictionary = built["parts"]
		for part in tpl.get("parts", []):
			if str(part.get("kind", "")) == "text":
				parts[str(part["id"])].set_meta("box_w", Layout.rect_of(part).size.x)
		(parts["pic"] as TextureRect).texture = Art.item(str(it.get("art", "")))
		ItemGround.under(parts["pic"], str(it.get("tier", "")), OFFER_GROUND, true)
		_fit_line(parts["name"], str(it.get("name", "")), 18)
		_fit_line(parts["detail"], "%s %s" % [str(it.get("tier", "")).to_upper(), str(it.get("slot", "")).to_upper()], 14)
		var id := str(it.get("id", ""))
		var name := str(it.get("name", ""))
		(parts["donate"] as BaseButton).pressed.connect(func() -> void:
			if bool(p.get("_armed")):
				await _donate(p, id, name))
	var sc := p.node("offers") as ScrollContainer
	content.custom_minimum_size.y = maxf(sc.size.y, offer.size() * pitch - (pitch - row_h))
	p.set_shown("offers_empty", offer.is_empty())
	if offer.is_empty():
		p.set_text("offers_empty", "Nothing new in your bags: every piece you hold is on the wall already, or worn.", 18)


## A row's words at the layout's size, down to `min_size`, then an ellipsis.
static func _fit_line(l: Label, text: String, min_size: int) -> void:
	var painted := int(l.get_meta("painted_size", l.label_settings.font_size))
	l.set_meta("painted_size", painted)
	l.label_settings.font_size = painted
	l.text = text
	UI.fit_line(l, painted, min_size)


static func _donate(p: PaintedPage, id: String, name: String) -> void:
	if not await Dialog.ask(p, {"title": "Give %s to the wall?" % name,
			"body": "The piece is gone for good; its design stays on the wall and adds its luck to every roll.",
			"confirm_text": "Donate"}):
		return
	var res: Api.Response = await GameState.act("/v1/collection/donate", {"item_id": id})
	if not res.ok or not is_instance_valid(p):
		return
	GameState.toast("%s is on the wall" % name)
	var inv: Api.Response = await Api.get_json("/v1/inventory")
	if inv.ok and is_instance_valid(p):
		p.set_meta("inventory", inv.data)
	if is_instance_valid(p):
		_load(p)
